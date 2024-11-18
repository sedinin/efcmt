%%%-------------------------------------------------------------------
%%% @author sedinin
%%% @copyright (C) 2024, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 03. Nov 2024 16:44
%%%-------------------------------------------------------------------
-module(efcm_conn).
-author("sedinin").

-behaviour(gen_statem).

-include("efcm.hrl").

%% API
-export([start_link/1, push/3]).

%% gen_statem callbacks
-export([init/1, format_status/1, handle_event/4, terminate/3,
         code_change/4, callback_mode/0]).
%% gen_statem states
-export([open_connection/3, connected/3, down/3]).

%% spawn
-export([reply_errors_and_cancel_timers/2]).

-define(SCOPE, <<"https://www.googleapis.com/auth/firebase.messaging">>).
-define(JSX_OPTS, [return_maps, {labels, atom}]).
-define(HTTP_OPTS, [{timeout, 5000}]).
-define(REQ_OPTS, [{full_result, false}, {body_format, binary}]).
-define(TIMEOUT, 5000).

%% new
-define(FCM_HOST, "fcm.googleapis.com").
-define(FCM_PORT, 443).


-type stream_data() :: #{reg_id := binary()
                        , message := term()
                        , from := {pid(), term()}
                        , stream := gun:stream_ref()
                        , timer := reference()
                        , status := non_neg_integer()
                        , headers := gun:req_headers()
                        , body := binary()}.

-type state() :: #{service_file := binary() | string()
                  , push_path := binary()
                  , auth_bearer := binary()
                  , token_tref := reference()
                  , gun_pid := pid()
                  , gun_mon := reference()
                  , streams := #{gun:stream_ref() := stream_data()}
                  , max_streams := non_neg_integer()}.

%% todo:
%% 1. renew token (on 401 error)
%% 2. process responses (status + body)
%% 3. some logging
%% 4. reconnects on errors
%% 5. format status

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
start_link(ServiceFile) ->
    gen_statem:start_link(?MODULE, [ServiceFile], []).

push(Pid, RegId, Message) ->
    gen_statem:call(Pid, {push, RegId, Message}).


%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================
%% @private
%% @doc This function is called by a gen_statem when it needs to find out
%% the callback mode of the callback module.
-spec callback_mode() -> state_functions.
callback_mode() -> state_functions.

%% @private
%% @doc Whenever a gen_statem is started using gen_statem:start/[3,4] or
%% gen_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
init([ServiceFile]) ->
    {ok, open_connection, #{service_file => ServiceFile, token_tref => null},
     {next_event, internal, init}}.

%% @private
%% @doc Called (1) whenever sys:get_status/1,2 is called by gen_statem or
%% (2) when gen_statem terminates abnormally.
%% This callback is optional.
format_status(State) ->
    State.

%% @private
%% @doc There should be one instance of this function for each possible
%% state name.  If callback_mode is state_functions, one of these
%% functions is called when gen_statem receives and event from
%% call/2, cast/2, or as a normal process message.
open_connection(internal, _, State0 = #{}) ->
    Opts = #{protocols => [http2]
            , http2_opts => http2_opts()
            , tls_opts => tls_opts()
            , retry => 0},
    {ok, GunPid} = gun:open(?FCM_HOST, ?FCM_PORT, Opts),
    GunMon = monitor(process, GunPid),
    %% got connection, now we have to reload access token
    State1 = reload_access_token(State0),
    %% initially one stream allowed
    State2 = State1#{gun_pid => GunPid
                    , gun_mon => GunMon
                    , streams => #{}
                    , max_streams => 1},
    {next_state, connected, State2}.


