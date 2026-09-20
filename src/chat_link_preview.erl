%%% Fetches Open Graph / <title> metadata for a link shared in a message,
%%% so the client can render a small preview card instead of a bare URL.
%%%
%%% The one genuinely risky thing here is "the server fetches a URL someone
%%% else typed" -- classic SSRF territory (pointing the server at its own
%%% internal network, a cloud metadata endpoint, another host on the LAN,
%%% etc). Everything in validate_host/1 exists to close that off:
%%%   - only http/https
%%%   - the literal or *resolved* IP must be public (checked against the
%%%     standard private/reserved IPv4 ranges)
%%%   - IPv6 targets are rejected outright rather than reimplementing the
%%%     private-range logic for it -- this app has no need to preview an
%%%     IPv6-only link
%%%   - redirects are never auto-followed: a public host could 302 to a
%%%     private one, and validating only the first hop would miss that
%%% Fetching itself uses httpc (part of stock OTP's inets app -- no external
%%% dependency), with a short timeout so one slow/malicious server can't
%%% tie up a fetch indefinitely.
-module(chat_link_preview).
-export([maybe_fetch_and_notify/3]).

-define(FETCH_TIMEOUT, 5000).
-define(CONNECT_TIMEOUT, 3000).
-define(MAX_FIELD_LEN, 300).
-define(URL_RE, "https?://[^\\s<>\"']+").

%% Looks for the first URL in Text; if there is one, fetches its preview
%% *asynchronously* (never blocks the caller, which is in the middle of
%% routing the message itself) and calls NotifyFun(MessageId, Url, Preview)
%% once it's ready. Preview fetch failures are silent -- a message with an
%% unpreviewable link is just a message with an unpreviewable link, not an
%% error condition worth surfacing.
%%
%% Skipped entirely when the *whole* message is just a bare link to a media
%% file (GIF/sticker picks, uploaded images, voice notes all send exactly
%% this shape -- see GIF_RE/AUDIO_RE in web/index.html, which this mirrors).
%% Those already render as an inline image/audio player; fetching a "web
%% page preview" of the picture is redundant work and, worse, produces a
%% second, distracting card of the *page* Giphy serves that image on
%% (title/description of an unrelated GIF-hosting page) stacked right below
%% the picture that's already the actual content.
maybe_fetch_and_notify(MessageId, Text, NotifyFun) ->
    case find_url(Text) of
        {ok, Url} ->
            case is_bare_media_url(Text, Url) of
                true ->
                    ok;
                false ->
                    spawn(fun() ->
                        case fetch_preview(Url) of
                            {ok, {Title, Description, Image}} ->
                                %% Url travels bundled inside the stored/pushed
                                %% Preview tuple itself now, rather than as a
                                %% separate argument -- one shape whether a caller
                                %% got it from a live push or from history.
                                FullPreview = {Url, Title, Description, Image},
                                chat_store:save_link_preview(MessageId, FullPreview),
                                NotifyFun(MessageId, FullPreview);
                            error ->
                                ok
                        end
                    end),
                    ok
            end;
        error ->
            ok
    end.

-define(MEDIA_EXTENSIONS, [".gif", ".png", ".jpg", ".jpeg", ".webp",
                           ".webm", ".ogg", ".m4a"]).

is_bare_media_url(Text, Url) ->
    string:trim(Text) =:= Url andalso
    lists:any(fun(Ext) -> lists:suffix(Ext, string:lowercase(strip_query(Url))) end,
              ?MEDIA_EXTENSIONS).

strip_query(Url) ->
    hd(string:split(Url, "?")).

find_url(Text) ->
    %% `unicode` matters here: Text is a decoded Erlang string (a list of
    %% codepoints from user-typed message text, which can contain anything
    %% up to full Unicode -- emoji, non-Latin scripts). Without this option
    %% re:run assumes each list element is a single Latin-1 byte and throws
    %% badarg the moment a codepoint over 255 shows up anywhere in the
    %% subject, even far from the actual match.
    case re:run(Text, ?URL_RE, [{capture, first, list}, unicode]) of
        {match, [Url]} -> {ok, Url};
        nomatch -> error
    end.

