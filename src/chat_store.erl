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
         delete_message/2, edit_message/3,
         save_link_preview/2, find_or_create_account/3,
         set_pubkey/2, get_pubkey/1, set_avatar/2, set_status/2, get_profile/1]).

-record(chat_message, {id, conv_key, from, text, kind, private, ts, reactions = [], preview = [], reply_to = [], deleted = false, edited = false}).
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
-record(user_profile, {username, pubkey = undefined, avatar_url = undefined, status = undefined}).

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
    ok = mnesia:wait_for_tables([chat_message, chat_group, chat_account, user_profile], 10000),
    migrate_preview_shape(),
    ok.

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
    Id = erlang:unique_integer([monotonic, positive]),
    Msg = #chat_message{id = Id, conv_key = ConvKey, from = From, text = Text,
                         kind = Kind, private = Private, ts = erlang:system_time(millisecond),
                         reply_to = ReplyTo},
    ok = mnesia:dirty_write(Msg),
    Id.

%% Last ?HISTORY_LIMIT messages for a conversation, oldest first, as plain
%% {Id, From, Text, Private, Reactions, Preview, ReplyTo} tuples -- callers
%% never need the Mnesia record. Reactions is a [{User, Emoji}] list;
%% Preview is [] (none yet, or never will be) or {Url, Title, Description,
%% Image}; ReplyTo is [] (not a reply) or the id of the original message.
load_history(ConvKey) ->
    Records = mnesia:dirty_index_read(chat_message, ConvKey, #chat_message.conv_key),
    Sorted = lists:keysort(#chat_message.id, Records),
    Len = length(Sorted),
    Trimmed = lists:nthtail(max(0, Len - ?HISTORY_LIMIT), Sorted),
    [{R#chat_message.id, R#chat_message.from, R#chat_message.text,
      R#chat_message.private, R#chat_message.reactions, R#chat_message.preview,
      R#chat_message.reply_to, R#chat_message.deleted =:= true,
      case R#chat_message.ts of T when is_integer(T) -> T; _ -> 0 end,
      R#chat_message.edited =:= true} || R <- Trimmed].

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
get_profile(Username) ->
    case mnesia:dirty_read(user_profile, Username) of
        [#user_profile{avatar_url = A, status = S}] -> {A, S};
        [] -> {undefined, undefined}
    end.
