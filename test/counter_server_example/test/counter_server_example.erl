%%% @doc
%%%
%%% Example for using vnet to simulate a cluster of nodes, one of
%%% which serves as a counter server.
%%%
%%% All _test functions demonstrate scenarios of using the server. See
%%% their documentation for more info.
%%%
%%% All _no_vnet_test functions do not use vnet and their purpose is
%%% to check the core implementation of the counter server.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(counter_server_example).

%%%-------------------------------------------------------------------

-include_lib("eunit/include/eunit.hrl").

-concuerror_options(
   [ {instant_delivery, false}
   , assertions_only
   , {ignore_error, deadlock}
   ]).

%%%-------------------------------------------------------------------

-export(
   [ setup_server/0
   , once_valid_client/0
   , twice_valid_client/0
   , invalid_client/0
   , twice_valid_same_gen_client/0
   ]).

%%%-------------------------------------------------------------------

-include("counter_server.hrl").

%%%-------------------------------------------------------------------

%% @doc
%% Simulating a scenario with one client, making requests and checking
%% results, without using any vnet logic.
valid_no_vnet_test() ->
  {ok, P1} = counter_server_supervisor:start_link_no_vnet(),
  %% Unlinking to not send signals to supervisor from main process
  %% exiting.
  unlink(P1),
  valid_client_no_vnet().

%%%-------------------------------------------------------------------

%% @doc Client making a second request if the first was successful and
%% verifying that the second answer is greater than the first.
valid_client_no_vnet() ->
  Res1 = valid_local_request(),
  case Res1 =:= error of
    true -> ok;
    false ->
      Res2 = valid_local_request(),
      check_results(Res1, Res2)
  end.

valid_local_request() ->
  local_request(increment).

%%%-------------------------------------------------------------------

local_request(Request) ->
  try
    counter_server:request(?SERVER, Request)
  catch
    _:_ -> error
  end.

%%%-------------------------------------------------------------------

check_results(error, _Res2) -> ok;
check_results(_Res1, error) -> ok;
check_results({ok, _Gen1, Res1}, {ok, _Gen2, Res2}) ->
  ?assert(Res2 > Res1);
check_results(Res1, Res2) ->
  ?assertEqual(ok, {unexpected, Res1, Res2}).

%%%-------------------------------------------------------------------

%% @doc
%% Simulating a scenario with two clients, making requests and
%% checking results, without using any vnet logic.
%% The second client will break the server.
%% Nevertheless, the replies that the first client receives are
%% expected to satisfy the correctness properties.
invalid_no_vnet_test() ->
  {ok, P1} = counter_server_supervisor:start_link_no_vnet(),
  unlink(P1),
  spawn(fun valid_client_no_vnet/0),
  spawn(fun invalid_client_no_vnet/0).

%%--------------------------------------------------------------------

invalid_client_no_vnet() ->
  ?assertEqual(error, local_request(invalid)).

%%%-------------------------------------------------------------------

%% @doc
%% Same as before, but now the first client checks a property that is
%% not always satisfied: each reply will be from the same generation
%% of server. As the server might be broken and restarted, this
%% assertion will fail in some interleavings.
invalid_same_gen_no_vnet_test() ->
  {ok, P1} = counter_server_supervisor:start_link_no_vnet(),
  unlink(P1),
  spawn(fun valid_client_same_gen_no_vnet/0),
  spawn(fun invalid_client_no_vnet/0).

%%--------------------------------------------------------------------

valid_client_same_gen_no_vnet() ->
  Res1 = valid_local_request(),
  case Res1 =:= error of
    true -> ok;
    false ->
      Res2 = valid_local_request(),
      check_results(Res1, Res2),
      check_same_gen(Res1, Res2)
  end.

%%--------------------------------------------------------------------

check_same_gen(error, _) -> ok;
check_same_gen(_, error) -> ok;
check_same_gen({ok, G1, _R1}, {ok, G2, _R2}) ->
  ?assertEqual(G1, G2);
