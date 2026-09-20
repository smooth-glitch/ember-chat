%%% Accepts plain HTTP connections and hands each one to chat_web,
%%% which decides whether it's a page request or a WebSocket upgrade.
-module(chat_web_listener).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {listen_socket}).

start_link(Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Port], []).

init([Port]) ->
    %% No {ip, ...} given, so this binds all interfaces (0.0.0.0) --
    %% required for a tunnel (ngrok, etc.) or reverse proxy to reach it.
    %% {nodelay, true} turns off Nagle's algorithm: without it the OS can
    %% hold a small outgoing chat message for tens of milliseconds waiting
    %% to coalesce it with more data, which is pure added latency for a
    %% protocol that's nothing but small, interactive writes.
    {ok, ListenSocket} = gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true}, {nodelay, true}]),
    self() ! accept,
    {ok, #state{listen_socket = ListenSocket}}.

handle_info(accept, State = #state{listen_socket = ListenSocket}) ->
    case gen_tcp:accept(ListenSocket, infinity) of
        {ok, Socket} ->
            chat_web:start(Socket),
            self() ! accept,
            {noreply, State};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.
