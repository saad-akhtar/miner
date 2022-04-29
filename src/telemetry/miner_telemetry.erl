-module(miner_telemetry).
-behaviour(gen_server).
-include("miner_jsonrpc.hrl").

-export([start_link/0, log/2]).

-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

%% defines how frequently we send telemetry when a node is in consensus (seconds)
-define(CONSENSUS_TELEMETRY_INTERVAL, 30 * 1000).

-record(state, {
    logs = [],
    traces = [],
    counts = #{},
    timer = make_ref(),
    sample_rate,
    pubkey,
    sigfun
}).

log(Metadata, Msg) ->
    gen_server:cast(?MODULE, {log, Metadata, Msg}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = blockchain_event:add_handler(self()),
    lager_app:start_handler(lager_event, miner_lager_telemetry_backend, [{level, none}]),
    Rate = application:get_env(miner, telemetry_sample_rate, 0.1),
    Modules = [
        miner_hbbft_handler,
        libp2p_group_relcast_server,
        miner_consensus_mgr,
        miner_dkg_handler,
        miner
    ],
    Traces = [
        lager:trace(miner_lager_telemetry_backend, [{module, Module}], debug)
     || Module <- Modules
    ],
    {ok, {PubKey, SigFun}} = miner:keys(),
    {ok, #state{traces = Traces, sample_rate = Rate, pubkey = PubKey, sigfun = SigFun}}.

%% Normally we will collect and emit telemetry every block, but when
% a node is in consensus, we will send telemetry more frequently
%%
%% (Currently every 30 seconds)
handle_info({blockchain_event, {add_block, _Hash, _Sync, Ledger}}, State) ->
    %% cancel any timers from the previous block
    erlang:cancel_timer(State#state.timer),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    Data0 = #{
        id => ?BIN_TO_B58(State#state.pubkey),
        name => ?BIN_TO_ANIMAL(State#state.pubkey),
        height => Height,
        logs => lists:reverse(State#state.logs),
        counts => State#state.counts
    },
    {Timer, NewData} =
        case miner_consensus_mgr:in_consensus() of
            true ->
                Status = miner:hbbft_status(),
                Queue = miner:relcast_queue(consensus_group),
                %% pull telemetry again in 30s
                T = erlang:send_after(?CONSENSUS_TELEMETRY_INTERVAL, self(), telemetry_timeout),
                {T, Data0#{
                    hbbft => #{
                        status => Status,
                        queue => format_hbbft_queue(Queue)
                    }
                }};
            false ->
                {make_ref(), Data0}
        end,
    send_telemetry(jsx:encode(NewData), State#state.sigfun),
    {noreply, State#state{logs = [], counts = #{}, timer = Timer}};
handle_info(telemetry_timeout, State) ->
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger()),
    Id = State#state.pubkey,
    Status = miner:hbbft_status(),
    Queue = miner:relcast_queue(consensus_group),
    send_telemetry(
        jsx:encode(#{
            id => ?BIN_TO_B58(Id),
            name => ?BIN_TO_ANIMAL(Id),
            height => Height,
            logs => lists:reverse(State#state.logs),
            counts => State#state.counts,
            hbbft => #{
                status => Status,
                queue => format_hbbft_queue(Queue)
            }
        }),
        State#state.sigfun
    ),
    %% pull telemetry again in 30s
    Timer = erlang:send_after(30000, self(), telemetry_timeout),
    {noreply, State#state{logs = [], counts = #{}, timer = Timer}};
handle_info(Msg, State) ->
    lager:info("unhandled info ~p", [Msg]),
    {noreply, State}.

handle_call(Msg, _From, State) ->
    lager:info("unhandled call ~p", [Msg]),
    {reply, ok, State}.

handle_cast({log, Metadata, Msg}, State = #state{sample_rate = R, counts = C, logs = Logs}) ->
    %% we will only collect a sample of the log messages, but we will count _all_ of the
    %% log messages.
    NewLogs =
        case rand:uniform() =< R of
            true -> [Msg | Logs];
            false -> Logs
        end,
    Severity = get_metadata(severity, Metadata),
    Module = get_metadata(module, Metadata),
    {Line, _Col} = get_metadata(line, Metadata, {0, 0}),

    %% We want to end up with a data structure that looks like
    %% #{ Module => #{ Severity => #{ LineNum => Count } } }
    %% This will make it easier to serialize to JSON and to
    %% handle it when we get it on the other side of the HTTP connection
    NewCounts = maps:update_with(
        Module,
        fun(M) ->
            maps:update_with(
                Severity,
                fun(V) ->
                    maps:update_with(
                        Line,
                        fun(Cnt) -> Cnt + 1 end,
                        #{Line => 1},
                        V
                    )
                end,
                #{Severity => #{Line => 1}},
                M
            )
        end,
        #{Module => #{Severity => #{Line => 1}}},
        C
    ),
    {noreply, State#state{counts = NewCounts, logs = NewLogs}};
handle_cast(Msg, State) ->
    lager:info("unhandled cast ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, State) ->
    [lager:remove_trace(Trace) || Trace <- State#state.traces],
    ok.

send_telemetry(Json, SigFun) ->
    Compressed = zlib:gzip(Json),
    case application:get_env(miner, telemetry_url) of
        {ok, URL} ->
            Signature = SigFun(Compressed),
            catch httpc:request(
                post,
                {URL,
                    [
                        {"X-Telemetry-Signature", ?BIN_TO_B58(Signature)},
                        {"Content-Encoding", "gzip"}
                    ],
                    "application/json", Compressed},
                [{timeout, 30000}],
                []
            );
        _ ->
            ok
    end.

get_metadata(Key, M) ->
    get_metadata(Key, M, undefined).

get_metadata(Key, M, Default) ->
    case lists:keyfind(Key, 1, M) of
        {Key, Value} -> Value;
        false -> Default
    end.

%% copy-pasta'd from miner_jsonrpc_hbbft
format_hbbft_queue(Queue) ->
    #{
        inbound := Inbound,
        outbound := Outbound
    } = Queue,
    Workers = miner:relcast_info(consensus_group),
    Outbound1 = maps:map(
        fun(K, V) ->
            #{
                address := Raw,
                connected := Connected,
                ready := Ready,
                in_flight := InFlight,
                connects := Connects,
                last_take := LastTake,
                last_ack := LastAck
            } = maps:get(K, Workers),
            #{
                address => ?BIN_TO_B58(Raw),
                name => ?BIN_TO_ANIMAL(Raw),
                count => length(V),
                connected => Connected,
                blocked => not Ready,
                in_flight => InFlight,
                connects => Connects,
                last_take => LastTake,
                last_ack => erlang:system_time(seconds) - LastAck
            }
        end,
        Outbound
    ),
    #{
        inbound => length(Inbound),
        outbound => Outbound1
    }.