fetch_preview(Url) ->
    case validate_public_url(Url) of
        ok ->
            %% ensure_all_started, not ensure_started: ssl depends on
            %% public_key (and inets pulls its own deps too), and this node
            %% never happens to start those on its own otherwise -- plain
            %% ensure_started only starts the named app, silently leaving an
            %% unstarted dependency for httpc to fail on the first time an
            %% https:// link is fetched.
            {ok, _} = application:ensure_all_started(inets),
            {ok, _} = application:ensure_all_started(ssl),
            Opts = [{timeout, ?FETCH_TIMEOUT}, {connect_timeout, ?CONNECT_TIMEOUT}, {autoredirect, false}],
            Req = {Url, [{"User-Agent", "ErlangChatLinkPreview/1.0"}, {"Accept", "text/html"}]},
            case httpc:request(get, Req, Opts, [{body_format, binary}]) of
                {ok, {{_, 200, _}, Headers, Body}} ->
                    case looks_like_html(Headers) of
                        true -> extract_preview(Body);
                        false -> error
                    end;
                _ ->
                    error
            end;
        error ->
            error
    end.

looks_like_html(Headers) ->
    case lists:keyfind("content-type", 1, [{string:lowercase(K), V} || {K, V} <- Headers]) of
        {_, CT} ->
            Lower = string:lowercase(CT),
            string:find(Lower, "html") =/= nomatch;
        false ->
            %% No declared type -- best effort, still try to parse it as HTML
            %% rather than refusing outright.
            true
    end.

%% ---- SSRF guard ---------------------------------------------------------

validate_public_url(UrlStr) ->
    case uri_string:parse(UrlStr) of
        #{scheme := Scheme, host := Host} when Scheme =:= "http"; Scheme =:= "https" ->
            validate_host(unicode:characters_to_list(Host));
        _ ->
            error
    end.

validate_host("") -> error;
validate_host("localhost") -> error;
validate_host(HostStr) ->
    case inet:parse_ipv4strict_address(HostStr) of
        {ok, Ip} ->
            case is_public_ipv4(Ip) of
                true -> ok;
                false -> error
            end;
        {error, _} ->
            case inet:parse_ipv6strict_address(HostStr) of
                {ok, _} -> error; %% IPv6 literal -- see module doc
                {error, _} -> resolve_and_validate(HostStr)
            end
    end.

resolve_and_validate(Host) ->
    case inet:getaddrs(Host, inet, 3000) of
        {ok, Ips} when Ips =/= [] ->
            case lists:all(fun is_public_ipv4/1, Ips) of
                true -> ok;
                false -> error
            end;
        _ ->
            error
    end.

%% Standard private/reserved IPv4 ranges (RFC 1918, loopback, link-local
%% incl. the 169.254.169.254 cloud metadata address, CGNAT, documentation/
%% test ranges, multicast, reserved).
-define(PRIVATE_V4_RANGES, [
    {{0,0,0,0}, 8}, {{10,0,0,0}, 8}, {{100,64,0,0}, 10}, {{127,0,0,0}, 8},
    {{169,254,0,0}, 16}, {{172,16,0,0}, 12}, {{192,0,0,0}, 24}, {{192,0,2,0}, 24},
    {{192,168,0,0}, 16}, {{198,18,0,0}, 15}, {{198,51,100,0}, 24}, {{203,0,113,0}, 24},
    {{224,0,0,0}, 4}, {{240,0,0,0}, 4}
]).

is_public_ipv4(Ip = {_, _, _, _}) ->
    not lists:any(fun({Base, Bits}) -> ip_in_range(Ip, Base, Bits) end, ?PRIVATE_V4_RANGES);
