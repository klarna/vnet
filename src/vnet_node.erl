%%% @doc Node process.
%%% @copyright 2018 Klarna Bank AB
-module(vnet_node).

%% API
-export([ start_link/1
        , rpc/4
        , start/1
        , stop/1
        ]).

-behaviour(gen_statem).
-export([ callback_mode/0
        , init/1
        , started/3
        , stopped/3
        , terminate/3
        ]).

%% The possible states of the `gen_statem'.
-opaque state() :: started | stopped.

%% The non-state data of the `gen_statem'.
-opaque data() :: pid().                        % The original group leader

-export_type([ state/0
             , data/0
             ]).

%% ---------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------

%% @doc Start the root process of a virtual node.
-spec start_link(vnet:vnode()) -> {ok, pid()} | {error, any()}.
start_link(VNode) ->
  gen_statem:start_link( {local, vnet:node_proc(VNode)}
                       , ?MODULE
                       , VNode
                       , []
                       ).

%% @doc Do an rpc call in parallel to a list of virtual nodes. This
%% can be used from processes on other vnodes or processes that are
%% not part of the virtual network alike.
-spec rpc([vnet:vnode()], module(), atom(), list()) ->
             {[term()], [vnet:vnode()]}.
rpc(VNodes, Module, Function, Args) ->
  From = vnet:type(self()),
  Workers = [case setup_rpc_proc(VNode, From) of
               {ok, Pid} ->
                 Ref = monitor(process, Pid),
                 Pid ! {rpc, Module, Function, Args},
                 {pending, VNode, Pid, Ref};
               error ->
                 {error, VNode}
             end
             || VNode <- VNodes
            ],
  wait_rpc_results(lists:reverse(Workers), [], []).

%% @doc Start the virtual node.
-spec start(vnet:vnode()) -> ok | {error, already_started}.
start(VNode) ->
  gen_statem:call(vnet:node_proc(VNode), start).

%% @doc Stop the virtual node.
-spec stop(vnet:vnode()) -> ok | {error, already_stopped}.
stop(VNode) ->
  gen_statem:call(vnet:node_proc(VNode), stop).

%% ---------------------------------------------------------------------
%% gen_statem callbacks
%% ---------------------------------------------------------------------

-spec callback_mode() -> gen_statem:callback_mode().
callback_mode() -> state_functions.

-spec init(vnet:vnode()) -> gen_statem:init_result(state()).
init(VNode) ->
  process_flag(trap_exit, true),
  put(vnode, VNode),
  GL = group_leader(),
  group_leader(self(), self()),
  {ok, started, GL}.

-spec started(gen_statem:event_type(), any(), data()) ->
                 gen_statem:event_handler_result(state()).
started({call, From}, {setup_rpc, Name}, _GL) ->
  Pid = spawn(erlang, apply, [fun rpc_worker/1, [Name]]),
  {keep_state_and_data, {reply, From, {ok, Pid}}};
started({call, From}, start, _GL) ->
  {keep_state_and_data, {reply, From, {error, already_started}}};
started({call, From}, stop, GL) ->
  vnet_conn:vnode_stopping(get(vnode)),
  kill_processes_on_vnode(),
  {next_state, stopped, GL, {reply, From, ok}};
started(EventType, EventContent, GL) ->
  handle_event(EventType, EventContent, GL).

-spec stopped(gen_statem:event_type(), any(), data()) ->
                 gen_statem:event_handler_result(state()).
stopped({call, From}, {setup_rpc, _}, _GL) ->
  {keep_state_and_data, {reply, From, error}};
stopped({call, From}, start, GL) ->
  vnet_conn:vnode_starting(get(vnode)),
  {next_state, started, GL, {reply, From, ok}};
stopped({call, From}, stop, _GL) ->
  {keep_state_and_data, {reply, From, {error, already_stopped}}};
stopped(EventType, EventContent, GL) ->
  handle_event(EventType, EventContent, GL).

-spec terminate(term(), state(), data()) -> false.
terminate(_Reason, _State, _GL) ->
  kill_processes_on_vnode().

%% ---------------------------------------------------------------------
%% Helper functions
%% ---------------------------------------------------------------------

-spec handle_event(gen_statem:event_type(), any(), data()) ->
                      keep_state_and_data.
