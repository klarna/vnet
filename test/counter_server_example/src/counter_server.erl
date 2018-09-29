%%% @doc
%%%
%%% A counter server that assumes there is a permanent ETS table
%%% tracking it's 'reincarnation' generation and a simple counter.
%%% If an 'increment' request is made, it increments the counter.
%%% Crashes for any other request.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(counter_server).

%% API
-export([ start_link/2
        , request/2
        ]).

-behaviour(gen_server).
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

%%%-------------------------------------------------------------------

-record(state,
        { generation :: pos_integer()
        , table :: ets:tid()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Name, TableName) ->
  gen_server:start_link(Name, ?MODULE, TableName, []).

request(Name, Request) ->
  gen_server:call(Name, Request).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init(TableName) ->
  Generation = ets:update_counter(TableName, generation, 1),
  {ok, #state{generation = Generation, table = TableName}}.

%%--------------------------------------------------------------------

%% @private
handle_call(increment, _From, State) ->
  #state{ generation = Generation
        , table = TableName
        } = State,
  Counter = ets:update_counter(TableName, counter, 1),
  {reply, {ok, Generation, Counter}, State};
handle_call(_Request, _From, _State) ->
  error(invalid).

%%--------------------------------------------------------------------

%% @private
handle_cast(_Msg, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------

%% @private
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------

%% @private
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------

%% @private
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
