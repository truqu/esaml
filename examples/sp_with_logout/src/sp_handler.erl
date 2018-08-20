%% esaml - SAML for erlang
%%
%% Copyright (c) 2013, Alex Wilson and the University of Queensland
%% All rights reserved.
%%
%% Distributed subject to the terms of the 2-clause BSD license, see
%% the LICENSE file in the root of the distribution.

-module(sp_handler).
-include_lib("esaml/include/esaml.hrl").

-record(state, {sp, idp}).
-export([init/3, handle/2, terminate/3]).

init(_Transport, Req, _Args) ->
    % Load the certificate and private key for the SP
    PrivKey = esaml_util:load_private_key("test.key"),
    Cert = esaml_util:load_certificate("test.crt"),
    % We build all of our URLs (in metadata, and in requests) based on this
    Base = "http://some.hostname.com/saml",
    % Certificate fingerprints to accept from our IDP
    FPs = ["6b:d1:24:4b:38:cf:6c:1f:4e:53:56:c5:c8:90:63:68:55:5e:27:28"],

    SP = esaml_sp:setup(#esaml_sp{
        key = PrivKey,
        certificate = Cert,
        trusted_fingerprints = FPs,
        consume_uri = Base ++ "/consume",
        metadata_uri = Base ++ "/metadata",
        logout_uri = Base ++ "/logout",
        org = #esaml_org{
            % example of multi-lingual data -- only works in #esaml_org{}
            name = [{en, "Foo Bar"}, {de, "Das Foo Bar"}],
            displayname = "Foo Bar",
            url = "http://some.hostname.com"
        },
        tech = #esaml_contact{
            name = "Foo Bar",
            email = "foo@bar.com"
        }
    }),
    % Rather than copying the IDP's metadata into our code, we'll just fetch it
    % (this call will cache after the first time around, so it will be fast)
    IdpMeta = esaml_util:load_metadata("https://some.idp.com/idp/saml2/idp/metadata.php"),

    {ok, Req, #state{sp = SP, idp = IdpMeta}}.

handle(#{method := Method} = Req, S = #state{}) ->
    Operation = cowboy_req:binding(operation, Req),
    handle(Method, Operation, Req, S).

% Return our SP metadata as signed XML
handle(<<"GET">>, <<"metadata">>, Req, S = #state{sp = SP}) ->
    {ok, Req2} = esaml_cowboy:reply_with_metadata(SP, Req),
    {ok, Req2, S};

% Visit /saml/auth to start the authentication process -- first check to see if
% we are already logged in, otherwise we will make an AuthnRequest and send it to 
% our IDP
handle(<<"GET">>, <<"auth">>, Req, S = #state{sp = SP,
        idp = #esaml_idp_metadata{login_location = IDP}}) ->
    #{sp_cookie := CookieID} = cowboy_req:match_cookies([{sp_cookie, [], undefined}], Req),
    case CookieID of
        undefined ->
            % no cookie set, send them to the IdP
            {ok, Req3} = esaml_cowboy:reply_with_authnreq(SP, IDP, <<"foo">>, Req),
            {ok, Req3, S};

        _ ->
            case ets:lookup(sp_cookies, CookieID) of
                [{CookieID, _NameID, Uid}] ->
                    Output = io_lib:format("
                        <html>
                        <head><title>SAML SP demo</title></head>
                        <body>
                        <h1>Hi there!</h1>
                        <p>You're authenticated as ~s!</p>
                        <p><a href=\"/saml/deauth\">Log out</a></p>
                        </body>
                        </html>", [Uid]),
                    Req3 = cowboy_req:reply(200, #{<<"Content-Type">> => <<"text/html">>}, Output, Req),
                    {ok, Req3, S};

                _ ->
                    % cookie was invalid, send them to the IdP
                    Req3 = esaml_cowboy:reply_with_authnreq(SP, IDP, <<"foo">>, Req),
                    {ok, Req3, S}
            end
    end;

% Handles HTTP-POST bound assertions coming back from the IDP.
handle(<<"POST">>, <<"consume">>, Req, S = #state{sp = SP}) ->
    case esaml_cowboy:validate_assertion(SP, fun esaml_util:check_dupe_ets/2, Req) of
        {ok, Assertion, RelayState, Req2} ->
            NameID = Assertion#esaml_assertion.subject#esaml_subject.name,
            Attrs = Assertion#esaml_assertion.attributes,
            Uid = proplists:get_value(uid, Attrs),

            CookieID = gen_cookie_id(),
            ets:insert(sp_cookies, {CookieID, NameID, Uid}),
            ets:insert(sp_nameids, {NameID, CookieID}),

            Output = io_lib:format("
                <html>
                <head><title>SAML SP demo</title></head>
                <body>
                <h1>Hi there!</h1>
                <p>You're now authenticated as ~s!</p>
                <hr /><p>RelayState:</p><pre>\n~p\n</pre><p>Assertion:</p><pre>\n~p\n</pre>
                <p><a href=\"/saml/deauth\">Log out</a></p>
                </body>
                </html>", [Uid, RelayState, Assertion]),
            Req3 = cowboy_req:set_resp_cookie(<<"sp_cookie">>,
                CookieID, Req2, #{path, <<"/">>}),
            {ok, Req4} = cowboy_req:reply(200, #{<<"Content-Type">> => <<"text/html">>}, Output, Req3),
            {ok, Req4, S};

        {error, Reason, Req2} ->
            {ok, Req3} = cowboy_req:reply(403, #{<<"content-type">> => <<"text/plain">>},
                ["Access denied, assertion failed validation:\n", io_lib:format("~p\n", [Reason])],
                Req2),
            {ok, Req3, S}
    end;

handle(<<"GET">>, <<"deauth">>, Req, S = #state{sp = SP, idp = #esaml_idp_metadata{logout_location = IDP}}) ->
    #{sp_cookie := CookieID} = cowboy_req:match_cookies([{sp_cookie, [], undefined}], Req),
    case CookieID of
        undefined ->
            {ok, Req3} = cowboy_req:reply(403, #{<<"content-type">> => <<"text/plain">>},
                ["Access denied, can't read your sp_cookie cookie!"], Req),
            {ok, Req3, S};

        _ ->
            [{CookieID, NameID, _Uid}] = ets:lookup(sp_cookies, CookieID),
            ets:delete(sp_cookies, CookieID),
            ets:delete(sp_nameids, NameID),
            {ok, Req3} = esaml_cowboy:reply_with_logoutreq(SP, IDP, NameID, Req),
            {ok, Req3, S}
    end;

handle(_Method, <<"logout">>, Req, S = #state{sp = SP, idp = #esaml_idp_metadata{logout_location = IDP}}) ->
    case esaml_cowboy:validate_logout(SP, Req) of
        {request, #esaml_logoutreq{name = NameID}, RS, Req2} ->
            Cookies = [Cookie || {_, Cookie} <- ets:lookup(sp_nameids, NameID)],
            lists:foreach(fun(C) -> ets:delete(sp_cookies, C) end, Cookies),
            {ok, Req3} = esaml_cowboy:reply_with_logoutresp(SP, IDP, success, RS, Req2),
            {ok, Req3, S};

        {response, LR = #esaml_logoutresp{}, RS, Req2} ->
            Output = io_lib:format("<html>
                <head><title>SAML SP demo</title></head>
                <body>
                <h1>Logout finished</h1>
                <p>Logout response:</p>
                <pre>\n~p\n</pre>
                <p>RelayState:</p>
                <pre>\n~p\n</pre>
                </body>
                </html>", [LR, RS]),
            Req3 = cowboy_req:reply(200, #{<<"content-type">> => <<"text/html">>}, Output, Req2),
            {ok, Req3, S};

        {error, Reason, Req2} ->
            Req3 = cowboy_req:reply(500, #{<<"content-type">> => <<"text/plain">>},
                ["Logout failed validation:\n", io_lib:format("~p\n", [Reason])], Req2),
            {ok, Req3, S}
    end;

handle(_, _, Req, S = #state{}) ->
    Req2 = cowboy_req:reply(404, #{}, <<"Not found">>, Req),
    {ok, Req2, S}.

terminate(_Reason, _Req, _State) -> ok.

gen_cookie_id() ->
    Bytes = crypto:strong_rand_bytes(24),
    Base = base64:encode(Bytes),
    Base2 = binary:replace(Base, <<"/">>, <<"_">>, [global]),
    binary:replace(Base2, <<"+">>, <<"-">>, [global]).