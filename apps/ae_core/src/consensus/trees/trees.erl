-module(trees).
-export([accounts/1,channels/1,existence/1,
	 oracles/1,new/6,update_accounts/2,
	 update_channels/2,update_existence/2,
	 update_oracles/2,
	 update_governance/2, governance/1,
	 root_hash/1, name/1, %garbage/0, 
         prune/0,
	 hash2int/1, verify_proof/5,
         root_hash2/2, serialized_roots/1,
         restore/3]).
-record(trees, {accounts, channels, existence,
		oracles, governance}).
name(<<"accounts">>) -> accounts;
name("accounts") -> accounts;
name(<<"channels">>) -> channels;
name("channels") -> channels;
name(<<"existence">>) -> existence;
name("existence") -> existence;
name(<<"oracles">>) -> oracles;
name("oracles") -> oracles;
name(<<"governance">>) -> governance;
name("governance") -> governance.
accounts(X) -> X#trees.accounts.
channels(X) -> X#trees.channels.
existence(X) -> X#trees.existence.
oracles(X) -> X#trees.oracles.
governance(X) -> X#trees.governance.
new(A, C, E, B, O, G) ->
    #trees{accounts = A, channels = C,
	   existence = E, 
	   oracles = O, governance = G}.
update_governance(X, A) ->
    X#trees{governance = A}.
update_accounts(X, A) ->
    X#trees{accounts = A}.
update_channels(X, A) ->
    X#trees{channels = A}.
update_existence(X, E) ->
    X#trees{existence = E}.
update_oracles(X, A) ->
    X#trees{oracles = A}.
root_hash2(Trees, Roots) ->
    A = rh2(accounts, Trees, Roots),
    C = rh2(channels, Trees, Roots),
    E = rh2(existence, Trees, Roots),
    O = rh2(oracles, Trees, Roots),
    G = rh2(governance, Trees, Roots),
    HS = constants:hash_size(),
    HS = size(A),
    HS = size(C),
    HS = size(E),
    HS = size(O),
    HS = size(G),
    hash:doit(<<
               A/binary,
               C/binary,
               E/binary,
               O/binary,
               G/binary
               >>).
rh2(Type, Trees, Roots) ->
    X = trees:Type(Trees),
    Out = case X of
        empty -> 
            Fun = list_to_atom(atom_to_list(Type) ++ "_root"),
            block:Fun(Roots);
        Y -> 
            Type:root_hash(Y)
    end,
    Out.
serialized_roots(Trees) -> 
    A = accounts:root_hash(trees:accounts(Trees)),
    C = channels:root_hash(trees:channels(Trees)),
    E = existence:root_hash(trees:existence(Trees)),
    O = oracles:root_hash(trees:oracles(Trees)),
    G = governance:root_hash(trees:governance(Trees)),
    <<
     A/binary,
     C/binary,
     E/binary,
     O/binary,
     G/binary
     >>.
root_hash(Trees) ->
    hash:doit(serialized_roots(Trees)).
keepers_block(_, _, 0) -> [1];%gather the pointer to every trie that we don't want to prune.
keepers_block(TreeID, BP, Many) ->
    Trees = block:trees(BP),
    Height = block:height(BP),
    Root = trees:TreeID(Trees),
    T = case Height of
	0 -> [1];
	_ ->
	    keepers_block(TreeID, block:get_by_hash(block:prev_hash(BP)), Many-1)
    end,
    [Root|T].
  
headers2blocks([]) -> [];
headers2blocks([Header|T]) ->
    [block:get_by_hash(block:hash(Header))|headers2blocks(T)].
prune() -> 
    Blocks = headers2blocks(headers:recent_tops()),
    Trees = [accounts, channels, oracles, existence, governance],
    prune2(Blocks, Trees),
    ALeaves = get_all_leaves0(Blocks, accounts, fun(X) -> trees:accounts(block:trees(X)) end),
    OLeaves = get_all_leaves0(Blocks, oracles, fun(X) -> trees:oracles(block:trees(X)) end),
    OBK = oracle_bets_keepers(ALeaves),
    trie:garbage(OBK, oracle_bets),
    OK = orders_keepers(OLeaves),
    trie:garbage(OK, orders),
    ok.
