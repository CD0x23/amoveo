-module(grow_channel_tx).
-export([go/3, make/5, good/1, acc1/1, acc2/1, id/1]).
-record(gc, {acc1 = 0, acc2 = 0, fee = 0, nonce = 0, inc1 = 0, inc2 = 0, channel_nonce = 0, id = -1}).
acc1(X) -> X#gc.acc1.
acc2(X) -> X#gc.acc2.
id(X) -> X#gc.id.
good(Tx) ->
    %ChannelLife = how long they are requesting the channel to be open for.
    %charge a fee = ((time_value) * (ChannelLife + Delay) * (how much the server puts into the channel)) + (max(0, ChannelLife - (OldChannelLife - OldChannelAge)) * (how much server already had in the channel) * (time_value))
    I1 = Tx#gc.inc1,
    I2 = Tx#gc.inc2,
    Acc1 = Tx#gc.acc1,
    Acc2 = Tx#gc.acc2,
    {Me, Other} = 
        case keys:pubkey() of
            Acc1 -> {I1, Acc2};
            Acc2 -> {I2, Acc1}
        end,
    NewCNLimit = Tx#gc.channel_nonce,
    {ok, CD} = channel_manager:read(Other),
    SPK = channel_feeder:me(CD),
    CN = spk:nonce(SPK),
    true = CN > NewCNLimit,%This checks that our SPK is still valid.
    SSPK = channel_feeder:them(CD),
    CN2 = spk:nonce(testnet_sign:data(SSPK)),
    true = CN2 > NewCNLimit,%This checks that the SPK they signed is still valid.
    Frac = Me / (I1 + I2),
    {ok, MCR} = application:get_env(ae_core, min_channel_ratio),
    true = Frac > MCR,
    true.
    
make(ID,Trees,Inc1,Inc2,Fee) ->
    Accounts = trees:accounts(Trees),
    Channels = trees:channels(Trees),
    {_, C, CProof} = channels:get(ID, Channels),
    A1 = channels:acc1(C),
    A2 = channels:acc2(C),
    {_, Acc1, Proof1} = accounts:get(A1, Accounts),
    {_, _, Proof2} = accounts:get(A2, Accounts),
    Nonce = accounts:nonce(Acc1),
    CNonce = channels:nonce(C),
    Tx = #gc{id = ID, acc1 = A1, acc2 = A2, 
	     fee = Fee, nonce = Nonce+1, inc1 = Inc1,
	     inc2 = Inc2, channel_nonce = CNonce + 1},
    {Tx, [CProof, Proof1, Proof2]}.
    
go(Tx, Dict, NewHeight) ->
    ID = Tx#gc.id,
    OldChannel = channels:dict_get(ID, Dict),
    0 = channels:slasher(OldChannel),
    false = channels:closed(OldChannel),
    Aid1 = channels:acc1(OldChannel),
    Aid2 = channels:acc2(OldChannel),
    ID = channels:id(OldChannel),
    Aid1 = Tx#gc.acc1,
    Aid2 = Tx#gc.acc2,
    false = Aid1 == Aid2,
    Inc1 = Tx#gc.inc1,
    Inc2 = Tx#gc.inc2,
    true = Inc1 + Inc2 >= 0,
    CNonce = Tx#gc.channel_nonce,
    NewChannel = channels:dict_update(0, ID, Dict, CNonce, Inc1, Inc2, 0, channels:delay(OldChannel), NewHeight, false),
    Dict2 = channels:dict_write(NewChannel, Dict),
    Acc1 = accounts:dict_update(Aid1, Dict, -Inc1, Tx#gc.nonce, NewHeight),
    Acc2 = accounts:dict_update(Aid2, Dict, -Inc2, none, NewHeight),
    Dict3 = accounts:dict_write(Acc1, Dict2),
    accounts:dict_write(Acc2, Dict3).
    
