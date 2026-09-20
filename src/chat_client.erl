%%% Minimal interactive client for demos, so testing doesn't depend on
%%% telnet being enabled on Windows. Usage from an erl shell:
%%%   chat_client:connect("localhost", 5555).
-module(chat_client).
-export([connect/2]).

connect(Host, Port) ->
    {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {packet, line}, {active, true}]),
    spawn_link(fun() -> recv_loop(Socket) end),
    send_loop(Socket).

recv_loop(Socket) ->
    receive
        {tcp, Socket, Data} ->
            io:format("~s", [Data]),
            recv_loop(Socket);
        {tcp_closed, Socket} ->
            io:format("Connection closed.~n")
    end.

send_loop(Socket) ->
    case io:get_line("") of
        eof -> gen_tcp:close(Socket);
        {error, _} -> gen_tcp:close(Socket);
        Line ->
            gen_tcp:send(Socket, Line),
            send_loop(Socket)
    end.
