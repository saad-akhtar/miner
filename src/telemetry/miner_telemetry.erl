
-module(miner_telemetry).

-behaviour(gen_server).

-export([start_link/0, log/1]).

-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {logs = [], traces= [], timer = make_ref()}).


log(Msg) ->
    gen_server:cast(?MODULE, {log, Msg}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
     ok = blockchain_event:add_handler(self()),
    lager_app:start_handler(lager_event, miner_lager_telemetry_backend, [{level, none}]),
    Modules = [miner_hbbft_handler, libp2p_group_relcast_server, miner_consensus_mgr, miner_dkg_handler, miner],
    Traces = [lager:trace(miner_lager_telemetry_backend, [{module, Module}], debug) || Module <- Modules ],
    {ok, #state{traces=Traces}}.

handle_info({blockchain_event, {add_block, _Hash, _Sync, Ledger}}, State) ->
    %% cancel any timers from the previous block
    erlang:cancel_timer(State#state.timer),
    Timer = case miner_consensus_mgr:in_consensus() of
        true ->
            {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
            Status = miner:hbbft_status(),
            Queue = miner:relcast_queue(consensus_group),
            StatusBin = list_to_binary(io_lib:format("~p", [Status])),
            QueueBin = list_to_binary(io_lib:format("~p", [Queue])),
            send_telemetry(jsx:encode(#{height => Height, logs => lists:reverse(State#state.logs), status => StatusBin, queue => QueueBin})),
            %% pull telemetry again in 30s
            erlang:send_after(30000, self(), telemetry_timeout);
        false ->
            make_ref()
    end,
    {noreply, State#state{logs=[], timer=Timer}};
handle_info(telemetry_timeout, State) ->
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger()),
    Status = miner:hbbft_status(),
    Queue = miner:relcast_queue(consensus_group),
    StatusBin = list_to_binary(io_lib:format("~p", [Status])),
    QueueBin = list_to_binary(io_lib:format("~p", [Queue])),
    send_telemetry(jsx:encode(#{height => Height, logs => lists:reverse(State#state.logs), status => StatusBin, queue => QueueBin})),
    %% pull telemetry again in 30s
    Timer = erlang:send_after(30000, self(), telemetry_timeout),
    {noreply, State#state{logs=[], timer=Timer}};
handle_info(Msg, State) ->
    lager:info("unhandled info ~p", [Msg]),
    {noreply, State}.

handle_call(Msg, _From, State) ->
    lager:info("unhandled call ~p", [Msg]),
    {reply, ok, State}.

handle_cast({log, Log}, State=#state{logs=Logs}) ->
    {noreply, State#state{logs=[Log|Logs]}};
handle_cast(Msg, State) ->
    lager:info("unhandled cast ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, State) ->
    [ lager:remove_trace(Trace) || Trace <- State#state.traces ],
    ok.

send_telemetry(Json) ->
    case application:get_env(miner, telemetry_url) of
        {ok, URL} ->
            catch httpc:request(post, {URL, [], "application/json", Json}, [{timeout, 30000}], []);
        _ ->
            ok
    end.

