%%% @doc
%%%
%%% Supervisor for the counter server. Responsible for maintaining the
%%% permanent ETS table that the counter server uses to store state.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(counter_server_supervisor).

%% API
-export([ start_link/0
        , start_link_no_vnet/0
        ]).

-behaviour(supervisor).
-export([init/1]).

%%%-------------------------------------------------------------------

-include("counter_server.hrl").

-define(SUPERVISOR, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
  start_link(vnet).

start_link_no_vnet() ->
  start_link(no_vnet).

%%%-------------------------------------------------------------------

start_link(Arg) ->
  SupervisorName =
    case Arg of
      no_vnet -> {local, ?SUPERVISOR};
      vnet -> {via, vnet, ?SUPERVISOR}
    end,
  supervisor:start_link(SupervisorName, ?MODULE, [Arg]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([Arg]) ->

  TableName =
    case Arg of
      no_vnet -> ?TABLE;
      vnet -> vnet:tab(vnet:vnode(), ?TABLE)
    end,
  TableName = ets:new(TableName, [named_table, public]),
  true = ets:insert(TableName, [{generation, 0}, {counter, 0}]),

  SupFlags =
    #{ strategy => one_for_one
     , intensity => 1
     , period => 5
     },

  ServerName =
    case Arg of
      no_vnet -> {local, ?SERVER};
      vnet -> {via, vnet, ?SERVER}
    end,

  AChild =
    # { id => ?SERVER
      , start => {?SERVER, start_link, [ServerName, TableName]}
      , restart => permanent
      , shutdown => 5000
      , modules => [?SERVER]
      },

  {ok, {SupFlags, [AChild]}}.
