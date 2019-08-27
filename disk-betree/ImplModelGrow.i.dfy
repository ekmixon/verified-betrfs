include "ImplModelCache.i.dfy"
include "ImplModelFlushRootBucket.i.dfy"

module ImplModelGrow { 
  import opened ImplModel
  import opened ImplModelIO
  import opened ImplModelCache
  import opened ImplModelFlushRootBucket

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets
  import opened BucketWeights

  import opened NativeTypes

  /// The root was found to be too big: grow
  function {:opaque} grow(k: Constants, s: Variables)
  : (Variables)
  requires Inv(k, s)
  requires s.Ready?
  requires BT.G.Root() in s.cache
  {
    if (
      && s.frozenIndirectionTable.Some?
      && BT.G.Root() in s.frozenIndirectionTable.value
      && var entry := s.frozenIndirectionTable.value[BT.G.Root()];
      && var (loc, _) := entry;
      && loc.None?
    ) then (
      s
    ) else (
      var s0 := flushRootBucket(k, s);
      flushRootBucketCorrect(k, s);

      var oldroot := s0.cache[BT.G.Root()];
      var (s1, newref) := alloc(k, s0, oldroot);
      match newref {
        case None => (
          s1
        )
        case Some(newref) => (
          var newroot := Node([], Some([newref]), [KMTable.Empty()]);
          var s0' := write(k, s1, BT.G.Root(), newroot);
          s0'
        )
      }
    )
  }

  lemma WeightOneEmptyKMTable()
  ensures WeightBucketList(KMTable.ISeq([KMTable.Empty()])) == 0

  lemma growCorrect(k: Constants, s: Variables)
  requires Inv(k, s)
  requires s.Ready?
  requires BT.G.Root() in s.cache
  ensures var s' := grow(k, s);
    && WFVars(s')
    && M.Next(Ik(k), IVars(s), IVars(s'), UI.NoOp, D.NoDiskOp)
  {
    reveal_grow();

    if (
      && s.frozenIndirectionTable.Some?
      && BT.G.Root() in s.frozenIndirectionTable.value
      && var entry := s.frozenIndirectionTable.value[BT.G.Root()];
      && var (loc, _) := entry;
      && loc.None?
    ) {
      assert noop(k, IVars(s), IVars(s));
      return;
    }

    var s0 := flushRootBucket(k, s);
    flushRootBucketCorrect(k, s);
    reveal_flushRootBucket();

    var oldroot := s0.cache[BT.G.Root()];
    var (s1, newref) := alloc(k, s0, oldroot);
    reveal_alloc();
    reveal_write();

    match newref {
      case None => {
        assert noop(k, IVars(s0), IVars(s1));
      }
      case Some(newref) => {
        var newroot := Node([], Some([newref]), [KMTable.Empty()]);
        WeightOneEmptyKMTable();

        assert BT.G.Root() in s0.cache;
        assert BT.G.Root() in ICache(s0.cache, s0.rootBucket);
        assert BT.G.Root() in ICache(s1.cache, s1.rootBucket);
        assert BT.G.Root() in s1.cache;

        INodeRootEqINodeForEmptyRootBucket(oldroot);
        assert INodeRoot(s.cache[BT.G.Root()], s.rootBucket)
            == IVars(s).cache[BT.G.Root()]
            == IVars(s0).cache[BT.G.Root()]
            == INodeRoot(oldroot, s0.rootBucket)
            == INode(oldroot);

        var s' := write(k, s1, BT.G.Root(), newroot);

        allocCorrect(k, s0, oldroot);
        writeCorrect(k, s1, BT.G.Root(), newroot);

        var growth := BT.RootGrowth(INode(oldroot), newref);
        assert INode(newroot) == BT.G.Node([], Some([growth.newchildref]), [map[]]);
        var step := BT.BetreeGrow(growth);
        BC.MakeTransaction2(Ik(k), IVars(s0), IVars(s1), IVars(s'), BT.BetreeStepOps(step));
        assert BBC.BetreeMove(Ik(k), IVars(s0), IVars(s'), UI.NoOp, M.IDiskOp(D.NoDiskOp), step);
        assert stepsBetree(k, IVars(s0), IVars(s'), UI.NoOp, step);
        assert stepsBetree(k, IVars(s), IVars(s'), UI.NoOp, step);
      }
    }
  }
}