is_public_ipv4(_) ->
    false. %% not even a v4 tuple (e.g. inet:getaddrs returned something odd) -- refuse

ip_in_range({A, B, C, D}, {BA, BB, BC, BD}, Bits) ->
    <<IpInt:32>> = <<A, B, C, D>>,
    <<BaseInt:32>> = <<BA, BB, BC, BD>>,
    Mask = (16#FFFFFFFF bsl (32 - Bits)) band 16#FFFFFFFF,
    (IpInt band Mask) =:= (BaseInt band Mask).

%% ---- Extraction ----------------------------------------------------------

%% Best-effort, regex-based (no HTML parser dependency, consistent with the
%% rest of this hand-rolled app). Doesn't need to be perfect -- a missed
%% og:image just means a text-only preview card.
extract_preview(Body) ->
    Text = to_text(Body),
    Title = truncate(html_unescape(first_of([
        meta_content(Text, "og:title"),
        tag_content(Text, "title")
    ]))),
    Description = truncate(html_unescape(first_of([
        meta_content(Text, "og:description"),
        meta_content(Text, "description")
    ]))),
    Image = truncate(html_unescape(first_of([
        meta_content(Text, "og:image")
    ]))),
    case {Title, Description, Image} of
        {undefined, undefined, undefined} -> error;
        _ -> {ok, {Title, Description, Image}}
    end.

to_text(Body) ->
    case unicode:characters_to_list(Body, utf8) of
        L when is_list(L) -> L;
        _ -> binary_to_list(Body) %% not valid UTF-8 -- fall back byte-for-byte rather than crash
    end.

first_of([undefined | Rest]) -> first_of(Rest);
first_of([Value | _]) -> Value;
first_of([]) -> undefined.

truncate(undefined) -> undefined;
truncate(Str) when length(Str) > ?MAX_FIELD_LEN -> string:slice(Str, 0, ?MAX_FIELD_LEN);
truncate(Str) -> Str.

%% <meta property="og:title" content="..."> or the property/content
%% attributes in the other order, or name="..." instead of property=.
meta_content(Text, Name) ->
    Patterns = [
        "<meta[^>]*property=[\"']" ++ Name ++ "[\"'][^>]*content=[\"']([^\"']*)[\"']",
        "<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*property=[\"']" ++ Name ++ "[\"']",
        "<meta[^>]*name=[\"']" ++ Name ++ "[\"'][^>]*content=[\"']([^\"']*)[\"']",
        "<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*name=[\"']" ++ Name ++ "[\"']"
    ],
    first_of([regex_capture(Text, P) || P <- Patterns]).

tag_content(Text, Tag) ->
    regex_capture(Text, "<" ++ Tag ++ "[^>]*>([^<]*)</" ++ Tag ++ ">").

regex_capture(Text, Pattern) ->
    %% See find_url/1 for why `unicode` is required -- fetched HTML bodies
    %% routinely contain non-Latin-1 codepoints (curly quotes, em dashes,
    %% non-English text) anywhere in the document, not just inside the tag
    %% being matched.
    case re:run(Text, Pattern, [{capture, all_but_first, list}, caseless, unicode]) of
        {match, [Capture]} ->
            case string:trim(Capture) of
                "" -> undefined;
                V -> V
            end;
        _ ->
            undefined
    end.

html_unescape(undefined) -> undefined;
html_unescape(Str) ->
    Steps = [
        {"&amp;", "&"}, {"&quot;", "\""}, {"&#39;", "'"}, {"&#x27;", "'"},
        {"&lt;", "<"}, {"&gt;", ">"}, {"&nbsp;", " "}
    ],
    lists:foldl(fun({From, To}, Acc) -> replace_all(Acc, From, To) end, Str, Steps).

replace_all(Str, From, To) ->
    lists:flatten(string:replace(Str, From, To, all)).
