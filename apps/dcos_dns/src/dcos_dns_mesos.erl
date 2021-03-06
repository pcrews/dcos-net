-module(dcos_dns_mesos).
-behavior(gen_server).

-include("dcos_dns.hrl").
-include_lib("dns/include/dns.hrl").

%% API
-export([
    start_link/0,
    dns_records/2,
    push_zone/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-type task() :: dcos_net_mesos_listener:task().
-type task_id() :: dcos_net_mesos_listener:task_id().

-record(state, {
    ref :: reference(),
    tasks :: #{task_id() => [dns:dns_rr()]},
    records :: #{dns:dns_rr() => pos_integer()},
    masters_ref :: reference(),
    masters = [] :: [dns:dns_rr()],
    ops_ref = undefined :: reference() | undefined,
    ops = [] :: [riak_dt_orswot:orswot_op()]
}).
-type state() :: #state{}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, State) ->
    State0 = handle_init(State),
    {noreply, State0};
handle_info({task_updated, Ref, TaskId, Task}, #state{ref=Ref}=State) ->
    ok = dcos_net_mesos_listener:next(Ref),
    {noreply, handle_task_updated(TaskId, Task, State)};
handle_info({'DOWN', Ref, process, _Pid, Info}, #state{ref=Ref}=State) ->
    {stop, Info, State};
handle_info({timeout, Ref, masters}, #state{masters_ref=Ref}=State) ->
    {noreply, handle_masters(State)};
handle_info({timeout, Ref, push_ops}, #state{ops_ref=Ref}=State) ->
    {noreply, handle_push_ops(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(handle_init(State) -> State when State :: state() | []).
handle_init(State) ->
    case dcos_net_mesos_listener:subscribe() of
        {ok, Ref, MTasks} ->
            MRef = start_masters_timer(),
            {Tasks, Records} = task_records(MTasks),
            {ok, NewRRs, OldRRs} = push_tasks(Tasks),
            lager:notice(
                "DC/OS DNS Sync: ~p records were added, ~p records were removed",
                [length(NewRRs), length(OldRRs)]),
            #state{ref=Ref, tasks=Tasks, records=Records, masters_ref=MRef};
        {error, timeout} ->
            exit(timeout);
        {error, subscribed} ->
            exit(subscribed);
        {error, _Error} ->
            self() ! init,
            timer:sleep(100),
            State
    end.

%%%===================================================================
%%% Tasks functions
%%%===================================================================

-spec(handle_task_updated(task_id(), task(), state()) -> state()).
handle_task_updated(TaskId, Task,
        #state{tasks=Tasks, records=Records}=State) ->
    {Tasks0, Records0, Ops} = task_updated(TaskId, Task, Tasks, Records),
    handle_push_ops(Ops, State#state{tasks=Tasks0, records=Records0}).

-spec(task_updated(task_id(), task(), Tasks, RRs) -> {Tasks, RRs, Ops}
    when Tasks :: #{task_id() => [dns:dns_rr()]},
         RRs :: #{dns:dns_rr() => pos_integer()},
         Ops :: [riak_dt_orswot:orswot_op()]).
task_updated(TaskId, Task, Tasks, RRs) ->
    TaskState = maps:get(state, Task),
    case {is_running(TaskState), maps:is_key(TaskId, Tasks)} of
        {Same, Same} ->
            {Tasks, RRs, []};
        {false, true} ->
            {Records, Tasks0} = maps:take(TaskId, Tasks),
            RRs0 = update_records(Records, -1, RRs),
            % Remove records if there is no another task with such records
            Records0 = [RR || RR <- Records, not maps:is_key(RR, RRs0)],
            {Tasks0, RRs0, [{remove_all, Records0} || Records0 =/= []]};
        {true, false} ->
            TaskRecords = task_records(TaskId, Task),
            Tasks0 = maps:put(TaskId, TaskRecords, Tasks),
            RRs0 = update_records(TaskRecords, 1, RRs),
            {Tasks0, RRs0, [{add_all, TaskRecords}]}
    end.

-spec(task_records(#{task_id() => task()}) ->
    {#{task_id() => [dns:dns_rr()]}, #{dns:dns_rr() => pos_integer()}}).
task_records(Tasks) ->
    maps:fold(fun (TaskId, #{state := TaskState} = Task, {Acc, RRs}) ->
        case is_running(TaskState) of
            true ->
                TaskRecords = task_records(TaskId, Task),
                Acc0 = maps:put(TaskId, TaskRecords, Acc),
                RRs0 = update_records(TaskRecords, 1, RRs),
                {Acc0, RRs0};
            false ->
                {Acc, RRs}
        end
    end, {#{}, #{}}, Tasks).

-spec(task_records(task_id(), task()) -> dns:dns_rr()).
task_records(TaskId, Task) ->
    lists:flatten([
        task_agentip(TaskId, Task),
        task_containerip(TaskId, Task),
        task_autoip(TaskId, Task)
    ]).

-spec(task_agentip(task_id(), task()) -> [dns:dns_rr()]).
task_agentip(_TaskId, #{name := Name,
        framework := Fwrk, agent_ip := AgentIP}) ->
    DName = format_name([Name, Fwrk, <<"agentip">>], ?DCOS_DOMAIN),
    dns_records(DName, [AgentIP]);
task_agentip(TaskId, Task) ->
    lager:warning("Unexpected task ~p with ~p", [TaskId, Task]),
    [].

-spec(task_containerip(task_id(), task()) -> [dns:dns_rr()]).
task_containerip(_TaskId, #{name := Name,
        framework := Fwrk, task_ip := TaskIPs}) ->
    DName = format_name([Name, Fwrk, <<"containerip">>], ?DCOS_DOMAIN),
    dns_records(DName, TaskIPs);
task_containerip(_TaskId, _Task) ->
    [].

-spec(task_autoip(task_id(), task()) -> [dns:dns_rr()]).
task_autoip(_TaskId, #{name := Name, framework := Fwrk,
        agent_ip := AgentIP, task_ip := TaskIPs} = Task) ->
    %% if task.port_mappings then agent_ip else task_ip
    DName = format_name([Name, Fwrk, <<"autoip">>], ?DCOS_DOMAIN),
    Ports = maps:get(ports, Task, []),
    dns_records(DName,
        case lists:any(fun is_port_mapping/1, Ports) of
            true -> [AgentIP];
            false -> TaskIPs
        end
    );
task_autoip(_TaskId, #{name := Name,
        framework := Fwrk, agent_ip := AgentIP}) ->
    DName = format_name([Name, Fwrk, <<"autoip">>], ?DCOS_DOMAIN),
    dns_records(DName, [AgentIP]);
task_autoip(TaskId, Task) ->
    lager:warning("Unexpected task ~p with ~p", [TaskId, Task]),
    [].

-spec(is_running(dcos_net_mesos_listener:task_state()) -> boolean()).
is_running(running) ->
    true;
is_running(_TaskState) ->
    false.

-spec(is_port_mapping(dcos_net_mesos_listener:task_port()) -> boolean()).
is_port_mapping(#{host_port := _HPort}) ->
    true;
is_port_mapping(_Port) ->
    false.

-spec(update_records([dns:dns_rr()], integer(), RRs) -> RRs
    when RRs :: #{dns:dns_rr() => pos_integer()}).
update_records(Records, Incr, RRs) when is_list(Records) ->
    lists:foldl(fun (Record, Acc) ->
        update_record(Record, Incr, Acc)
    end, RRs, Records).

-spec(update_record(dns:dns_rr(), integer(), RRs) -> RRs
    when RRs :: #{dns:dns_rr() => pos_integer()}).
update_record(Record, Incr, RRs) ->
    case maps:get(Record, RRs, 0) + Incr of
        0 -> maps:remove(Record, RRs);
        N -> RRs#{Record => N}
    end.

%%%===================================================================
%%% Masters functions
%%%===================================================================

-spec(handle_masters(state()) -> state()).
handle_masters(#state{masters=MRRs}=State) ->
    ZoneName = ?DCOS_DOMAIN,
    MRRs0 = master_records(ZoneName),

    {NewRRs, OldRRs} = dcos_net_utils:complement(MRRs0, MRRs),
    lists:foreach(fun (#dns_rr{data=#dns_rrdata_a{ip = IP}}) ->
        lager:notice("DNS records: master ~p was added", [IP])
    end, NewRRs),
    lists:foreach(fun (#dns_rr{data=#dns_rrdata_a{ip = IP}}) ->
        lager:notice("DNS records: master ~p was removed", [IP])
    end, OldRRs),

    Ref = start_masters_timer(),
    AddOps = [{add_all, NewRRs} || NewRRs =/= []],
    RemoveOps = [{remove_all, OldRRs} || OldRRs =/= []],
    State0 = State#state{masters_ref=Ref, masters=MRRs0},
    handle_push_ops(AddOps ++ RemoveOps, State0).

-spec(master_records(dns:dname()) -> [dns:dns_rr()]).
master_records(ZoneName) ->
    Masters = [IP || {IP, _} <- dcos_dns_config:mesos_resolvers()],
    dns_records(<<"master.", ZoneName/binary>>, Masters).

-spec(leader_records(dns:dname()) -> dns:dns_rr()).
leader_records(ZoneName) ->
    % dcos-net connects only to local mesos,
    % operator API works only on a leader mesos,
    % so this node is the leader node
    IP = dcos_net_dist:nodeip(),
    dns_record(<<"leader.", ZoneName/binary>>, IP).

-spec(start_masters_timer() -> reference()).
start_masters_timer() ->
    Timeout = application:get_env(dcos_dns, masters_timeout, 5000),
    erlang:start_timer(Timeout, self(), masters).

%%%===================================================================
%%% DNS functions
%%%===================================================================

-spec(push_tasks(#{task_id() => task()}) ->
    {ok, New :: [dns:dns_rr()], Old :: [dns:dns_rr()]}).
push_tasks(Tasks) ->
    ZoneName = ?DCOS_DOMAIN,
    Records = maps:values(Tasks),
    Records0 =
        lists:flatten([
            Records,
            zone_records(ZoneName),
            leader_records(ZoneName)
        ]),
    push_zone(ZoneName, Records0).

-spec(dns_records(dns:dname(), [inet:ip_address()]) -> [dns:dns_rr()]).
dns_records(DName, IPs) ->
    [dns_record(DName, IP) || IP <- IPs].

-spec(dns_record(dns:dname(), inet:ip_address()) -> dns:dns_rr()).
dns_record(DName, IP) ->
    {Type, Data} =
        case dcos_dns:family(IP) of
            inet -> {?DNS_TYPE_A, #dns_rrdata_a{ip = IP}};
            inet6 -> {?DNS_TYPE_AAAA, #dns_rrdata_aaaa{ip = IP}}
        end,
    #dns_rr{name = DName, type = Type, ttl = ?DCOS_DNS_TTL, data = Data}.

-spec(format_name([binary()], binary()) -> binary()).
format_name(ListOfNames, Postfix) ->
    ListOfNames1 = lists:map(fun mesos_state:label/1, ListOfNames),
    ListOfNames2 = lists:map(fun list_to_binary/1, ListOfNames1),
    Prefix = join(ListOfNames2, <<".">>),
    <<Prefix/binary, ".", Postfix/binary>>.

-spec(join([binary()], binary()) -> binary()).
join(List, Sep) ->
    SepSize = size(Sep),
    <<Sep:SepSize/binary, Result/binary>> =
        << <<Sep/binary, X/binary>> || X <- List >>,
    Result.

%%%===================================================================
%%% Lashup functions
%%%===================================================================

-spec(push_zone(dns:dname(), [dns:dns_rr()]) ->
    {ok, New :: [dns:dns_rr()], Old :: [dns:dns_rr()]}).
push_zone(ZoneName, Records) ->
    Key = ?LASHUP_KEY(ZoneName),
    LRecords = lashup_kv:value(Key),
    LRecords0 =
        case lists:keyfind(?RECORDS_FIELD, 1, LRecords) of
            false -> [];
            {_, LR} -> LR
        end,
    push_diff(ZoneName, Records, LRecords0).

-spec(push_diff(dns:dname(), [dns:dns_rr()], [dns:dns_rr()]) ->
    {ok, New :: [dns:dns_rr()], Old :: [dns:dns_rr()]}).
push_diff(ZoneName, New, Old) ->
    case dcos_net_utils:complement(New, Old) of
        {[], []} ->
            {ok, [], []};
        {AddRecords, RemoveRecords} ->
            Ops = [{remove_all, RemoveRecords}, {add_all, AddRecords}],
            ok = push_ops(ZoneName, Ops),
            {ok, AddRecords, RemoveRecords}
    end.

-spec(push_ops(dns:dname(), [riak_dt_orswot:orswot_op()]) -> ok).
push_ops(_ZoneName, []) ->
    ok;
push_ops(ZoneName, Ops) ->
    % TODO: use lww
    Key = ?LASHUP_KEY(ZoneName),
    Updates = [{update, ?RECORDS_FIELD, Op} || Op <- Ops],
    case lashup_kv:request_op(Key, {update, Updates}) of
        {ok, _} -> ok
    end.

-spec(zone_records(dns:dname()) -> [dns:dns_rr()]).
zone_records(ZoneName) ->
    [
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_SOA,
            ttl = 3600,
            data = #dns_rrdata_soa{
                mname = <<"ns.spartan">>,
                rname = <<"support.mesosphere.com">>,
                serial = 1,
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ].

-spec(handle_push_ops([riak_dt_orswot:orswot_op()], state()) -> state()).
handle_push_ops([], State) ->
    State;
handle_push_ops(Ops, #state{ops=[], ops_ref=undefined}=State) ->
    % NOTE: push data to lashup 1 time per second
    ok = push_ops(?DCOS_DOMAIN, Ops),
    State#state{ops_ref=start_push_ops_timer()};
handle_push_ops(Ops, #state{ops=Buf}=State) ->
    State#state{ops=Buf ++ Ops}.

-spec(handle_push_ops(state()) -> state()).
handle_push_ops(#state{ops=Ops}=State) ->
    ok = push_ops(?DCOS_DOMAIN, Ops),
    State#state{ops=[], ops_ref=undefined}.

-spec(start_push_ops_timer() -> reference()).
start_push_ops_timer() ->
    Timeout = application:get_env(dcos_dns, push_ops_timeout, 1000),
    erlang:start_timer(Timeout, self(), push_ops).
