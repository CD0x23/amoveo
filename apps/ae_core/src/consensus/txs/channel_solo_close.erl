-module(channel_solo_close).
-export([go/3, make/5, from/1, id/1]).
-record(csc, {from, nonce, fee = 0, 
	      scriptpubkey, scriptsig}).

from(X) -> X#csc.from.
id(X) -> 
    SPK = X#csc.scriptpubkey,
    spk:cid(testnet_sign:data(SPK)).
make(From, Fee, ScriptPubkey, ScriptSig, Trees) ->
    Accounts = trees:accounts(Trees),
    Channels = trees:channels(Trees),
    true = is_list(ScriptSig),
    CID = spk:cid(testnet_sign:data(ScriptPubkey)),
    {_, Acc, Proof1} = accounts:get(From, Accounts),
    {_, _Channel, Proofc} = channels:get(CID, Channels),
    
    Tx = #csc{from = From, nonce = accounts:nonce(Acc)+1, 
	      fee = Fee,
	      scriptpubkey = ScriptPubkey, 
	      scriptsig = ScriptSig},
    {Tx, [Proof1, Proofc]}.

go(Tx, Dict, NewHeight) ->
    From = Tx#csc.from, 
    SPK = Tx#csc.scriptpubkey,
    ScriptPubkey = testnet_sign:data(SPK),
    TimeGas = governance:dict_get_value(time_gas, Dict),
    SpaceGas = governance:dict_get_value(space_gas, Dict),
    true = spk:time_gas(ScriptPubkey) < TimeGas,
    true = spk:space_gas(ScriptPubkey) < SpaceGas,
    CID = spk:cid(testnet_sign:data(SPK)),
    OldChannel = channels:dict_get(CID, Dict),
    0 = channels:amount(OldChannel),
    true = testnet_sign:verify(SPK),
    Acc1 = channels:acc1(OldChannel),
    Acc2 = channels:acc2(OldChannel),
    Acc1 = spk:acc1(ScriptPubkey),
    Acc2 = spk:acc2(ScriptPubkey),
    true = channels:entropy(OldChannel) == spk:entropy(ScriptPubkey),
    %NewCNonce = spk:nonce(ScriptPubkey),
    SS = Tx#csc.scriptsig,
    {Amount, NewCNonce, Delay} = spk:dict_run(fast, SS, ScriptPubkey, NewHeight, 0, Dict),
    %false = Amount == 0,
    true = NewCNonce > channels:nonce(OldChannel),
    %SharesRoot = shares:root_hash(shares:write_many(Shares, 0)),
    NewChannel = channels:dict_update(From, CID, Dict, NewCNonce, 0, 0, Amount, Delay, NewHeight, false),

    true = (-1 < (channels:bal1(NewChannel)-Amount)),
    true = (-1 < (channels:bal2(NewChannel)+Amount)),
    Dict2 = channels:dict_write(NewChannel, Dict),
    Facc = accounts:dict_update(From, Dict, -Tx#csc.fee, Tx#csc.nonce, NewHeight),
    Dict3 = accounts:dict_write(Facc, Dict2),
    spawn(fun() -> dict_check_slash(From, Dict3, NewHeight, NewCNonce) end), 
   %If our channel is closing somewhere we don't like, then we should try to use a channel_slash transaction to save our money.
    Dict3.
dict_check_slash(From, Dict, NewHeight, TheirNonce) ->
    case channel_manager:read(From) of
	error -> 
	    ok;
	{ok, CD} ->
	    SPK = channel_feeder:them(CD),
	    SS = channel_feeder:script_sig_them(CD), 
	    {_, CDNonce, _} = 
		spk:dict_run(fast, 
			SS,
			testnet_sign:data(SPK),
			NewHeight, 1, Dict),
	    if
		CDNonce > TheirNonce ->
                    wait_block(NewHeight, SPK, SS);
		true -> ok
	    end
    end.
wait_block(X, SPK, SS) ->
    Y = api:height(),
    case Y of
        X -> slash_it(SPK, SS);
        _ -> 
            timer:sleep(500),
            wait_block(X, SPK, SS)
    end.
slash_it(SPK, SS) ->
    {Trees, _, _} = tx_pool:data(),
    Governance = trees:governance(Trees),
    GovCost = governance:get_value(cs, Governance),
    {Tx, _} = channel_slash_tx:make(keys:pubkey(), free_constants:tx_fee() + GovCost, keys:sign(SPK), SS, Trees),
    Stx = keys:sign(Tx),
    tx_pool_feeder:absorb(Stx).
