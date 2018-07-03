%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ HTTP authentication.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_auth_backend_uaa).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(rabbit_authn_backend).
-behaviour(rabbit_authz_backend).

-export([description/0]).
-export([user_login_authentication/2, user_login_authorization/1,
         check_vhost_access/3, check_resource_access/3,
         check_topic_access/4]).

-ifdef(TEST).
-compile(export_all).
-endif.
%%--------------------------------------------------------------------

description() ->
    [{name, <<"UAA">>},
     {description, <<"Performs authentication and authorisation using JWT tokens and OAuth 2 scopes">>}].

%%--------------------------------------------------------------------

user_login_authentication(Username, _AuthProps) ->
    case check_token(Username) of
        {error, _} = E  -> E;
        {refused, Err}  ->
            {refused, "Authentication using an OAuth 2/JWT token failed: ~p", [Err]};
        {ok, UserData} -> {ok, #auth_user{username = Username,
                                           tags = [],
                                           impl = UserData}}
    end.

user_login_authorization(Username) ->
    case user_login_authentication(Username, []) of
        {ok, #auth_user{impl = Impl}} -> {ok, Impl};
        Else                          -> Else
    end.

check_vhost_access(#auth_user{impl = DecodedToken},
                   VHost, _Sock) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes = get_scopes(DecodedToken),
            rabbit_oauth2_scope:vhost_access(VHost, Scopes)
        end).

check_resource_access(#auth_user{impl = DecodedToken},
                      Resource, Permission) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes = get_scopes(DecodedToken),
            rabbit_oauth2_scope:resource_access(Resource, Permission, Scopes)
        end).

check_topic_access(#auth_user{impl = DecodedToken},
                   Resource, Permission, Context) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes = get_scopes(DecodedToken),
            rabbit_oauth2_scope:topic_access(Resource, Permission, Context, Scopes)
        end).

%%--------------------------------------------------------------------

with_decoded_token(DecodedToken, Fun) ->
    case validate_token_active(DecodedToken) of
        ok               -> Fun();
        {error, _} = Err -> Err
    end.

validate_token_active(#{<<"exp">> := Exp}) when is_integer(Exp) ->
    case Exp =< os:system_time(seconds) of
        true  -> {error, rabbit_misc:format("Provided JWT token has expired at timestamp ~p", [Exp])};
        false -> ok
    end;
validate_token_active(#{}) -> ok.

-spec check_token(binary()) -> {ok, map()} | {error, term()}.
check_token(Token) ->
    case uaa_jwt:decode_and_verify(Token) of
        {error, Reason} -> {refused, {error, Reason}};
        {true, Payload} -> validate_payload(Payload);
        {false, _}      -> {refused, signature_invalid}
    end.

validate_payload(#{<<"scope">> := _Scope, <<"aud">> := _Aud} = UserData) ->
    ResourceServerId = rabbit_data_coercion:to_binary(application:get_env(rabbitmq_auth_backend_uaa,
                                                                          resource_server_id, <<>>)),
    validate_payload(UserData, ResourceServerId).

validate_payload(#{<<"scope">> := Scope, <<"aud">> := Aud} = UserData, ResourceServerId) ->
    case check_aud(Aud, ResourceServerId) of
        ok           -> {ok, UserData#{<<"scope">> => filter_scope(Scope, ResourceServerId)}};
        {error, Err} -> {refused, {invalid_aud, Err}}
    end.

filter_scope(Scope, <<"">>) -> Scope;
filter_scope(Scope, ResourceServerId)  ->
    Pattern = <<ResourceServerId/binary, ".">>,
    PatternLength = byte_size(Pattern),
    lists:filtermap(
        fun(ScopeEl) ->
            case binary:match(ScopeEl, Pattern) of
                {0, PatternLength} ->
                    ElLength = byte_size(ScopeEl),
                    {true,
                     binary:part(ScopeEl,
                                 {PatternLength, ElLength - PatternLength})};
                _ -> false
            end
        end,
        Scope).

check_aud(_, <<>>)    -> ok;
check_aud(Aud, ResourceServerId) ->
    case Aud of
        List when is_list(List) ->
            case lists:member(ResourceServerId, Aud) of
                true  -> ok;
                false -> {error, {resource_id_not_found_in_aud, ResourceServerId, Aud}}
            end;
        _ -> {error, {badarg, {aud_is_not_a_list, Aud}}}
    end.

get_scopes(#{<<"scope">> := Scope}) -> Scope.

%%--------------------------------------------------------------------
