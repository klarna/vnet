%%% @doc Connection process.
%%% @copyright 2018 Klarna Bank AB
-module(vnet_conn).

%% API
-export([ start_link/2
        , maybe_proxy/1
        , maybe_proxy/2
        , maybe_proxy/3
        , connect/2
        , disconnect/2
        , vnode_starting/1
        , vnode_stopping/1
        ]).

-behaviour(gen_statem).
-export([ callback_mode/0
        , init/1
        , connected/3
        , disconnected/3
        , terminating_proxies/3
        ]).

%% The possible states of the `gen_statem'.
-opaque state() :: connected
                 | disconnected
                 | terminating_proxies.

%% The generation of a connection means how many times have the
%% connection been broken so far.
-type generation() :: non_neg_integer().

%% The non-state data of the `gen_statem'. Contains original process
%% to proxy process mappings and a connection generation counter.
-opaque data() :: #{ pid() => {vnet:vnode(), generation(), pid()}
                   , vnet:vnode() => started | stopped
                   , gen => generation()

                     %% The following keys are specific to the
                     %% `terminating_proxies' state
                   , monitors => [reference()]
                   , next_state => state()
                   }.

-export_type([ state/0
             , data/0
             ]).

%% ---------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------

-spec start_link(vnet:vnode(), vnet:vnode()) -> {ok, pid()} | {error, any()}.
start_link(VNode1, VNode2) ->
  gen_statem:start_link( {local, vnet:conn_proc(VNode1, VNode2)}
                       , ?MODULE
                       , [VNode1, VNode2]
                       , []
                       ).

-spec maybe_proxy(pid()) -> pid().
maybe_proxy(Pid) ->
  case vnet:type(Pid) of
    {virtual, VNodeS} -> maybe_proxy(VNodeS, Pid);
    {proxy, _, {VNodeS, RealPid}} -> maybe_proxy(VNodeS, RealPid);
    _Other -> Pid
  end.

-spec maybe_proxy(vnet:vnode(), pid()) -> pid().
maybe_proxy(VNodeS, Pid) ->
  case vnet:type(self()) of
    native -> Pid;
    {virtual, VNodeC} -> maybe_proxy(VNodeC, VNodeS, Pid);
    {proxy, _, {VNodeC, _}} ->
      %% When a proxy process calls this function it means it's
      %% translating a message before forwarding it to the real
      %% process. Therefore the client vnode shall be the vnode of the
      %% real process.
      maybe_proxy(VNodeC, VNodeS, Pid)
  end.

-spec maybe_proxy(vnet:vnode(), vnet:vnode(), pid()) -> pid().
maybe_proxy(VNode, VNode, Pid) ->
  Pid;
maybe_proxy(VNodeC, VNodeS, Pid) ->
  gen_statem:call( vnet:conn_proc(VNodeC, VNodeS)
                 , {proxy, VNodeC, {VNodeS, Pid}}
                 ).

-spec connect(vnet:vnode(), vnet:vnode()) -> ok | {error, already_connected}.
connect(VNode1, VNode2) ->
  gen_statem:call(vnet:conn_proc(VNode1, VNode2), connect).

-spec disconnect(vnet:vnode(), vnet:vnode()) -> ok |
                                                {error, already_disconnected}.
disconnect(VNode1, VNode2) ->
  gen_statem:call(vnet:conn_proc(VNode1, VNode2), disconnect).

-spec vnode_starting(vnet:vnode()) -> ok.
vnode_starting(VNode) ->
  [gen_statem:call(Pid, {vnode_starting, VNode})
   || Pid <- vnet:conn_pids(VNode)],
  ok.

-spec vnode_stopping(vnet:vnode()) -> ok.
vnode_stopping(VNode) ->
  [gen_statem:call(Pid, {vnode_stopping, VNode})
   || Pid <- vnet:conn_pids(VNode)],
  ok.

%% ---------------------------------------------------------------------
%% gen_statem callbacks
%% ---------------------------------------------------------------------

-spec callback_mode() -> gen_statem:callback_mode().
callback_mode() -> state_functions.

-spec init([vnet:vnode()]) -> gen_statem:init_result(state()).
init(VConn = [VNode1, VNode2]) ->
  put(vconn, VConn),
  {ok, connected, #{gen => 0, VNode1 => started, VNode2 => started}}.

-spec connected(gen_statem:event_type(), any(), data()) ->
                   gen_statem:event_handler_result(state()).
connected({call, From}, {proxy, VNodeC, {VNodeS, Pid}}, Data = #{gen := Gen}) ->
  case maps:find(Pid, Data) of
    {ok, {VNodeS, Gen, Proxy}} ->
      {keep_state_and_data, {reply, From, Proxy}};
    _Other ->
      %% Pid is not yet proxied or the proxy is from a previous
      %% generation (and therefore is already dead)
      Status = maps:get(VNodeS, Data),
      {ok, Proxy} =
        try
          Status = started,
          true = is_process_alive(Pid),
          {ok, _} = vnet_proxy:start(VNodeC, VNodeS, Pid, Gen)
        catch
          _:_ ->
            {ok, vnet:dead_pid()}
        end,
      {keep_state, Data#{Pid => {VNodeS, Gen, Proxy}}, {reply, From, Proxy}}
  end;
connected({call, From}, connect, _Data) ->
  {keep_state_and_data, {reply, From, {error, already_connected}}};
connected({call, From}, disconnect, Data) ->
  Monitors = for_each_proxy(fun on_disconnect/1, Data),
  wait_for_proxies_to_terminate(From, disconnected, Data, Monitors);
connected({call, From}, {vnode_starting, VNode}, Data) ->
  {keep_state, Data#{VNode => started}, {reply, From, ok}};
connected({call, From}, {vnode_stopping, VNode}, Data) ->
  Monitors = for_each_proxy_on_vnode(fun on_stop/1, VNode, Data),
  NewData = Data#{VNode => stopped},
  wait_for_proxies_to_terminate(From, connected, NewData, Monitors);
connected(_EventType, _EventContent, _Data) ->
  keep_state_and_data.

-spec disconnected(gen_statem:event_type(), any(), data()) ->
                      gen_statem:event_handler_result(state()).
disconnected({call, From}, {proxy, _VNodeC, {VNodeS, Pid}}, Data) ->
  case maps:find(Pid, Data) of
    {ok, {VNodeS, _Gen, Proxy}} ->
      {keep_state_and_data, {reply, From, Proxy}};
    error ->
      Proxy = vnet:dead_pid(),
      {keep_state, Data#{Pid => {VNodeS, 0, Proxy}}, {reply, From, Proxy}}
  end;
disconnected({call, From}, connect, Data = #{gen := Gen}) ->
  {next_state, connected, Data#{gen => Gen + 1}, {reply, From, ok}};
disconnected({call, From}, disconnect, _Data) ->
  {keep_state_and_data, {reply, From, {error, already_disconnected}}};
disconnected({call, From}, {vnode_starting, VNode}, Data) ->
  {keep_state, Data#{VNode => started}, {reply, From, ok}};
disconnected({call, From}, {vnode_stopping, VNode}, Data) ->
  {keep_state, Data#{VNode => stopped}, {reply, From, ok}};
disconnected(_EventContent, _EventContent, _Data) ->
  keep_state_and_data.

-spec terminating_proxies(gen_statem:event_type(), any(), data()) ->
                             gen_statem:event_handler_result(state()).
terminating_proxies( Type = {call, _}
                   , Req = {proxy, _, _}
                   , Data = #{next_state := State}) ->
  %% Note: we assume that handling a proxy request would never change the state!
  apply(?MODULE, State, [Type, Req, Data]);
terminating_proxies( info
                   , {'DOWN', Monitor, process, _, _}
                   , Data = #{ monitors := Monitors
                             , next_state := NextState
                             }) ->
  case lists:delete(Monitor, Monitors) of
    [] ->
      NewData = maps:without([monitors, next_state], Data),
      {next_state, NextState, NewData};
    NewMonitors ->
      {keep_state, Data#{monitors => NewMonitors}}
  end;
terminating_proxies(_, _, _) ->
  {keep_state_and_data, postpone}.

%% ---------------------------------------------------------------------
%% Helper functions
%% ---------------------------------------------------------------------

-spec wait_for_proxies_to_terminate( gen_statem:from()
                                   , state()
                                   , data()
                                   , [reference()]
                                   ) -> gen_statem:event_handler_result(state()).
wait_for_proxies_to_terminate(From, NextState, Data, []) ->
  {next_state, NextState, Data, {reply, From, ok}};
wait_for_proxies_to_terminate(From, NextState, Data, Monitors) ->
  { next_state
  , terminating_proxies
  , Data#{ next_state => NextState
         , monitors => Monitors
         }
  , {reply, From, ok}
  }.

-spec on_disconnect(pid()) -> reference().
on_disconnect(Pid) ->
  Monitor = monitor(process, Pid),
  vnet_proxy:on_disconnect(Pid),
  Monitor.

-spec on_stop(pid()) -> reference().
on_stop(Pid) ->
  Monitor = monitor(process, Pid),
  vnet_proxy:on_stop(Pid),
  Monitor.

-spec for_each_proxy(fun ((pid()) -> T), data()) -> [T].
for_each_proxy(Fun, Data) ->
  maps:fold(fun (_RealPid, {_VNodeS, _Gen, Proxy}, Acc) ->
                [Fun(Proxy) | Acc];
                (_OtherKey, _OtherVal, Acc) ->
                Acc
            end,
            [],
            Data).

-spec for_each_proxy_on_vnode( fun ((pid()) -> T)
                             , vnet:vnode()
                             , data()) -> [T].
for_each_proxy_on_vnode(Fun, VNode, Data) ->
  maps:fold(fun (RealPid, {VNodeS, _Gen, Proxy}, Acc) when is_pid(RealPid),
                                                           VNode =:= VNodeS ->
                [Fun(Proxy) | Acc];
                (_OtherKey, _OtherVal, Acc) ->
                Acc
            end,
            [],
            Data).
