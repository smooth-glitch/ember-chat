%%% One process per connected TCP client. Owns the socket, prompts for
%%% a username, then relays lines to chat_room and pushes back whatever
%%% chat_room routes to this user.
-module(chat_client_handler).
-export([start/1]).
-include("chat.hrl").

start(Socket) ->
    Pid = spawn(fun() -> wait_for_socket(Socket) end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! go,
    {ok, Pid}.

%% Block until socket ownership has actually been handed over, otherwise
%% inet:setopts/gen_tcp:send below would race controlling_process/2.
wait_for_socket(Socket) ->
    receive
        go -> init(Socket)
    end.

init(Socket) ->
    inet:setopts(Socket, [{active, once}, {nodelay, true}]),
    gen_tcp:send(Socket, "Welcome! Enter your username: "),
    username_loop(Socket).

username_loop(Socket) ->
    receive
        {tcp, Socket, Data} ->
            case string:trim(binary_to_list(Data)) of
                "" ->
                    inet:setopts(Socket, [{active, once}]),
                    gen_tcp:send(Socket, "Username cannot be empty. Try again: "),
                    username_loop(Socket);
                Name when length(Name) > ?MAX_USERNAME_LEN ->
                    inet:setopts(Socket, [{active, once}]),
                    gen_tcp:send(Socket, io_lib:format(
                        "Username too long (max ~p chars). Try again: ", [?MAX_USERNAME_LEN])),
                    username_loop(Socket);
                Name ->
                    case chat_room:register_user(Name, self()) of
                        ok ->
                            gen_tcp:send(Socket, io_lib:format(
                                "Welcome, ~s! Type /help for commands.~n", [Name])),
                            inet:setopts(Socket, [{active, once}]),
                            loop(Socket, Name);
                        {error, taken} ->
                            inet:setopts(Socket, [{active, once}]),
                            gen_tcp:send(Socket, "Username taken. Try another: "),
                            username_loop(Socket)
                    end
            end;
        {tcp_closed, Socket} -> ok;
        {tcp_error, Socket, _Reason} -> ok
    end.

loop(Socket, Name) ->
    receive
        {tcp, Socket, Data} ->
            case string:trim(binary_to_list(Data)) of
                "/quit" ->
                    gen_tcp:send(Socket, "Goodbye!\n"),
                    chat_room:unregister_user(Name),
                    gen_tcp:close(Socket);
                Line ->
                    handle_line(Socket, Name, Line),
                    inet:setopts(Socket, [{active, once}]),
                    loop(Socket, Name)
            end;
        {tcp_closed, Socket} ->
            chat_room:unregister_user(Name);
        {tcp_error, Socket, _Reason} ->
            chat_room:unregister_user(Name);
        {chat_message, From, Text} ->
            gen_tcp:send(Socket, io_lib:format("~s: ~s~n", [From, Text])),
            loop(Socket, Name);
        {private_message, From, Text} ->
            gen_tcp:send(Socket, io_lib:format("[private] ~s: ~s~n", [From, Text])),
            loop(Socket, Name);
        {system, Text} ->
            gen_tcp:send(Socket, io_lib:format("* ~s~n", [Text])),
            loop(Socket, Name);
        {group_message, GroupName, From, Text} ->
            gen_tcp:send(Socket, io_lib:format("[~s] ~s: ~s~n", [GroupName, From, Text])),
            loop(Socket, Name);
        {group_system, GroupName, Text} ->
            gen_tcp:send(Socket, io_lib:format("* [~s] ~s~n", [GroupName, Text])),
            loop(Socket, Name);
        {added_to_group, GroupName, Members, By} ->
            gen_tcp:send(Socket, io_lib:format(
                "* ~s added you to group '~s' (members: ~s)~n",
                [By, GroupName, string:join(Members, ", ")])),
            loop(Socket, Name)
    end.

handle_line(_Socket, _Name, "") ->
    ok;
handle_line(Socket, _Name, "/list") ->
    Users = chat_room:list_users(),
    gen_tcp:send(Socket, io_lib:format("Online: ~s~n", [string:join(Users, ", ")]));
handle_line(Socket, _Name, "/help") ->
    gen_tcp:send(Socket,
        "Commands:\n"
        "  /list                       who's online\n"
        "  /msg <user> <text>          private message\n"
        "  /creategroup <name>         create a group (you become the only member)\n"
        "  /addmember <group> <user>   add an online user to a group you're in\n"
        "  /leavegroup <group>         leave a group\n"
        "  /groupmsg <group> <text>    message a group you're in\n"
        "  /groups                     list your groups and their members\n"
        "  /quit                       disconnect\n"
        "  (anything else = broadcast to everyone)\n");
handle_line(Socket, Name, "/msg " ++ Rest) ->
    case string:split(Rest, " ") of
        [_To, Text] when length(Text) > ?MAX_MESSAGE_LEN ->
            gen_tcp:send(Socket, io_lib:format(
                "Message too long (max ~p chars).~n", [?MAX_MESSAGE_LEN]));
        [To, Text] when Text =/= "" ->
            case chat_room:send_private(Name, To, Text) of
                ok -> ok;
                {error, not_found} ->
                    gen_tcp:send(Socket, io_lib:format("No such user: ~s~n", [To]))
            end;
        _ ->
            gen_tcp:send(Socket, "Usage: /msg <username> <message>\n")
    end;
handle_line(Socket, Name, "/creategroup " ++ Rest) ->
    case string:trim(Rest) of
        "" ->
            gen_tcp:send(Socket, "Usage: /creategroup <name>\n");
        GroupName when length(GroupName) > ?MAX_GROUP_NAME_LEN ->
            gen_tcp:send(Socket, io_lib:format(
                "Group name too long (max ~p chars).~n", [?MAX_GROUP_NAME_LEN]));
        GroupName ->
            case chat_groups:create_group(GroupName, Name) of
                {ok, _Members} ->
                    gen_tcp:send(Socket, io_lib:format("Created group '~s'.~n", [GroupName]));
                {error, exists} ->
                    gen_tcp:send(Socket, "A group with that name already exists.\n")
            end
    end;
handle_line(Socket, Name, "/addmember " ++ Rest) ->
    case string:split(Rest, " ") of
        [GroupName, NewMember] when NewMember =/= "" ->
            case chat_groups:add_member(GroupName, Name, NewMember) of
                {ok, Members} ->
                    gen_tcp:send(Socket, io_lib:format("~s added to '~s'. Members: ~s~n",
                        [NewMember, GroupName, string:join(Members, ", ")]));
                {error, not_found} ->
                    gen_tcp:send(Socket, io_lib:format("No such group: ~s~n", [GroupName]));
                {error, not_member} ->
                    gen_tcp:send(Socket, "You're not in that group.\n");
                {error, already_member} ->
                    gen_tcp:send(Socket, io_lib:format("~s is already in the group.~n", [NewMember]));
                {error, user_offline} ->
                    gen_tcp:send(Socket, io_lib:format("~s isn't online right now.~n", [NewMember]))
            end;
        _ ->
            gen_tcp:send(Socket, "Usage: /addmember <group> <username>\n")
    end;
handle_line(Socket, Name, "/leavegroup " ++ Rest) ->
    GroupName = string:trim(Rest),
    case chat_groups:leave_group(GroupName, Name) of
        ok ->
            gen_tcp:send(Socket, io_lib:format("Left '~s'.~n", [GroupName]));
        {error, not_found} ->
            gen_tcp:send(Socket, io_lib:format("No such group: ~s~n", [GroupName]));
        {error, not_member} ->
            gen_tcp:send(Socket, "You're not in that group.\n")
    end;
handle_line(Socket, Name, "/groupmsg " ++ Rest) ->
    case string:split(Rest, " ") of
        [_GroupName, Text] when length(Text) > ?MAX_MESSAGE_LEN ->
            gen_tcp:send(Socket, io_lib:format(
                "Message too long (max ~p chars).~n", [?MAX_MESSAGE_LEN]));
        [GroupName, Text] when Text =/= "" ->
            case chat_groups:group_message(GroupName, Name, Text) of
                ok -> ok;
                {error, not_found} ->
                    gen_tcp:send(Socket, io_lib:format("No such group: ~s~n", [GroupName]));
                {error, not_member} ->
                    gen_tcp:send(Socket, "You're not in that group.\n")
            end;
        _ ->
            gen_tcp:send(Socket, "Usage: /groupmsg <group> <message>\n")
    end;
handle_line(Socket, Name, "/groups") ->
    case chat_groups:list_groups_for(Name) of
        [] ->
            gen_tcp:send(Socket, "You're not in any groups.\n");
        Groups ->
            Lines = [io_lib:format("  ~s: ~s~n", [G, string:join(M, ", ")]) || {G, M} <- Groups],
            gen_tcp:send(Socket, ["Your groups:\n", Lines])
    end;
handle_line(Socket, _Name, Text) when length(Text) > ?MAX_MESSAGE_LEN ->
    gen_tcp:send(Socket, io_lib:format("Message too long (max ~p chars).~n", [?MAX_MESSAGE_LEN]));
handle_line(_Socket, Name, Text) ->
    chat_room:broadcast(Name, Text).
