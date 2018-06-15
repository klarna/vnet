%%% @doc The main application module.
%%% @copyright 2018 Klarna Bank AB
-module(vnet).

%% API
-export([ start_link/1
        , stop/0

          %% Controlling the virtual network
        , rpc/4
        , start/1
        , stop/1
        , connect/2
        , disconnect/2

          %% Well-known process names
        , node_proc/1
        , conn_proc/2
        , tab/2

          %% Process classification
        , vnode/0
        , vnode/1
        , type/1

          %% Helper functions
        , dead_pid/0
        , conn_pids/1
        ]).

%% Process registry callbacks
-export([ register_name/2
        , unregister_name/1
        , whereis_name/1
        , send/2
        ]).

-behaviour(supervisor).
-export([ init/1
        ]).

-include_lib("eunit/include/eunit.hrl").

%% The name of a virtual node in the network. Node names shall not
%% contain dashes, slashes or at-signs.
-type vnode() :: atom().

%% The fully qualified name of processes resolvable via the process
%% registry implemented in this module.
-type vname() :: {vnode(), lname()}.

%% The vnode-local name of processes resolvable via the process
%% registry implemented in this module.
-type lname() :: atom().

-export_type([ vnode/0
             , vname/0
             , lname/0
             ]).

%% The ETS table for the pid type cache table
-define(cache_tab, pid_type_cache).

%% ---------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------

%% @doc Start a virtual network.
-spec start_link([vnode(), ...]) -> {ok, pid()}.
start_link(Vnet) ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, Vnet).

%% @doc Stop the virtual network.
-spec stop() -> ok.
stop() ->
  case whereis(?MODULE) of
    undefined -> ok;
    Pid ->
      unlink(Pid),
      [supervisor:terminate_child(Pid, Id)
       || {Id, Child, _, _} <- supervisor:which_children(Pid),
          is_pid(Child)
      ],
      exit(Pid, shutdown),
      timer:sleep(50),
      exit(Pid, kill),
      ok
  end.

%% @doc Do an rpc call to a virtual node. This can be used from
%% processes on other vnodes or processes that are not part of the
%% virtual network alike.
-spec rpc(vnode(), module(), atom(), list()) -> term();
         ([vnode()], module(), atom(), list()) -> {[term()], [vnode()]}.
rpc(VNodes, Module, Function, Args) when is_list(VNodes) ->
  vnet_node:rpc(VNodes, Module, Function, Args);
rpc(VNode, Module, Function, Args) ->
  case rpc([VNode], Module, Function, Args) of
    {[Result], []} -> Result;
    {[], [VNode]}  -> {badrpc, nodedown}
  end.

%% @doc Start the virtual node.
-spec start(vnode()) -> ok | {error, already_started}.
start(VNode) ->
  vnet_node:start(VNode).

%% @doc Stop the virtual node.
-spec stop(vnode()) -> ok | {error, already_stopped}.
stop(VNode) ->
  vnet_node:stop(VNode).

%% @doc Restore the connection between two virtual nodes.
-spec connect(vnode(), vnode()) -> ok | {error, already_connected}.
connect(VNode1, VNode2) ->
  vnet_conn:connect(VNode1, VNode2).

%% @doc Break the connection between two virtual nodes.
-spec disconnect(vnet:vnode(), vnet:vnode()) -> ok |
                                                {error, already_disconnected}.
disconnect(VNode1, VNode2) ->
  vnet_conn:disconnect(VNode1, VNode2).

%% @doc Get the registered name of the root process of a virtual node.
-spec node_proc(vnode()) -> atom().
node_proc(VNode) ->
  list_to_atom("node/" ++ atom_to_list(VNode)).

%% @doc Get the registered name of the connection process between two
%% virtual nodes.
-spec conn_proc(vnode(), vnode()) -> atom().
conn_proc(VNode, VNode) ->
  error(badarg);
conn_proc(VNode1, VNode2) when VNode1 < VNode2 ->
  list_to_atom("conn/" ++ atom_to_list(VNode1) ++ "-" ++ atom_to_list(VNode2));
conn_proc(VNode1, VNode2) ->
  conn_proc(VNode2, VNode1).

%% @doc Get a virtual node-local name for an ETS table.
-spec tab(vnode(), atom()) -> atom().
tab(VNode, Tab) ->
  list_to_atom(atom_to_list(Tab) ++ "@" ++ atom_to_list(VNode)).

