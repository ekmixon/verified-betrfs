include "ImplCache.i.dfy"
include "ImplModelGrow.i.dfy"

module ImplGrow { 
  import opened Impl
  import opened ImplIO
  import opened ImplCache
  import opened ImplState
  import opened ImplNode
  import ImplModelGrow

  import KVList
  import MutableBucket

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets
  import opened BucketWeights

  import opened NativeTypes

  /// The root was found to be too big: grow
  method grow(k: ImplConstants, s: ImplVariables)
  requires Inv(k, s)
  requires s.ready
  requires BT.G.Root() in s.cache.I()
  modifies s.Repr()
  ensures WellUpdated(s)
  ensures s.ready
  ensures s.I() == ImplModelGrow.grow(Ic(k), old(s.I()))
  {
    ImplModelGrow.reveal_grow();

    if s.frozenIndirectionTable != null {
      var rootLbaGraph := s.frozenIndirectionTable.Get(BT.G.Root());
      if rootLbaGraph.Some? {
        var (lba, _) := rootLbaGraph.value;
        if lba.None? {
          print "giving up; grow can't run because frozen isn't written\n";
          return;
        }
      }
    }

    var oldrootOpt := s.cache.GetOpt(BT.G.Root());
    var oldroot := oldrootOpt.value;
    var newref := allocBookkeeping(k, s, oldroot.children);

    match newref {
      case None => {
        print "giving up; could not allocate ref\n";
      }
      case Some(newref) => {
        var emptyKvl := KVList.Empty();
        WeightBucketEmpty();

        var mutbucket := new MutableBucket.MutBucket(emptyKvl);

        BucketListReprDisjointOfLen1([mutbucket]);
        var newroot := new Node([], Some([newref]), [mutbucket]);
        
        assert newroot.I() == IM.Node([], Some([newref]), [map[]]);
        assert s.I().cache[BT.G.Root()] == old(s.I().cache[BT.G.Root()]);

        writeBookkeeping(k, s, BT.G.Root(), newroot.children);

        s.cache.MoveAndReplace(BT.G.Root(), newref, newroot);

        ghost var a := s.I();
        ghost var b := ImplModelGrow.grow(Ic(k), old(s.I()));
        assert a.cache == b.cache;
        assert a.ephemeralIndirectionTable == b.ephemeralIndirectionTable;
        assert a.lru == b.lru;
      }
    }
  }
}
