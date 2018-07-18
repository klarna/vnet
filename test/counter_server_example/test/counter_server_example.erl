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
   , once_valid_client/1
   , twice_valid_client/1
   , invalid_client/1
   , twice_valid_same_gen_client/1
   ]).

%%%-------------------------------------------------------------------

-include("../src/counter_server.hrl").

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
check_results({ok, Gen1, Res1}, {ok, Gen2, Res2}) ->
  ?assert(Res2 > Res1),
  ?assert(Gen2 >= Gen1);
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
  ClientRPC = [counter_server_example, once_valid_client, [proxy]],
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

once_valid_client(Mode) ->
  valid_rpc_request(Mode).

valid_rpc_request(Mode) ->
  server_request(increment, Mode).

server_request(Request, Mode) ->
  try
    Response =
      case Mode of
        rpc ->
          {ok, _, _} =
            vnet:rpc(server, counter_server, request, [{via, vnet, ?SERVER}, Request]);
        proxy ->
          counter_server:request({via, vnet, {server, ?SERVER}}, Request)
      end,
    check_response(Response),
    Response
  catch
    exit:B ->
      check_exit(B),
      error
  end.

check_response({ok, _, _}) -> ok;
check_response(Unexp) ->
  ?assertEqual(unexpected_response, Unexp).

check_exit({timeout, _}) -> ok;
check_exit({noproc, _}) -> ok;
check_exit({rpc_crash, _}) -> ok;
check_exit({{invalid, _}, _}) -> ok;
check_exit(UnexpReason) ->
  ?assertEqual(unexpected_exit, UnexpReason).

%%--------------------------------------------------------------------

%% @doc
%% Simulating a scenario with one node as client, making two requests
%% and checking results.

twice_valid_proxy_test() ->
  twice_valid_test(proxy).

twice_valid_rpc_test() ->
  twice_valid_test(rpc).

twice_valid_test(Mode) ->
  Nodes = [server, client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  vnet:rpc(server, counter_server_example, setup_server, []),
  ClinetRPC = [counter_server_example, twice_valid_client, [Mode]],
  spawned_vnet_rpc(client, ClinetRPC).

%%--------------------------------------------------------------------

twice_valid_client(Mode) ->
  Res1 = valid_rpc_request(Mode),
  case Res1 =:= error of
    true -> ok;
    false ->
      Res2 = valid_rpc_request(Mode),
      check_results(Res1, Res2)
  end.

%%--------------------------------------------------------------------

%% @doc
%% Simulating a scenario with two client nodes, one of which will
%% break the server.
invalid_proxy_test() ->
  invalid_test(proxy).

invalid_rpc_test() ->
  invalid_test(rpc).

invalid_test(Mode) ->
  Nodes = [server, client, bad_client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  vnet:rpc(server, counter_server_example, setup_server, []),
  GoodClientRPC = [counter_server_example, twice_valid_client, [Mode]],
  spawned_vnet_rpc(client, GoodClientRPC),
  BadClientRPC = [counter_server_example, invalid_client, [Mode]],
  spawned_vnet_rpc(bad_client, BadClientRPC).

%%--------------------------------------------------------------------

invalid_client(Mode) ->
  invalid_rpc_request(Mode).

invalid_rpc_request(Mode) ->
  ?assertEqual(error, server_request(invalid, Mode)).

%%--------------------------------------------------------------------

%% @doc
%% Simulating a scenario with one node as client, making a requests and
%% checking results.
invalid_same_gen_proxy_test() ->
  invalid_same_gen_test(proxy).

invalid_same_gen_rpc_test() ->
  invalid_same_gen_test(rpc).

invalid_same_gen_test(Mode) ->
  Nodes = [server, client, bad_client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  vnet:rpc(server, counter_server_example, setup_server, []),
  GoodRPC = [counter_server_example, twice_valid_same_gen_client, [Mode]],
  spawned_vnet_rpc(client, GoodRPC),
  BadRPC = [counter_server_example, invalid_client, [Mode]],
  spawned_vnet_rpc(bad_client, BadRPC).

%%--------------------------------------------------------------------

twice_valid_same_gen_client(Mode) ->
  Res1 = valid_rpc_request(Mode),
  case Res1 =:= error of
    true -> ok;
    false ->
      Res2 = valid_rpc_request(Mode),
      check_results(Res1, Res2),
      check_same_gen(Res1, Res2)
  end.

%%%===================================================================

%% @doc
%% Simulating a scenario with one node as client, making a request,
%% while the connection is broken.
disconnect_proxy_test() ->
  disconnect_test(proxy).

disconnect_rpc_test() ->
  disconnect_test(rpc).

disconnect_test(Mode) ->
  Nodes = [server, client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  %% Synchronous server setup
  vnet:rpc(server, counter_server_example, setup_server, []),
  %% Async client request
  ClientRPC = [counter_server_example, twice_valid_same_gen_client, [Mode]],
  spawned_vnet_rpc(client, ClientRPC),
  vnet:disconnect(server, client).

%%%===================================================================

%% @doc
%% Simulating a scenario with one node as client, making a request,
%% while the connection is broken.
node_down_proxy_test() ->
  node_down_test(proxy).

node_down_rpc_test() ->
  node_down_test(rpc).

node_down_test(Mode) ->
  Nodes = [server, client],
  {ok, S} = vnet:start_link(Nodes),
  unlink(S),
  %% Synchronous server setup
  vnet:rpc(server, counter_server_example, setup_server, []),
  %% Async client request
  ClientRPC = [counter_server_example, twice_valid_same_gen_client, [Mode]],
  spawned_vnet_rpc(client, ClientRPC),
  vnet:stop(server).
