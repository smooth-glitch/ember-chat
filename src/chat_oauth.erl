%%% Google & Apple Sign-In. Both are the same shape underneath ("OpenID
%%% Connect authorization code flow"): send the person to the provider's
%%% consent page, they come back with a short-lived code, we trade that
%%% code for an id_token (a JWT the provider signed), verify the signature
%%% ourselves against the provider's published public keys, and trust the
%%% email/subject-id claims inside once that verification passes.
%%%
%%% Verifying the signature ourselves (RS256, against the provider's JWKS)
%%% rather than only checking response status is the whole point -- without
%%% it, anything that could get a crafted "id_token"-shaped string in front
%%% of this code could impersonate any account. See verify_id_token/2.
%%%
%%% No external dependency: httpc/ssl (inets, stock OTP) for the network
%%% calls, public_key/crypto (also stock OTP) for the actual RSA/EC
%%% signature math, json (built into OTP 27+) for parsing.
-module(chat_oauth).
-export([google_auth_url/2, google_exchange_code/2,
         apple_auth_url/2, apple_exchange_code/2,
         random_state/0]).
-include_lib("public_key/include/public_key.hrl").

-define(FETCH_TIMEOUT, 8000).
-define(CONNECT_TIMEOUT, 4000).
-define(JWKS_CACHE_TTL_MS, 3600000). % 1 hour -- providers rotate these periodically

-define(GOOGLE_AUTH_ENDPOINT, "https://accounts.google.com/o/oauth2/v2/auth").
-define(GOOGLE_TOKEN_ENDPOINT, "https://oauth2.googleapis.com/token").
-define(GOOGLE_JWKS_URI, "https://www.googleapis.com/oauth2/v3/certs").
-define(GOOGLE_ISSUERS, ["accounts.google.com", "https://accounts.google.com"]).

-define(APPLE_AUTH_ENDPOINT, "https://appleid.apple.com/auth/authorize").
-define(APPLE_TOKEN_ENDPOINT, "https://appleid.apple.com/auth/token").
-define(APPLE_JWKS_URI, "https://appleid.apple.com/auth/keys").
-define(APPLE_ISSUER, "https://appleid.apple.com").

%% A fresh, URL-safe random token for the OAuth "state" parameter -- the
%% caller stores this (see chat_web.erl's oauth state cookie) and checks the
%% callback's state matches, which is what stops a CSRF login (an attacker
%% tricking someone into completing *the attacker's* OAuth flow under the
%% victim's session).
random_state() ->
    b64url_encode(crypto:strong_rand_bytes(24)).

%% ---- Google -------------------------------------------------------------

google_auth_url(RedirectUri, State) ->
    Qs = uri_string:compose_query([
        {"client_id", oauth_config:google_client_id()},
        {"redirect_uri", RedirectUri},
        {"response_type", "code"},
        {"scope", "openid email profile"},
        {"state", State},
        %% Google specifically recommends this over the fully-manual nonce
        %% dance for web server flows; state alone already covers CSRF here.
        {"access_type", "online"},
        {"prompt", "select_account"}
    ]),
    ?GOOGLE_AUTH_ENDPOINT ++ "?" ++ Qs.

%% Exchanges an authorization Code for a verified identity. Returns
%% {ok, #{email, name, sub}} or {error, Reason}. Every failure mode --
%% network error, bad code, signature mismatch, expired token, wrong
%% audience -- collapses to {error, Reason} rather than ever returning a
%% partially-trusted result; the caller has nothing safe to do with "maybe
%% verified."
google_exchange_code(Code, RedirectUri) ->
    ensure_http_apps(),
    Body = uri_string:compose_query([
        {"code", Code},
        {"client_id", oauth_config:google_client_id()},
        {"client_secret", oauth_config:google_client_secret()},
        {"redirect_uri", RedirectUri},
        {"grant_type", "authorization_code"}
    ]),
    case post_form(?GOOGLE_TOKEN_ENDPOINT, Body) of
        {ok, RespBody} ->
            case json_get(RespBody, [<<"id_token">>]) of
                {ok, IdToken} ->
                    verify_id_token(binary_to_list(IdToken), google, ?GOOGLE_JWKS_URI,
                                     ?GOOGLE_ISSUERS, oauth_config:google_client_id());
                error ->
                    {error, no_id_token}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% ---- Apple ----------------------------------------------------------------

apple_auth_url(RedirectUri, State) ->
    Qs = uri_string:compose_query([
        {"client_id", oauth_config:apple_client_id()},
        {"redirect_uri", RedirectUri},
        {"response_type", "code"},
        {"scope", "email name"},
        {"response_mode", "form_post"}, % Apple requires form_post when requesting "name"/"email" scopes
        {"state", State}
    ]),
    ?APPLE_AUTH_ENDPOINT ++ "?" ++ Qs.

apple_exchange_code(Code, RedirectUri) ->
    ensure_http_apps(),
    ClientSecret = apple_client_secret(),
    Body = uri_string:compose_query([
        {"code", Code},
        {"client_id", oauth_config:apple_client_id()},
        {"client_secret", ClientSecret},
        {"redirect_uri", RedirectUri},
        {"grant_type", "authorization_code"}
    ]),
    case post_form(?APPLE_TOKEN_ENDPOINT, Body) of
        {ok, RespBody} ->
            case json_get(RespBody, [<<"id_token">>]) of
                {ok, IdToken} ->
                    verify_id_token(binary_to_list(IdToken), apple, ?APPLE_JWKS_URI,
                                     [?APPLE_ISSUER], oauth_config:apple_client_id());
                error ->
                    {error, no_id_token}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Apple's token endpoint authenticates the caller with a short-lived
%% ES256-signed JWT instead of a static secret string -- generated fresh
%% each call (they're cheap to make and this sidesteps ever needing to
%% think about caching/expiring one).
apple_client_secret() ->
    Now = erlang:system_time(second),
    Header = #{<<"alg">> => <<"ES256">>, <<"kid">> => list_to_binary(oauth_config:apple_key_id())},
    Claims = #{
        <<"iss">> => list_to_binary(oauth_config:apple_team_id()),
        <<"iat">> => Now,
        <<"exp">> => Now + 300,
        <<"aud">> => <<"https://appleid.apple.com">>,
        <<"sub">> => list_to_binary(oauth_config:apple_client_id())
    },
    Signing = b64url_encode(json:encode(Header)) ++ "." ++ b64url_encode(json:encode(Claims)),
    PrivateKey = decode_ec_private_key(oauth_config:apple_private_key_pem()),
    %% ES256 wants the raw (r,s) concatenation, not the DER sequence
    %% public_key:sign/3 returns for 'ecdsa' -- see der_ecdsa_to_raw/1.
    DerSig = public_key:sign(list_to_binary(Signing), sha256, PrivateKey),
    RawSig = der_ecdsa_to_raw(DerSig, 32),
    Signing ++ "." ++ b64url_encode(RawSig).

decode_ec_private_key(Pem) ->
    [Entry] = public_key:pem_decode(list_to_binary(Pem)),
    public_key:pem_entry_decode(Entry).

%% ---- Shared: JWT verification -------------------------------------------

%% The one function both providers' id_tokens go through. Checks, in order:
%% the token is well-formed and RS256-signed; the signature actually
%% verifies against a key the provider currently publishes (kid lookup in
%% their JWKS); the token hasn't expired; the issuer is really the provider
%% claimed; and the audience is *this app's* client id (without that last
%% check, a valid token issued to a *different* app using the same provider
%% would also pass -- aud is what ties the token to us specifically).
verify_id_token(Jwt, Provider, JwksUri, ValidIssuers, ExpectedAud) ->
    case string:split(Jwt, ".", all) of
        [HeaderB64, PayloadB64, SigB64] ->
            case {b64url_decode(HeaderB64), b64url_decode(PayloadB64), b64url_decode(SigB64)} of
                {HeaderJson, PayloadJson, Sig} when is_binary(HeaderJson) ->
                    try
                        Header = json:decode(HeaderJson),
                        Claims = json:decode(PayloadJson),
                        Kid = maps:get(<<"kid">>, Header, undefined),
                        SigningInput = list_to_binary(HeaderB64 ++ "." ++ PayloadB64),
                        case find_jwk(Provider, JwksUri, Kid) of
                            {ok, PublicKey} ->
                                case public_key:verify(SigningInput, sha256, Sig, PublicKey) of
                                    true -> check_claims(Claims, ValidIssuers, ExpectedAud);
                                    false -> {error, bad_signature}
                                end;
                            {error, Reason} ->
                                {error, Reason}
                        end
                    catch
                        _:_ -> {error, malformed_token}
                    end;
                _ ->
                    {error, malformed_token}
            end;
        _ ->
            {error, malformed_token}
    end.

check_claims(Claims, ValidIssuers, ExpectedAud) ->
    Iss = binary_to_list(maps:get(<<"iss">>, Claims, <<>>)),
    Aud = binary_to_list(maps:get(<<"aud">>, Claims, <<>>)),
    Exp = maps:get(<<"exp">>, Claims, 0),
    Now = erlang:system_time(second),
    case {lists:member(Iss, ValidIssuers), Aud =:= ExpectedAud, Exp > Now} of
        {true, true, true} ->
            Email = maps:get(<<"email">>, Claims, undefined),
            Sub = maps:get(<<"sub">>, Claims, undefined),
            {ok, #{
                sub => Sub,
                email => Email,
                %% Google puts a display name in the id_token; Apple only
                %% ever sends a name via the separate form-post "user" field
                %% on first login, never in the token -- callers fall back
                %% to deriving something from the email when this is undefined.
                name => maps:get(<<"name">>, Claims, undefined)
            }};
        {false, _, _} -> {error, {bad_issuer, Iss}};
        {_, false, _} -> {error, {bad_audience, Aud}};
        {_, _, false} -> {error, token_expired}
    end.

%% ---- JWKS fetch + cache ---------------------------------------------------

find_jwk(Provider, JwksUri, Kid) ->
    case get_jwks(Provider, JwksUri) of
        {ok, Keys} ->
            case lists:search(fun(K) -> maps:get(<<"kid">>, K, undefined) =:= Kid end, Keys) of
                {value, Jwk} -> {ok, jwk_to_public_key(Jwk)};
                false -> {error, unknown_kid}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

get_jwks(Provider, JwksUri) ->
    CacheKey = {?MODULE, jwks, Provider},
    Now = erlang:monotonic_time(millisecond),
    case persistent_term:get(CacheKey, undefined) of
        {Keys, FetchedAt} when Now - FetchedAt < ?JWKS_CACHE_TTL_MS ->
            {ok, Keys};
        _ ->
            case fetch_jwks(JwksUri) of
                {ok, Keys} ->
                    persistent_term:put(CacheKey, {Keys, Now}),
                    {ok, Keys};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

fetch_jwks(JwksUri) ->
    ensure_http_apps(),
    Opts = [{timeout, ?FETCH_TIMEOUT}, {connect_timeout, ?CONNECT_TIMEOUT}, {autoredirect, false}],
    case httpc:request(get, {JwksUri, []}, Opts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Headers, RespBody}} ->
            try json:decode(RespBody) of
                #{<<"keys">> := Keys} -> {ok, Keys};
                _ -> {error, bad_jwks}
            catch
                _:_ -> {error, bad_jwks}
            end;
        _ ->
            {error, jwks_fetch_failed}
    end.