check_same_gen(Res1, Res2) ->
  ?assertEqual(ok, {unexpected, Res1, Res2}).

%%%===================================================================

%% @doc
%% Simulating a scenario with one node as client, making a request.
once_valid_test() ->
  Nodes = [server, client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  %% Synchronous server setup
  vnet:rpc(server, counter_server_example, setup_server, []),
  %% Async client request
  ClientRPC = [counter_server_example, once_valid_client, []],
  spawned_vnet_rpc(client, ClientRPC).

%%%-------------------------------------------------------------------

setup_server() ->
  {ok, P} = counter_server_supervisor:start_link(),
  unlink(P).

%%%-------------------------------------------------------------------

%% @doc Adding a spawn wrapper serves two purposes: it makes the
%% request asynchronous and ensures exceptions reach the 'top'
%% undisturbed and can be picked e.g. by --assertions_only (otherwise,
%% vnet:rpc might use a try/catch statement and modify them).
spawned_vnet_rpc(VNode, RPC) ->
  vnet:rpc(VNode, erlang, spawn, RPC).

%%%-------------------------------------------------------------------

once_valid_client() ->
  valid_rpc_request().

valid_rpc_request() ->
  server_request(increment).

server_request(Request) ->
  try
    %% %% The commented out variant leads to schedulings where
    %% %% vnet_proxy.erl, l52 crashes cause the process is not
    %% %% alive and the call returns `undefined'
     counter_server:request({via, vnet, {server, ?SERVER}}, Request)
     %% {ok, _, _} =
     %%   vnet:rpc(server, counter_server, request, [{via, vnet, ?SERVER}, Request])
  catch
    _:_ -> error
  end.

%%--------------------------------------------------------------------

%% @doc
%% Simulating a scenario with one node as client, making two requests
%% and checking results.
twice_valid_test() ->
  Nodes = [server, client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  vnet:rpc(server, counter_server_example, setup_server, []),
  ClinetRPC = [counter_server_example, twice_valid_client, []],
  spawned_vnet_rpc(client, ClinetRPC).

%%--------------------------------------------------------------------

twice_valid_client() ->
  Res1 = valid_rpc_request(),
  case Res1 =:= error of
    true -> ok;
    false ->
      Res2 = valid_rpc_request(),
      check_results(Res1, Res2)
  end.

%%--------------------------------------------------------------------

%% @doc
%% Simulating a scenario with two client nodes, one of which will
%% break the server.
invalid_test() ->
  Nodes = [server, client, bad_client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  vnet:rpc(server, counter_server_example, setup_server, []),
  GoodClientRPC = [counter_server_example, twice_valid_client, []],
  spawned_vnet_rpc(client, GoodClientRPC),
  BadClientRPC = [counter_server_example, invalid_client, []],
  spawned_vnet_rpc(bad_client, BadClientRPC).

%%--------------------------------------------------------------------

invalid_client() ->
  invalid_rpc_request().

invalid_rpc_request() ->
  ?assertEqual(error, server_request(invalid)).

%%--------------------------------------------------------------------

%% @doc
%% Simulating a scenario with one node as client, making a requests and
%% checking results.
invalid_same_gen_test() ->
  Nodes = [server, client, bad_client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  vnet:rpc(server, counter_server_example, setup_server, []),
  GoodRPC = [counter_server_example, twice_valid_same_gen_client, []],
  spawned_vnet_rpc(client, GoodRPC),
  BadRPC = [counter_server_example, invalid_client, []],
  spawned_vnet_rpc(bad_client, BadRPC).

%%--------------------------------------------------------------------

twice_valid_same_gen_client() ->
  Res1 = valid_rpc_request(),
  case Res1 =:= error of
    true -> ok;
    false ->
      Res2 = valid_rpc_request(),
      check_results(Res1, Res2),
      check_same_gen(Res1, Res2)
  end.