handle_event(info, IoReq, GL) when element(1, IoReq) =:= io_request ->
  GL ! IoReq,
  keep_state_and_data;
handle_event(_EventType, _EventContent, _GL) ->
  keep_state_and_data.

-spec kill_processes_on_vnode() -> false.
kill_processes_on_vnode() ->
  Self = self(),
  lists:foldl(fun (Pid, KilledPids) when Pid =:= Self -> KilledPids;
                  (Pid, KilledPids) ->
                  case process_info(Pid, group_leader) of
                    {group_leader, Self} ->
                      Mon = monitor(process, Pid),
                      exit(Pid, kill),
                      receive
                        {'DOWN', Mon, process, Pid, _} -> true
                      end;
                    _Other ->
                      KilledPids
                  end
              end,
              false,
              processes())
  %% Repeat until no more processes are left to kill
    andalso kill_processes_on_vnode().

-spec setup_rpc_proc(vnet:vnode(), {virtual, vnet:vnode()} | any()) ->
                        {ok, pid()} | error.
setup_rpc_proc(VNodeS, {virtual, VNodeC}) when VNodeC =/= VNodeS ->
  try gen_statem:call(vnet:node_proc(VNodeS), {setup_rpc, rpc_name(VNodeS)}) of
    error -> error;
    {ok, RealPid} ->
      ProxyPid = vnet_conn:maybe_proxy(VNodeC, VNodeS, RealPid),
      case is_process_alive(ProxyPid) of
        true -> {ok, ProxyPid};
        false ->
          %% Looks like the two vnodes are disconnected
          RealPid ! norpc,
          error
      end
  catch
    %% The vnode root is not supposed to crash, so assume this is a
    %% nonexistent vnode.
    exit:{noproc, _} -> error
  end;
setup_rpc_proc(VNode, _Other) ->
  %% Caller must be either a native process or belong to the same
  %% vnode. (Proxy processes will never do rpc-s).
  try gen_statem:call(vnet:node_proc(VNode), {setup_rpc, rpc_name(VNode)})
  catch
    exit:{noproc, _} -> error
  end.

-spec rpc_worker(atom()) -> ok | {ok, reference(), term()}.
rpc_worker(Name) ->
  register(Name, self()),
  receive
    {rpc, Module, Function, Args} ->
      try apply(Module, Function, Args) of
        Result -> exit({rpc, Result})
      catch
        throw:Result -> exit({rpc, Result});
        exit:Reason  -> exit({badrpc, Reason});
        error:Reason -> exit({badrpc, {Reason, erlang:get_stacktrace()}})
      end;
    norpc ->
      ok
  end.

-spec rpc_name(vnet:vnode()) -> atom().
rpc_name(VNode) ->
  ParentStr =
    case process_info(self(), registered_name) of
      {registered_name, ParentName} -> atom_to_list(ParentName);
      [] -> pid_to_list(self())
    end,
  RpcStr = lists:flatten(
             io_lib:format("~s rpc to ~s/~p", [ParentStr, VNode, self()])),
  list_to_atom(RpcStr).

-spec wait_rpc_results( [ {pending, vnet:vnode(), pid(), reference()} |
                          {error, vnet:vnode()}
                        ]
                      , Results
                      , BadNodes) ->
                          {Results, BadNodes} when Results :: [term()],
                                                   BadNodes :: [vnet:vnode()].
wait_rpc_results([], Results, BadNodes) ->
  {Results, BadNodes};
wait_rpc_results([{error, VNode} | Workers], Results, BadNodes) ->
  wait_rpc_results(Workers, Results, [VNode | BadNodes]);
wait_rpc_results([{pending, VNode, Pid, Ref} | Workers], Results, BadNodes) ->
  receive
    {'DOWN', Ref, process, Pid, {rpc, Result}} ->
      wait_rpc_results(Workers, [Result | Results], BadNodes);
    {'DOWN', Ref, process, Pid, noconnection} ->
      wait_rpc_results(Workers, Results, [VNode | BadNodes]);
    {'DOWN', Ref, process, Pid, {badrpc, Reason}} ->
      wait_rpc_results( Workers
                      , [{badrpc, {'EXIT', Reason}} | Results]
                      , BadNodes);
    {'DOWN', Ref, process, Pid, Reason} ->
      exit({rpc_crash, Reason})
  end.
