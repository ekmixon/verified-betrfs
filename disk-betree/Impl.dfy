include "Main.dfy"
include "BetreeBlockCache.dfy"
include "ByteBetree.dfy"

module {:extern} Impl refines Main {
  import BC = BetreeGraphBlockCache
  import BT = PivotBetreeSpec`Internal
  import M = BetreeBlockCache
  import Marshalling
  import Messages = ValueMessage
  import Pivots = PivotsLib

  import opened Maps
  import opened Sequences

  type Variables = M.Variables
  type Constants = M.Constants

  class ImplHeapState {
    var s: Variables
    constructor()
    ensures M.Init(BC.Constants(), s);
    {
      s := BC.Unready;
    }
  }
  type HeapState = ImplHeapState
  function HeapSet(hs: HeapState) : set<object> { {hs} }

  function Ik(k: Constants) : M.Constants { k }
  function I(k: Constants, hs: HeapState) : M.Variables { hs.s }

  predicate ValidSector(sector: Sector)
  {
    && Marshalling.parseSector(sector).Some?
  }

  function ISector(sector: Sector) : M.Sector
  {
    Marshalling.parseSector(sector).value
  }

  function ILBA(lba: LBA) : M.LBA { lba }

  predicate Inv(k: Constants, hs: HeapState)
  {
    M.Inv(k, hs.s)
  }

  method InitState() returns (k: Constants, hs: HeapState)
  {
    k := BC.Constants();
    hs := new ImplHeapState();

    M.InitImpliesInv(k, hs.s);
  }

  predicate WFSector(sector: M.Sector)
  {
    match sector {
      case SectorSuperblock(superblock) => BC.WFPersistentSuperblock(superblock)
      case SectorBlock(node) => BT.WFNode(node)
    }
  }

  method ReadSector(io: DiskIOHandler, lba: M.LBA)
  returns (sector: M.Sector)
  requires io.initialized()
  modifies io
  ensures IDiskOp(io.diskOp()) == D.ReadOp(lba, sector)
  ensures WFSector(sector)
  {
    var bytes := io.read(lba);
    var sectorOpt := Marshalling.ParseSector(bytes);
    sector := sectorOpt.value;
  }

  method PageInSuperblock(k: Constants, s: Variables, io: DiskIOHandler)
  returns (s': Variables)
  requires io.initialized();
  requires s.Unready?
  modifies io
  ensures M.Next(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()))
  {
    var sector := ReadSector(io, BC.SuperblockLBA());
    if (sector.SectorSuperblock?) {
      s' := BC.Ready(sector.superblock, sector.superblock, map[]);
      assert M.NextStep(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()), M.BlockCacheMoveStep(BC.PageInSuperblockStep));
    } else {
      s' := s;
      assert M.NextStep(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()), M.BlockCacheMoveStep(BC.ReadNoOpStep));
    }
  }

  method PageIn(k: Constants, s: Variables, io: DiskIOHandler, ref: BC.Reference)
  returns (s': Variables)
  requires io.initialized();
  requires s.Ready?
  requires M.Inv(k, s)
  requires ref in s.ephemeralSuperblock.lbas
  requires ref !in s.cache
  modifies io
  ensures M.Next(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()))
  {
    var lba := s.ephemeralSuperblock.lbas[ref];
    var sector := ReadSector(io, lba);
    if (sector.SectorBlock?) {
      var node := sector.block;
      if (s.ephemeralSuperblock.graph[ref] == (if node.children.Some? then node.children.value else [])) {
        s' := s.(cache := s.cache[ref := sector.block]);
        assert BC.PageIn(k, s, s', IDiskOp(io.diskOp()), ref);
        assert M.NextStep(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()), M.BlockCacheMoveStep(BC.PageInStep(ref)));
      } else {
        s' := s;
        assert M.NextStep(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()), M.BlockCacheMoveStep(BC.ReadNoOpStep));
      }
    } else {
      s' := s;
      assert M.NextStep(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()), M.BlockCacheMoveStep(BC.ReadNoOpStep));
    }
  }

  method InsertKeyValue(k: Constants, s: Variables, key: MS.Key, value: MS.Value)
  returns (s': Variables)
  requires M.Inv(k, s)
  requires s.Ready?
  requires BT.G.Root() in s.cache
  ensures M.Next(Ik(k), s, s', UI.PutOp(key, value), D.NoDiskOp)
  {
    var oldroot := s.cache[BT.G.Root()];
    var msg := Messages.Define(value);
    var newroot := BT.AddMessageToNode(oldroot, key, msg);
    s' := s.(cache := s.cache[BT.G.Root() := newroot])
           .(ephemeralSuperblock := s.ephemeralSuperblock.(lbas := MapRemove(s.ephemeralSuperblock.lbas, {BT.G.Root()})));

    assert s'.ephemeralSuperblock.graph[BT.G.Root()] == s.ephemeralSuperblock.graph[BT.G.Root()];
    assert BC.G.Successors(oldroot) == BC.G.Successors(oldroot);
    assert BC.BlockPointsToValidReferences(oldroot, s.ephemeralSuperblock.graph);
    assert BC.BlockPointsToValidReferences(newroot, s.ephemeralSuperblock.graph);
    assert (iset r | r in s.ephemeralSuperblock.graph[BC.G.Root()]) == BC.G.Successors(oldroot);
    assert (iset r | r in s'.ephemeralSuperblock.graph[BC.G.Root()])
        == (iset r | r in s.ephemeralSuperblock.graph[BC.G.Root()])
        == BC.G.Successors(oldroot)
        == BC.G.Successors(newroot);
    //assert BT.G.Successors(newroot) == BT.G.Successors(oldroot);
    //assert BC.BlockPointsToValidReferences(newroot, s.ephemeralSuperblock.refcounts);
    assert BC.Dirty(Ik(k), s, s', BT.G.Root(), newroot);
    assert BC.OpStep(Ik(k), s, s', BT.G.WriteOp(BT.G.Root(), newroot));
    assert BC.OpStep(Ik(k), s, s', BT.BetreeStepOps(BT.BetreeInsert(BT.MessageInsertion(key, msg, oldroot)))[0]);
    assert BC.OpTransaction(Ik(k), s, s', BT.BetreeStepOps(BT.BetreeInsert(BT.MessageInsertion(key, msg, oldroot))));
    assert M.BetreeMove(Ik(k), s, s', UI.PutOp(key, value), D.NoDiskOp, BT.BetreeInsert(BT.MessageInsertion(key, msg, oldroot)));
    assert M.NextStep(Ik(k), s, s', UI.PutOp(key, value), D.NoDiskOp, M.BetreeMoveStep(BT.BetreeInsert(BT.MessageInsertion(key, msg, oldroot))));
  }

  /*
  method doStuff(k: Constants, s: Variables, io: DiskIOHandler)
  returns (s': Variables)
  requires io.initialized()
  modifies io
  ensures M.Next(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()))
  {
    if (s.Unready?) {
      s' := PageInSuperblock(k, s, io);
      assert M.NextStep(Ik(k), s, s', UI.NoOp, IDiskOp(io.diskOp()), M.BlockCacheMoveStep(BC.PageInSuperblockStep));
    } else {
      assume false;
    }
  }
  */

  method query(k: Constants, s: Variables, io: DiskIOHandler, key: MS.Key)
  returns (s': Variables, res: Option<MS.Value>)
  requires io.initialized()
  requires M.Inv(k, s)
  modifies io
  ensures M.Next(Ik(k), s, s',
    if res.Some? then UI.GetOp(key, res.value) else UI.NoOp,
    IDiskOp(io.diskOp()))
  {
    if (s.Unready?) {
      s' := PageInSuperblock(k, s, io);
      res := None;
    } else {
      var ref := BT.G.Root();
      var msg := Messages.IdentityMessage();
      ghost var lookup := [];

      // TODO if we have the acyclicity invariant, we can prove
      // termination without a bound like this.
      var loopBound := 40;
      ghost var exiting := false;

      while !msg.Define? && loopBound > 0
      invariant |lookup| == 0 ==> ref == BT.G.Root()
      invariant msg.Define? ==> |lookup| > 0
      invariant |lookup| > 0 ==> BT.WFLookupForKey(lookup, key)
      invariant !exiting && !msg.Define? ==> |lookup| > 0 ==> Last(lookup).node.children.Some?
      invariant !exiting && !msg.Define? ==> |lookup| > 0 ==> Last(lookup).node.children.value[Pivots.Route(Last(lookup).node.pivotTable, key)] == ref
      invariant forall i | 0 <= i < |lookup| :: MapsTo(s.cache, lookup[i].ref, lookup[i].node)
      invariant ref in s.ephemeralSuperblock.graph
      invariant !exiting ==> msg == BT.InterpretLookup(lookup, key)
      {
        assert !exiting;
        loopBound := loopBound - 1;

        if (ref !in s.cache) {
          s' := PageIn(k, s, io, ref);
          res := None;

          exiting := true;
          return;
        } else {
          ghost var lookup' := lookup;

          var node := s.cache[ref];
          lookup := lookup + [BT.G.ReadOp(ref, node)];
          msg := Messages.Merge(msg, BT.NodeLookup(node, key));

          forall idx | BT.ValidLayerIndex(lookup, idx) && idx < |lookup| - 1
          ensures BT.LookupFollowsChildRefAtLayer(key, lookup, idx)
          {
            if idx == |lookup| - 2 {
              assert BT.LookupFollowsChildRefAtLayer(key, lookup, idx);
            } else {
              assert BT.LookupFollowsChildRefAtLayer(key, lookup', idx);
              assert BT.LookupFollowsChildRefAtLayer(key, lookup, idx);
            }
          }
          assert BT.LookupFollowsChildRefs(key, lookup);

          if (node.children.Some?) {
            ref := node.children.value[Pivots.Route(node.pivotTable, key)];
            assert ref in BT.G.Successors(node);
            assert ref in s.ephemeralSuperblock.graph;
          } else {
            if !msg.Define? {
              // Case where we reach leaf and find nothing
              s' := s;
              res := Some(MS.V.DefaultValue());

              assert M.NextStep(Ik(k), s, s',
                if res.Some? then UI.GetOp(key, res.value) else UI.NoOp,
                IDiskOp(io.diskOp()),
                M.BetreeMoveStep(BT.BetreeQuery(BT.LookupQuery(key, res.value, lookup))));

              exiting := true;
              return;
            }
          }
        }
      }

      if msg.Define? {
        s' := s;
        res := Some(msg.value);

        assert BT.ValidQuery(BT.LookupQuery(key, res.value, lookup));
        assert M.BetreeMove(Ik(k), s, s',
          UI.GetOp(key, res.value),
          IDiskOp(io.diskOp()),
          BT.BetreeQuery(BT.LookupQuery(key, res.value, lookup)));
        assert M.NextStep(Ik(k), s, s',
          if res.Some? then UI.GetOp(key, res.value) else UI.NoOp,
          IDiskOp(io.diskOp()),
          M.BetreeMoveStep(BT.BetreeQuery(BT.LookupQuery(key, res.value, lookup))));
      } else {
        // loop bound exceeded; do nothing :/
        s' := s;
        res := None;

        // TODO need a proper stutter step
        assert M.Next(Ik(k), s, s',
          if res.Some? then UI.GetOp(key, res.value) else UI.NoOp,
          IDiskOp(io.diskOp()));
      }
    }
  }

  method insert(k: Constants, s: Variables, io: DiskIOHandler, key: MS.Key, value: MS.Value)
  returns (s': Variables, success: bool)
  requires io.initialized()
  modifies io
  requires M.Inv(k, s)
  ensures M.Next(Ik(k), s, s',
    if success then UI.PutOp(key, value) else UI.NoOp,
    IDiskOp(io.diskOp()))
  {
    if (s.Unready?) {
      s' := PageInSuperblock(k, s, io);
      success := false;
      return;
    }

    if (BT.G.Root() !in s.cache) {
      s' := PageIn(k, s, io, BT.G.Root());
      success := false;
      return;
    }

    s' := InsertKeyValue(k, s, key, value);
    success := true;
  }

  method sync(k: Constants, s: Variables, io: DiskIOHandler)
  returns (s': Variables, success: bool)
  requires io.initialized()
  modifies io
  requires M.Inv(k, s)
  ensures M.Next(Ik(k), s, s',
    if success then UI.SyncOp else UI.NoOp,
    IDiskOp(io.diskOp()))
  {
    assume false;
  }

  ////////// Top-level handlers

  method handleSync(k: Constants, hs: HeapState, io: DiskIOHandler)
  returns (success: bool)
  {
    var s := hs.s;
    var s', succ := sync(k, s, io);
    var uiop := if succ then UI.SyncOp else UI.NoOp;
    M.NextPreservesInv(k, s, s', uiop, IDiskOp(io.diskOp()));
    hs.s := s';
    success := succ;
  }

  method handleQuery(k: Constants, hs: HeapState, io: DiskIOHandler, key: MS.Key)
  returns (v: Option<MS.Value>)
  {
    var s := hs.s;
    var s', value := query(k, s, io, key);
    var uiop := if value.Some? then UI.GetOp(key, value.value) else UI.NoOp;
    M.NextPreservesInv(k, s, s', uiop, IDiskOp(io.diskOp()));
    hs.s := s';
    v := value;
  }

  method handleInsert(k: Constants, hs: HeapState, io: DiskIOHandler, key: MS.Key, value: MS.Value)
  returns (success: bool)
  {
    var s := hs.s;
    var s', succ := insert(k, s, io, key, value);
    var uiop := if succ then UI.PutOp(key, value) else UI.NoOp;
    M.NextPreservesInv(k, s, s', uiop, IDiskOp(io.diskOp()));
    hs.s := s';
    success := succ;
  }

}
