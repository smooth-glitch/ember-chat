%%% Central registry + message router. One process, holds who's online
%%% and where to route broadcast/private messages. Crash-safe: if a
%%% client handler dies, its monitor fires and it's cleaned up here.
%%%
%%% Chat and private messages are persisted via chat_store as they're
%%% routed, so history survives a node restart. Presence/typing signals are
%%% deliberately NOT persisted -- they're transient by nature.
-module(chat_room).
-behaviour(gen_server).

-export([start_link/0]).
-export([register_user/2, unregister_user/1, broadcast/2, broadcast/3,
         send_private/3, send_private/4, list_users/0]).
-export([get_pid/1, typing/1, typing_dm/2, mark_read/2]).
-export([react_global/3, react_dm/4]).
-export([delete_global/2, delete_dm/3, edit_global/3, edit_dm/4]).
-export([broadcast_profile/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {users = #{} :: #{string() => pid()},
                 monitors = #{} :: #{reference() => string()}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register_user(Name, Pid) ->
    gen_server:call(?MODULE, {register, Name, Pid}).

unregister_user(Name) ->
    gen_server:cast(?MODULE, {unregister, Name}).

broadcast(From, Text) ->
    broadcast(From, Text, []).

%% ReplyTo is [] (not a reply) or the id of the message being replied to --
%% see chat_store:save_message/6 for why it's just an id, not a denormalized
%% copy of the original message.
broadcast(From, Text, ReplyTo) ->
    gen_server:cast(?MODULE, {broadcast, From, Text, ReplyTo}).

send_private(From, To, Text) ->
    send_private(From, To, Text, []).

send_private(From, To, Text, ReplyTo) ->
    gen_server:call(?MODULE, {private, From, To, Text, ReplyTo}).

list_users() ->
    gen_server:call(?MODULE, list_users).

%% Used by chat_groups to route a group message to each online member
%% without chat_groups needing its own copy of the username registry.
get_pid(Name) ->
    gen_server:call(?MODULE, {get_pid, Name}).

%% Ephemeral presence signals -- cast, not call: a lost typing/read ping
%% isn't worth blocking the sender over.
typing(From) -> gen_server:cast(?MODULE, {typing, From}).
typing_dm(From, To) -> gen_server:cast(?MODULE, {typing_dm, From, To}).
mark_read(Reader, Other) -> gen_server:cast(?MODULE, {mark_read, Reader, Other}).

react_global(MessageId, User, Emoji) -> gen_server:cast(?MODULE, {react_global, MessageId, User, Emoji}).
react_dm(MessageId, User, Emoji, Other) -> gen_server:cast(?MODULE, {react_dm, MessageId, User, Emoji, Other}).

delete_global(MessageId, User) -> gen_server:cast(?MODULE, {delete_global, MessageId, User}).
delete_dm(MessageId, User, Other) -> gen_server:cast(?MODULE, {delete_dm, MessageId, User, Other}).
edit_global(MessageId, User, Text) -> gen_server:cast(?MODULE, {edit_global, MessageId, User, Text}).
edit_dm(MessageId, User, Other, Text) -> gen_server:cast(?MODULE, {edit_dm, MessageId, User, Other, Text}).

%% Pushes User's current avatar/status to every online client (web + iOS
%% alike) right when it changes, instead of the old fetch-once-and-cache-
%% forever behavior (a client only ever learned it by asking, so an avatar
%% update made after that never reached anyone already connected).
broadcast_profile(User) -> gen_server:cast(?MODULE, {broadcast_profile, User}).

init([]) ->
    {ok, #state{}}.

handle_call({register, Name, Pid}, _From, State = #state{users = Users, monitors = Monitors}) ->
    case maps:is_key(Name, Users) of
        true ->
            {reply, {error, taken}, State};
        false ->
            Ref = erlang:monitor(process, Pid),
            NewUsers = maps:put(Name, Pid, Users),
            NewMonitors = maps:put(Ref, Name, Monitors),
            notify_all(NewUsers, {system, io_lib:format("~s has joined", [Name])}),
            {reply, ok, State#state{users = NewUsers, monitors = NewMonitors}}
    end;
handle_call({private, From, To, Text, ReplyTo}, _From, State = #state{users = Users}) ->
    case maps:find(To, Users) of
        {ok, Pid} ->
            Id = chat_store:save_message(chat_store:dm_key(From, To), From, Text, chat, true, ReplyTo),
            Pid ! {private_message, Id, From, Text, ReplyTo},
            chat_link_preview:maybe_fetch_and_notify(Id, Text, fun(MsgId, Preview) ->
                lists:foreach(
                    fun(N) ->
                        case maps:find(N, Users) of
                            {ok, P} -> P ! {dm_link_preview, MsgId, Preview, From, To};
                            error -> ok
                        end
                    end, [From, To])
            end),
            {reply, {ok, Id}, State};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call(list_users, _From, State = #state{users = Users}) ->
    {reply, maps:keys(Users), State};
handle_call({get_pid, Name}, _From, State = #state{users = Users}) ->
    {reply, maps:find(Name, Users), State}.

handle_cast({unregister, Name}, State = #state{users = Users, monitors = Monitors}) ->
    NewUsers = maps:remove(Name, Users),
    NewMonitors = maps:filter(
        fun(Ref, N) ->
            case N =:= Name of
                true -> erlang:demonitor(Ref, [flush]), false;
                false -> true
            end
        end, Monitors),
    notify_all(NewUsers, {system, io_lib:format("~s has left", [Name])}),
    {noreply, State#state{users = NewUsers, monitors = NewMonitors}};
handle_cast({broadcast, From, Text, ReplyTo}, State = #state{users = Users}) ->
    Id = chat_store:save_message("global", From, Text, chat, false, ReplyTo),
    %% The sender already rendered their own message optimistically and
    %% isn't in the broadcast recipient list below -- but they still need
    %% to learn the assigned id, so their own message becomes react-able
    %% and can receive reaction pushes from others.
    case maps:find(From, Users) of
        {ok, SelfPid} -> SelfPid ! {own_message_id, Id};
        error -> ok
    end,
    Others = maps:remove(From, Users),
    notify_all(Others, {chat_message, Id, From, Text, ReplyTo}),
    chat_link_preview:maybe_fetch_and_notify(Id, Text, fun(MsgId, Preview) ->
        notify_all(Users, {link_preview, "global", MsgId, Preview})
    end),
    {noreply, State};
handle_cast({typing, From}, State = #state{users = Users}) ->
    notify_all(maps:remove(From, Users), {typing, From}),
    {noreply, State};
handle_cast({typing_dm, From, To}, State = #state{users = Users}) ->
    case maps:find(To, Users) of
        {ok, Pid} -> Pid ! {typing_dm, From};
        error -> ok
    end,
    {noreply, State};
handle_cast({mark_read, Reader, Other}, State = #state{users = Users}) ->
    case maps:find(Other, Users) of
        {ok, Pid} -> Pid ! {dm_read, Reader};
        error -> ok
    end,
    {noreply, State};
handle_cast({react_global, MessageId, User, Emoji}, State = #state{users = Users}) ->
    case chat_store:toggle_reaction(MessageId, User, Emoji) of
        {ok, Reactions} -> notify_all(Users, {reaction, "global", MessageId, Reactions});
        {error, not_found} -> ok
    end,
    {noreply, State};
handle_cast({react_dm, MessageId, User, Emoji, Other}, State = #state{users = Users}) ->
    case chat_store:toggle_reaction(MessageId, User, Emoji) of
        {ok, Reactions} ->
            %% Push to both participants (including the reactor) so the UI
            %% always renders from the server-confirmed reaction set rather
            %% than predicting it optimistically.
            lists:foreach(
                fun(N) ->
                    case maps:find(N, Users) of
                        {ok, Pid} -> Pid ! {dm_reaction, MessageId, Reactions, User, Other};
                        error -> ok
                    end
                end, [User, Other]);
        {error, not_found} -> ok
    end,
    {noreply, State};
handle_cast({delete_global, MessageId, User}, State = #state{users = Users}) ->
    case chat_store:delete_message(MessageId, User) of
        {ok, deleted} -> notify_all(Users, {deleted, MessageId});
        _ -> ok
    end,
    {noreply, State};
handle_cast({delete_dm, MessageId, User, Other}, State = #state{users = Users}) ->
    case chat_store:delete_message(MessageId, User) of
        {ok, deleted} ->
            lists:foreach(
                fun(N) ->
                    case maps:find(N, Users) of
                        {ok, Pid} -> Pid ! {dm_deleted, MessageId, User, Other};
                        error -> ok
                    end
                end, [User, Other]);
        _ -> ok
    end,
    {noreply, State};
handle_cast({edit_global, MessageId, User, Text}, State = #state{users = Users}) ->
    case chat_store:edit_message(MessageId, User, Text) of
        {ok, edited} -> notify_all(Users, {edited, MessageId, Text});
        _ -> ok
    end,
    {noreply, State};
handle_cast({edit_dm, MessageId, User, Other, Text}, State = #state{users = Users}) ->
    case chat_store:edit_message(MessageId, User, Text) of
        {ok, edited} ->
            lists:foreach(
                fun(N) ->
                    case maps:find(N, Users) of
                        {ok, Pid} -> Pid ! {dm_edited, MessageId, User, Other, Text};
                        error -> ok
                    end
                end, [User, Other]);
        _ -> ok
    end,
    {noreply, State};
handle_cast({broadcast_profile, User}, State = #state{users = Users}) ->
    {Avatar, Status} = chat_store:get_profile(User),
    notify_all(Users, {profile_update, User, Avatar, Status}),
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #state{users = Users, monitors = Monitors}) ->
    case maps:find(Ref, Monitors) of
        {ok, Name} ->
            NewUsers = maps:remove(Name, Users),
            NewMonitors = maps:remove(Ref, Monitors),
            notify_all(NewUsers, {system, io_lib:format("~s has disconnected", [Name])}),
            {noreply, State#state{users = NewUsers, monitors = NewMonitors}};
        error ->
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

notify_all(Users, Msg) ->
    maps:foreach(fun(_Name, Pid) -> Pid ! Msg end, Users).
