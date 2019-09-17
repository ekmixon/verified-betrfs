include "ImplCache.i.dfy"
include "ImplModelSplit.i.dfy"

module ImplSplit { 
  import opened Impl
  import opened ImplIO
  import opened ImplCache
  import ImplModelSplit
  import opened ImplState
  import opened ImplNode

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets

  import opened BucketsLib
  import opened BucketWeights
  import PivotsLib

  import opened NativeTypes

  method splitBookkeeping(k: ImplConstants, s: ImplVariables, left_childref: BT.G.Reference, right_childref: BT.G.Reference, parentref: BT.G.Reference, fused_parent_children: seq<BT.G.Reference>, left_child: Node, right_child: Node, slot: uint64)
  requires Inv(k, s)
  requires 0 <= slot as int < |fused_parent_children|
  requires left_child.Inv()
  requires right_child.Inv()
  requires left_child.Repr !! s.Repr()
  requires right_child.Repr !! s.Repr()
  requires s.ready
  modifies s.lru.Repr
  modifies s.ephemeralIndirectionTable.Repr
  ensures s.ready
  ensures s.W()
  ensures forall o | o in s.lru.Repr :: o in old(s.lru.Repr) || fresh(o)
  ensures forall o | o in s.ephemeralIndirectionTable.Repr :: o in old(s.ephemeralIndirectionTable.Repr) || fresh(o)
  ensures s.I() == ImplModelSplit.splitBookkeeping(Ic(k), old(s.I()), left_childref, right_childref, parentref, fused_parent_children, left_child.I(), right_child.I(), slot as int);
  {
    ImplModelSplit.reveal_splitBookkeeping();
    writeBookkeeping(k, s, left_childref, left_child.children);
    writeBookkeeping(k, s, right_childref, right_child.children);
    writeBookkeeping(k, s, parentref, Some(replace1with2(fused_parent_children, left_childref, right_childref, slot as int)));
  }

  method splitCacheChanges(s: ImplVariables, child: Node, left_childref: BT.G.Reference,
      right_childref: BT.G.Reference, parentref: BT.G.Reference, slot: uint64, num_children_left: uint64, pivot: Key, left_child: Node, right_child: Node)
  requires s.ready
  requires s.W()
  requires s.cache.ptr(parentref).Some?
  requires IM.WFNode(s.cache.ptr(parentref).value.I())
  requires s.cache.ptr(parentref).value.I().children.Some?
  requires 0 <= slot as int < |s.cache.ptr(parentref).value.I().children.value|
  requires child.Inv()
  requires left_child.Inv()
  requires right_child.Inv()
  requires left_child.Repr !! s.Repr()
  requires right_child.Repr !! s.Repr()
  requires left_child.Repr !! right_child.Repr
  requires |s.cache.I()| <= 0x10000 - 2
  requires left_childref != parentref
  requires right_childref != parentref
  modifies s.Repr()
  modifies left_child.Repr // not really but it's easier to include this
  modifies right_child.Repr
  ensures s.W()
  ensures (forall o | o in s.Repr() :: o in old(s.Repr()) || o in old(left_child.Repr) || o in old(right_child.Repr) || fresh(o))
  ensures s.I() == ImplModelSplit.splitCacheChanges(old(s.I()), old(child.I()), left_childref, right_childref, parentref, slot as int, num_children_left as int, pivot, old(left_child.I()), old(right_child.I()))
  ensures s.ready
  {
    ImplModelSplit.reveal_splitCacheChanges();
    s.cache.Insert(left_childref, left_child);
    s.cache.Insert(right_childref, right_child);
    s.cache.SplitParent(parentref, slot as uint64, pivot, left_childref, right_childref);
  }

  method doSplit(k: ImplConstants, s: ImplVariables, parentref: BT.G.Reference, ref: BT.G.Reference, slot: int)
  requires s.ready
  requires Inv(k, s)
  requires ref in s.ephemeralIndirectionTable.Contents
  requires parentref in s.ephemeralIndirectionTable.Contents
  requires s.cache.ptr(ref).Some?
  requires s.cache.ptr(parentref).Some?
  requires s.cache.I()[parentref].children.Some?
  requires 0 <= slot < |s.cache.I()[parentref].children.value|
  requires s.cache.I()[parentref].children.value[slot] == ref
  modifies s.Repr()
  ensures WellUpdated(s)
  ensures s.ready
  ensures s.I() == ImplModelSplit.doSplit(Ic(k), old(s.I()), parentref, ref, slot);
  {
    ImplModelSplit.reveal_doSplit();

    if s.frozenIndirectionTable != null {
      var lbaGraph := s.frozenIndirectionTable.Get(parentref);
      if lbaGraph.Some? {
        var (lba, _) := lbaGraph.value;
        if lba.None? {
          print "giving up; doSplit can't run because frozen isn't written";
          return;
        }
      }
    }

    var fused_parent_opt := s.cache.GetOpt(parentref);
    var fused_parent := fused_parent_opt.value;
    var fused_child_opt := s.cache.GetOpt(ref);
    var fused_child := fused_child_opt.value;

    var lbound := (if slot > 0 then Some(fused_parent.pivotTable[slot - 1]) else None);
    var ubound := (if slot < |fused_parent.pivotTable| then Some(fused_parent.pivotTable[slot]) else None);
    var child := fused_child.CutoffNode(lbound, ubound);

    if (|child.pivotTable| == 0) {
      // TODO there should be an operation which just
      // cuts off the node and doesn't split it.
      print "giving up; doSplit can't run because child.pivots == 0\n";
      return;
    }

    var left_childref := getFreeRef(s);
    if left_childref.None? {
      print "giving up; doSplit can't allocate left_childref\n";
      return;
    }

    var right_childref := getFreeRef2(s, left_childref.value);
    if right_childref.None? {
      print "giving up; doSplit can't allocate right_childref\n";
      return;
    }

    var split_parent_children := Some(replace1with2(fused_parent.children.value, left_childref.value, right_childref.value, slot));

    assume left_childref.value != right_childref.value;
    assume parentref != left_childref.value;
    assume parentref != right_childref.value;

    var num_children_left := |child.buckets| / 2;
    assume 0 <= num_children_left < 0x100;
    var pivot := child.pivotTable[num_children_left - 1];

    var left_child := child.SplitChildLeft(num_children_left as uint64);
    var right_child := child.SplitChildRight(num_children_left as uint64);

    splitBookkeeping(k, s, left_childref.value, right_childref.value, parentref, fused_parent.children.value, left_child, right_child, slot as uint64);
    splitCacheChanges(s, child, left_childref.value, right_childref.value, parentref, slot as uint64, num_children_left as uint64, pivot, left_child, right_child);
  }
}
