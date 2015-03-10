-module(multiple_dcs_test).

-export([confirm/0, multiple_writes/4]).

-include_lib("eunit/include/eunit.hrl").

-define(HARNESS, (rt_config:get(rt_harness))).

confirm() ->
    [Cluster1, Cluster2, Cluster3] = rt:build_clusters([1,1,1]),
    HeadCluster1 = hd(Cluster1),
    HeadCluster2 = hd(Cluster2),
    HeadCluster3 = hd(Cluster3),

    rt:wait_until_ring_converged(Cluster1),
    rt:wait_until_ring_converged(Cluster2),
    rt:wait_until_ring_converged(Cluster3),
    timer:sleep(500), %%TODO: wait for inter_dc_manager to be up
    {ok, DC1up,DC1read} = rpc:call(HeadCluster1, antidote_sup, start_recvrs,[local,9000,9001]),
    {ok, DC2up,DC2read} = rpc:call(HeadCluster2, antidote_sup, start_recvrs,[local,9002,9003]),
    {ok, DC3up,DC3read} = rpc:call(HeadCluster3, antidote_sup, start_recvrs,[local,9004,9005]),
    lager:info("Receivers start results ~p, ~p and ~p", [DC1up, DC2up, DC3up]),

    ok = rpc:call(HeadCluster1, inter_dc_manager, add_list_dcs,[[DC2up, DC3up]]),
    ok = rpc:call(HeadCluster2, inter_dc_manager, add_list_dcs,[[DC1up, DC3up]]),
    ok = rpc:call(HeadCluster3, inter_dc_manager, add_list_dcs,[[DC1up, DC2up]]),

    ok = rpc:call(HeadCluster1, inter_dc_manager, add_list_read_dcs,[[DC2read, DC3read]]),
    ok = rpc:call(HeadCluster2, inter_dc_manager, add_list_read_dcs,[[DC1read, DC3read]]),
    ok = rpc:call(HeadCluster3, inter_dc_manager, add_list_read_dcs,[[DC1read, DC2read]]),

    ok = rpc:call(HeadCluster1, antidote_sup, start_senders, []),
    ok = rpc:call(HeadCluster2, antidote_sup, start_senders, []),
    ok = rpc:call(HeadCluster3, antidote_sup, start_senders, []),

    simple_replication_test(Cluster1, Cluster2, Cluster3),
    parallel_writes_test(Cluster1, Cluster2, Cluster3),
    pass.

simple_replication_test(Cluster1, Cluster2, Cluster3) ->
    Node1 = hd(Cluster1),
    Node2 = hd(Cluster2),
    Node3 = hd(Cluster3),
    WriteResult1 = rpc:call(Node1,
                            antidote, append,
                            [key1, riak_dt_gcounter, {increment, ucl}]),
    ?assertMatch({ok, _}, WriteResult1),
    WriteResult2 = rpc:call(Node1,
                            antidote, append,
                            [key1, riak_dt_gcounter, {increment, ucl}]),
    ?assertMatch({ok, _}, WriteResult2),
    WriteResult3 = rpc:call(Node1,
                            antidote, append,
                            [key1, riak_dt_gcounter, {increment, ucl}]),
    ?assertMatch({ok, _}, WriteResult3),
    {ok,{_,_,CommitTime}}=WriteResult3,
    ReadResult = rpc:call(Node1, antidote, read,
                          [key1, riak_dt_gcounter]),
    ?assertEqual({ok, 3}, ReadResult),

    lager:info("Done append in Node1"),

    ReadResult2 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [CommitTime, key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet1],_} }= ReadResult2,
    ?assertEqual(3, ReadSet1),
    lager:info("Done Read in Node3"),
    ReadResult3 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [CommitTime, key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet2],_} }= ReadResult3,
    ?assertEqual(3, ReadSet2),

    lager:info("Done first round of read, I am gonna append"),
    WriteResult4= rpc:call(Node2,
                           antidote, clocksi_bulk_update,
                           [ CommitTime,
                             [{update, key1, riak_dt_gcounter, {increment, ucl}}]]),
    ?assertMatch({ok, _}, WriteResult4),
    {ok,{_,_,CommitTime2}}=WriteResult4,
    lager:info("Done append in Node2"),
    WriteResult5= rpc:call(Node3,
                           antidote, clocksi_bulk_update,
                           [CommitTime2,
                            [{update, key1, riak_dt_gcounter, {increment, ucl}}]]),
    ?assertMatch({ok, _}, WriteResult5),
    {ok,{_,_,CommitTime3}}=WriteResult5,
    lager:info("Done append in Node3"),
    lager:info("Done waiting, I am gonna read"),

    SnapshotTime =
        CommitTime3,
    ReadResult4 = rpc:call(Node1,
                           antidote, clocksi_read,
                           [SnapshotTime, key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet4],_} }= ReadResult4,
    ?assertEqual(5, ReadSet4),
    lager:info("Done read in Node1"),
    ReadResult5 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [SnapshotTime,key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet5],_} }= ReadResult5,
    ?assertEqual(5, ReadSet5),
    lager:info("Done read in Node2"),
    ReadResult6 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [SnapshotTime,key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet6],_} }= ReadResult6,
    ?assertEqual(5, ReadSet6),
    pass.

