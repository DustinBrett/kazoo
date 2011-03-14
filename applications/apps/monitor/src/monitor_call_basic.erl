%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.com>
%%% @copyright (C) 2010, Karl Anderson
%%% @doc
%%% Responsible for runnning the basic call task
%%% @end
%%% Created : 2 Dec 2010 by Karl Anderson <karl@2600hz.com>
%%%-------------------------------------------------------------------
-module(monitor_call_basic).

-include("../include/monitor_amqp.hrl").

-import(logger, [format_log/3]).
-import(proplists, [get_value/2, get_value/3]).

%% API
-export([start/3]).

-define(SERVER, ?MODULE).
-define(FREQ, <<"2600">>).

start(AHost, Msg, Route) ->
    Msg_ID = get_value(<<"Msg-ID">>, Msg),
    {ok, Task_Q} = create_task_q(AHost),
    Result = case originate_call_req(AHost, Msg_ID, Route, Task_Q) of 
        {ok, Resource} ->
            CQ = get_value(<<"Control-Queue">>, Resource),
            Call_ID = get_value(<<"Call-ID">>, Resource),
            amqp_util:bind_q_to_callevt(AHost, Task_Q, Call_ID),
            answer_call(AHost, CQ, Call_ID, Task_Q),
            Rslt = test_tones(AHost, CQ, Call_ID, Task_Q),
            hangup_call(AHost, CQ, Call_ID, Task_Q), Rslt;
        {error, E} ->
            {error, [{<<"Error">>, E}, {<<"Success">>, <<"false">>}]}
    end,
    amqp_util:queue_delete(AHost, Task_Q),
    format_log(info, "MONITOR_CALL_BASIC(~p): Basic call test completed ~p", [self(), Result]),
    Result.

originate_call_req(AHost, Msg_ID, Route, Server_ID) ->
    Def = monitor_api:default_headers(Server_ID, <<"originate">>, <<"resource_req">>, Msg_ID),
    Req = [
            {<<"Resource-Type">>, <<"audio">>}
           ,{<<"Invite-Format">>, <<"route">>}
           ,{<<"Caller-ID-Name">>, <<"2600hz Monitoring">>}
           ,{<<"Caller-ID-Number">>, <<"4158867900">>}
           ,{<<"Route">>, Route}           
    ],
    format_log(info, "MONITOR_CALL_BASIC(~p): Originate call to ~p", [self(), Route]),
    {ok, JSON} = whistle_api:resource_req(lists:append([Def, Req])),
    amqp_util:callmgr_publish(AHost, JSON, <<"application/json">>, ?KEY_RESOURCE_REQ),
    wait_for_msg_type(<<"originate">>, <<"resource_resp">>, 20000).

answer_call(AHost, CQ, Call_ID, Server_ID) ->
    Def = monitor_api:default_headers(Server_ID, <<"call_control">>, <<"command">>),
    Req = [
         {<<"Call-ID">>, Call_ID}
        ,{<<"Application-Name">>, <<"answer">>}
    ],
    {ok, JSON} = whistle_api:answer_req(lists:append([Def, Req])),
    amqp_util:callctl_publish(AHost, CQ, JSON).

test_tones(AHost, CQ, Call_ID, Server_ID) ->
    arm_tone_detector(AHost, CQ, Call_ID, Server_ID),
    generate_tones(AHost, CQ, Call_ID, Server_ID),    
    Start = wait_for_call_event_exec(<<"play">>, 15000),
    End = wait_for_call_event_exec(<<"park">>, 15000),
    case {Start, End} of
        {{ok, StartMsg}, {ok, EndMsg}} ->
            Delay = whistle_util:to_integer(get_value(<<"Timestamp">>, EndMsg)) 
                    - whistle_util:to_integer(get_value(<<"Timestamp">>, StartMsg)),
            {ok, [{<<"Delay">>, Delay}, {<<"Success">>, <<"true">>}]};
        {{error, E}, _} ->
            {error, [{<<"Error">>, E}, {<<"Success">>, <<"false">>}]};
        {_, {error, E}} ->
            {error, [{<<"Error">>, E}, {<<"Success">>, <<"false">>}]};
        _ ->
            {error, [{<<"Error">>, <<"unspecified">>}, {<<"Success">>, <<"false">>}]}
    end.