-spec connected(_, _, state()) -> _.
connected({call, From}, {push, RegId, Message}, State = #{}) ->
    case send_push(From, RegId, Message, State) of
        {error, {overload, TotalStreams, MaxStreams}} ->
            {keep_state_and_data, {reply, From, {error, {overload, TotalStreams, MaxStreams}}}};
        {ok, State1} ->
            {keep_state, State1}
    end;
connected(info
         , {gun_response, GunPid, StreamRef, fin, 401, _Headers}
         , #{gun_pid := GunPid, streams := Streams0} = State0) ->
    %% got 401, refresh token then repeat request (send push)
    %% 1. closing stream
    gun:cancel(GunPid, StreamRef),
    %% 2. refreshing token
    State1 = reload_access_token(State0),
    %% get stream data, vars from it and remove it from map
    #{StreamRef := StreamData} = Streams0,
    #{from := From, reg_id := RegId, message := Message} = StreamData,
    Streams1 = maps:remove(StreamRef, Streams0),
    State2 = State1#{streams => Streams1},
    case send_push(From, RegId, Message, State2) of
        {error, {overload, TotalStreams, MaxStreams}} ->
            {keep_state_and_data, {reply, From, {error, {overload, TotalStreams, MaxStreams}}}};
        {ok, State2} ->
            {keep_state, State2}
    end;
connected(info
         , {gun_response, GunPid, StreamRef, fin, Status, Headers}
         , #{gun_pid := GunPid} = State0) ->
    %% got final response without body
    lager:debug("final response without body, status: ~B, headers: ~p", [Status, Headers]),
    #{streams := Streams0} = State0,
    #{StreamRef := StreamData} = Streams0,
    #{from := From} = StreamData,
    Streams1 = maps:remove(StreamRef, Streams0),
    gun:cancel(GunPid, StreamRef), %% final response, closing stream
    gen_statem:reply(From, {Status, Headers, no_body}),
    {keep_state, State0#{streams => Streams1}};
connected(info
         , {gun_response, GunPid, StreamRef, nofin, Status, Headers}
         , #{gun_pid := GunPid} = State0) ->
    %% non-final response without body
    lager:debug("non-final response without body, status: ~B, headers: ~p", [Status, Headers]),
    #{streams := Streams0} = State0,
    #{StreamRef := StreamState0} = Streams0,
    StreamState1 = StreamState0#{status => Status, headers => Headers},
    Streams1 = Streams0#{StreamRef => StreamState1},
    {keep_state, State0#{streams := Streams1}};
connected(info
         , {gun_data, GunPid, StreamRef, fin, Data}
         , #{gun_pid := GunPid} = State0) ->
    %% got data, finally
    #{streams := Streams0} = State0,
    #{StreamRef := StreamData} = Streams0,
    lager:debug("final data response, data: ~p, stream data: ~p", [Data, StreamData]),
    #{from := From, status := Status, body := B0, reg_id := PushId} = StreamData,
    FullBody = <<B0/binary, Data/binary>>,
    %% xxx: should we process 401 (refresh token) status here?
    case Status of
        200 ->
            %% response is 'ok', parsing json body and return result id
            #{name := Name} = jsx:decode(FullBody, ?JSX_OPTS),
            MsgId = lists:last(binary:split(Name, <<"/">>, [global, trim_all])),
            gen_statem:reply(From, {ok, MsgId});
        404 ->
            %% wrong (expired?) push id, specific error
            lager:debug("push id not found: ~s", [PushId]),
            gen_statem:reply(From, {error, wrong_push_id});
        _ ->
            %% unknown status, replying with error
            lager:debug("unknown error: ~B : ~p", [Status, FullBody]),
            gen_statem:reply(From, {error, {Status, FullBody}})
    end,
    Streams1 = maps:remove(StreamRef, Streams0),
    %% do not close stream, debug
    %% gun:cancel(GunPid, StreamRef), %% final, closing stream
    {keep_state, State0#{streams => Streams1}};
connected(info
         , {gun_data, GunPid, StreamRef, nofin, Data}
         , #{gun_pid := GunPid} = State0) ->
    %% add data to buffer, still waiting
    #{streams := Streams0} = State0,
    #{StreamRef := StreamState0} = Streams0,
    lager:debug("non-final data response, data: ~p, stream data: ~p", [Data, StreamState0]),
    #{body := B0} = StreamState0,
    StreamState1 = StreamState0#{body => <<B0/binary, Data/binary>>},
    Streams1 = Streams0#{StreamRef => StreamState1},
    {keep_state, State0#{streams => Streams1}};
connected(info
         , {gun_error, GunPid, StreamRef, Reason}
         , #{gun_pid := GunPid} = State0) ->
    %% answering with error, remove entry
    #{streams := Streams0} = State0,
    case maps:get(StreamRef, Streams0, null) of
        null ->
            lager:debug("stream error received, error: ~p, no stream data", [Reason]),
            %% nothing to do
            {keep_state, State0};
        StreamData ->
            lager:debug("stream error received, error: ~p, stream data: ~p", [Reason, StreamData]),
            #{from := From} = StreamData,
            gen_statem:reply(From, {error, Reason}),
            Streams1 = maps:remove(StreamRef, Streams0),
            gun:cancel(GunPid, StreamRef),
            {keep_state, State0#{streams => Streams1}}
    end;
connected(info
         , {gun_error, GunPid, Reason}
         , #{gun_pid := GunPid} = State0) ->
    %% answer with error for all streams, remove all entries, going to reconnect
    #{streams := Streams} = State0,
    lager:debug("gun error on connection received: ~p, streams count: ~B", [Reason, maps:size(Streams)]),
    spawn(efcm_conn, reply_errors_and_cancel_timers, [Streams, Reason]),
    {next_state, down, State0#{streams => #{}, max_streams => 1},
     {next_event, internal, {down, ?FUNCTION_NAME, Reason}}};
connected(info
         , {timeout, GunPid, StreamRef}
         , #{gun_pid := GunPid} = State0) ->
    #{streams := Streams0} = State0,
    %% gun pid matches, we have to answer {error, timeout}
    case maps:find(StreamRef, Streams0) of
        {ok, StreamData} ->
            lager:debug("timeout signalled on stream: ~p", [StreamData]),
            #{from := From} = StreamData,
            gen_statem:reply(From, {error, timeout}),
            Streams1 = maps:remove(StreamRef, Streams0),
            gun:cancel(GunPid, StreamRef),
            {keep_state, State0#{gun_streams => Streams1}};
        error ->
            %% cant find stream data by stream ref?
            %% may be just answered and removed,
            %% ignoring
            {keep_state, State0}
    end;
connected(info,
          {timeout, GotGunPid, _StreamRef},
          State0) ->
    %% timeout from different connection?
    %% ignoring
    #{gun_pid := MyGunPid} = State0,
    lager:debug("timeout from different connection: ~p, mine: ~p", [GotGunPid, MyGunPid]),
    {keep_state, State0};
connected(info
         , {gun_notify, GunPid, settings_changed, Settings}
         , #{gun_pid := GunPid} = State0) ->
    #{max_streams := MaxStreams0} = State0,
    %% settings received, if contains max_concurrent_streams, update it
    lager:debug("gun settings changed received: ~p", [Settings]),
    MaxStreams1 = maps:get(max_concurrent_streams, Settings, MaxStreams0),
    lager:debug("new max streams: ~p", [MaxStreams1]),
    {keep_state, State0#{max_streams => MaxStreams1}};
connected(EventType, EventContent, StateData) ->
    handle_common(EventType, EventContent, ?FUNCTION_NAME, StateData, drop).


-spec down(_, _, _) -> _.
down(internal
    , _
    , #{gun_pid := GunPid
       , gun_mon := GunMon
       }) ->
    lager:debug("down event received for gun pid: ~p", [GunPid]),
    true = demonitor(GunMon, [flush]),
    gun:close(GunPid),
    {keep_state_and_data, {state_timeout, 500, backoff}}; %% sleep 500ms before reconnect
down(state_timeout, backoff, State) ->
    {next_state, open_connection, State,
     {next_event, internal, init}};
down(EventType, EventContent, StateData) ->
    lager:debug("unknown (common) event received, type: ~p, content: ~p", [EventType, EventContent]),
    handle_common(EventType, EventContent, ?FUNCTION_NAME, StateData, postpone).


-spec handle_common(_, _, _, _, _) -> _.
handle_common({call, From}, gun_pid, _, #{gun_pid := GunPid}, _) ->
    {keep_state_and_data, {reply, From, GunPid}};
handle_common(cast, stop, _, _, _) ->
    {stop, normal};
handle_common(info
             , {'DOWN', GunMon, process, GunPid, Reason}
             , StateName
             , #{gun_pid := GunPid, gun_mon := GunMon} = State0
             , _) ->
    %% gun died, answering with errors, cleanup entries, reconnect
    lager:debug("gun process ~p died with reason: ~p", [GunPid, Reason]),
    #{streams := Streams} = State0,
    spawn(efcm_conn, reply_errors_and_cancel_timers, [Streams, Reason]),
    {next_state, down, State0#{gun_streams => #{}},
     {next_event, internal, {down, StateName, Reason}}};
handle_common(state_timeout
             , EventContent
             , StateName
             , #{gun_pid := GunPid} = State
             , _) ->
    lager:debug("state (~p) timeout on gun connection: ~p, event: ~p",
                [StateName, GunPid, EventContent]),
    gun:close(GunPid),
    {next_state, down, State,
     {next_event, internal, {state_timeout, StateName, EventContent}}};
%% xxx: WTF?
handle_common(_, _, _, _, postpone) ->
    {keep_state_and_data, postpone};
handle_common(_, _, _, _, drop) ->
    keep_state_and_data.


%% @private
%% @doc If callback_mode is handle_event_function, then whenever a
%% gen_statem receives an event from call/2, cast/2, or as a normal
%% process message, this function is called.
handle_event(_EventType, _EventContent, _StateName, State = #{}) ->
    NextStateName = the_next_state_name,
    {next_state, NextStateName, State}.

%% @private
%% @doc This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates with
%% Reason. The return value is ignored.
terminate(_Reason, _StateName, _State = #{}) ->
    ok.

%% @private
%% @doc Convert process state when code is changed
code_change(_OldVsn, StateName, State = #{}, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec(append_token(map(), binary()) -> map()).
append_token(#{message := Message} = M, Token) ->
    M#{message => Message#{token => Token}};
append_token(#{<<"message">> := Message} = M, Token) ->
    M#{message => Message#{token => Token}};
append_token(Message, Token) ->
    #{message => Message#{token => Token}}.


-spec(push(GunPid :: pid(), AuthKey :: binary(), PushPath :: binary(),
           RegId :: binary(), Message0 :: map()) -> {ok, gun:stream_ref()}).
push(GunPid, AuthKey, PushPath, RegId, Message0) ->
    MapBody = append_token(Message0, RegId),
    Body = jsx:encode(MapBody),
    Headers = http_headers(AuthKey),
    gun:post(GunPid, PushPath, Headers, Body).

-spec send_push({pid(), term()}, binary(), term(), map()) -> map().
send_push(From, RegId, Message, State) ->
    #{gun_pid := GunPid
     , push_path := PushPath
     , auth_bearer := AuthBearer
     , streams := Streams0
     , max_streams := MaxStreams} = State,
    TotalStreams = maps:size(Streams0),
    StreamAllowed = stream_allowed(TotalStreams, MaxStreams),
    if
        not StreamAllowed ->
            lager:debug("no more streams allowed, current: ~p, max: ~p", [TotalStreams, MaxStreams]),
            {error, {overload, TotalStreams, MaxStreams}};
        {keep_state_and_data, {reply, From, {error, {overload, TotalStreams, MaxStreams}}}};
        true ->
            StreamRef = push(GunPid, AuthBearer, PushPath, RegId, Message),
            Tmr = erlang:send_after(?TIMEOUT, self(), {timeout, GunPid, StreamRef}),
            StreamData = #{reg_id => RegId
                          , message => Message
                          , from => From
                          , stream => StreamRef
                          , timer => Tmr
                          , status => 200 %% b4 we know real status
                          , headers => []
                          , body => <<>>},
            Streams1 = Streams0#{StreamRef => StreamData},
            {ok, State#{streams => Streams1}}
    end.


-spec(make_fcm_push_path(binary()) -> binary()).
make_fcm_push_path(ProjectId) ->
    iolist_to_binary(["/v1/projects/", ProjectId, "/messages:send"]).


reload_access_token(#{service_file := ServiceFile} = State0) ->
    lager:debug("reloading access token"),
    cancel_timer(State0),
    lager:debug("loading google file: ~p", [ServiceFile]),
    {ok, Bin} = file:read_file(ServiceFile),
    #{project_id := ProjectId} = jsx:decode(Bin, ?JSX_OPTS),
    {ok, #{access_token := AccessToken}} = google_oauth:get_access_token(ServiceFile, ?SCOPE),
    AuthorizationBearer = <<"Bearer ", AccessToken/binary>>,
    State0#{
            push_path => make_fcm_push_path(ProjectId),
            auth_bearer => AuthorizationBearer,
            token_tref => erlang:send_after(timer:seconds(3540), self(), refresh_token)
           }.


cancel_timer(#{token_tref := null}) ->
    ok;
cancel_timer(#{token_tref := TimerRef}) ->
    erlang:cancel_timer(TimerRef).


http_headers(AuthKey) ->
    [{<<"authorization">>, AuthKey}
    , {<<"content-type">>, <<"application/json; UTF-8">>}].


http2_opts() -> #{notify_settings_changed => true}.


tls_opts() -> [{verify, verify_none}].


-spec(stream_allowed(StreamsCount :: non_neg_integer(),
                     MaxStreams :: non_neg_integer() | infinity) ->
             boolean()).
stream_allowed(_StreamsCount, infinity) -> true;
stream_allowed(StreamsCount, MaxStreams) ->
    StreamsCount < MaxStreams.

%%%===================================================================
%%% spawn/3 functions
%%%===================================================================
-spec reply_errors_and_cancel_timers(map(), term()) -> ok.
reply_errors_and_cancel_timers(Streams, Reason) ->
    [reply_error_and_cancel_timer(From, Reason, Tmr) ||
        #{from := From, timer := Tmr} <- maps:values(Streams)],
    ok.


-spec reply_error_and_cancel_timer(From :: {pid(), term()}, Reason :: term(),
                                   Tmr :: reference()) -> ok.
reply_error_and_cancel_timer(From, Reason, Tmr) ->
    erlang:cancel_timer(Tmr),
    gen_statem:reply(From, {error, Reason}).