%% A JWK's "n" (modulus) and "e" (exponent) are base64url-encoded big-endian
%% integers -- decode straight into an RSA public key record public_key can
%% verify against.
jwk_to_public_key(#{<<"n">> := NB64, <<"e">> := EB64}) ->
    N = crypto:bytes_to_integer(b64url_decode_bin(binary_to_list(NB64))),
    E = crypto:bytes_to_integer(b64url_decode_bin(binary_to_list(EB64))),
    #'RSAPublicKey'{modulus = N, publicExponent = E}.

%% ---- HTTP helpers ---------------------------------------------------------

ensure_http_apps() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl).

post_form(Url, Body) ->
    ensure_http_apps(),
    Opts = [{timeout, ?FETCH_TIMEOUT}, {connect_timeout, ?CONNECT_TIMEOUT}, {autoredirect, false}],
    Req = {Url, [{"Accept", "application/json"}], "application/x-www-form-urlencoded", Body},
    case httpc:request(post, Req, Opts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Headers, RespBody}} -> {ok, RespBody};
        {ok, {{_, Code, _}, _Headers, _RespBody}} -> {error, {http_error, Code}};
        {error, Reason} -> {error, Reason}
    end.

json_get(Body, Keys) ->
    try
        Decoded = json:decode(Body),
        json_get_path(Decoded, Keys)
    catch
        _:_ -> error
    end.