%% @equiv vnode(self())
-spec vnode() -> vnode() | node().
vnode() ->
  vnode(self()).

%% @doc Get the virtual node the given process belongs to. This
%% function crashes with `badarg' if the process is not alive or
%% doesn't belong to a virtual node.
-spec vnode(pid()) -> vnode().
vnode(Pid) ->
  case type(Pid) of
    {virtual, VNode} -> VNode;
    {proxy, _, {VNode, _}} -> VNode;
    _Other -> error(badarg)
  end.

%% @doc Get the role of a process in the virtual network.
%%
%% `dead': the process is no longer alive, and its original role
%% cannot be determined.
%%
%% `native': a process that is not part of the virtual network.
%%
%% `virtual': a process that belongs to a virtual node.
%%
%% `proxy': a proxy process between virtual nodes.
-spec type(pid()) -> dead |
                     native |
                     {virtual, vnode()} |
                     {proxy, vnode(), {vnode(), pid()}}.
type(Pid) ->
  case ets:lookup(?cache_tab, Pid) of
    [{Pid, Type}] -> Type;
    [] ->
      Type = get_type(Pid),
      ets:insert(?cache_tab, {Pid, Type}),
      Type
  end.

%% @doc Return a dead process' pid.
-spec dead_pid() -> pid().
dead_pid() ->
  {Pid, Ref} = spawn_monitor(erlang, self, []),
  receive
    {'DOWN', Ref, process, Pid, _} -> Pid
  end.

%% @doc Return the pids of all connection processes that belong to a
%% given virtual node.
-spec conn_pids(vnode()) -> [pid()].
conn_pids(VNode) ->
  [Pid
   || {Id, Pid, worker, [vnet_conn]} <- supervisor:which_children(vnet),
      is_pid(Pid), is_list(Id), % sanity checks
      lists:member(VNode, Id)
  ].

%% ---------------------------------------------------------------------
%% Process registry callbacks
%% ---------------------------------------------------------------------

%% @doc Associates a name with a process in the virtual network. The
%% process must belong to a virtual node (or be a proxy for a process
%% belonging to one), and can be registered to that vnode only.
%%
%% This function accepts a local name too: the process identifies the
%% vnode, so it can be converted to a fully qualified name.
-spec register_name(vname() | lname(), pid()) -> yes | no.
register_name({VNode, _Name} = VName, Pid) ->
  RealPid = case type(Pid) of
              {virtual, VNode} -> Pid;
              {proxy, _, {VNode, RPid}} -> RPid;
              _Other -> error(badarg)
            end,
  try register(vname_to_name(VName), RealPid) of
    true -> yes
  catch
    error:badarg -> no
  end;
register_name(LName, Pid) ->
  register_name({vnode(Pid), LName}, Pid).

%% @doc Removes the registered name from the virtual network.
%%
%% Processes on a virtual node can use this function with a local name
%% to unregister the name from their local vnode.
-spec unregister_name(vname() | lname()) -> true.
unregister_name({_VNode, _Name} = VName) ->
  unregister(vname_to_name(VName));
unregister_name(LName) ->
  unregister_name({vnode(), LName}).

%% @doc Returns the pid with the registered name in the virtual
%% network, or `undefined' if the name is not registered.
%%
%% Processes on a virtual node can use this function with a local name
%% to look up the name on their local vnode.
-spec whereis_name(vname() | lname()) -> pid() | undefined.
whereis_name({VNode, _Name} = VName) ->
  case whereis(vname_to_name(VName)) of
    undefined -> undefined;
    Pid -> vnet_conn:maybe_proxy(VNode, Pid)
  end;
whereis_name(LName) ->
  whereis_name({vnode(), LName}).

