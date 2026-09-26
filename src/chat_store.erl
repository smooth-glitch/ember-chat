%%% Durable storage for messages and groups, backed by Mnesia (part of
%%% stock OTP -- no external dependency, consistent with the rest of this
%%% app). Without this, every conversation and group lived only in the
%%% chat_room/chat_groups process state, gone the moment the node restarted.
%%%
%%% Keeps the persistence concern in one place: callers never touch Mnesia
%%% records directly, only the plain tuples/values returned here.
-module(chat_store).
-export([init/0, save_message/5, save_message/6, load_history/1, dm_key/2,
         save_group/3, delete_group/1, load_groups/0, toggle_reaction/3,
         delete_message/2, edit_message/3, post_status/4, dm_partners/1, list_statuses/0, view_status/2, delete_status/2, set_ttl/2, get_ttl/1, set_group_meta/3, get_group_meta/1, get_expires/1, sweep/0,
         save_link_preview/2, find_or_create_account/3,
         set_pubkey/2, get_pubkey/1, set_avatar/2, set_status/2, get_profile/1, set_last_seen/1, get_last_seen/1]).

-record(chat_message, {id, conv_key, from, text, kind, private, ts, reactions = [], preview = [], reply_to = [], deleted = false, edited = false, expires = undefined}).
-record(status_post, {id, user, kind, content, bg = 0, ts, expires, viewers = []}).
-record(conv_setting, {conv_key, ttl = 0, description = [], icon = []}).
-record(chat_group, {name, owner, members}).
%% Key is {Provider, Sub} (e.g. {google, "10769150350006150715"}) -- Sub is
%% the provider's own stable subject id, never the email (people can change
%% the email on a Google/Apple account; sub is documented by both as the
%% one claim guaranteed never to be reassigned to a different person).
-record(chat_account, {key, username}).
%% One row per username, persisted across reconnects (unlike presence,
%% which lives only in chat_room's in-memory state). pubkey is the user's
%% X25519 public key (base64) for DM end-to-end encryption -- see
%% CryptoBox.swift; a user who hasn't published one yet (older client, or
%% hasn't opened the app since this shipped) has pubkey = undefined, and
%% DMs to them fall back to plaintext with that fact surfaced in the UI
%% rather than silently pretending to encrypt.
-record(user_profile, {username, pubkey = undefined, avatar_url = undefined, status = undefined, last_seen = undefined}).

-define(HISTORY_LIMIT, 50).

init() ->
    case mnesia:create_schema([node()]) of
        ok -> ok;
        {error, {_, {already_exists, _}}} -> ok
    end,
    ok = application:ensure_started(mnesia),
    ensure_table(chat_message, record_info(fields, chat_message),
                 [{disc_copies, [node()]}, {index, [#chat_message.conv_key]}]),
    ensure_table(chat_group, record_info(fields, chat_group),
                 [{disc_copies, [node()]}]),
    ensure_table(chat_account, record_info(fields, chat_account),
                 [{disc_copies, [node()]}]),
    ensure_table(user_profile, record_info(fields, user_profile),
                 [{disc_copies, [node()]}]),
    ensure_table(conv_setting, record_info(fields, conv_setting),
                 [{disc_copies, [node()]}]),
    ensure_table(status_post, record_info(fields, status_post),
                 [{disc_copies, [node()]}]),
    ok = mnesia:wait_for_tables([chat_message, chat_group, chat_account, user_profile, conv_setting, status_post], 10000),
    migrate_preview_shape(),
    init_id_counters(),
    ok.

%% Ids must keep increasing across server restarts. erlang:unique_integer/1
%% restarts from 1 with every VM start, so after a restart new messages
%% reused old ids: they silently overwrote the stored message with that id
%% and sorted to the top of history. Instead resume from the highest id
%% already on disk.
init_id_counters() ->
    lists:foreach(
        fun(Table) ->
            Max = lists:max([0 | [K || K <- mnesia:dirty_all_keys(Table), is_integer(K)]]),
            Ref = atomics:new(1, []),
            atomics:put(Ref, 1, Max),
            persistent_term:put({?MODULE, id_counter, Table}, Ref)
        end, [chat_message, status_post]).

next_id(Table) ->
    atomics:add_get(persistent_term:get({?MODULE, id_counter, Table}), 1, 1).

%% Preview used to be stored as a 3-tuple {Title, Description, Image}; it's
%% now {Url, Title, Description, Image} so the url travels with the rest of
%% the preview instead of as a separate live-push argument (see
%% chat_link_preview.erl). transform_table/3 only rewrites the *record*
%% shape, not values nested inside a field, so any preview persisted before
%% that change is still the old 3-tuple on disk and crashes preview_fields/1
%% the moment it's read. The lost Url can't be recovered for these -- they
%% predate it being stored at all -- so they get "" rather than being
%% dropped entirely.
migrate_preview_shape() ->
    Old = mnesia:dirty_select(chat_message,
        [{#chat_message{id = '$1', preview = '$2', _ = '_'},
          [{'==', {tuple_size, '$2'}, 3}],
          ['$1']}]),
    lists:foreach(
        fun(Id) ->
            case mnesia:dirty_read(chat_message, Id) of
                [Msg = #chat_message{preview = {Title, Description, Image}}] ->
                    mnesia:dirty_write(Msg#chat_message{preview = {"", Title, Description, Image}});
                _ ->
                    ok
            end
        end, Old).

ensure_table(Name, Fields, Opts) ->
    case mnesia:create_table(Name, [{attributes, Fields} | Opts]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Name}} -> migrate_if_needed(Name, Fields)
    end.

%% A table created by an earlier version of this module (before a record
%% gained a field) keeps its on-disk shape until told otherwise -- without
%% this, adding `reactions` to #chat_message{} would make every already
%% hot-loaded read/write on the existing table fail. transform_table/3
%% rewrites each record to the new shape in place; nothing here throws away
%% data that was already persisted. Any newly-added field defaults to `[]`,
%% which is the right default for reactions and safe as a general default.
migrate_if_needed(Name, CurrentFields) ->
    case mnesia:table_info(Name, attributes) of
        CurrentFields ->
            ok;
        _OldFields ->
            %% A disc table isn't readable until it has loaded; transforming
            %% before that aborts with no_exists.
            ok = mnesia:wait_for_tables([Name], 30000),
            NewSize = length(CurrentFields) + 1, %% +1 for the record-name element
            {atomic, ok} = mnesia:transform_table(Name,
                fun(Rec) ->
                    OldVals = tuple_to_list(Rec),
                    Missing = NewSize - length(OldVals),
                    list_to_tuple(OldVals ++ lists:duplicate(max(0, Missing), []))
                end, CurrentFields),
            ok
    end.

%% Canonical key for a 1:1 conversation -- sorted so it's the same
%% regardless of which side is asking, e.g. dm_key("bob","alice") ==
%% dm_key("alice","bob").
dm_key(A, B) ->
    [First, Second] = lists:sort([A, B]),
    "dm:" ++ First ++ "|" ++ Second.

%% Everyone User has a live (non-expired) 1:1 conversation with, most recent
%% first, as [{Partner, LastMessageTs}]. Lets a client rebuild its chat list
%% after a relaunch. Scans the message table (fine at this project's scale;
%% a per-user index would be the next step for a large deployment).
dm_partners(User) ->
    Now = erlang:system_time(millisecond),
    Rows = mnesia:dirty_select(chat_message,
        [{#chat_message{conv_key = '$1', ts = '$2', expires = '$3', _ = '_'}, [], [['$1', '$2', '$3']]}]),
    ByPartner = lists:foldl(
        fun([Key, Ts, Exp], Acc) ->
            Expired = is_integer(Exp) andalso Exp =< Now,
            case {Expired, dm_partner(Key, User)} of
                {false, Partner} when Partner =/= none ->
                    T = case Ts of I when is_integer(I) -> I; _ -> 0 end,
                    maps:update_with(Partner, fun(Old) -> max(Old, T) end, T, Acc);
                _ -> Acc
            end
        end, #{}, Rows),
    lists:reverse(lists:keysort(2, maps:to_list(ByPartner))).

dm_partner("dm:" ++ Rest, User) ->
    case string:split(Rest, "|") of
        [User, B] -> B;
        [A, User] -> A;
        _ -> none
    end;
dm_partner(_, _) -> none.

%% Kind is 'chat' | 'group_message' (system/presence notices are transient
%% and deliberately not persisted -- they'd bloat storage fast in a busy
%% room and add nothing worth replaying). Returns the new message's id, so
%% callers can thread it through to live pushes for reactions to target.
save_message(ConvKey, From, Text, Kind, Private) ->
    save_message(ConvKey, From, Text, Kind, Private, []).

%% ReplyTo is [] (not a reply) or the id of the message being replied to.
%% Deliberately just an id, not a denormalized copy of the original sender/
%% text: the client already keeps every rendered message in a local map
%% (messagesById), so it can render the quoted snippet from its own cache
%% without this module duplicating (and risking going stale on) that data.
save_message(ConvKey, From, Text, Kind, Private, ReplyTo) ->
    Id = next_id(chat_message),
    Now = erlang:system_time(millisecond),
    Expires = case get_ttl(ConvKey) of
        0 -> undefined;
        Secs -> Now + Secs * 1000
    end,
    Msg = #chat_message{id = Id, conv_key = ConvKey, from = From, text = Text,
                         kind = Kind, private = Private, ts = Now,
                         reply_to = ReplyTo, expires = Expires},
    ok = mnesia:dirty_write(Msg),
    Id.

%% Last ?HISTORY_LIMIT messages for a conversation, oldest first, as plain
%% {Id, From, Text, Private, Reactions, Preview, ReplyTo} tuples -- callers
%% never need the Mnesia record. Reactions is a [{User, Emoji}] list;
%% Preview is [] (none yet, or never will be) or {Url, Title, Description,
%% Image}; ReplyTo is [] (not a reply) or the id of the original message.
load_history(ConvKey) ->
    Now = erlang:system_time(millisecond),
    Records = [R || R <- mnesia:dirty_index_read(chat_message, ConvKey, #chat_message.conv_key),
                    not is_expired(R, Now)],
    Sorted = lists:keysort(#chat_message.id, Records),
    Len = length(Sorted),
    Trimmed = lists:nthtail(max(0, Len - ?HISTORY_LIMIT), Sorted),
    [{R#chat_message.id, R#chat_message.from, R#chat_message.text,
      R#chat_message.private, R#chat_message.reactions, R#chat_message.preview,
      R#chat_message.reply_to, R#chat_message.deleted =:= true,
      case R#chat_message.ts of T when is_integer(T) -> T; _ -> 0 end,
      R#chat_message.edited =:= true,
      case R#chat_message.expires of E when is_integer(E) -> E; _ -> 0 end} || R <- Trimmed].

is_expired(#chat_message{expires = E}, Now) when is_integer(E) -> E =< Now;
is_expired(_, _) -> false.

%% Disappearing-messages timer for a conversation, in seconds (0 = off).
%% Applies to messages saved from now on; older ones keep whatever expiry
%% (or none) they were saved with.
set_ttl(ConvKey, Secs) ->
    ok = mnesia:dirty_write((setting_or_new(ConvKey))#conv_setting{ttl = Secs}).

setting_or_new(ConvKey) ->
    case mnesia:dirty_read(conv_setting, ConvKey) of
        [S] -> S;
        [] -> #conv_setting{conv_key = ConvKey}
    end.

%% Group description + icon URL, kept beside the timer setting so editing
%% either never clobbers the other (and group membership rewrites, which
%% replace the whole chat_group row, never touch them). Unset reads as "".
set_group_meta(ConvKey, Description, Icon) ->
    ok = mnesia:dirty_write((setting_or_new(ConvKey))#conv_setting{description = Description, icon = Icon}).

get_group_meta(ConvKey) ->
    #conv_setting{description = D, icon = I} = setting_or_new(ConvKey),
    {case D of L when is_list(L) -> L; _ -> "" end,
     case I of L2 when is_list(L2) -> L2; _ -> "" end}.

get_ttl(ConvKey) ->
    case mnesia:dirty_read(conv_setting, ConvKey) of
        [#conv_setting{ttl = T}] when is_integer(T) -> T;
        _ -> 0
    end.

get_expires(MessageId) ->
    case mnesia:dirty_read(chat_message, MessageId) of
        [#chat_message{expires = E}] when is_integer(E) -> E;
        _ -> 0
    end.

%% Permanently removes messages whose timer has run out. Clients hide
%% expired messages themselves at the same instant; this just reclaims
%% storage (and guarantees they never come back in a later history load).
sweep() ->
    Now = erlang:system_time(millisecond),
    Expired = mnesia:dirty_select(chat_message,
        [{#chat_message{expires = '$1', _ = '_'},
          [{is_integer, '$1'}, {'=<', '$1', Now}], ['$_']}]),
    lists:foreach(fun(R) -> mnesia:dirty_delete(chat_message, R#chat_message.id) end, Expired),
    ExpiredStatuses = mnesia:dirty_select(status_post,
        [{#status_post{expires = '$1', _ = '_'}, [{'=<', '$1', Now}], ['$_']}]),
    lists:foreach(fun(R) -> mnesia:dirty_delete(status_post, R#status_post.id) end, ExpiredStatuses),
    length(Expired) + length(ExpiredStatuses).

%% ---- status updates ("stories"): visible to everyone for 24 hours ----
-define(STATUS_TTL_MS, 24 * 60 * 60 * 1000).

%% Kind is "text" (Content = the text, Bg = palette index) or "image"
%% (Content = an uploaded image URL). Returns the new post's id.
post_status(User, Kind, Content, Bg) ->
    Id = next_id(status_post),
    Now = erlang:system_time(millisecond),
    ok = mnesia:dirty_write(#status_post{id = Id, user = User, kind = Kind, content = Content,
                                          bg = Bg, ts = Now, expires = Now + ?STATUS_TTL_MS}),
    {ok, status_item(hd(mnesia:dirty_read(status_post, Id)))}.

%% Live posts, oldest first: [{Id, User, Kind, Content, Bg, Ts, Exp, Viewers}].
list_statuses() ->
    Now = erlang:system_time(millisecond),
    All = mnesia:dirty_select(status_post,
        [{#status_post{expires = '$1', _ = '_'}, [{'>', '$1', Now}], ['$_']}]),
    [status_item(R) || R <- lists:keysort(#status_post.id, All)].

status_item(#status_post{id = I, user = U, kind = K, content = C, bg = B, ts = T, expires = E, viewers = V}) ->
    {I, U, K, C, B, T, E, V}.

%% Records that Viewer saw the post (once; the owner's own views don't
%% count). Returns {ok, Owner, NewlyRecorded} so the owner can be told.
view_status(Id, Viewer) ->
    case mnesia:dirty_read(status_post, Id) of
        [P = #status_post{user = Owner, viewers = V}] when Owner =/= Viewer ->
            case lists:member(Viewer, V) of
                true -> {ok, Owner, false};
                false ->
                    ok = mnesia:dirty_write(P#status_post{viewers = V ++ [Viewer]}),
                    {ok, Owner, true}
            end;
        [#status_post{user = Owner}] -> {ok, Owner, false};
        [] -> {error, not_found}
    end.

delete_status(Id, User) ->
    case mnesia:dirty_read(status_post, Id) of
        [#status_post{user = User}] -> mnesia:dirty_delete(status_post, Id), ok;
        [_] -> {error, forbidden};
        [] -> {error, not_found}
    end.

%% Replaces the text of the sender's own, not-yet-deleted message. Same
%% ownership rule as delete_message/2, enforced here. Any cached link
%% preview is dropped since it described the old text.
edit_message(MessageId, User, NewText) ->
    case mnesia:dirty_read(chat_message, MessageId) of
        [Msg = #chat_message{from = User, deleted = D}] when D =/= true ->
            ok = mnesia:dirty_write(Msg#chat_message{text = NewText, edited = true, preview = []}),
            {ok, edited};
        [#chat_message{from = User}] ->
            {error, deleted};
        [#chat_message{}] ->
            {error, forbidden};
        [] ->
            {error, not_found}
    end.

%% Deletes a message for everyone -- only the original sender may delete
%% their own message (enforced here, not just client-side, so a malicious
%% client can't wipe someone else's message by guessing an id). The row
%% stays (so ids/history ordering and any reply-quotes pointing at it don't
%% dangle), text is cleared, and `deleted` is set so clients render "This
%% message was deleted" instead of the original content.
delete_message(MessageId, User) ->
    case mnesia:dirty_read(chat_message, MessageId) of
        [Msg = #chat_message{from = User}] ->
            ok = mnesia:dirty_write(Msg#chat_message{text = "", deleted = true}),
            {ok, deleted};
        [#chat_message{}] ->
            {error, forbidden};
        [] ->
            {error, not_found}
    end.

%% Attaches a fetched link preview to an already-persisted message, so it
%% shows up in history without being re-fetched (and without re-exposing
%% the SSRF-checked fetch on every history load).
save_link_preview(MessageId, Preview) ->
    case mnesia:dirty_read(chat_message, MessageId) of
        [Msg] -> mnesia:dirty_write(Msg#chat_message{preview = Preview});
        [] -> ok
    end.

%% Toggle User's Emoji reaction on MessageId: adds it if absent, removes it
%% if User already reacted with that exact emoji (so re-tapping the same
%% reaction clears it -- a user can still hold several *different* emoji
%% reactions on the same message at once, Slack/Discord-style rather than
%% one-reaction-replaces-the-last like WhatsApp).
toggle_reaction(MessageId, User, Emoji) ->
    case mnesia:dirty_read(chat_message, MessageId) of
        [Msg] ->
            Key = {User, Emoji},
            NewReactions = case lists:member(Key, Msg#chat_message.reactions) of
                true -> lists:delete(Key, Msg#chat_message.reactions);
                false -> [Key | Msg#chat_message.reactions]
            end,
            ok = mnesia:dirty_write(Msg#chat_message{reactions = NewReactions}),
            {ok, NewReactions};
        [] ->
            {error, not_found}
    end.

%% Returns the persistent username for a given OAuth identity, creating one
%% the first time that identity is seen. PreferredName is what the provider
%% told us to call them (their display name, or the local part of their
%% email as a fallback) -- used as-is if nothing else in chat_account
%% already claimed it, otherwise suffixed with digits until it's unique.
%% This only reserves the name at the *account* level; a live guest can
%% still be occupying it in chat_room at the moment this account tries to
%% connect, which is handled the same way any other name collision is (the
%% existing "taken" rejection), not specially here.
find_or_create_account(Provider, Sub, PreferredName) ->
    Key = {Provider, Sub},
    case mnesia:dirty_read(chat_account, Key) of
        [#chat_account{username = Username}] ->
            Username;
        [] ->
            Username = unique_account_username(sanitize_username(PreferredName)),
            ok = mnesia:dirty_write(#chat_account{key = Key, username = Username}),
            Username
    end.

sanitize_username(Name) when is_binary(Name) ->
    sanitize_username(unicode:characters_to_list(Name));
sanitize_username(Name) ->
    Trimmed = string:trim(Name),
    Truncated = case length(Trimmed) > 24 of
        true -> string:slice(Trimmed, 0, 24);
        false -> Trimmed
    end,
    case Truncated of
        "" -> "User" ++ integer_to_list(rand:uniform(9999));
        _ -> Truncated
    end.

unique_account_username(Base) ->
    Taken = sets:from_list(
        [U || #chat_account{username = U} <- mnesia:dirty_match_object(#chat_account{key = '_', username = '_'})]),
    case sets:is_element(Base, Taken) of
        false -> Base;
        true -> unique_account_username(Base, Taken, 2)
    end.

unique_account_username(Base, Taken, N) ->
    %% Keep the combined name within the same 24-char limit everything else
    %% respects, trimming the base rather than letting "#2" push it over.
    Suffix = "#" ++ integer_to_list(N),
    Candidate = string:slice(Base, 0, max(0, 24 - length(Suffix))) ++ Suffix,
    case sets:is_element(Candidate, Taken) of
        false -> Candidate;
        true -> unique_account_username(Base, Taken, N + 1)
    end.

save_group(Name, Owner, Members) ->
    ok = mnesia:dirty_write(#chat_group{name = Name, owner = Owner, members = Members}).

delete_group(Name) ->
    ok = mnesia:dirty_delete({chat_group, Name}).

%% All persisted groups as {Name, Owner, Members} tuples, for chat_groups
%% to repopulate its in-memory state from on startup.
load_groups() ->
    Records = mnesia:dirty_match_object(#chat_group{name = '_', owner = '_', members = '_'}),
    [{R#chat_group.name, R#chat_group.owner, R#chat_group.members} || R <- Records].

%% ---- profiles: E2EE public key, avatar, status ----
%% Read-modify-write on the same row rather than three separate tables,
%% since a client publishing its pubkey on connect and a client setting an
%% avatar later both need to preserve whatever the other already set --
%% mnesia:dirty_write with a fresh #user_profile{} would silently wipe out
%% a field it didn't intend to touch otherwise.
profile_or_new(Username) ->
    case mnesia:dirty_read(user_profile, Username) of
        [P] -> P;
        [] -> #user_profile{username = Username}
    end.

set_pubkey(Username, Base64Key) ->
    ok = mnesia:dirty_write((profile_or_new(Username))#user_profile{pubkey = Base64Key}).

get_pubkey(Username) ->
    case mnesia:dirty_read(user_profile, Username) of
        [#user_profile{pubkey = Key}] -> Key;
        [] -> undefined
    end.

set_avatar(Username, Url) ->
    ok = mnesia:dirty_write((profile_or_new(Username))#user_profile{avatar_url = Url}).

set_status(Username, Status) ->
    ok = mnesia:dirty_write((profile_or_new(Username))#user_profile{status = Status}).

%% {AvatarUrlOrUndefined, StatusOrUndefined} -- pubkey isn't included here,
%% it's fetched separately (get_pubkey/1) only when actually starting a DM,
%% not broadcast with every profile lookup.
%% Stamped when a user disconnects; rows written before this field existed
%% carry [] in it after migration, which reads back as "unknown".
set_last_seen(Username) ->
    ok = mnesia:dirty_write((profile_or_new(Username))#user_profile{last_seen = erlang:system_time(millisecond)}).

get_last_seen(Username) ->
    case mnesia:dirty_read(user_profile, Username) of
        [#user_profile{last_seen = T}] when is_integer(T) -> T;
        _ -> undefined
    end.

get_profile(Username) ->
    case mnesia:dirty_read(user_profile, Username) of
        [#user_profile{avatar_url = A, status = S}] -> {A, S};
        [] -> {undefined, undefined}
    end.