get_all_leaves0(B, K, F) ->
    remove_repeats(get_all_leaves(B, K, F)).
remove_repeats([]) -> [];
remove_repeats([H|T]) ->
    T2 = remove_element(H, T),
    [H|remove_repeats(T)].
remove_element(_, []) -> [];
remove_element(E, [E|T]) ->
    remove_element(E, T);
remove_element(E, [A|T]) ->
    [A|remove_element(E, T)].
get_all_leaves([], _, _) -> [];
get_all_leaves([Block|T], Key, Fun) ->
    trie:get_all(Fun(Block), Key) ++
        get_all_leaves(T, Key, Fun).
prune_old(Block) ->
    Trees = [accounts, channels, oracles, existence, governance],
    gb2(Block, Trees),%deletes everything from Trees that isn't referenced in the most recent N blocks.
    %This is deleting too much, if there is a recent small fork, we want to remember both sides.
    ALeaves = trie:get_all(trees:accounts(block:trees(Block)), accounts),
    OLeaves = trie:get_all(trees:oracles(block:trees(Block)), oracles),
    OBK = oracle_bets_keepers(ALeaves),
    trie:garbage(OBK, oracle_bets),%this is deleting every oracle_bet that isn't pointed to by an account in this block.
    %This is deleting too much. we want to remember all the oracle_bets since revert_depth.
    OK = orders_keepers(OLeaves),
    trie:garbage(OK, orders),
    ok.
oracle_bets_keepers([]) -> [1];
oracle_bets_keepers([L|T]) ->
    M = leaf:meta(L),
    [M|oracle_bets_keepers(T)].
orders_keepers([]) -> [1];
orders_keepers([L|T]) ->
    [leaf:meta(L)|
     orders_keepers(T)].
prune2(_, []) -> ok;
prune2(Blocks, [TID|Trees]) ->
    Pointers = remove_repeats(prune3(Blocks, TID)),
    trie:garbage(Pointers, TID),
    prune2(Blocks, Trees).
prune3([], _) -> [1];
prune3([B|Blocks], TID) ->
    H = block:height(B),
    case H of
        0 -> [1];
        _ ->
            Trees = block:trees(B),
            Root = trees:TID(Trees),
            [Root|prune3(Blocks, TID)]
    end.
gb2(_, []) -> ok;
gb2(B, [H|T]) ->
    garbage_block(B, H),
    gb2(B, T).
garbage_block(Block, TreeID) -> 
    {ok, RD} = application:get_env(ae_core, revert_depth),
    Keepers = keepers_block(TreeID, Block, RD),
    trie:garbage(Keepers, TreeID).
hash2int(X) ->
    U = size(X),
    U = constants:hash_size(),
    S = U*8,
    <<A:S>> = X,
    A.
verify_proof(TreeID, RootHash, Key, Value, Proof) ->
    CFG = trie:cfg(TreeID),
    V = case Value of
            0 -> empty;
            X -> X
        end,
    verify:proof(RootHash, 
                 TreeID:make_leaf(Key, V, CFG),
                 Proof, CFG).
restore(Root, Fact, Meta) ->
    Key = proofs:key(Fact),
    Value = case proofs:value(Fact) of
                0 -> empty;
                X -> X
            end,
    Hash = proofs:root(Fact),
    Path = proofs:path(Fact),
    TreeID = proofs:tree(Fact),
    Hash = TreeID:root_hash(Root),
    Hash = proofs:root(Fact),
    KeyInt = TreeID:key_to_int(Key),
    Leaf = leaf:new(KeyInt, Value, Meta, trie:cfg(TreeID)),
    Out = trie:restore(Leaf, Hash, Path, Root, TreeID),
    {Hash, Leaf2, _} = trie:get(KeyInt, Out, TreeID),
    case Leaf2 of %sanity check
        empty -> 
            Value = empty;
        _ -> Leaf = Leaf2
    end,
    Out.
    
                
    
    %we also need to garbage orders, oracle_bets, shares, proof of burn.
    %proof of burn doesn't exist yet.
    %The other three are not stored in Trees, they are inside of oracles and accounts, so garbage/1 does not work for them.
