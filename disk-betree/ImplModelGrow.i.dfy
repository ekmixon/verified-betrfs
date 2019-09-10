include "ImplModelCache.i.dfy"

module ImplModelGrow { 
  import opened ImplModel
  import opened ImplModelIO
  import opened ImplModelCache

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets
  import opened BucketWeights
  import opened Bounds

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
      var oldroot := s.cache[BT.G.Root()];
      var (s1, newref) := alloc(k, s, oldroot);
      match newref {
        case None => (
          s1
        )
        case Some(newref) => (
          var newroot := Node([], Some([newref]), [map[]]);
          var s' := write(k, s1, BT.G.Root(), newroot);
          s'
        )
      }
    )
  }

  lemma WeightOneEmpty()
  ensures WeightBucketList([map[]]) == 0

  lemma growCorrect(k: Constants, s: Variables)
  requires Inv(k, s)
  requires s.Ready?
  requires BT.G.Root() in s.cache
  requires TotalCacheSize(s) <= MaxCacheSize() - 1
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

    var oldroot := s.cache[BT.G.Root()];
    var (s1, newref) := alloc(k, s, oldroot);
    reveal_alloc();
    reveal_write();

    match newref {
      case None => {
        assert noop(k, IVars(s), IVars(s1));
      }
      case Some(newref) => {
        var newroot := Node([], Some([newref]), [map[]]);
        WeightOneEmpty();

        assert BT.G.Root() in s.cache;
        assert BT.G.Root() in ICache(s.cache);
        assert BT.G.Root() in ICache(s1.cache);
        assert BT.G.Root() in s1.cache;

        var s' := write(k, s1, BT.G.Root(), newroot);

        allocCorrect(k, s, oldroot);
        writeCorrect(k, s1, BT.G.Root(), newroot);

        var growth := BT.RootGrowth(INode(oldroot), newref);
        assert INode(newroot) == BT.G.Node([], Some([growth.newchildref]), [map[]]);
        var step := BT.BetreeGrow(growth);
        BC.MakeTransaction2(Ik(k), IVars(s), IVars(s1), IVars(s'), BT.BetreeStepOps(step));
        assert BBC.BetreeMove(Ik(k), IVars(s), IVars(s'), UI.NoOp, M.IDiskOp(D.NoDiskOp), step);
        assert stepsBetree(k, IVars(s), IVars(s'), UI.NoOp, step);
        assert stepsBetree(k, IVars(s), IVars(s'), UI.NoOp, step);
      }
    }
  }
}
