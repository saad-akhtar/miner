-module(miner_jsonrpc_ledger).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

-define(MAYBE(X), jsonrpc_maybe(X)).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(Method, []) ->
    handle_rpc_(Method, []);
handle_rpc(Method, {Params}) ->
    handle_rpc(Method, kvc:to_proplist({Params}));
handle_rpc(Method, Params) when is_list(Params) ->
    handle_rpc(Method, maps:from_list(Params));
handle_rpc(Method, Params) when is_map(Params) andalso map_size(Params) == 0 ->
    handle_rpc_(Method, []);
handle_rpc(Method, Params) when is_map(Params) ->
    handle_rpc_(Method, Params).

handle_rpc_(<<"ledger_balance">>, []) ->
    %% get all
    Entries = maps:filter(
        fun(K, _V) ->
            is_binary(K)
        end,
        blockchain_ledger_v1:entries(get_ledger())
    ),
    [format_ledger_balance(A, E) || {A, E} <- maps:to_list(Entries)];
handle_rpc_(<<"ledger_balance">>, #{<<"address">> := Address}) ->
    %% get for address
    try
        BinAddr = ?B58_TO_BIN(Address),
        case blockchain_ledger_v1:find_entry(BinAddr, get_ledger()) of
            {error, not_found} -> #{Address => <<"not_found">>};
            {ok, Entry} -> format_ledger_balance(BinAddr, Entry)
        end
    catch
        _:_ -> ?jsonrpc_error({invalid_params, Address})
    end;
handle_rpc_(<<"ledger_balance">>, #{<<"htlc">> := true}) ->
    %% get htlc
    H = maps:filter(
        fun(K, _V) -> is_binary(K) end,
        blockchain_ledger_v1:htlcs(get_ledger())
    ),
    maps:fold(
        fun(Addr, Htlc, Acc) ->
            [
                #{
                    address => ?BIN_TO_B58(Addr),
                    payer => ?BIN_TO_B58(blockchain_ledger_htlc_v1:payer(Htlc)),
                    payee => ?BIN_TO_B58(blockchain_ledger_htlc_v1:payee(Htlc)),
                    hashlock => blockchain_utils:bin_to_hex(
                        blockchain_ledger_htlc_v1:hashlock(Htlc)
                    ),
                    timelock => blockchain_ledger_htlc_v1:timelock(Htlc),
                    amount => blockchain_ledger_htlc_v1:amount(Htlc)
                }
                | Acc
            ]
        end,
        [],
        H
    );
handle_rpc_(<<"ledger_balance">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc_(<<"ledger_gateways">>, []) ->
    handle_rpc_(<<"ledger_gateways">>, #{<<"verbose">> => false});
handle_rpc_(<<"ledger_gateways">>, #{<<"verbose">> := Verbose}) ->
    L = get_ledger(),
    {ok, Height} = blockchain_ledger_v1:current_height(L),
    blockchain_ledger_v1:cf_fold(
        active_gateways,
        fun({Addr, BinGw}, Acc) ->
            GW = blockchain_ledger_gateway_v2:deserialize(BinGw),
            [format_ledger_gateway_entry(Addr, GW, Height, Verbose) | Acc]
        end,
        [],
        L
    );
handle_rpc_(<<"ledger_gateways">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc_(<<"ledger_validators">>, []) ->
    handle_rpc_(<<"ledger_validators">>, #{<<"verbose">> => false});
handle_rpc_(<<"ledger_validators">>, #{<<"verbose">> := Verbose}) ->
    Ledger = get_ledger(),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    blockchain_ledger_v1:cf_fold(
        validators,
        fun({Addr, BinVal}, Acc) ->
            Val = blockchain_ledger_validator_v1:deserialize(BinVal),
            [format_ledger_validator(Addr, Val, Ledger, Height, Verbose) | Acc]
        end,
        [],
        Ledger
    );
handle_rpc_(<<"ledger_validators">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc_(<<"ledger_variables">>, []) ->
    Vars = blockchain_ledger_v1:snapshot_vars(get_ledger()),
    lists:foldl(fun({K, V}, Acc) ->
                      BinK = to_key(K),
                      BinV = to_value(V),
                      Acc#{ BinK => BinV }
              end, #{}, Vars);
handle_rpc_(<<"ledger_variables">>, #{ <<"name">> := Name }) ->
    try
        NameAtom = binary_to_existing_atom(Name, utf8),
        case blockchain_ledger_v1:config(NameAtom, get_ledger()) of
            {ok, Var} ->
                #{ Name => to_value(Var) };
            {error, not_found} ->
                #{ error => not_found}
        end
    catch
        error:badarg ->
            ?jsonrpc_error({invalid_params, Name})
    end;
handle_rpc_(<<"ledger_variables">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});

handle_rpc_(_, _) ->
    ?jsonrpc_error(method_not_found).

get_ledger() ->
    case blockchain_worker:blockchain() of
        undefined ->
            blockchain_ledger_v1:new("data");
        Chain ->
            blockchain:ledger(Chain)
    end.

format_ledger_balance(Addr, Entry) ->
    #{
        address => ?BIN_TO_B58(Addr),
        nonce => blockchain_ledger_entry_v1:nonce(Entry),
        balance => blockchain_ledger_entry_v1:balance(Entry)
    }.

format_ledger_gateway_entry(Addr, GW, Height, Verbose) ->
    GWAddr = ?BIN_TO_B58(Addr),
    O = #{
        name => iolist_to_binary(blockchain_utils:addr2name(GWAddr)),
        address => GWAddr,
        owner_address => ?BIN_TO_B58(blockchain_ledger_gateway_v2:owner_address(GW)),
        location => ?MAYBE(blockchain_ledger_gateway_v2:location(GW)),
        last_challenge => last_challenge(
            Height,
            blockchain_ledger_gateway_v2:last_poc_challenge(GW)
        ),
        nonce => blockchain_ledger_gateway_v2:nonce(GW)
    },
    case Verbose of
        false ->
            O;
        true ->
            O#{
                elevation => ?MAYBE(blockchain_ledger_gateway_v2:elevation(GW)),
                gain => ?MAYBE(blockchain_ledger_gateway_v2:gain(GW)),
                mode => ?MAYBE(blockchain_ledger_gateway_v2:mode(GW))
            }
    end.

last_challenge(_Height, undefined) -> <<"undefined">>;
last_challenge(Height, LC) -> Height - LC.
jsonrpc_maybe(undefined) -> <<"undefined">>;
jsonrpc_maybe(X) -> X.

format_ledger_validator(Addr, Val, Ledger, Height, Verbose) ->
    maps:from_list([
        {name, blockchain_utils:addr2name(Addr)}
        | blockchain_ledger_validator_v1:print(Val, Height, Verbose, Ledger)
    ]).

to_key(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_key(X) when is_list(X) -> iolist_to_binary(X);
to_key(X) when is_binary(X) -> X.

to_value(X) when is_float(X) -> float_to_binary(blockchain_utils:normalize_float(X), 2);
to_value(X) when is_integer(X) -> X;
to_value(X) when is_list(X) -> iolist_to_binary(X);
to_value(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_value(X) when is_binary(X) -> X;
to_value(X) when is_map(X) -> X;
to_value(X) -> iolist_to_binary(io_lib:format("~p", [X])).
