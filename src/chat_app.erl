%%% Entry point. Run with:
%%%   erl -noshell -pa ebin -s chat_app start
%%% or, from a shell, chat_app:start().
%%% Optional args: [TcpPort] or [TcpPort, WebPort].
-module(chat_app).
-export([start/0, start/1]).

-define(DEFAULT_TCP_PORT, 5555).
-define(DEFAULT_WEB_PORT, 8080).

start() ->
    start([integer_to_list(?DEFAULT_TCP_PORT), integer_to_list(?DEFAULT_WEB_PORT)]).

start([TcpPortArg]) ->
    start([TcpPortArg, integer_to_list(?DEFAULT_WEB_PORT)]);
start([TcpPortArg, WebPortArg]) ->
    {ok, _} = application:ensure_all_started(crypto),
    ok = chat_store:init(),
    TcpPort = to_port(TcpPortArg),
    WebPort = to_port(WebPortArg),
    {ok, _Pid} = chat_app_sup:start_link(TcpPort, WebPort),
    io:format("Chat server: raw TCP on port ~p, web UI on http://localhost:~p~n",
              [TcpPort, WebPort]),
    receive
        stop -> ok
    end.

to_port(Port) when is_integer(Port) -> Port;
to_port(Port) when is_atom(Port) -> to_port(atom_to_list(Port));
to_port(Port) when is_list(Port) -> list_to_integer(Port).
