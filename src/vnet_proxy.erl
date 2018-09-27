%%% @doc Proxy process.
%%% @copyright 2018 Klarna Bank AB
-module(vnet_proxy).

%% API
-export([ start/4
        , on_disconnect/1
        , on_stop/1
        ]).

%% Internal callbacks
-export([ init/4
        , loop/2
        ]).

%% A message to signal the proxy shall go down with noconnection
%% reason.
-define(noconnection(From, Ref, Type),
        {'$$$_vnet_proxy_noconnection_signal_$$$', From, Ref, Type}).

%% ---------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------

-spec start(vnet:vnode(), vnet:vnode(), pid(), term()) -> {ok, pid()} |
                                                          {error, any()}.
start(VNodeC, VNodeS, Pid, Gen) ->
  proc_lib:start( ?MODULE
                , init
                , [VNodeC, VNodeS, Pid, Gen]
                ).

-spec on_disconnect(pid()) -> ok.
on_disconnect(Proxy) ->
  sync_noconnection(Proxy, disconnect).

-spec on_stop(pid()) -> ok.
on_stop(Proxy) ->
  sync_noconnection(Proxy, stop).

%% ---------------------------------------------------------------------
%% Internal callbacks
%% ---------------------------------------------------------------------

-spec init(vnet:vnode(), vnet:vnode(), pid(), term()) -> no_return().
init(VNodeC, VNodeS, Pid, Gen) ->
  process_flag(trap_exit, true),
  put(proxy, {VNodeC, VNodeS, Pid}),
  link(Pid),
  PidName =
    case process_info(Pid, registered_name) of
      [] -> erlang:pid_to_list(Pid);
      {registered_name, Name} -> Name
    end,
  ProxyName =
    lists:flatten(io_lib:format( "~p/~s->~s/~p"
                               , [PidName, VNodeC, VNodeS, Gen])),
  register(list_to_atom(ProxyName), self()),
  proc_lib:init_ack({ok, self()}),
  loop(Pid).

-spec loop(pid()) -> no_return().
loop(Pid) ->
  receive Msg -> ?MODULE:loop(Msg, Pid) end.

-spec loop(term(), pid()) -> no_return().
loop(?noconnection(From, Ref, disconnect), Pid) ->
  %% Simulate the connection going down
  unlink(Pid),
  From ! Ref,
  exit(noconnection);
loop(?noconnection(From, Ref, stop), Pid) ->
  %% Wait for the real process going down and convert the exit reason
  %% to a `noconnection'
  From ! Ref,
  receive {'EXIT', Pid, _Reason} -> exit(noconnection) end;
loop({'EXIT', Pid, Reason}, Pid) ->
  %% Real process died, terminate with the same reason
  exit(Reason);
loop({'EXIT', _Other, Reason}, Pid) ->
  %% Some other process linking to us died, forward the exit signal to
  %% the real process (note: this will not terminate the process in
  %% case the original reason is `normal')
  exit(Pid, Reason),
  loop(Pid);
loop(Msg, Pid) ->
  Pid ! translate_msg(Msg),
  loop(Pid).

translate_msg(Term) ->
  {NewTerm, _Changed} = translate_msg(Term, false),
  NewTerm.

translate_msg(Pid, Changed) when is_pid(Pid) ->
  ProxyPid = vnet_conn:maybe_proxy(Pid),
  {ProxyPid, Changed orelse (ProxyPid =/= Pid)};
translate_msg(List, Changed) when is_list(List) ->
  case lists:mapfoldl(fun translate_msg/2, false, List) of
    {_, false} -> {List, Changed};
    Other -> Other
  end;
translate_msg(Tuple, Changed) when is_tuple(Tuple) ->
  case translate_msg(tuple_to_list(Tuple), false) of
    {_, false}   -> {Tuple, Changed};
    {List, true} -> {list_to_tuple(List), true}
  end;
translate_msg(Map, Changed) when is_map(Map) ->
  case translate_msg(maps:to_list(Map), false) of
    {_, false}   -> {Map, Changed};
    {List, true} -> {maps:from_list(List), true}
  end;
translate_msg(Term, Changed) ->
  %% TODO: if term is a local fun, it may have pids in its env that
  %% would have to be translated. This would be possible by converting
  %% the fun to a binary, then parsing and updating the binary in
  %% external term format and finally converting it back to a fun. But
  %% it's not convenient, and not yet implemented.
  {Term, Changed}.

sync_noconnection(Pid, Type) ->
  Ref = monitor(process, Pid),
  Pid ! ?noconnection(self(), Ref, Type),
  receive
    Ref -> ok;
    {'DOWN', Ref, process, Pid, _Reason} -> ok
  end.