%% @doc Sends a message to the process registered with the given name
%% in the virtual network. If the name is not registered, this
%% function exits with `{badarg, {Name, Msg}}'.
%%
%% Processes on a virtual node can use this function with a local name
%% to send message to the name on their local vnode.
-spec send(vname() | lname(), term()) -> pid().
send(Name, Msg) ->
  case whereis_name(Name) of
    undefined ->
      exit({badarg, {Name, Msg}});
    Pid ->
      Pid ! Msg,
      Pid
  end.

%% ---------------------------------------------------------------------
%% Supervisor callbacks
%% ---------------------------------------------------------------------

-spec init([vnode(), ...]) ->
              {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(VNet) ->
  %% Create the ETS table of the vnode cache
  ets:new(?cache_tab, [public, set, named_table]),
  %% Now the supervisor stuff: create node and connection processes
  %% for the entire network.
  SupFlags = #{ intensity => 0
              },
  NodeSpecs = [node_spec(VNode) || VNode <- VNet],
  ConnSpecs = [conn_spec(VNode1, VNode2) || {VNode1, VNode2} <- pairs(VNet)],
  {ok, {SupFlags, NodeSpecs ++ ConnSpecs}}.

%% ---------------------------------------------------------------------
%% Helper functions
%% ---------------------------------------------------------------------

-spec pairs([T]) -> [{T, T}].
pairs(L) -> pairs(L, []).

-spec pairs([T], [{T, T}]) -> [{T, T}].
pairs([E1 | T], Pairs) when T =/= [] ->
  NewPairs = lists:foldl( fun (E2, Acc) -> [{E1, E2} | Acc] end
                        , Pairs
                        , T),
  pairs(T, NewPairs);
pairs(_, Pairs) ->
  Pairs.

-spec node_spec(vnode()) -> supervisor:child_spec().
node_spec(VNode) ->
  #{ id       => VNode
   , start    => {vnet_node, start_link, [VNode]}
   , shutdown => infinity
   }.

-spec conn_spec(vnode(), vnode()) -> supervisor:child_spec().
conn_spec(VNode1, VNode2) ->
  Conn = lists:sort([VNode1, VNode2]),
  #{ id       => Conn
   , start    => {vnet_conn, start_link, Conn}
   , shutdown => infinity
   }.

-spec vname_to_name(vname()) -> atom().
vname_to_name({VNode, Name}) ->
  list_to_atom(atom_to_list(Name) ++ "@" ++ atom_to_list(VNode)).

-spec get_type(pid()) -> dead |
                         native |
                         {virtual, vnet:vnode()} |
                         {proxy, vnet:vnode(), {vnet:vnode(), pid()}}.
get_type(Pid) ->
  case process_info(Pid, [group_leader, dictionary]) of
    [{group_leader, Pid}, _Dict] ->
      %% The root process of a virtual node: not considered to be part
      %% of the virtual network.
      native;
    [{group_leader, GL}, {dictionary, Dict}] ->
      case lists:keyfind(proxy, 1, Dict) of
        {proxy, {VNodeC, VNodeS, RealPid}} ->
          {proxy, VNodeC, {VNodeS, RealPid}};
        false ->
          {dictionary, GlDict} = process_info(GL, dictionary),
          case lists:keyfind(vnode, 1, GlDict) of
            false -> native;
            {vnode, VNode} -> {virtual, VNode}
          end
      end;
    undefined ->
      dead
  end.

-ifdef(TEST).
%% ---------------------------------------------------------------------
%% Tests
%% ---------------------------------------------------------------------

%% The vnodes in the virtual network used by the tests.
-define(test_vnet, [alpha, bravo, charlie]).

%% A vnode name that is not part of the virtual network. This value
%% can also be used as a nonexistent node name.
-define(nonode, zulu).

%% The identifier of a process used by the {@link rcv/1} function.
-type rid() :: {pid(), reference(), vnode()}.

-spec vnet_test_() -> {setup, fun(), list()}.
vnet_test_() ->
  { setup
  , fun () ->
        {ok, Pid} = start_link(?test_vnet),
        Pid
    end
  , { spawn
    , [ %% rpc to vnodes from the controller
        fun single_rpc_t/0
      , fun multi_rpc_t/0
      , fun badrpc_t/0
      , rpc_errors_t_()

        %% message passing, linking, monitoring between vnodes
      , fun messaging_t/0
      , fun rpc_t/0
      , fun link_t/0
      , fun monitor_t/0

        %% disconnecting nodes from each other
      , fun disconnect_t/0

        %% stopping nodes
      , fun stop_t/0
      ]
    }
  }.

single_rpc_t() ->
  VNode = hd(?test_vnet),
  ?assertEqual(VNode, rpc(VNode, ?MODULE, vnode, [])).

multi_rpc_t() ->
  ?assertEqual({?test_vnet, []}, rpc(?test_vnet, ?MODULE, vnode, [])).

badrpc_t() ->
  ?assertEqual( rpc:call(?nonode, erlang, now, [])
              , rpc(?nonode, erlang, now, [])
              ),
  ?assertEqual( rpc:multicall([?nonode], erlang, now, [])
              , rpc([?nonode], erlang, now, [])
              ).

rpc_errors_t_() ->
  VNode = hd(?test_vnet),
  RNet = lists:duplicate(length(?test_vnet), node()),
  [{ lists:flatten(io_lib:format("rpc ~p test failing with ~p", [C, T]))
   , ?_assertEqual( rpc:C(R, erlang, raise, [T, test, []])
                  , rpc(V, erlang, raise, [T, test, []])
                  )
   }
   || T <- [throw, error, exit],
      {C, R, V} <- [ {call, node(), VNode}
                   , {multicall, RNet, ?test_vnet}
                   ]
  ].

messaging_t() ->
  [VNode1, VNode2 | _] = ?test_vnet,
  Name = messaging_t_proc,
  {P1, Id1} = start_mon_tesproc(VNode1, Name),
  {P2, Id2} = start_mon_tesproc(VNode2, Name),
  %% Verify names are registered properly
  ?assertEqual(P1, whereis_name({VNode1, Name})),
  ?assertEqual(P2, whereis_name({VNode2, Name})),
  %% Instruct P1 to send a message to P2 that contains pids
  P1 ! {ctrl, send, {VNode2, Name}},
  %% Receive the  responses from the processes
  {ok, {sent,     {P2P, Msg1}}} = rcv(Id1),
  {ok, {received, {P1P, Msg2}}} = rcv(Id2),
  %% Verify the type of all these processes
  ?assertEqual(native, type(self())),
  ?assertEqual({virtual, VNode1}, type(P1)),
  ?assertEqual({virtual, VNode2}, type(P2)),
  ?assertEqual({proxy, VNode2, {VNode1, P1}}, type(P1P)),
  ?assertEqual({proxy, VNode1, {VNode2, P2}}, type(P2P)),
  %% Verify the message got translated properly
  ?assertEqual(msg(P1, P2P), Msg1),
  ?assertEqual(msg(P1P, P2), Msg2),
  %% Let both processes terminate
  P1 ! P2 ! {ctrl, quit},
  {down, VNode1, normal} = rcv(Id1),
  {down, VNode2, normal} = rcv(Id2),
  ok.

rpc_t() ->
  [VNode1, VNode2 | _] = ?test_vnet,
  Name = rpc_t_proc,
  {P1, Id1} = start_mon_tesproc(VNode1, Name),
  {P2, Id2} = start_mon_tesproc(VNode2, Name),
  %% Verify rpc calls work
  P1 ! {ctrl, rpc, VNode2},
  {ok, {rpc, VNode2}} = rcv(Id1),
  P2 ! {ctrl, rpc, VNode1},
  {ok, {rpc, VNode1}} = rcv(Id2),
  P1 ! {ctrl, rpc, [VNode1, VNode2]},
  {ok, {rpc, {[VNode1, VNode2], []}}} = rcv(Id1),
  %% Let both processes terminate
  P1 ! P2 ! {ctrl, quit},
  {down, VNode1, normal} = rcv(Id1),
  {down, VNode2, normal} = rcv(Id2),
  ok.

link_t() ->
  [VNode1, VNode2, VNode3 | _] = ?test_vnet,
  Name = link_t_proc,
  {P1, Id1} = start_mon_tesproc(VNode1, Name),
  {P2, Id2} = start_mon_tesproc(VNode2, Name),
  {P3, Id3} = start_mon_tesproc(VNode3, Name),
  %% Instruct P1 to link to P2 and P3 to link to P1 (this way P1 has
  %% links both placed by itself and placed on it by others)
  P1 ! {ctrl, link, {VNode2, Name}},
  {ok, {linked, P2P}} = rcv(Id1),
  P3 ! {ctrl, link, {VNode1, Name}},
  {ok, {linked, P1P}} = rcv(Id3),
  %% Verify the type of all these processes
  ?assertEqual({virtual, VNode1}, type(P1)),
  ?assertEqual({virtual, VNode2}, type(P2)),
  ?assertEqual({virtual, VNode3}, type(P3)),
  ?assertEqual({proxy, VNode3, {VNode1, P1}}, type(P1P)),
  ?assertEqual({proxy, VNode1, {VNode2, P2}}, type(P2P)),
  %% Kill P1 and verify the other two processes terminate with the
  %% same exit reason
  Reason = link_t_test_reason,
  exit(P1, Reason),
  {down, VNode1, Reason} = rcv(Id1),
  {down, VNode2, Reason} = rcv(Id2),
  {down, VNode3, Reason} = rcv(Id3).

monitor_t() ->
  [VNode1, VNode2 | _] = ?test_vnet,
  Name = monitor_t_proc,
  {P1, Id1} = start_mon_tesproc(VNode1, Name),
  {P2, Id2} = start_mon_tesproc(VNode2, Name),
  %% Instruct P1 to monitor P2
  P1 ! {ctrl, monitor, {VNode2, Name}},
  {ok, {monitored, P2P, Mon}} = rcv(Id1),
  %% Verify the type of all these processes
  ?assertEqual({virtual, VNode1}, type(P1)),
  ?assertEqual({virtual, VNode2}, type(P2)),
  ?assertEqual({proxy, VNode1, {VNode2, P2}}, type(P2P)),
  %% Kill P2 and verify the DOWN message is received
  Reason = monitor_t_test_reason,
  exit(P2, Reason),
  {down, VNode2, Reason} = rcv(Id2),
  {ok, {received, {'DOWN', Mon, process, P2P, Reason}}} = rcv(Id1),
  %% Terminate P1
  P1 ! {ctrl, quit},
  {down, VNode1, normal} = rcv(Id1).

disconnect_t() ->
  [VNode1, VNode2 | _] = ?test_vnet,
  Name = disconnect_t_proc,
  {P1, Id1} = start_mon_tesproc(VNode1, Name),
  {P2, Id2} = start_mon_tesproc(VNode2, Name),
  %% Instruct P1 to monitor P2
  P1 ! {ctrl, monitor, {VNode2, Name}},
  {ok, {monitored, P2P, Mon}} = rcv(Id1),
  %% Verify the type of all these processes
  ?assertEqual({virtual, VNode1}, type(P1)),
  ?assertEqual({virtual, VNode2}, type(P2)),
  ?assertEqual({proxy, VNode1, {VNode2, P2}}, type(P2P)),
  %% Disconnect the nodes and verify the DOWN message is received
  ok = disconnect(VNode1, VNode2),
  {ok, {received, {'DOWN', Mon, process, P2P, noconnection}}} = rcv(Id1),
  ?assert(is_process_alive(P1)),
  ?assert(is_process_alive(P2)),
  %% Verify message passing doesn't work between nodes
  P1 ! {ctrl, send, {VNode2, Name}},
  {ok, {sent, _}} = rcv(Id1),
  P2 ! {ctrl, send, {VNode1, Name}},
  {ok, {sent, _}} = rcv(Id2),
  %% Verify rpc doesn't work between nodes (but works locally)
  P1 ! {ctrl, rpc, VNode2},
  {ok, {rpc, {badrpc, nodedown}}} = rcv(Id1),
  P2 ! {ctrl, rpc, [VNode1, VNode2]},
  {ok, {rpc, {[VNode2], [VNode1]}}} = rcv(Id2),
  %% Restore the connection and verify message passing is back to
  %% normal again
  ok = connect(VNode1, VNode2),
  P1 ! {ctrl, send, {VNode2, Name}},
  {ok, {sent,     _}} = rcv(Id1),
  {ok, {received, _}} = rcv(Id2),
  P2 ! {ctrl, send, {VNode1, Name}},
  {ok, {sent,     _}} = rcv(Id2),
  {ok, {received, _}} = rcv(Id1),
  %% Verify rpc is back to normal between nodes
  P1 ! {ctrl, rpc, VNode2},
  {ok, {rpc, VNode2}} = rcv(Id1),
  P2 ! {ctrl, rpc, VNode1},
  {ok, {rpc, VNode1}} = rcv(Id2),
  %% Terminate both processes
  P1 ! P2 ! {ctrl, quit},
  {down, VNode1, normal} = rcv(Id1),
  {down, VNode2, normal} = rcv(Id2).

stop_t() ->
  [VNode1, VNode2 | _] = ?test_vnet,
  Name = stop_t_proc,
  {P1, Id1} = start_mon_tesproc(VNode1, Name),
  {P2, Id2} = start_mon_tesproc(VNode2, Name),
  %% Instruct P1 to monitor P2
  P1 ! {ctrl, monitor, {VNode2, Name}},
  {ok, {monitored, P2P, Mon}} = rcv(Id1),
  %% Verify the type of all these processes
  ?assertEqual({virtual, VNode1}, type(P1)),
  ?assertEqual({virtual, VNode2}, type(P2)),
  ?assertEqual({proxy, VNode1, {VNode2, P2}}, type(P2P)),
  %% Stop the second node and verify the DOWN message is received
  ok = stop(VNode2),
  {ok, {received, {'DOWN', Mon, process, P2P, noconnection}}} = rcv(Id1),
  {down, VNode2, killed} = rcv(Id2),
  %% Verify rpc doesn't work between nodes (but works locally)
  P1 ! {ctrl, rpc, VNode2},
  {ok, {rpc, {badrpc, nodedown}}} = rcv(Id1),
  ?assertEqual({badrpc, nodedown}, rpc(VNode2, erlang, hd, [[ok]])),
  %% Restart the node and verify rpc is back to normal again
  ok = start(VNode2),
  P1 ! {ctrl, rpc, VNode2},
  {ok, {rpc, VNode2}} = rcv(Id1),
  ?assertEqual(ok, rpc(VNode2, erlang, hd, [[ok]])),
  %% Terminate both processes
  P1 ! {ctrl, quit},
  {down, VNode1, normal} = rcv(Id1).

%% @doc Some term that contains `P1' and `P2' wrapped into different
%% type of data structures. Used for testing message translations.
-spec msg(pid(), pid()) -> term().
msg(P1, P2) ->
  { test, P1, P2
  , [test, P1, P2]
  , #{ 1 => test
     , 2 => P1
     , 3 => P2
     , {4, P1} => test
     , {5, P2} => test
     }
  }.

