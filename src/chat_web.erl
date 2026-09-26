%%% Minimal HTTP + WebSocket server, hand-rolled on gen_tcp (no cowboy/
%%% ranch dependency, so the whole app stays zero-install). Serves the
%%% single-page UI at GET / and upgrades WebSocket connections into the
%%% same chat_room registry the raw TCP handler uses. Also accepts image
%%% uploads (POST /upload) and serves them back (GET /uploads/<name>).
-module(chat_web).
-export([start/1]).
-include("chat.hrl").

-define(WS_GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").
-define(MAX_UPLOAD_SIZE, 8 * 1024 * 1024).
-define(DRAIN_CEILING, 32 * 1024 * 1024).
-define(ALLOWED_UPLOAD_TYPES, ["image/png", "image/jpeg", "image/gif", "image/webp",
                                "audio/webm", "audio/ogg", "audio/mp4", "application/pdf"]).

start(Socket) ->
    Pid = spawn(fun() -> wait_for_socket(Socket) end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! go,
    {ok, Pid}.

wait_for_socket(Socket) ->
    receive
        go ->
            try
                read_request(Socket)
            catch
                Class:Reason:Stack ->
                    io:format("chat_web handler crashed: ~p:~p~n~p~n", [Class, Reason, Stack]),
                    gen_tcp:close(Socket)
            end
    end.

%% ---- HTTP request parsing -------------------------------------------

%% Read raw bytes (rather than relying on {packet, line} reframing
%% already-buffered data, which isn't reliable once a connection has
%% just been handed off via controlling_process/2) until the blank line
%% that ends the HTTP header block, then parse it by hand. Whatever was
%% already read *past* that blank line (the start of a POST body, if one
%% arrived in the same TCP segment as the headers) is handed along rather
%% than discarded, so a POST handler doesn't lose the first chunk of it.
read_request(Socket) ->
    inet:setopts(Socket, [{active, false}, {packet, raw}, binary, {nodelay, true}]),
    case read_headers_blob(Socket, <<>>) of
        {ok, HeaderBlob, BodyStart} ->
            Lines = binary:split(HeaderBlob, <<"\r\n">>, [global]),
            parse_and_dispatch(Socket, Lines, BodyStart);
        error ->
            gen_tcp:close(Socket)
    end.

read_headers_blob(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, Len} ->
            HeaderBlob = binary:part(Acc, 0, Pos),
            BodyStart = binary:part(Acc, Pos + Len, byte_size(Acc) - Pos - Len),
            {ok, HeaderBlob, BodyStart};
        nomatch when byte_size(Acc) > 16384 ->
            error;
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> read_headers_blob(Socket, <<Acc/binary, Data/binary>>);
                _ -> error
            end
    end.

parse_and_dispatch(Socket, [ReqLineBin | HeaderLines], BodyStart) ->
    case string:split(binary_to_list(ReqLineBin), " ", all) of
        [Method, RawPath, _Ver] ->
            %% The request line's path is the raw target -- "/?cb=123" for a
            %% cache-busted reload, "/auth/google/callback?code=..&state=.."
            %% for an OAuth redirect back -- but route matching only cares
            %% about the path itself. Splitting the query string off here,
            %% once, keeps every dispatch clause (and any future one) from
            %% having to remember to do it, rather than each accidentally
            %% 404ing on a URL that happens to carry a "?". Query params
            %% still reach the handlers that need them, just as a separate,
            %% already-decoded argument instead of raw text glued onto Path.
            {Path, QueryParams} = case string:split(RawPath, "?") of
                [P] -> {P, []};
                [P, Qs] ->
                    %% Malformed percent-encoding (attacker-controlled, not
                    %% just a theoretical case) makes this return an error
                    %% tuple instead of a list -- treat that the same as no
                    %% query string rather than letting a bad "%zz" crash
                    %% whatever handler expects a proplist.
                    case uri_string:dissect_query(Qs) of
                        Parsed when is_list(Parsed) -> {P, Parsed};
                        _ -> {P, []}
                    end
            end,
            Headers = parse_headers(HeaderLines, #{}),
            dispatch(Socket, Method, Path, QueryParams, Headers, BodyStart);
        _ ->
            gen_tcp:close(Socket)
    end;
parse_and_dispatch(Socket, [], _BodyStart) ->
    gen_tcp:close(Socket).

parse_headers([], Acc) ->
    Acc;
parse_headers([<<>> | Rest], Acc) ->
    parse_headers(Rest, Acc);
parse_headers([Line | Rest], Acc) ->
    case string:split(binary_to_list(Line), ":", leading) of
        [K, V] ->
            Key = string:lowercase(string:trim(K)),
            parse_headers(Rest, maps:put(Key, string:trim(V), Acc));
        _ ->
            parse_headers(Rest, Acc)
    end.

dispatch(Socket, "GET", Path, QueryParams, Headers, _BodyStart) ->
    case string:lowercase(maps:get("upgrade", Headers, "")) of
        "websocket" ->
            handshake(Socket, Headers);
        _ ->
            case Path of
                "/" ->
                    serve_index(Socket);
                "/auth/google/start" ->
                    start_oauth(Socket, google, Headers, QueryParams);
                "/auth/google/callback" ->
                    handle_oauth_callback(Socket, google, QueryParams, Headers);
                "/auth/apple/start" ->
                    start_oauth(Socket, apple, Headers, QueryParams);
                "/auth/session" ->
                    serve_session(Socket, Headers);
                "/manifest.json" ->
                    serve_web_file(Socket, "manifest.json");
                "/sw.js" ->
                    serve_web_file(Socket, "sw.js");
                _ ->
                    case string:prefix(Path, "/uploads/") of
                        nomatch ->
                            case string:prefix(Path, "/icons/") of
                                nomatch -> serve_404(Socket);
                                IconFile -> serve_icon(Socket, IconFile)
                            end;
                        Filename -> serve_upload(Socket, Filename, Headers)
                    end
            end
    end;
dispatch(Socket, "POST", "/upload", _QueryParams, Headers, BodyStart) ->
    handle_upload(Socket, Headers, BodyStart);
%% Apple mandates response_mode=form_post whenever the "name"/"email" scopes
%% are requested -- the code/state/user payload arrives as a POST body
%% (application/x-www-form-urlencoded), not query params like every other
%% OAuth provider's GET-redirect callback.
dispatch(Socket, "POST", "/auth/apple/callback", _QueryParams, Headers, BodyStart) ->
    handle_apple_form_callback(Socket, Headers, BodyStart);
dispatch(Socket, "POST", "/auth/logout", _QueryParams, _Headers, _BodyStart) ->
    respond_with_headers(Socket, 200, "OK", "application/json", <<"{\"ok\":true}">>,
                          [clear_session_cookie_header()]),
    gen_tcp:close(Socket);
dispatch(Socket, _Method, _Path, _QueryParams, _Headers, _BodyStart) ->
    serve_404(Socket).

serve_index(Socket) ->
    case file:read_file(index_path()) of
        {ok, Body} ->
            respond(Socket, 200, "OK", "text/html; charset=utf-8", Body);
        {error, _} ->
            respond(Socket, 500, "Internal Server Error", "text/plain",
                    <<"web/index.html not found next to the project root">>)
    end,
    gen_tcp:close(Socket).

serve_404(Socket) ->
    respond(Socket, 404, "Not Found", "text/plain", <<"Not found">>),
    gen_tcp:close(Socket).

respond(Socket, Code, Reason, ContentType, Body) ->
    Head = ["HTTP/1.1 ", integer_to_list(Code), " ", Reason, "\r\n",
            "Content-Type: ", ContentType, "\r\n",
            "Content-Length: ", integer_to_list(byte_size(Body)), "\r\n",
            %% Belt-and-suspenders alongside the upload magic-byte check: even
            %% if a browser somehow doubted our declared Content-Type, this
            %% tells it not to sniff the body and guess at executing it as
            %% something else (relevant to /uploads/*, harmless elsewhere).
            "X-Content-Type-Options: nosniff\r\n",
            %% This app changes several times a day during the demo push --
            %% no-cache forces the browser to revalidate every request
            %% instead of silently serving a stale index.html/JS from
            %% before the latest fix (the exact "why isn't my change
            %% showing up on the phone" class of confusion).
            "Cache-Control: no-cache\r\n",
            "Accept-Ranges: bytes\r\n",
            "Connection: close\r\n\r\n"],
    gen_tcp:send(Socket, [Head, Body]).

index_path() ->
    Ebin = filename:dirname(code:which(?MODULE)),
    filename:join([filename:dirname(Ebin), "web", "index.html"]).

uploads_dir() ->
    Ebin = filename:dirname(code:which(?MODULE)),
    filename:join([filename:dirname(Ebin), "uploads"]).

web_dir() ->
    Ebin = filename:dirname(code:which(?MODULE)),
    filename:join([filename:dirname(Ebin), "web"]).

%% manifest.json / sw.js -- fixed filenames, not user input, so no
%% path-traversal concern the way /uploads/* and /icons/* (built from a
%% URL segment) need is_safe_filename for.
serve_web_file(Socket, Filename) ->
    Path = filename:join(web_dir(), Filename),
    case file:read_file(Path) of
        {ok, Data} ->
            respond(Socket, 200, "OK", content_type_for_filename(Filename), Data);
        {error, _} ->
            serve_404(Socket)
    end,
    gen_tcp:close(Socket).

%% Same path-traversal guard as serve_upload/2 -- FilenameStr here also
%% comes straight from the URL.
serve_icon(Socket, FilenameStr) ->
    case is_safe_filename(FilenameStr) of
        false ->
            serve_404(Socket);
        true ->
            Path = filename:join([web_dir(), "icons", FilenameStr]),
            case file:read_file(Path) of
                {ok, Data} ->
                    respond(Socket, 200, "OK", content_type_for_filename(FilenameStr), Data);
                {error, _} ->
                    serve_404(Socket)
            end
    end,
    gen_tcp:close(Socket).

%% ---- Image uploads ------------------------------------------------------
%% No auth exists anywhere in this app (identity is just a claimed username
%% on the websocket, same as every other command), so this endpoint is
%% reachable by anyone who can reach the server -- consistent with, not a
%% regression from, the app's existing trust model. What it does guard,
%% because these are the actual attack surface for an endpoint that writes
%% files to disk and serves them back to other users:
%%   - a hard size cap, so one upload can't exhaust disk space
%%   - a strict content-type whitelist (images only)
%%   - a server-generated random filename -- the client's filename is never
%%     used for the on-disk path, which rules out path traversal and name
%%     collisions in one move
%%   - a matching check on the *serving* side, so a crafted GET can't walk
%%     out of the uploads directory either

handle_upload(Socket, Headers, BodyStart) ->
    ContentType = maps:get("content-type", Headers, ""),
    case extract_boundary(ContentType) of
        {ok, Boundary} ->
            case read_body(Socket, Headers, BodyStart) of
                {ok, Body} ->
                    case find_file_part(Body, Boundary) of
                        {ok, _Filename, PartContentType, Data} ->
                            store_upload(Socket, PartContentType, Data);
                        error ->
                            respond_json_error(Socket, 400, "No file found in upload")
                    end;
                {error, too_large} ->
                    respond_json_error(Socket, 413, "File too large (max 8 MB)");
                {error, _} ->
                    respond_json_error(Socket, 400, "Bad request")
            end;
        error ->
            respond_json_error(Socket, 400, "Expected multipart/form-data")
    end,
    gen_tcp:close(Socket).

read_body(Socket, Headers, BodyStart) ->
    case maps:find("content-length", Headers) of
        {ok, LenStr} ->
            case string:to_integer(LenStr) of
                {Len, []} when Len >= 0, Len =< ?MAX_UPLOAD_SIZE ->
                    read_body_bytes(Socket, BodyStart, Len);
                {Len, []} when Len > ?MAX_UPLOAD_SIZE ->
                    %% Drain the rejected body (bounded) before responding,
                    %% rather than closing out from under a client still
                    %% mid-upload -- that closes the TCP connection with data
                    %% still unread, which tends to send a RST instead of a
                    %% clean FIN, and a browser surfaces that as a network
                    %% error instead of our actual "file too large" message.
                    %% Capped so a client claiming a multi-gigabyte body can't
                    %% make the server sit there reading it all first.
                    drain_body(Socket, byte_size(BodyStart), min(Len, ?DRAIN_CEILING)),
                    {error, too_large};
                _ ->
                    {error, bad_length}
            end;
        error ->
            {error, no_length}
    end.

drain_body(_Socket, AlreadyRead, Target) when AlreadyRead >= Target ->
    ok;
drain_body(Socket, AlreadyRead, Target) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {ok, Data} -> drain_body(Socket, AlreadyRead + byte_size(Data), Target);
        {error, _} -> ok
    end.

read_body_bytes(_Socket, Acc, Len) when byte_size(Acc) >= Len ->
    {ok, binary:part(Acc, 0, Len)};
read_body_bytes(Socket, Acc, Len) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Data} -> read_body_bytes(Socket, <<Acc/binary, Data/binary>>, Len);
        {error, _} -> {error, closed}
    end.

extract_boundary(ContentType) ->
    case string:find(ContentType, "boundary=") of
        nomatch ->
            error;
        Match ->
            AfterKey = string:slice(Match, string:length("boundary=")),
            Value = case string:split(AfterKey, ";") of
                [B | _] -> B;
                _ -> AfterKey
            end,
            {ok, string:trim(Value, both, "\" \r\n")}
    end.

find_file_part(Body, Boundary) ->
    BoundaryBin = list_to_binary("--" ++ Boundary),
    Parts = binary:split(Body, BoundaryBin, [global]),
    find_file_part_loop(Parts).

find_file_part_loop([]) ->
    error;
find_file_part_loop([Part | Rest]) ->
    case parse_part(Part) of
        {ok, PartHeaders, Content} ->
            Disposition = maps:get("content-disposition", PartHeaders, ""),
            case extract_disposition_field(Disposition, "filename") of
                Filename when Filename =/= undefined, Filename =/= "" ->
                    PartContentType = maps:get("content-type", PartHeaders, "application/octet-stream"),
                    {ok, Filename, PartContentType, Content};
                _ ->
                    find_file_part_loop(Rest)
            end;
        error ->
            find_file_part_loop(Rest)
    end.

%% A part looks like "\r\nHeader: v\r\nHeader2: v2\r\n\r\n<content>\r\n"
%% (the leading \r\n is the boundary line's own terminator; the trailing
%% \r\n precedes the next boundary marker).
parse_part(PartBin) ->
    Trimmed = case PartBin of
        <<"\r\n", Rest/binary>> -> Rest;
        _ -> PartBin
    end,
    case binary:match(Trimmed, <<"\r\n\r\n">>) of
        {Pos, Len} ->
            HeaderBlob = binary:part(Trimmed, 0, Pos),
            ContentRaw = binary:part(Trimmed, Pos + Len, byte_size(Trimmed) - Pos - Len),
            Content = strip_trailing_crlf(ContentRaw),
            HeaderLines = binary:split(HeaderBlob, <<"\r\n">>, [global]),
            {ok, parse_part_headers(HeaderLines), Content};
        nomatch ->
            error
    end.

strip_trailing_crlf(Bin) ->
    Size = byte_size(Bin),
    case Size >= 2 andalso binary:part(Bin, Size - 2, 2) =:= <<"\r\n">> of
        true -> binary:part(Bin, 0, Size - 2);
        false -> Bin
    end.

parse_part_headers(Lines) ->
    lists:foldl(fun(Line, Acc) ->
        case binary:split(Line, <<":">>) of
            [K, V] ->
                Key = string:lowercase(string:trim(binary_to_list(K))),
                maps:put(Key, string:trim(binary_to_list(V)), Acc);
            _ ->
                Acc
        end
    end, #{}, Lines).

extract_disposition_field(DispositionValue, Field) ->
    Marker = Field ++ "=\"",
    case string:find(DispositionValue, Marker) of
        nomatch ->
            undefined;
        Match ->
            AfterMarker = string:slice(Match, string:length(Marker)),
            case string:split(AfterMarker, "\"") of
                [Value | _] -> Value;
                _ -> undefined
            end
    end.

store_upload(Socket, ContentType, Data) ->
    %% MediaRecorder's blob.type (voice notes) commonly carries a codec
    %% parameter, e.g. "audio/webm;codecs=opus" -- strip it before comparing
    %% against the whitelist. Harmless for image uploads, which never have one.
    Trimmed = string:lowercase(string:trim(ContentType)),
    NormalizedType = string:trim(hd(string:split(Trimmed, ";"))),
    case lists:member(NormalizedType, ?ALLOWED_UPLOAD_TYPES) of
        false ->
            respond_json_error(Socket, 415, "Only images, voice notes or PDFs are allowed");
        true ->
            case byte_size(Data) of
                0 ->
                    respond_json_error(Socket, 400, "Empty file");
                Size when Size > ?MAX_UPLOAD_SIZE ->
                    respond_json_error(Socket, 413, "File too large (max 8 MB)");
                _ ->
                    %% The declared Content-Type is whatever the client claimed --
                    %% never trusted alone. Check the file's actual magic bytes
                    %% match, so a renamed/relabeled non-image can't ride in
                    %% under an image content-type.
                    case matches_signature(NormalizedType, Data) of
                        false ->
                            respond_json_error(Socket, 415, "File content doesn't match its declared type");
                        true ->
                            store_upload_bytes(Socket, NormalizedType, Data)
                    end
            end
    end.

store_upload_bytes(Socket, NormalizedType, Data) ->
    Ext = extension_for(NormalizedType),
    RandomName = random_hex(24) ++ Ext,
    UploadsDir = uploads_dir(),
    ok = filelib:ensure_dir(filename:join(UploadsDir, "x")),
    Path = filename:join(UploadsDir, RandomName),
    ok = file:write_file(Path, Data),
    Json = "{\"url\":\"/uploads/" ++ RandomName ++ "\"}",
    respond(Socket, 200, "OK", "application/json", list_to_binary(Json)).

%% Magic-byte signature check -- the first few bytes of each format are
%% fixed regardless of the rest of the file's content.
matches_signature("image/png", <<137, "PNG", 13, 10, 26, 10, _/binary>>) -> true;
matches_signature("image/png", _) -> false;
matches_signature("image/jpeg", <<255, 216, 255, _/binary>>) -> true;
matches_signature("image/jpeg", _) -> false;
matches_signature("image/gif", <<"GIF87a", _/binary>>) -> true;
matches_signature("image/gif", <<"GIF89a", _/binary>>) -> true;
matches_signature("image/gif", _) -> false;
matches_signature("image/webp", <<"RIFF", _Size:32/little, "WEBP", _/binary>>) -> true;
matches_signature("image/webp", _) -> false;
matches_signature("audio/webm", <<16#1A, 16#45, 16#DF, 16#A3, _/binary>>) -> true;
matches_signature("audio/webm", _) -> false;
matches_signature("audio/ogg", <<"OggS", _/binary>>) -> true;
matches_signature("audio/ogg", _) -> false;
%% ISO base media (mp4/m4a): a 32-bit box size, then the 4-byte box type
%% "ftyp" -- the size varies per file, so only the type tag itself is fixed.
matches_signature("audio/mp4", <<_Size:32, "ftyp", _/binary>>) -> true;
matches_signature("audio/mp4", _) -> false;
matches_signature("application/pdf", <<"%PDF-", _/binary>>) -> true;
matches_signature("application/pdf", _) -> false;
matches_signature(_, _) -> false.

extension_for("image/png") -> ".png";
extension_for("image/jpeg") -> ".jpg";
extension_for("image/gif") -> ".gif";
extension_for("image/webp") -> ".webp";
extension_for("audio/webm") -> ".webm";
extension_for("audio/ogg") -> ".ogg";
extension_for("audio/mp4") -> ".m4a";
extension_for("application/pdf") -> ".pdf".

random_hex(NumBytes) ->
    Bytes = crypto:strong_rand_bytes(NumBytes),
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bytes]).

serve_upload(Socket, FilenameStr, Headers) ->
    case is_safe_filename(FilenameStr) of
        false ->
            serve_404(Socket);
        true ->
            Path = filename:join(uploads_dir(), FilenameStr),
            case file:read_file(Path) of
                {ok, Data} ->
                    serve_with_range(Socket, content_type_for_filename(FilenameStr), Data, Headers);
                {error, _} ->
                    serve_404(Socket)
            end
    end,
    gen_tcp:close(Socket).

%% A browser's <audio>/<video> element (preload="metadata" especially)
%% probes media with a byte-Range request, and some browsers refuse to
%% play at all -- surfacing as a bare "Error" state, with the file
%% otherwise downloading fine -- if the server always replies with the
%% whole file instead of honoring it. Only the single-range forms a media
%% element actually sends ("bytes=N-M" / "bytes=N-") are handled; anything
%% else, or no Range header at all, falls back to the original plain 200.
serve_with_range(Socket, ContentType, Data, Headers) ->
    Total = byte_size(Data),
    case maps:find("range", Headers) of
        {ok, "bytes=" ++ RangeSpec} ->
            case parse_byte_range(RangeSpec, Total) of
                {ok, Start, End} ->
                    Chunk = binary:part(Data, Start, End - Start + 1),
                    respond_range(Socket, ContentType, Chunk, Start, End, Total);
                error ->
                    respond(Socket, 200, "OK", ContentType, Data)
            end;
        _ ->
            respond(Socket, 200, "OK", ContentType, Data)
    end.

parse_byte_range(Spec, Total) when Total > 0 ->
    case string:split(Spec, "-") of
        [StartStr, ""] ->
            case string:to_integer(StartStr) of
                {Start, []} when Start >= 0, Start < Total -> {ok, Start, Total - 1};
                _ -> error
            end;
        [StartStr, EndStr] ->
            case {string:to_integer(StartStr), string:to_integer(EndStr)} of
                {{Start, []}, {End, []}} when Start >= 0, End >= Start ->
                    {ok, Start, min(End, Total - 1)};
                _ -> error
            end;
        _ ->
            error
    end;
parse_byte_range(_, _) -> error.

respond_range(Socket, ContentType, Chunk, Start, End, Total) ->
    Head = ["HTTP/1.1 206 Partial Content\r\n",
            "Content-Type: ", ContentType, "\r\n",
            "Content-Range: bytes ", integer_to_list(Start), "-", integer_to_list(End), "/", integer_to_list(Total), "\r\n",
            "Content-Length: ", integer_to_list(byte_size(Chunk)), "\r\n",
            "Accept-Ranges: bytes\r\n",
            "X-Content-Type-Options: nosniff\r\n",
            "Connection: close\r\n\r\n"],
    gen_tcp:send(Socket, [Head, Chunk]).

is_safe_filename(Name) ->
    Name =/= "" andalso
    not lists:member($/, Name) andalso
    not lists:member($\\, Name) andalso
    string:find(Name, "..") =:= nomatch.

content_type_for_filename(Name) ->
    case string:lowercase(filename:extension(Name)) of
        ".png" -> "image/png";
        ".jpg" -> "image/jpeg";
        ".jpeg" -> "image/jpeg";
        ".gif" -> "image/gif";
        ".webp" -> "image/webp";
        ".webm" -> "audio/webm";
        ".ogg" -> "audio/ogg";
        ".m4a" -> "audio/mp4";
        ".pdf" -> "application/pdf";
        ".json" -> "application/json";
        ".js" -> "application/javascript";
        _ -> "application/octet-stream"
    end.

respond_json_error(Socket, Code, Message) ->
    Json = "{\"error\":\"" ++ json_escape(Message) ++ "\"}",
    respond(Socket, Code, http_reason(Code), "application/json", list_to_binary(Json)).

http_reason(400) -> "Bad Request";
http_reason(413) -> "Payload Too Large";
http_reason(415) -> "Unsupported Media Type";
http_reason(_) -> "Error".

%% ---- Google/Apple sign-in ------------------------------------------------
%% The whole flow in one paragraph: browser hits /auth/<provider>/start,
%% which drops a short-lived "oauth_state" cookie and 302s to the provider's
%% consent page; the provider redirects (or, for Apple, form-POSTs) back to
%% /auth/<provider>/callback with a code and that same state; we check the
%% state cookie matches (the actual CSRF defense -- without it, an attacker
%% could complete *their own* OAuth login and trick a victim's browser into
%% carrying the result), trade the code for a verified identity via
%% chat_oauth, map that identity to a persistent username via
%% chat_store:find_or_create_account/3, and set a signed "session" cookie
%% before redirecting to "/". The SPA then calls GET /auth/session on load
%% to find out it's already signed in and skip the username prompt.
-define(SESSION_COOKIE_MAX_AGE_SEC, 30 * 24 * 3600). % 30 days
-define(OAUTH_STATE_COOKIE_MAX_AGE_SEC, 600). % 10 minutes -- just long enough to complete the redirect round trip

%% QueryParams carries "client=native" when this request came from the
%% Swift app's ASWebAuthenticationSession rather than a browser tab -- a
%% native client has nowhere to receive a Set-Cookie + redirect-to-"/" the
%% way a browser does, so that flag threads through `state` (opaque to
%% Google/Apple, round-trips unchanged) to tell complete_login/4 where to
%% send the result instead. This is the *only* difference in the two
%% flows -- the actual OAuth exchange and identity verification are
%% identical either way.
start_oauth(Socket, Provider, Headers, QueryParams) ->
    case provider_configured(Provider) of
        false ->
            %% Redirect back into the SPA with a query flag rather than a
            %% raw 503 page -- this is the state a real visitor sees the
            %% moment they click the button before oauth_config.erl has
            %% real credentials in it, and it should look like part of the
            %% app (a toast) instead of a broken server error page.
            respond_with_headers(Socket, 302, "Found", "text/plain", <<>>,
                [{"Location", "/?authError=" ++ atom_to_list(Provider) ++ "_not_configured"}]),
            gen_tcp:close(Socket);
        true ->
            RedirectUri = redirect_uri_for(Provider, Headers),
            IsNative = proplists:get_value("client", QueryParams) =:= "native",
            RawState = chat_oauth:random_state(),
            State = case IsNative of true -> "native:" ++ RawState; false -> RawState end,
            AuthUrl = case Provider of
                google -> chat_oauth:google_auth_url(RedirectUri, State);
                apple -> chat_oauth:apple_auth_url(RedirectUri, State)
            end,
            respond_with_headers(Socket, 302, "Found", "text/plain", <<>>,
                [{"Location", AuthUrl}, oauth_state_cookie_header(State)]),
            gen_tcp:close(Socket)
    end.

provider_configured(google) -> oauth_config:is_google_configured();
provider_configured(apple) -> oauth_config:is_apple_configured().

handle_oauth_callback(Socket, Provider, QueryParams, Headers) ->
    Code = proplists:get_value("code", QueryParams),
    State = proplists:get_value("state", QueryParams),
    finish_oauth(Socket, Provider, Code, State, Headers, undefined).

%% Apple's form_post callback carries the same code/state, plus (only on
%% the very first authorization ever, per Apple's docs -- never on
%% subsequent sign-ins) a "user" field: a JSON string with the name they
%% typed into Apple's consent screen, which never appears in the id_token
%% itself and would otherwise be lost forever after this one request.
handle_apple_form_callback(Socket, Headers, BodyStart) ->
    case read_body(Socket, Headers, BodyStart) of
        {ok, Body} ->
            Params = uri_string:dissect_query(binary_to_list(Body)),
            case is_list(Params) of
                true ->
                    Code = proplists:get_value("code", Params),
                    State = proplists:get_value("state", Params),
                    UserJson = proplists:get_value("user", Params),
                    finish_oauth(Socket, apple, Code, State, Headers, UserJson);
                false ->
                    respond_json_error(Socket, 400, "Bad request"),
                    gen_tcp:close(Socket)
            end;
        {error, _} ->
            respond_json_error(Socket, 400, "Bad request"),
            gen_tcp:close(Socket)
    end.

finish_oauth(Socket, _Provider, undefined, _State, _Headers, _RawUser) ->
    respond_oauth_error(Socket, "Missing authorization code");
finish_oauth(Socket, Provider, Code, State, Headers, RawUser) ->
    Cookies = parse_cookies(Headers),
    CookieState = maps:get("oauth_state", Cookies, undefined),
    case State =:= CookieState andalso State =/= undefined of
        false ->
            respond_oauth_error(Socket, "Sign-in request expired or was tampered with -- please try again");
        true ->
            RedirectUri = redirect_uri_for(Provider, Headers),
            ExchangeResult = case Provider of
                google -> chat_oauth:google_exchange_code(Code, RedirectUri);
                apple -> chat_oauth:apple_exchange_code(Code, RedirectUri)
            end,
            case ExchangeResult of
                {ok, Identity} ->
                    complete_login(Socket, Provider, Identity, RawUser, lists:prefix("native:", State));
                {error, Reason} ->
                    io:format("oauth exchange failed (~p): ~p~n", [Provider, Reason]),
                    respond_oauth_error(Socket, "Sign-in failed -- please try again")
            end
    end.

complete_login(Socket, Provider, #{sub := Sub, email := Email, name := Name}, RawUser, IsNative) ->
    PreferredName = first_defined([
        Name,
        apple_form_name(RawUser),
        email_local_part(Email),
        <<"User">>
    ]),
    Username = chat_store:find_or_create_account(Provider, binary_to_list(Sub), PreferredName),
    %% A native client has no use for the session cookie (ChatClient joins
    %% with a plain WebSocket handshake, not HTTP session auth) -- it just
    %% needs the resulting username back, handed off via the custom URL
    %% scheme ASWebAuthenticationSession is listening for. A browser tab
    %% gets the usual cookie + redirect-to-"/" instead.
    Location = case IsNative of
        true -> "ember://auth-complete?username=" ++ uri_string:quote(Username);
        false -> "/"
    end,
    ExtraHeaders = case IsNative of
        true -> [clear_oauth_state_cookie_header()];
        false -> [session_cookie_header(Username), clear_oauth_state_cookie_header()]
    end,
    respond_with_headers(Socket, 302, "Found", "text/plain", <<>>,
        [{"Location", Location} | ExtraHeaders]),
    gen_tcp:close(Socket).

%% Apple's "user" form field, when present, is itself a JSON string like
%% {"name":{"firstName":"Ada","lastName":"Lovelace"}} -- best-effort pull a
%% display name out of it; anything short of that clean shape just falls
%% through to the next candidate in first_defined/1 above.
apple_form_name(undefined) -> undefined;
apple_form_name(RawUser) ->
    try
        case json:decode(list_to_binary(RawUser)) of
            #{<<"name">> := #{<<"firstName">> := First} = NameMap} ->
                Last = maps:get(<<"lastName">>, NameMap, <<>>),
                string:trim(unicode:characters_to_list([First, " ", Last]));
            _ ->
                undefined
        end
    catch
        _:_ -> undefined
    end.

email_local_part(undefined) -> undefined;
email_local_part(Email) ->
    hd(binary:split(Email, <<"@">>)).

first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value;
first_defined([]) -> <<"User">>.

respond_oauth_error(Socket, Message) ->
    Html = "<!doctype html><html><body style=\"font-family:sans-serif;padding:40px;text-align:center\">"
           "<p>" ++ json_escape(Message) ++ "</p><p><a href=\"/\">Back to Ember</a></p></body></html>",
    respond(Socket, 200, "OK", "text/html; charset=utf-8", list_to_binary(Html)),
    gen_tcp:close(Socket).

serve_session(Socket, Headers) ->
    Cookies = parse_cookies(Headers),
    Json = case maps:get("session", Cookies, undefined) of
        undefined ->
            "{\"username\":null}";
        Cookie ->
            case verify_session_cookie(Cookie) of
                {ok, Username} -> "{\"username\":\"" ++ json_escape(Username) ++ "\"}";
                error -> "{\"username\":null}"
            end
    end,
    respond(Socket, 200, "OK", "application/json", list_to_binary(Json)),
    gen_tcp:close(Socket).

%% ---- Cookies & signed sessions --------------------------------------------
%% No server-side session table: the cookie itself carries
%% "Username|Expiry|HMAC" (HMAC over "Username|Expiry" with a secret
%% generated once at node boot -- see oauth_config:session_secret/0), so
%% verifying a session is just recomputing that HMAC and comparing. Simpler
%% than a session store, at the cost of every existing session becoming
%% invalid the moment the node restarts -- an acceptable trade for how
%% rarely that happens here, and consistent with this app persisting almost
%% nothing about "logged in right now" state elsewhere either.
make_session_cookie(Username) ->
    Expiry = integer_to_list(erlang:system_time(second) + ?SESSION_COOKIE_MAX_AGE_SEC),
    Payload = Username ++ "|" ++ Expiry,
    Mac = crypto:mac(hmac, sha256, oauth_config:session_secret(), Payload),
    Payload ++ "|" ++ binary_to_list(binary:encode_hex(Mac)).

verify_session_cookie(Cookie) ->
    case string:split(Cookie, "|", all) of
        [Username, ExpiryStr, MacHex] ->
            Payload = Username ++ "|" ++ ExpiryStr,
            ExpectedMac = crypto:mac(hmac, sha256, oauth_config:session_secret(), Payload),
            %% crypto:hash_equals/2 requires equal-length inputs -- it's a
            %% badarg, not a clean `false`, on a mismatch. A forged or just
            %% corrupted cookie's decoded MAC is under attacker control and
            %% has no reason to happen to be exactly 32 bytes, so this has
            %% to be checked before calling it, not just try/catch around
            %% the hex-decode -- an all-zero-length GivenMac from a failed
            %% decode would hit the exact same badarg one step later.
            GivenMac = try binary:decode_hex(list_to_binary(MacHex)) catch _:_ -> <<>> end,
            Now = erlang:system_time(second),
            MacOk = byte_size(GivenMac) =:= byte_size(ExpectedMac) andalso
                    crypto:hash_equals(ExpectedMac, GivenMac),
            case {MacOk, string:to_integer(ExpiryStr)} of
                {true, {Expiry, []}} when Expiry > Now ->
                    {ok, Username};
                _ ->
                    error
            end;
        _ ->
            error
    end.

session_cookie_header(Username) ->
    Value = uri_string:quote(make_session_cookie(Username)),
    {"Set-Cookie",
     "session=" ++ Value ++ "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" ++
     integer_to_list(?SESSION_COOKIE_MAX_AGE_SEC)}.

clear_session_cookie_header() ->
    {"Set-Cookie", "session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"}.

oauth_state_cookie_header(State) ->
    {"Set-Cookie",
     "oauth_state=" ++ State ++ "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" ++
     integer_to_list(?OAUTH_STATE_COOKIE_MAX_AGE_SEC)}.

clear_oauth_state_cookie_header() ->
    {"Set-Cookie", "oauth_state=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"}.

%% Cookie header is "name1=value1; name2=value2; ...", values here are never
%% quoted/percent-encoded on the way in except through uri_string:quote/1 on
%% the way out (session cookie only), so a plain split is enough.
parse_cookies(Headers) ->
    case maps:get("cookie", Headers, undefined) of
        undefined ->
            #{};
        CookieHeader ->
            Pairs = string:split(CookieHeader, ";", all),
            lists:foldl(fun(Pair, Acc) ->
                case string:split(string:trim(Pair), "=", leading) of
                    [K, V] -> maps:put(K, uri_string:unquote(V), Acc);
                    _ -> Acc
                end
            end, #{}, Pairs)
    end.

%% Builds the callback URL the OAuth provider redirects back to, matching
%% whatever host/scheme the browser is actually using right now -- this
%% has to be registered verbatim in the provider's console, see
%% oauth_config.erl's module doc for the localhost-vs-https caveat.
redirect_uri_for(Provider, Headers) ->
    Host = maps:get("host", Headers, "localhost:8080"),
    Scheme = case string:lowercase(maps:get("x-forwarded-proto", Headers, "http")) of
        "https" -> "https";
        _ -> "http"
    end,
    Scheme ++ "://" ++ Host ++ "/auth/" ++ atom_to_list(Provider) ++ "/callback".

%% respond/5's sibling for responses that need extra headers (redirects'
%% Location, any Set-Cookie) -- kept separate rather than adding an
%% always-empty-list parameter to every existing respond/5 call site.
respond_with_headers(Socket, Code, Reason, ContentType, Body, ExtraHeaders) ->
    ExtraLines = [[K, ": ", V, "\r\n"] || {K, V} <- ExtraHeaders],
    Head = ["HTTP/1.1 ", integer_to_list(Code), " ", Reason, "\r\n",
            "Content-Type: ", ContentType, "\r\n",
            "Content-Length: ", integer_to_list(byte_size(Body)), "\r\n",
            "X-Content-Type-Options: nosniff\r\n",
            ExtraLines,
            "Connection: close\r\n\r\n"],
    gen_tcp:send(Socket, [Head, Body]).

%% ---- WebSocket handshake ----------------------------------------------

handshake(Socket, Headers) ->
    Key = maps:get("sec-websocket-key", Headers, ""),
    Accept = base64:encode(crypto:hash(sha, Key ++ ?WS_GUID)),
    Resp = ["HTTP/1.1 101 Switching Protocols\r\n",
            "Upgrade: websocket\r\n",
            "Connection: Upgrade\r\n",
            "Sec-WebSocket-Accept: ", Accept, "\r\n\r\n"],
    gen_tcp:send(Socket, Resp),
    inet:setopts(Socket, [{active, once}, {packet, raw}, binary, {nodelay, true}]),
    ws_username_loop(Socket, <<>>).

%% ---- pre-login: first WS text frame is the username -------------------

ws_username_loop(Socket, Buf) ->
    receive
        {tcp, Socket, Data} ->
            handle_username_data(Socket, <<Buf/binary, Data/binary>>);
        {tcp_closed, Socket} -> ok;
        {tcp_error, Socket, _Reason} -> ok
    end.

%% Recurses on Rest instead of handing off to ws_username_loop/ws_loop's
%% blocking receive, so any second (or third...) frame that arrived bundled
%% in the same TCP read is decoded and handled immediately instead of
%% sitting stuck in the buffer until a *later* read finally wakes the
%% process back up. Only "more" (a genuinely incomplete frame) should wait
%% on the network; a fully-buffered frame should never wait on anything.
handle_username_data(Socket, Buf) ->
    case ws_decode(Buf) of
        {ok, 1, Payload, Rest} ->
            case string:trim(binary_to_list(Payload)) of
                "" ->
                    ws_send_json(Socket, "error", "Username cannot be empty"),
                    handle_username_data(Socket, Rest);
                Name when length(Name) > ?MAX_USERNAME_LEN ->
                    ws_send_json(Socket, "error",
                        io_lib:format("Username too long (max ~p chars)", [?MAX_USERNAME_LEN])),
                    handle_username_data(Socket, Rest);
                Name ->
                    %% Load global history *before* registering: this user
                    %% isn't in chat_room's recipient map yet at this point,
                    %% so nothing broadcast from here on can already be both
                    %% in this snapshot and in a live push racing it in --
                    %% closes off a rare duplicate-line-on-login window.
                    GlobalHistory = chat_store:load_history("global"),
                    case chat_room:register_user(Name, self()) of
                        ok ->
                            ws_send(Socket, json_obj([{"type", "welcome"}, {"name", Name}])),
                            send_history_payload(Socket, "global", [], GlobalHistory),
                            handle_ws_data(Socket, Name, Rest);
                        {error, taken} ->
                            ws_send_json(Socket, "error", "Username taken"),
                            handle_username_data(Socket, Rest)
                    end
            end;
        {ok, 8, _Payload, _Rest} ->
            gen_tcp:close(Socket);
        {ok, 9, Payload, Rest} ->
            gen_tcp:send(Socket, ws_encode(10, Payload)),
            handle_username_data(Socket, Rest);
        {ok, _OtherOpcode, _Payload, Rest} ->
            handle_username_data(Socket, Rest);
        {error, too_large} ->
            gen_tcp:close(Socket);
        more ->
            inet:setopts(Socket, [{active, once}]),
            ws_username_loop(Socket, Buf)
    end.

%% ---- post-login loop ---------------------------------------------------

ws_loop(Socket, Name, Buf) ->
    receive
        {tcp, Socket, Data} ->
            handle_ws_data(Socket, Name, <<Buf/binary, Data/binary>>);
        {tcp_closed, Socket} ->
            chat_room:unregister_user(Name);
        {tcp_error, Socket, _Reason} ->
            chat_room:unregister_user(Name);
        {chat_message, Id, From, Text, ReplyTo} ->
            ws_send_chat(Socket, "chat", Id, From, Text, ReplyTo),
            ws_loop(Socket, Name, Buf);
        {private_message, Id, From, Text, ReplyTo} ->
            ws_send_chat(Socket, "private", Id, From, Text, ReplyTo),
            ws_loop(Socket, Name, Buf);
        {system, Text} ->
            ws_send_json(Socket, "system", Text),
            ws_loop(Socket, Name, Buf);
        {group_message, GroupName, Id, From, Text, ReplyTo} ->
            ws_send_group_message(Socket, GroupName, Id, From, Text, ReplyTo),
            ws_loop(Socket, Name, Buf);
        {group_system, GroupName, Text} ->
            ws_send_group_system(Socket, GroupName, Text),
            ws_loop(Socket, Name, Buf);
        {group_members, GroupName, Members, Owner} ->
            ws_send_group_members(Socket, GroupName, Members, Owner),
            ws_loop(Socket, Name, Buf);
        {removed_from_group, GroupName} ->
            ws_send_json(Socket, "left_group", GroupName),
            ws_loop(Socket, Name, Buf);
        {added_to_group, GroupName, Members, By} ->
            ws_send_added_to_group(Socket, GroupName, Members, By),
            ws_loop(Socket, Name, Buf);
        {typing, From} ->
            ws_send_json(Socket, "typing", From),
            ws_loop(Socket, Name, Buf);
        {typing_dm, From} ->
            ws_send(Socket, json_obj2([{"type", {str, "typing_dm"}}, {"from", {str, From}}])),
            ws_loop(Socket, Name, Buf);
        {group_typing, GroupName, From} ->
            ws_send(Socket, json_obj2([{"type", {str, "group_typing"}}, {"group", {str, GroupName}}, {"from", {str, From}}])),
            ws_loop(Socket, Name, Buf);
        {dm_read, From} ->
            ws_send(Socket, json_obj2([{"type", {str, "dm_read"}}, {"from", {str, From}}])),
            ws_loop(Socket, Name, Buf);
        {reaction, Scope, MessageId, Reactions} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "reaction"}}, {"scope", {str, Scope}},
                {"messageId", {raw, integer_to_list(MessageId)}},
                {"reactions", {raw, reactions_json(Reactions)}}])),
            ws_loop(Socket, Name, Buf);
        {dm_reaction, MessageId, Reactions, UserA, UserB} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "dm_reaction"}},
                {"messageId", {raw, integer_to_list(MessageId)}},
                {"reactions", {raw, reactions_json(Reactions)}},
                {"userA", {str, UserA}}, {"userB", {str, UserB}}])),
            ws_loop(Socket, Name, Buf);
        {profile_update, User, Avatar, Status} ->
            AvatarField = case Avatar of undefined -> {"avatar", {raw, "null"}}; A -> {"avatar", {str, A}} end,
            StatusField = case Status of undefined -> {"status", {raw, "null"}}; S -> {"status", {str, S}} end,
            ws_send(Socket, json_obj2([{"type", {str, "profile"}}, {"user", {str, User}}, AvatarField, StatusField])),
            ws_loop(Socket, Name, Buf);
        {edited, MessageId, Text} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "edited"}}, {"scope", {str, "global"}},
                {"messageId", {raw, integer_to_list(MessageId)}}, {"text", {str, Text}}])),
            ws_loop(Socket, Name, Buf);
        {dm_edited, MessageId, UserA, UserB, Text} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "dm_edited"}},
                {"messageId", {raw, integer_to_list(MessageId)}}, {"text", {str, Text}},
                {"userA", {str, UserA}}, {"userB", {str, UserB}}])),
            ws_loop(Socket, Name, Buf);
        {group_edited, GroupName, MessageId, Text} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "group_edited"}}, {"group", {str, GroupName}},
                {"messageId", {raw, integer_to_list(MessageId)}}, {"text", {str, Text}}])),
            ws_loop(Socket, Name, Buf);
        {deleted, MessageId} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "deleted"}}, {"scope", {str, "global"}},
                {"messageId", {raw, integer_to_list(MessageId)}}])),
            ws_loop(Socket, Name, Buf);
        {dm_deleted, MessageId, UserA, UserB} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "dm_deleted"}},
                {"messageId", {raw, integer_to_list(MessageId)}},
                {"userA", {str, UserA}}, {"userB", {str, UserB}}])),
            ws_loop(Socket, Name, Buf);
        {group_deleted, GroupName, MessageId} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "group_deleted"}}, {"group", {str, GroupName}},
                {"messageId", {raw, integer_to_list(MessageId)}}])),
            ws_loop(Socket, Name, Buf);
        {own_message_id, Id} ->
            ws_send(Socket, json_obj2([{"type", {str, "own_message_id"}}, {"id", {raw, integer_to_list(Id)}}])),
            ws_loop(Socket, Name, Buf);
        {group_reaction, GroupName, MessageId, Reactions} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "group_reaction"}}, {"group", {str, GroupName}},
                {"messageId", {raw, integer_to_list(MessageId)}},
                {"reactions", {raw, reactions_json(Reactions)}}])),
            ws_loop(Socket, Name, Buf);
        {link_preview, Scope, MessageId, Preview} ->
            ws_send(Socket, json_obj2(
                [{"type", {str, "link_preview"}}, {"scope", {str, Scope}},
                 {"messageId", {raw, integer_to_list(MessageId)}}]
                ++ preview_fields(Preview))),
            ws_loop(Socket, Name, Buf);
        {dm_link_preview, MessageId, Preview, UserA, UserB} ->
            ws_send(Socket, json_obj2(
                [{"type", {str, "dm_link_preview"}},
                 {"messageId", {raw, integer_to_list(MessageId)}},
                 {"userA", {str, UserA}}, {"userB", {str, UserB}}]
                ++ preview_fields(Preview))),
            ws_loop(Socket, Name, Buf);
        {group_link_preview, GroupName, MessageId, Preview} ->
            ws_send(Socket, json_obj2(
                [{"type", {str, "group_link_preview"}}, {"group", {str, GroupName}},
                 {"messageId", {raw, integer_to_list(MessageId)}}]
                ++ preview_fields(Preview))),
            ws_loop(Socket, Name, Buf);
        {gif, gif_results, Query, Gifs} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "gif_results"}}, {"query", {str, Query}},
                {"results", {raw, gifs_json(Gifs)}}])),
            ws_loop(Socket, Name, Buf);
        {sticker, gif_results, Query, Stickers} ->
            ws_send(Socket, json_obj2([
                {"type", {str, "sticker_results"}}, {"query", {str, Query}},
                {"results", {raw, gifs_json(Stickers)}}])),
            ws_loop(Socket, Name, Buf)
    end.

%% See handle_username_data/2 for why this recurses on Rest rather than
%% going back through ws_loop's blocking receive.
handle_ws_data(Socket, Name, Buf) ->
    case ws_decode(Buf) of
        {ok, 1, Payload, Rest} ->
            case string:trim(binary_to_list(Payload)) of
                "/quit" ->
                    chat_room:unregister_user(Name),
                    gen_tcp:send(Socket, ws_encode(8, <<>>)),
                    gen_tcp:close(Socket);
                Line ->
                    handle_line(Socket, Name, Line),
                    handle_ws_data(Socket, Name, Rest)
            end;
        {ok, 8, _Payload, _Rest} ->
            chat_room:unregister_user(Name),
            gen_tcp:close(Socket);
        {ok, 9, Payload, Rest} ->
            gen_tcp:send(Socket, ws_encode(10, Payload)),
            handle_ws_data(Socket, Name, Rest);
        {ok, _OtherOpcode, _Payload, Rest} ->
            handle_ws_data(Socket, Name, Rest);
        {error, too_large} ->
            chat_room:unregister_user(Name),
            gen_tcp:close(Socket);
        more ->
            inet:setopts(Socket, [{active, once}]),
            ws_loop(Socket, Name, Buf)
    end.

handle_line(_Socket, _Name, "") ->
    ok;
handle_line(Socket, _Name, "/list") ->
    ws_send_users(Socket, chat_room:list_users());
handle_line(Socket, Name, "/msg " ++ Rest) ->
    case string:split(Rest, " ") of
        [_To, Text] when length(Text) > ?MAX_MESSAGE_LEN ->
            ws_send_json(Socket, "error",
                io_lib:format("Message too long (max ~p chars)", [?MAX_MESSAGE_LEN]));
        [To, Text] when Text =/= "" ->
            case chat_room:send_private(Name, To, Text) of
                {ok, Id} ->
                    ws_send(Socket, json_obj2([
                        {"type", {str, "dm_ack"}}, {"with", {str, To}}, {"status", {str, "delivered"}},
                        {"id", {raw, integer_to_list(Id)}}]));
                {error, not_found} ->
                    ws_send_json(Socket, "error", "No such user: " ++ To)
            end;
        _ ->
            ws_send_json(Socket, "error", "Usage: /msg <username> <message>")
    end;
handle_line(Socket, Name, "/reply " ++ Rest) ->
    case string:split(Rest, " ") of
        [_IdStr, Text] when length(Text) > ?MAX_MESSAGE_LEN ->
            ws_send_json(Socket, "error",
                io_lib:format("Message too long (max ~p chars)", [?MAX_MESSAGE_LEN]));
        [IdStr, Text] when Text =/= "" ->
            case string:to_integer(IdStr) of
                {ReplyTo, []} -> chat_room:broadcast(Name, Text, ReplyTo);
                _ -> ws_send_json(Socket, "error", "Usage: /reply <messageId> <message>")
            end;
        _ ->
            ws_send_json(Socket, "error", "Usage: /reply <messageId> <message>")
    end;
handle_line(Socket, Name, "/replydm " ++ Rest) ->
    case string:split(Rest, " ") of
        [To, Rest2] ->
            case string:split(Rest2, " ") of
                [_IdStr, Text] when length(Text) > ?MAX_MESSAGE_LEN ->
                    ws_send_json(Socket, "error",
                        io_lib:format("Message too long (max ~p chars)", [?MAX_MESSAGE_LEN]));
                [IdStr, Text] when Text =/= "" ->
                    case string:to_integer(IdStr) of
                        {ReplyTo, []} ->
                            case chat_room:send_private(Name, To, Text, ReplyTo) of
                                {ok, Id} ->
                                    ws_send(Socket, json_obj2([
                                        {"type", {str, "dm_ack"}}, {"with", {str, To}}, {"status", {str, "delivered"}},
                                        {"id", {raw, integer_to_list(Id)}}]));
                                {error, not_found} ->
                                    ws_send_json(Socket, "error", "No such user: " ++ To)
                            end;
                        _ -> ws_send_json(Socket, "error", "Usage: /replydm <username> <messageId> <message>")
                    end;
                _ ->
                    ws_send_json(Socket, "error", "Usage: /replydm <username> <messageId> <message>")
            end;
        _ ->
            ws_send_json(Socket, "error", "Usage: /replydm <username> <messageId> <message>")
    end;
handle_line(Socket, Name, "/history " ++ Rest) ->
    case string:split(Rest, " ") of
        ["global"] ->
            send_history_payload(Socket, "global", [], chat_store:load_history("global"));
        ["dm", Other] ->
            Key = chat_store:dm_key(Name, Other),
            send_history_payload(Socket, "dm", [{"with", Other}], chat_store:load_history(Key));
        ["group", GroupName] ->
            Key = "group:" ++ GroupName,
            send_history_payload(Socket, "group", [{"group", GroupName}], chat_store:load_history(Key));
        _ ->
            ok
    end;
handle_line(_Socket, Name, "/typing " ++ Rest) ->
    case string:split(Rest, " ") of
        ["global"] -> chat_room:typing(Name);
        ["dm", Other] -> chat_room:typing_dm(Name, Other);
        ["group", GroupName] -> chat_groups:typing(GroupName, Name);
        _ -> ok
    end;
handle_line(_Socket, Name, "/read " ++ Rest) ->
    case string:split(Rest, " ") of
        ["dm", Other] -> chat_room:mark_read(Name, Other);
        _ -> ok
    end;
%% ---- DM end-to-end encryption: public key exchange ----
%% The server only ever stores/relays the public key and (separately)
%% opaque ciphertext -- it never sees a private key or plaintext DM
%% content. Publishing is idempotent (last write wins), same as the web
%% client re-sending "/list" -- a client just re-publishes on every
%% connect, no separate "do I already have one" check needed.
handle_line(_Socket, Name, "/pubkey " ++ Base64Key) when Base64Key =/= "" ->
    chat_store:set_pubkey(Name, Base64Key);
handle_line(Socket, _Name, "/getpubkey " ++ Other) ->
    KeyField = case chat_store:get_pubkey(Other) of
        undefined -> {"key", {raw, "null"}};
        Key -> {"key", {str, Key}}
    end,
    ws_send(Socket, json_obj2([{"type", {str, "pubkey"}}, {"user", {str, Other}}, KeyField]));
%% ---- profile: avatar + status ----
handle_line(_Socket, Name, "/setavatar " ++ Url) ->
    chat_store:set_avatar(Name, Url),
    chat_room:broadcast_profile(Name);
handle_line(_Socket, Name, "/setstatus " ++ Status) ->
    chat_store:set_status(Name, Status),
    chat_room:broadcast_profile(Name);
handle_line(Socket, _Name, "/getprofile " ++ Other) ->
    {Avatar, Status} = chat_store:get_profile(Other),
    AvatarField = case Avatar of undefined -> {"avatar", {raw, "null"}}; A -> {"avatar", {str, A}} end,
    StatusField = case Status of undefined -> {"status", {raw, "null"}}; S -> {"status", {str, S}} end,
    ws_send(Socket, json_obj2([{"type", {str, "profile"}}, {"user", {str, Other}}, AvatarField, StatusField]));
handle_line(_Socket, _Name, "/gifsearch") ->
    %% No query yet -- e.g. the picker was just opened. The trailing-space
    %% variant below can never carry an empty Query itself: handle_ws_data
    %% trims the whole line before it reaches here, so "/gifsearch " (with
    %% nothing after) arrives as this exact bare form instead.
    chat_gif:search_async(gif, "", self());
handle_line(_Socket, _Name, "/gifsearch " ++ Query) ->
    chat_gif:search_async(gif, Query, self());
handle_line(_Socket, _Name, "/stickersearch") ->
    chat_gif:search_async(sticker, "", self());
handle_line(_Socket, _Name, "/stickersearch " ++ Query) ->
    chat_gif:search_async(sticker, Query, self());
handle_line(_Socket, Name, "/react " ++ Rest) ->
    case string:split(Rest, " ", all) of
        ["global", MsgIdStr, Emoji] ->
            with_int(MsgIdStr, fun(Id) -> chat_room:react_global(Id, Name, Emoji) end);
        ["dm", Other, MsgIdStr, Emoji] ->
            with_int(MsgIdStr, fun(Id) -> chat_room:react_dm(Id, Name, Emoji, Other) end);
        ["group", GroupName, MsgIdStr, Emoji] ->
            with_int(MsgIdStr, fun(Id) -> chat_groups:react(GroupName, Id, Name, Emoji) end);
        _ ->
            ok
    end;
%% /edit <global|dm Other|group Name> <MsgId> <new text> -- new text may
%% contain spaces, so only the leading tokens are split off.
handle_line(_Socket, Name, "/edit " ++ Rest) ->
    case string:split(Rest, " ") of
        ["global", R2] ->
            case string:split(R2, " ") of
                [IdStr, Text] when Text =/= "" -> with_int(IdStr, fun(Id) -> chat_room:edit_global(Id, Name, Text) end);
                _ -> ok
            end;
        ["dm", R2] ->
            case string:split(R2, " ") of
                [Other, R3] ->
                    case string:split(R3, " ") of
                        [IdStr, Text] when Text =/= "" -> with_int(IdStr, fun(Id) -> chat_room:edit_dm(Id, Name, Other, Text) end);
                        _ -> ok
                    end;
                _ -> ok
            end;
        ["group", R2] ->
            case string:split(R2, " ") of
                [GroupName, R3] ->
                    case string:split(R3, " ") of
                        [IdStr, Text] when Text =/= "" -> with_int(IdStr, fun(Id) -> chat_groups:edit(GroupName, Id, Name, Text) end);
                        _ -> ok
                    end;
                _ -> ok
            end;
        _ ->
            ok
    end;
handle_line(_Socket, Name, "/delete " ++ Rest) ->
    case string:split(Rest, " ", all) of
        ["global", MsgIdStr] ->
            with_int(MsgIdStr, fun(Id) -> chat_room:delete_global(Id, Name) end);
        ["dm", Other, MsgIdStr] ->
            with_int(MsgIdStr, fun(Id) -> chat_room:delete_dm(Id, Name, Other) end);
        ["group", GroupName, MsgIdStr] ->
            with_int(MsgIdStr, fun(Id) -> chat_groups:delete(GroupName, Id, Name) end);
        _ ->
            ok
    end;
handle_line(Socket, Name, "/creategroup " ++ Rest) ->
    case string:trim(Rest) of
        "" ->
            ws_send_json(Socket, "error", "Usage: /creategroup <name>");
        GroupName when length(GroupName) > ?MAX_GROUP_NAME_LEN ->
            ws_send_json(Socket, "error",
                io_lib:format("Group name too long (max ~p chars)", [?MAX_GROUP_NAME_LEN]));
        GroupName ->
            case chat_groups:create_group(GroupName, Name) of
                {ok, Members} ->
                    ws_send_group_created(Socket, GroupName, Members),
                    ws_send_group_members(Socket, GroupName, Members, Name);
                {error, exists} -> ws_send_json(Socket, "error", "A group with that name already exists")
            end
    end;
handle_line(Socket, Name, "/addmember " ++ Rest) ->
    case string:split(Rest, " ") of
        [GroupName, NewMember] when NewMember =/= "" ->
            case chat_groups:add_member(GroupName, Name, NewMember) of
                {ok, Members} -> ws_send_group_created(Socket, GroupName, Members);
                {error, not_found} -> ws_send_json(Socket, "error", "No such group: " ++ GroupName);
                {error, not_member} -> ws_send_json(Socket, "error", "You're not in that group");
                {error, already_member} -> ws_send_json(Socket, "error", NewMember ++ " is already in the group");
                {error, user_offline} -> ws_send_json(Socket, "error", NewMember ++ " isn't online right now")
            end;
        _ ->
            ws_send_json(Socket, "error", "Usage: /addmember <group> <username>")
    end;
handle_line(Socket, Name, "/removemember " ++ Rest) ->
    case string:split(Rest, " ") of
        [GroupName, Target] when Target =/= "" ->
            case chat_groups:remove_member(GroupName, Name, Target) of
                ok -> ok;
                {error, not_found} -> ws_send_json(Socket, "error", "No such group: " ++ GroupName);
                {error, not_owner} -> ws_send_json(Socket, "error", "Only the group owner can remove members");
                {error, cannot_remove_owner} -> ws_send_json(Socket, "error", "The owner can't be removed");
                {error, not_member} -> ws_send_json(Socket, "error", Target ++ " isn't in the group")
            end;
        _ ->
            ws_send_json(Socket, "error", "Usage: /removemember <group> <user>")
    end;
handle_line(Socket, Name, "/leavegroup " ++ Rest) ->
    GroupName = string:trim(Rest),
    case chat_groups:leave_group(GroupName, Name) of
        ok -> ws_send_json(Socket, "left_group", GroupName);
        {error, not_found} -> ws_send_json(Socket, "error", "No such group: " ++ GroupName);
        {error, not_member} -> ws_send_json(Socket, "error", "You're not in that group")
    end;
handle_line(Socket, Name, "/groupmsg " ++ Rest) ->
    case string:split(Rest, " ") of
        [_GroupName, Text] when length(Text) > ?MAX_MESSAGE_LEN ->
            ws_send_json(Socket, "error",
                io_lib:format("Message too long (max ~p chars)", [?MAX_MESSAGE_LEN]));
        [GroupName, Text] when Text =/= "" ->
            case chat_groups:group_message(GroupName, Name, Text) of
                {ok, Id} ->
                    ws_send(Socket, json_obj2([
                        {"type", {str, "group_msg_ack"}}, {"group", {str, GroupName}},
                        {"id", {raw, integer_to_list(Id)}}]));
                {error, not_found} -> ws_send_json(Socket, "error", "No such group: " ++ GroupName);
                {error, not_member} -> ws_send_json(Socket, "error", "You're not in that group")
            end;
        _ ->
            ws_send_json(Socket, "error", "Usage: /groupmsg <group> <message>")
    end;
handle_line(Socket, Name, "/replygroup " ++ Rest) ->
    case string:split(Rest, " ") of
        [GroupName, Rest2] ->
            case string:split(Rest2, " ") of
                [_IdStr, Text] when length(Text) > ?MAX_MESSAGE_LEN ->
                    ws_send_json(Socket, "error",
                        io_lib:format("Message too long (max ~p chars)", [?MAX_MESSAGE_LEN]));
                [IdStr, Text] when Text =/= "" ->
                    case string:to_integer(IdStr) of
                        {ReplyTo, []} ->
                            case chat_groups:group_message(GroupName, Name, Text, ReplyTo) of
                                {ok, Id} ->
                                    ws_send(Socket, json_obj2([
                                        {"type", {str, "group_msg_ack"}}, {"group", {str, GroupName}},
                                        {"id", {raw, integer_to_list(Id)}}]));
                                {error, not_found} -> ws_send_json(Socket, "error", "No such group: " ++ GroupName);
                                {error, not_member} -> ws_send_json(Socket, "error", "You're not in that group")
                            end;
                        _ -> ws_send_json(Socket, "error", "Usage: /replygroup <group> <messageId> <message>")
                    end;
                _ ->
                    ws_send_json(Socket, "error", "Usage: /replygroup <group> <messageId> <message>")
            end;
        _ ->
            ws_send_json(Socket, "error", "Usage: /replygroup <group> <messageId> <message>")
    end;
handle_line(Socket, Name, "/groups") ->
    ws_send_groups(Socket, chat_groups:list_groups_for(Name));
handle_line(Socket, _Name, Text) when length(Text) > ?MAX_MESSAGE_LEN ->
    ws_send_json(Socket, "error",
        io_lib:format("Message too long (max ~p chars)", [?MAX_MESSAGE_LEN]));
%% Safety net: a bare command name with no argument (e.g. "/getprofile"
%% with no trailing " <user>") doesn't match that command's own clause
%% above (which requires the space), so without this it falls all the way
%% through to the plain-broadcast catch-all below and gets sent to the
%% whole room as literal chat text -- confirmed live, this is exactly
%% what was showing up as spurious "/getprofile" messages. Swallow any
%% of these known command names on their own rather than broadcasting
%% them; this doesn't affect ordinary chat text, which never happens to
%% exactly equal one of these.
handle_line(_Socket, _Name, Text) when
    Text =:= "/msg"; Text =:= "/reply"; Text =:= "/replydm"; Text =:= "/history";
    Text =:= "/typing"; Text =:= "/read"; Text =:= "/pubkey"; Text =:= "/getpubkey";
    Text =:= "/setavatar"; Text =:= "/setstatus"; Text =:= "/getprofile";
    Text =:= "/react"; Text =:= "/delete"; Text =:= "/edit"; Text =:= "/creategroup";
    Text =:= "/addmember"; Text =:= "/removemember"; Text =:= "/leavegroup"; Text =:= "/groupmsg";
    Text =:= "/replygroup" ->
    ok;
handle_line(_Socket, Name, Text) ->
    chat_room:broadcast(Name, Text).

%% ---- WebSocket framing (RFC 6455) --------------------------------------

ws_encode(Opcode, Payload) ->
    Len = byte_size(Payload),
    Header = if
        Len =< 125 -> <<1:1, 0:3, Opcode:4, 0:1, Len:7>>;
        Len =< 65535 -> <<1:1, 0:3, Opcode:4, 0:1, 126:7, Len:16>>;
        true -> <<1:1, 0:3, Opcode:4, 0:1, 127:7, Len:64>>
    end,
    <<Header/binary, Payload/binary>>.

ws_decode(Bin) ->
    case Bin of
        <<_Fin:1, _Rsv:3, Opcode:4, Mask:1, Len7:7, Rest/binary>> ->
            decode_len(Opcode, Mask, Len7, Rest);
        _ ->
            more
    end.

decode_len(Opcode, Mask, 126, Rest) ->
    case Rest of
        <<Len:16, Rest2/binary>> -> check_len(Opcode, Mask, Len, Rest2);
        _ -> more
    end;
decode_len(Opcode, Mask, 127, Rest) ->
    case Rest of
        <<Len:64, Rest2/binary>> -> check_len(Opcode, Mask, Len, Rest2);
        _ -> more
    end;
decode_len(Opcode, Mask, Len7, Rest) ->
    check_len(Opcode, Mask, Len7, Rest).

%% Reject an oversized declared length immediately rather than buffering
%% while we wait for a body that may never fully arrive (or would, if it
%% did, be a multi-gigabyte allocation) — see ?MAX_WS_FRAME_LEN.
check_len(_Opcode, _Mask, Len, _Rest) when Len > ?MAX_WS_FRAME_LEN ->
    {error, too_large};
check_len(Opcode, Mask, Len, Rest) ->
    decode_mask(Opcode, Mask, Len, Rest).

decode_mask(Opcode, 1, Len, Rest) when byte_size(Rest) >= 4 ->
    <<MaskKey:4/binary, Body/binary>> = Rest,
    case byte_size(Body) >= Len of
        true ->
            <<Payload:Len/binary, Leftover/binary>> = Body,
            {ok, Opcode, unmask(Payload, MaskKey), Leftover};
        false ->
            more
    end;
decode_mask(_Opcode, 1, _Len, _Rest) ->
    more;
decode_mask(Opcode, 0, Len, Rest) when byte_size(Rest) >= Len ->
    <<Payload:Len/binary, Leftover/binary>> = Rest,
    {ok, Opcode, Payload, Leftover};
decode_mask(_Opcode, 0, _Len, _Rest) ->
    more.

unmask(Payload, MaskKey) ->
    Keys = list_to_tuple(binary_to_list(MaskKey)),
    list_to_binary(unmask_bytes(binary_to_list(Payload), Keys, 0)).

unmask_bytes([], _Keys, _I) -> [];
unmask_bytes([B | Rest], Keys, I) ->
    K = element((I rem 4) + 1, Keys),
    [B bxor K | unmask_bytes(Rest, Keys, I + 1)].

%% ---- tiny JSON encoding (no external deps) -----------------------------

ws_send(Socket, Json) ->
    gen_tcp:send(Socket, ws_encode(1, list_to_binary(Json))).

ws_send_json(Socket, Type, Text) ->
    ws_send(Socket, json_obj([{"type", Type}, {"text", lists:flatten(Text)}])).

ws_send_chat(Socket, Type, Id, From, Text, ReplyTo) ->
    ws_send(Socket, json_obj2([
        {"type", {str, Type}}, {"id", {raw, integer_to_list(Id)}},
        {"from", {str, From}}, {"text", {str, Text}},
        {"ts", {raw, integer_to_list(erlang:system_time(millisecond))}}, reply_field(ReplyTo)])).

ws_send_users(Socket, Users) ->
    ws_send(Socket, json_obj2([{"type", {str, "users"}}, {"list", {raw, json_string_array(Users)}}])).

ws_send_group_created(Socket, GroupName, Members) ->
    ws_send(Socket, json_obj2([
        {"type", {str, "group_created"}},
        {"name", {str, GroupName}},
        {"members", {raw, json_string_array(Members)}}])).

ws_send_group_message(Socket, GroupName, Id, From, Text, ReplyTo) ->
    ws_send(Socket, json_obj2([
        {"type", {str, "group_message"}},
        {"group", {str, GroupName}},
        {"id", {raw, integer_to_list(Id)}},
        {"from", {str, From}},
        {"text", {str, Text}},
        {"ts", {raw, integer_to_list(erlang:system_time(millisecond))}},
        reply_field(ReplyTo)])).

ws_send_group_members(Socket, GroupName, Members, Owner) ->
    ws_send(Socket, json_obj2([
        {"type", {str, "group_members"}},
        {"name", {str, GroupName}},
        {"members", {raw, json_string_array(Members)}},
        {"owner", {str, Owner}}])).

ws_send_group_system(Socket, GroupName, Text) ->
    ws_send(Socket, json_obj2([
        {"type", {str, "group_system"}},
        {"group", {str, GroupName}},
        {"text", {str, Text}}])).

ws_send_added_to_group(Socket, GroupName, Members, By) ->
    ws_send(Socket, json_obj2([
        {"type", {str, "added_to_group"}},
        {"name", {str, GroupName}},
        {"members", {raw, json_string_array(Members)}},
        {"by", {str, By}}])).

ws_send_groups(Socket, Groups) ->
    Items = [json_obj2([{"name", {str, Name}}, {"members", {raw, json_string_array(Members)}},
                        {"owner", {str, case chat_groups:owner(Name) of {ok, O} -> O; _ -> "" end}}])
             || {Name, Members} <- Groups],
    ws_send(Socket, json_obj2([
        {"type", {str, "groups"}},
        {"list", {raw, "[" ++ string:join(Items, ",") ++ "]"}}])).

%% Scope is "global" | "dm" | "group"; ExtraFields identify which
%% conversation (e.g. [{"with", Username}] for a dm, [{"group", Name}] for
%% a group -- [] for global); Items are {Id, From, Text, Private, Reactions,
%% Preview, ReplyTo} tuples from chat_store:load_history/1 (Preview/ReplyTo
%% are [] if none).
send_history_payload(Socket, Scope, ExtraFields, Items) ->
    ItemsJson = [json_obj2(
        [{"id", {raw, integer_to_list(Id)}}, {"from", {str, From}}, {"text", {str, Text}},
         {"private", {raw, bool_str(Private)}}, {"reactions", {raw, reactions_json(Reactions)}},
         {"deleted", {raw, bool_str(Deleted)}},
         {"ts", {raw, integer_to_list(Ts)}}, {"edited", {raw, bool_str(Edited)}},
         reply_field(ReplyTo)]
        ++ preview_fields(Preview))
                 || {Id, From, Text, Private, Reactions, Preview, ReplyTo, Deleted, Ts, Edited} <- Items],
    ListJson = "[" ++ string:join(ItemsJson, ",") ++ "]",
    Fields = [{"type", {str, "history"}}, {"scope", {str, Scope}}] ++
             [{K, {str, V}} || {K, V} <- ExtraFields] ++
             [{"list", {raw, ListJson}}],
    ws_send(Socket, json_obj2(Fields)).

bool_str(true) -> "true";
bool_str(false) -> "false".

reactions_json(Reactions) ->
    Items = [json_obj2([{"user", {str, U}}, {"emoji", {str, E}}]) || {U, E} <- Reactions],
    "[" ++ string:join(Items, ",") ++ "]".

gifs_json(Gifs) ->
    Items = [json_obj2([
        {"id", {str, Id}}, {"url", {str, Url}}, {"preview", {str, Preview}},
        {"width", {str, Width}}, {"height", {str, Height}}])
             || {Id, Url, Preview, Width, Height} <- Gifs],
    "[" ++ string:join(Items, ",") ++ "]".

%% Preview is [] (none) or {Title, Description, Image}, each of which is
%% itself `undefined` or a string -- returns a list of {K, {str, V}} pairs
%% ready to splice into a json_obj2 field list. Always emits all four keys
%% (empty string for missing ones) so the client doesn't need to branch on
%% whether they're present. Used identically for a live push and a history
%% item, so both shapes go through this same function.
preview_fields([]) ->
    [{"previewUrl", {str, ""}}, {"previewTitle", {str, ""}},
     {"previewDescription", {str, ""}}, {"previewImage", {str, ""}}];
preview_fields({Url, Title, Description, Image}) ->
    [{"previewUrl", {str, default_str(Url)}},
     {"previewTitle", {str, default_str(Title)}},
     {"previewDescription", {str, default_str(Description)}},
     {"previewImage", {str, default_str(Image)}}].

default_str(undefined) -> "";
default_str(V) -> V.

%% ReplyTo is [] (not a reply) or a message id -- emitted as JSON null or a
%% raw integer so the client can tell "no reply" apart from "reply to
%% message 0" without a sentinel value collision.
reply_field([]) -> {"replyTo", {raw, "null"}};
reply_field(ReplyTo) -> {"replyTo", {raw, integer_to_list(ReplyTo)}}.

%% Parses Str as a plain integer (no leading/trailing junk) and calls Fun
%% with it; silently does nothing on a malformed id rather than crashing
%% the connection on attacker-controlled input.
with_int(Str, Fun) ->
    case string:to_integer(Str) of
        {Int, []} -> Fun(Int);
        _ -> ok
    end.

json_obj(Pairs) ->
    Body = string:join(
        ["\"" ++ K ++ "\":\"" ++ json_escape(V) ++ "\"" || {K, V} <- Pairs], ","),
    "{" ++ Body ++ "}".

%% General-purpose JSON object builder: each field is either a plain
%% string value ({str, V}, quoted+escaped) or a pre-built JSON fragment
%% ({raw, V}, embedded verbatim -- e.g. an array from json_string_array/1).
json_obj2(Pairs) ->
    "{" ++ string:join([json_field(P) || P <- Pairs], ",") ++ "}".

json_field({K, {str, V}}) ->
    "\"" ++ K ++ "\":\"" ++ json_escape(lists:flatten(V)) ++ "\"";
json_field({K, {raw, V}}) ->
    "\"" ++ K ++ "\":" ++ V.

json_string_array(List) ->
    "[" ++ string:join(["\"" ++ json_escape(X) ++ "\"" || X <- List], ",") ++ "]".

json_escape(Str) ->
    lists:flatten([escape_char(C) || C <- Str]).

escape_char($") -> "\\\"";
escape_char($\\) -> "\\\\";
escape_char($\n) -> "\\n";
escape_char($\r) -> "\\r";
escape_char($\t) -> "\\t";
escape_char(C) when C < 32 -> io_lib:format("\\u~4.16.0B", [C]);
escape_char(C) -> [C].
