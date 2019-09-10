include "ImplCache.i.dfy"
include "ImplModelGrow.i.dfy"

module ImplGrow { 
  import opened Impl
  import opened ImplIO
  import opened ImplCache
  import opened ImplState
  import ImplModelGrow

  import KVList
  import MutableBucket

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets

  import opened NativeTypes

  /// The root was found to be too big: grow
  method grow(k: ImplConstants, s: ImplVariables)
  requires Inv(k, s)
  requires s.ready
  requires BT.G.Root() in s.cache.Contents
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

    var oldrootOpt := s.cache.Get(BT.G.Root());
    var oldroot := oldrootOpt.value;
    assert INode(oldroot) == ICache(s.cache)[BT.G.Root()];
    var newref := alloc(k, s, oldroot);

    assume false;

    match newref {
      case None => {
        print "giving up; could not allocate ref\n";
      }
      case Some(newref) => {
        var emptyKvl := KVList.Empty();
        var mutbucket := new MutableBucket.MutBucket(emptyKvl);
        var newroot := IS.Node([], Some([newref]), [mutbucket]);

        write(k, s, BT.G.Root(), newroot);
      }
    }
  }

}