%% @doc Receive the next event from a test process.
-spec rcv(rid()) -> {ok, term()} |
                    {down, vnode(), term()} |
                    {no_progress, vnode()}.
rcv({Pid, Mon, VNode}) ->
  receive
    {status, Pid, Msg}                  -> {ok, Msg};
    {'DOWN', Mon, process, Pid, Reason} -> {down, VNode, Reason}
  after 1000                            -> {no_progress, VNode}
  end.

%% @doc Start a test process. The test process can be instructed with
%% `ctrl' messages to send a message, perform an rpc call, link to or
%% monitor an other named process. It can be also ordered to quit. It
%% will forward any non-control message it receives to its parent.
-spec start_mon_tesproc(vnode(), lname()) -> {pid(), rid()}.
start_mon_tesproc(VNode, Name) ->
  Parent = self(),
  Fun = fun () ->
            yes = register_name(Name, self()),
            Mon = monitor(process, Parent),
            Parent ! {status, self(), ready},
            testproc_loop(Parent, Mon)
        end,
  Pid = rpc(VNode, erlang, spawn, [Fun]),
  Mon = monitor(process, Pid),
  Id = {Pid, Mon, VNode},
  {ok, ready} = rcv(Id),
  {Pid, Id}.

-spec testproc_loop(pid(), reference()) -> no_return().
testproc_loop(Parent, ParentMon) ->
  receive
    {ctrl, rpc, VNode} ->
      Result = rpc(VNode, ?MODULE, vnode, []),
      Parent ! {status, self(), {rpc, Result}};
    {ctrl, send, Name} ->
      P1 = self(),
      P2 = whereis_name(Name),
      Msg = msg(P1, P2),
      Parent ! {status, self(), {sent, {P2, Msg}}},
      P2 ! {self(), Msg};
    {ctrl, link, Name} ->
      P2 = whereis_name(Name),
      link(P2),
      Parent ! {status, self(), {linked, P2}};
    {ctrl, monitor, Name} ->
      P2 = whereis_name(Name),
      Mon = monitor(process, P2),
      Parent ! {status, self(), {monitored, P2, Mon}};
    {ctrl, quit} ->
      exit(normal);
    {'DOWN', ParentMon, process, Parent, Reason} ->
      exit(Reason);
    Msg ->
      Parent ! {status, self(), {received, Msg}}
  end,
  testproc_loop(Parent, ParentMon).

-endif.