hangup_call(AHost, CQ, Call_ID, Server_ID) ->
    Def = monitor_api:default_headers(Server_ID, <<"call_control">>, <<"command">>),
    Req = [
         {<<"Call-ID">>, Call_ID}
        ,{<<"Application-Name">>, <<"hangup">>}
    ],
    {ok, JSON} = whistle_api:hangup_req(lists:append([Def, Req])),
    amqp_util:callctl_publish(AHost, CQ, JSON).

create_task_q(AHost) ->
    Q = amqp_util:new_monitor_queue(AHost),
    %% Bind the queue to the targeted exchange
    amqp_util:bind_q_to_targeted(AHost, Q),
    %% Register a consumer to listen to the queue
    amqp_util:basic_consume(AHost, Q),
    {ok, Q}.

arm_tone_detector(AHost, CQ, Call_ID, Server_ID) ->
    Def = monitor_api:default_headers(Server_ID, <<"call_control">>, <<"command">>),
    Req = [
         {<<"Call-ID">>, Call_ID}
        ,{<<"Application-Name">>, <<"tone_detect">>}
        ,{<<"Tone-Detect-Name">>, Call_ID}
        ,{<<"Frequencies">>, [?FREQ]}
        ,{<<"Sniff-Direction">>, <<"read">>}
        ,{<<"Timeout">>, <<"0">>}
    ],
    {ok, JSON} = whistle_api:tone_detect_req(lists:append([Def, Req])),
    amqp_util:callctl_publish(AHost, CQ, JSON).

generate_tones(AHost, CQ, Call_ID, Server_ID) ->
    Def = monitor_api:default_headers(Server_ID, <<"call_control">>, <<"command">>),
    Req = [
         {<<"Call-ID">>, Call_ID}
        ,{<<"Application-Name">>, <<"tones">>}
        ,{<<"Tones">>, [
            {struct, [
                 {<<"Frequencies">>, [?FREQ]}
                ,{<<"Duration-ON">>, <<"5000">>}
                ,{<<"Duration-OFF">>, <<"10">>}
            ]}
        ]}
    ],
    {ok, JSON} = whistle_api:tones_req(lists:append([Def, Req])),
    amqp_util:callctl_publish(AHost, CQ, JSON).

wait_for_msg_type(Category, Name, Timeout) ->
    receive
        {_, #amqp_msg{props = Props, payload = Payload}} when Props#'P_basic'.content_type == <<"application/json">> ->
            {struct, Msg} = mochijson2:decode(binary_to_list(Payload)),
            case { get_value(<<"Event-Category">>, Msg), get_value(<<"Event-Name">>, Msg) } of
                { Category, Name } ->
                    {ok, Msg};
                { <<"originate">>, <<"originate_error">> } ->
                    Error = get_value(<<"Failure-Message">>, Msg),
                    format_log(info, "MONITOR_CALL_BASIC(~p): Recieved originator error ~p", [self(), Error]),
                    {error, Error};
                { <<"originate">>, <<"resource_error">> } ->
                    format_log(info, "MONITOR_CALL_BASIC(~p): Recieved originator error resource_unavliable", [self()]),
                    {error, resources_unavaliable};
                _ ->
                    wait_for_msg_type(Category, Name, Timeout)
            end
    after
        Timeout ->
            format_log(info, "MONITOR_CALL_BASIC(~p): Timed out waiting for orignate response", [self()]),
            {error, timeout}
    end.

wait_for_call_event_exec(Application, Timeout) ->
    wait_for_call_event(<<"CHANNEL_EXECUTE">>, Application, Timeout).

wait_for_call_event(Name, Application, Timeout) ->
    receive
        {_, #amqp_msg{props = Props, payload = Payload}} when Props#'P_basic'.content_type == <<"application/json">> ->
            {struct, Msg} = mochijson2:decode(binary_to_list(Payload)),
            case { get_value(<<"Event-Category">>, Msg), get_value(<<"Event-Name">>, Msg), get_value(<<"Application-Name">>, Msg) } of
                { <<"call_event">>, Name, Application } ->                
                    {ok, Msg};
                { <<"call_event">>, <<"CHANNEL_HANGUP">>, _Name } ->
                    format_log(info, "MONITOR_CALL_BASIC(~p): Channel ~p hungup before anticipated event ~p", [self(), get_value(<<"Call-ID">>, Msg), Application]),
                    {error, channel_hungup};
                _ ->
                    wait_for_call_event(Name, Application, Timeout)
            end
    after
        Timeout ->
            format_log(info, "MONITOR_CALL_BASIC(~p): Timeout while waiting for call event ~p", [self(), Application]),
            {error, timeout}
    end.
