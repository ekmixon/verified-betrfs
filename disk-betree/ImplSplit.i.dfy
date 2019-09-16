include "ImplCache.i.dfy"
include "ImplModelSplit.i.dfy"

module ImplSplit { 
  import opened Impl
  import opened ImplIO
  import opened ImplCache
  import ImplModelSplit
  import opened ImplState

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets

  import opened BucketsLib
  import opened BucketWeights
  import PivotsLib

  import opened NativeTypes

  method CutoffNodeAndKeepLeft(node: Node, pivot: Key)
  returns (node': Node)
  requires IM.WFNode(node)
  ensures node' == ImplModelSplit.CutoffNodeAndKeepLeft(node, pivot)
  {
    ImplModelSplit.reveal_CutoffNodeAndKeepLeft();
    var cLeft := Pivots.ComputeCutoffForLeft(node.pivotTable, pivot);
    var leftPivots := node.pivotTable[.. cLeft];
    var leftChildren := if node.children.Some? then Some(node.children.value[.. cLeft + 1]) else None;
    WeightBucketLeBucketList(KMTable.ISeq(node.buckets), cLeft);
    var splitBucket := KMTable.SplitLeft(node.buckets[cLeft], pivot);
    var leftBuckets := node.buckets[.. cLeft] + [splitBucket];
    node' := IM.Node(leftPivots, leftChildren, leftBuckets);
  }

  method CutoffNodeAndKeepRight(node: Node, pivot: Key)
  returns (node': Node)
  requires IM.WFNode(node)
  ensures node' == ImplModelSplit.CutoffNodeAndKeepRight(node, pivot)
  {
    ImplModelSplit.reveal_CutoffNodeAndKeepRight();
    var cRight := Pivots.ComputeCutoffForRight(node.pivotTable, pivot);
    var rightPivots := node.pivotTable[cRight ..];
    var rightChildren := if node.children.Some? then Some(node.children.value[cRight ..]) else None;
    WeightBucketLeBucketList(KMTable.ISeq(node.buckets), cRight);
    var splitBucket := KMTable.SplitRight(node.buckets[cRight], pivot);
    var rightBuckets := [splitBucket] + node.buckets[cRight + 1 ..];
    node' := IM.Node(rightPivots, rightChildren, rightBuckets);
  }

  method CutoffNode(node: Node, lbound: Option<Key>, rbound: Option<Key>)
  returns (node' : Node)
  requires IM.WFNode(node)
  ensures node' == ImplModelSplit.CutoffNode(node, lbound, rbound)
  {
    ImplModelSplit.reveal_CutoffNode();

    match lbound {
      case None => {
        match rbound {
          case None => {
            node' := node;
          }
          case Some(rbound) => {
            node' := CutoffNodeAndKeepLeft(node, rbound);
          }
        }
      }
      case Some(lbound) => {
        match rbound {
          case None => {
            node' := CutoffNodeAndKeepRight(node, lbound);
          }
          case Some(rbound) => {
            var node1 := CutoffNodeAndKeepLeft(node, rbound);
            ImplModelSplit.CutoffNodeAndKeepLeftCorrect(node, rbound);
            node' := CutoffNodeAndKeepRight(node1, lbound);
          }
        }
      }
    }
  }

  method doSplit(k: ImplConstants, s: ImplVariables, parentref: BT.G.Reference, ref: BT.G.Reference, slot: int)
  requires s.ready
  requires Inv(k, s)
  requires ref in s.ephemeralIndirectionTable.Contents
  requires parentref in s.ephemeralIndirectionTable.Contents
  requires ref in s.cache.Contents
  requires parentref in s.cache.Contents
  requires s.cache.Contents[parentref].children.Some?
  requires 0 <= slot < |s.cache.Contents[parentref].children.value|
  requires s.cache.Contents[parentref].children.value[slot] == ref
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

    var fused_parent_opt := s.cache.Get(parentref);
    var fused_parent := fused_parent_opt.value;
    var fused_child_opt := s.cache.Get(ref);
    var fused_child := fused_child_opt.value;

    var lbound := (if slot > 0 then Some(fused_parent.pivotTable[slot - 1]) else None);
    var ubound := (if slot < |fused_parent.pivotTable| then Some(fused_parent.pivotTable[slot]) else None);
    var child := CutoffNode(fused_child, lbound, ubound);

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

    assert left_childref != right_childref;
    assert parentref != left_childref;
    assert parentref != right_childref;

    var num_children_left := |child.buckets| / 2;
    var pivot := child.pivotTable[num_children_left - 1];

    var left_child := ImplModelSplit.SplitChildLeft(child, num_children_left);
    var right_child := ImplModelSplit.SplitChildRight(child, num_children_left);
    var split_parent := SplitParent(fused_parent, pivot, slot, left_childref.value, right_childref.value);

    write(k, s, left_childref.value, left_child);
    write(k, s, right_childref.value, right_child);
    write(k, s, parentref, split_parent);
  }
}
