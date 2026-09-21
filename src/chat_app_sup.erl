%%% Top supervisor: restarts chat_room / chat_listener / chat_web_listener
%%% independently if any of them crashes, without taking down already-
%%% connected clients on the others.
-module(chat_app_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

start_link(TcpPort, WebPort) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [TcpPort, WebPort]).

init([TcpPort, WebPort]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    ChatRoom = #{id => chat_room,
                 start => {chat_room, start_link, []},
                 restart => permanent,
                 shutdown => 5000,
                 type => worker,
                 modules => [chat_room]},
    ChatGroups = #{id => chat_groups,
                   start => {chat_groups, start_link, []},
                   restart => permanent,
                   shutdown => 5000,
                   type => worker,
                   modules => [chat_groups]},
    WebListener = #{id => chat_web_listener,
                    start => {chat_web_listener, start_link, [WebPort]},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [chat_web_listener]},
    %% TcpPort is `undefined` for a hosted deploy (chat_app:start_web_only/1)
    %% that deliberately doesn't open the raw TCP port at all -- see its doc
    %% comment for why a second open port there is actively dangerous, not
    %% just unused.
    Children = case TcpPort of
        undefined ->
            [ChatRoom, ChatGroups, WebListener];
        _ ->
            Listener = #{id => chat_listener,
                         start => {chat_listener, start_link, [TcpPort]},
                         restart => permanent,
                         shutdown => 5000,
                         type => worker,
                         modules => [chat_listener]},
            [ChatRoom, ChatGroups, Listener, WebListener]
    end,
    {ok, {SupFlags, Children}}.