parallel_writes_test(Cluster1, Cluster2, Cluster3) ->
    Node1 = hd(Cluster1),
    Node2 = hd(Cluster2),
    Node3 = hd(Cluster3),
    Key = parkey,
    Pid = self(),
    %% WriteFun = fun(A,B,C,D) ->
    %%                    multiple_writes(A,B,C,D)
    %%            end,
    spawn(?MODULE, multiple_writes,[Node1,Key, node1, Pid]),
    spawn(?MODULE, multiple_writes,[Node2,Key, node2, Pid]),
    spawn(?MODULE, multiple_writes,[Node3,Key, node3, Pid]),
    Result = receive
        {ok, CT1} ->
            receive
                {ok, CT2} ->
                receive
                    {ok, CT3} ->
                        Time = dict:merge(fun(_K, T1,T2) ->
                                                  max(T1,T2)
                                          end,
                                          CT3, dict:merge(
                                                 fun(_K, T1,T2) ->
                                                         max(T1,T2)
                                                 end,
                                                 CT1, CT2)),
                        ReadResult1 = rpc:call(Node1,
                           antidote, clocksi_read,
                           [Time, Key, riak_dt_gcounter]),
                        {ok, {_,[ReadSet1],_} }= ReadResult1,
                        ?assertEqual(15, ReadSet1),
                        ReadResult2 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [Time, Key, riak_dt_gcounter]),
                        {ok, {_,[ReadSet2],_} }= ReadResult2,
                        ?assertEqual(15, ReadSet2),
                        ReadResult3 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [Time, Key, riak_dt_gcounter]),
                        {ok, {_,[ReadSet3],_} }= ReadResult3,
                        ?assertEqual(15, ReadSet3),
                        lager:info("Parallel reads passed"),
                        pass
                    end
            end
    end,
    ?assertEqual(Result, pass),
    pass.

multiple_writes(Node, Key, Actor, ReplyTo) ->
    WriteResult1 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, Actor}]),
    ?assertMatch({ok, _}, WriteResult1),
    WriteResult2 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, Actor}]),
    ?assertMatch({ok, _}, WriteResult2),
    WriteResult3 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, Actor}]),
    ?assertMatch({ok, _}, WriteResult3),
    WriteResult4 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, Actor}]),
    ?assertMatch({ok, _}, WriteResult4),
    WriteResult5 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, Actor}]),
    ?assertMatch({ok, _}, WriteResult5),
    {ok,{_,_,CommitTime}}=WriteResult5,
    ReplyTo ! {ok, CommitTime}.