json_get_path(Value, []) -> {ok, Value};
json_get_path(Map, [Key | Rest]) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, V} -> json_get_path(V, Rest);
        error -> error
    end;
json_get_path(_, _) -> error.

%% ---- base64url --------------------------------------------------------

%% JWTs use base64url (RFC 4648 sec 5) without padding, not the standard
%% base64 OTP's base64 module speaks -- translate the alphabet and pad back
%% out before/after handing off to it.
b64url_encode(Bin) ->
    Std = base64:encode(iolist_to_binary(Bin)),
    NoPad = binary:replace(Std, <<"=">>, <<"">>, [global]),
    Url = binary:replace(binary:replace(NoPad, <<"+">>, <<"-">>, [global]), <<"/">>, <<"_">>, [global]),
    binary_to_list(Url).

b64url_decode(Str) ->
    try b64url_decode_bin(Str) of
        Bin -> Bin
    catch
        _:_ -> error
    end.

b64url_decode_bin(Str) ->
    Std0 = lists:map(fun($-) -> $+; ($_) -> $/; (C) -> C end, Str),
    Padded = Std0 ++ lists:duplicate((4 - (length(Std0) rem 4)) rem 4, $=),
    base64:decode(Padded).

%% ECDSA signatures from public_key:sign/3 come back DER-encoded
%% (SEQUENCE of two INTEGERs); JWS ES256 wants the raw r||s concatenation,
%% each fixed at Size bytes (32 for P-256), zero-padded on the left. Both
%% integers can DER-encode with a leading 0x00 (whenever the high bit would
%% otherwise make them look negative) or come in shorter than Size bytes
%% (whenever the integer has leading zero bytes), so this strips/pads
%% rather than assuming a fixed offset into the DER bytes.
der_ecdsa_to_raw(Der, Size) ->
    {'ECDSA-Sig-Value', R, S} = public_key:der_decode('ECDSA-Sig-Value', Der),
    RB = int_to_fixed_bytes(R, Size),
    SB = int_to_fixed_bytes(S, Size),
    <<RB/binary, SB/binary>>.

int_to_fixed_bytes(Int, Size) ->
    Bin = binary:encode_unsigned(Int),
    Pad = Size - byte_size(Bin),
    if
        Pad > 0 -> <<0:(Pad * 8), Bin/binary>>;
        Pad =:= 0 -> Bin;
        true -> binary:part(Bin, byte_size(Bin) - Size, Size)
    end.
