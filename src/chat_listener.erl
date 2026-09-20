%%% Owns the listening socket and spawns a handler process per
%%% incoming connection.
-module(chat_listener).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {listen_socket}).

start_link(Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Port], []).

init([Port]) ->
    %% No {ip, ...} given, so this binds all interfaces (0.0.0.0), not
    %% just loopback -- required for the port to be reachable from
    %% outside this machine (e.g. through a tunnel or port forward).
    %% {nodelay, true}: see chat_web_listener for why -- same Nagle's-algorithm
    %% latency applies here, since every chat line is its own small write.
    {ok, ListenSocket} = gen_tcp:listen(Port,
        [binary, {packet, line}, {active, false}, {reuseaddr, true}, {nodelay, true}]),
    self() ! accept,
    {ok, #state{listen_socket = ListenSocket}}.

handle_info(accept, State = #state{listen_socket = ListenSocket}) ->
    case gen_tcp:accept(ListenSocket, infinity) of
        {ok, Socket} ->
            chat_client_handler:start(Socket),
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
