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
    Listener = #{id => chat_listener,
                 start => {chat_listener, start_link, [TcpPort]},
                 restart => permanent,
                 shutdown => 5000,
                 type => worker,
                 modules => [chat_listener]},
    WebListener = #{id => chat_web_listener,
                    start => {chat_web_listener, start_link, [WebPort]},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [chat_web_listener]},
    {ok, {SupFlags, [ChatRoom, ChatGroups, Listener, WebListener]}}.
