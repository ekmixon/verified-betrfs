include "KMTable.i.dfy"
include "Bounds.i.dfy"
include "PivotsLib.i.dfy"

module KMTablePartialFlush {
  import opened KMTable
  import opened Lexicographic_Byte_Order
  import opened ValueMessage`Internal
  import opened BucketWeights
  import opened BucketsLib
  import opened NativeTypes
  import Pivots = PivotsLib
  import opened Bounds

  function partialFlushIterate(parent: KMT, children: seq<KMT>, pivots: seq<Key>,
      parentIdx: int, childrenIdx: int, childIdx: int, acc: seq<KMT>, cur: KMT, newParent: KMT, weightSlack: int) : (KMT, seq<KMT>)
  requires WF(parent)
  requires forall i | 0 <= i < |children| :: WF(children[i])
  requires |pivots| + 1 == |children|
  requires 0 <= parentIdx <= |parent.keys|
  requires 0 <= childrenIdx <= |children|
  requires childrenIdx < |children| ==> 0 <= childIdx <= |children[childrenIdx].keys|
  decreases |children| - childrenIdx
  decreases |parent.keys| - parentIdx +
      (if childrenIdx < |children| then |children[childrenIdx].keys| - childIdx else 0)
  {
    if childrenIdx == |children| then (
      (newParent, acc)
    ) else (
      var child := children[childrenIdx];

      if parentIdx == |parent.keys| then (
        if childIdx == |child.keys| then (
          partialFlushIterate(parent, children, pivots, parentIdx, childrenIdx + 1, 0, acc + [cur], KMT([], []), newParent, weightSlack)
        //) else if |cur.keys| == 0 then (
        //  partialFlushIterate(parent, children, pivots, parentIdx, childrenIdx + 1, 0, acc + [child], KMT([], []))
        ) else (
          partialFlushIterate(parent, children, pivots, parentIdx, childrenIdx, childIdx + 1, acc, append(cur, child.keys[childIdx], child.values[childIdx]), newParent, weightSlack)
        )
      ) else (
        if childIdx == |child.keys| then (
          if childrenIdx == |children| - 1 then (
            var w := WeightKey(parent.keys[parentIdx]) + WeightMessage(parent.values[parentIdx]);
            if w <= weightSlack then (
              partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx, acc, append(cur, parent.keys[parentIdx], parent.values[parentIdx]), newParent, weightSlack - w)
            ) else (
              partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx, acc, cur, append(newParent, parent.keys[parentIdx], parent.values[parentIdx]), weightSlack)
            )
          ) else (
            if lt(parent.keys[parentIdx], pivots[childrenIdx]) then (
              var w := WeightKey(parent.keys[parentIdx]) + WeightMessage(parent.values[parentIdx]);
              if w <= weightSlack then (
                partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx, acc, append(cur, parent.keys[parentIdx], parent.values[parentIdx]), newParent, weightSlack - w)
              ) else (
                partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx, acc, cur, append(newParent, parent.keys[parentIdx], parent.values[parentIdx]), weightSlack)
              )
            ) else (
              partialFlushIterate(parent, children, pivots, parentIdx, childrenIdx + 1, 0, acc + [cur], KMT([], []), newParent, weightSlack)
            )
          )
        ) else (
          if child.keys[childIdx] == parent.keys[parentIdx] then (
            var m := Merge(parent.values[parentIdx], child.values[childIdx]);
            if m == IdentityMessage() then (
              partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx + 1, acc, cur, newParent, weightSlack + WeightKey(child.keys[childIdx]) + WeightMessage(child.values[childIdx]))
            ) else (
              if weightSlack + WeightMessage(child.values[childIdx]) >= WeightMessage(m) then (
                partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx + 1, acc, append(cur, child.keys[childIdx], m), newParent, weightSlack + WeightMessage(child.values[childIdx]) - WeightMessage(m))
              ) else (
                partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx + 1, acc, append(cur, child.keys[childIdx], child.values[childIdx]), append(newParent, parent.keys[parentIdx], parent.values[parentIdx]), weightSlack)
              )
            )
          ) else if lt(child.keys[childIdx], parent.keys[parentIdx]) then (
            partialFlushIterate(parent, children, pivots, parentIdx, childrenIdx, childIdx + 1, acc, append(cur, child.keys[childIdx], child.values[childIdx]), newParent, weightSlack)
          ) else (
            var w := WeightKey(parent.keys[parentIdx]) + WeightMessage(parent.values[parentIdx]);
            if w <= weightSlack then (
              partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx, acc, append(cur, parent.keys[parentIdx], parent.values[parentIdx]), newParent, weightSlack - w)
            ) else (
              partialFlushIterate(parent, children, pivots, parentIdx + 1, childrenIdx, childIdx, acc, cur, append(newParent, parent.keys[parentIdx], parent.values[parentIdx]), weightSlack)
            )
          )
        )
      )
    )
  }

  function {:opaque} partialFlush(parent: KMT, children: seq<KMT>, pivots: seq<Key>) : (KMT, seq<KMT>)
  requires WF(parent)
  requires forall i | 0 <= i < |children| :: WF(children[i])
  requires |pivots| + 1 == |children|
  {
    partialFlushIterate(parent, children, pivots, 0, 0, 0, [], KMT([], []), KMT([], []), MaxTotalBucketWeight() - WeightKMTSeq(children))
  }

  lemma partialFlushRes(parent: KMT, children: seq<KMT>, pivots: seq<Key>)
  returns (flushedKeys: set<Key>)
  requires WF(parent)
  requires Pivots.WFPivots(pivots)
  requires forall i | 0 <= i < |children| :: WF(children[i])
  requires |pivots| + 1 == |children|
  requires WeightBucketList(ISeq(children)) <= MaxTotalBucketWeight()
  ensures var (newParent, newChildren) := partialFlush(parent, children, pivots);
      && WF(newParent)
      && (forall i | 0 <= i < |newChildren| :: WF(newChildren[i]))
      && I(newParent) == BucketComplement(I(parent), flushedKeys)
      && ISeq(newChildren) == BucketListFlush(BucketIntersect(I(parent), flushedKeys), ISeq(children), pivots)
      && WeightBucket(I(newParent)) <= WeightBucket(I(parent))
      && WeightBucketList(ISeq(newChildren)) <= MaxTotalBucketWeight()

  method PartialFlush(parent: KMT, children: seq<KMT>, pivots: seq<Key>)
  returns (newParent: KMT, newChildren: seq<KMT>)
  requires WF(parent)
  requires forall i | 0 <= i < |children| :: WF(children[i])
  requires |pivots| + 1 == |children|
  requires |children| <= MaxNumChildren()
  requires WeightBucket(I(parent)) <= MaxTotalBucketWeight()
  requires WeightBucketList(ISeq(children)) <= MaxTotalBucketWeight()
  ensures (newParent, newChildren) == partialFlush(parent, children, pivots)
  {
    reveal_partialFlush();

    WeightBucketLeBucketList(ISeq(children), 0);
    lenKeysLeWeight(children[0]);
    lenKeysLeWeight(parent);
    assert |children[0].keys| + |parent.keys| < 0x8000_0000_0000_0000;

    var maxChildLen: uint64 := 0;
    var idx: uint64 := 0;
    while idx < |children| as uint64
    invariant 0 <= idx as int <= |children|
    invariant forall i | 0 <= i < idx as int :: |children[i].keys| <= maxChildLen as int
    invariant maxChildLen as int + |parent.keys| < 0x8000_0000_0000_0000
    {
      WeightBucketLeBucketList(ISeq(children), idx as int);
      lenKeysLeWeight(children[idx]);
      if |children[idx].keys| as uint64 > maxChildLen {
        maxChildLen := |children[idx].keys| as uint64;
      }
      idx := idx + 1;
    }

    var parentIdx: uint64 := 0;
    var childrenIdx: uint64 := 0;
    var childIdx: uint64 := 0;
    var acc := [];

    var defaultMessage := IdentityMessage();

    var cur_keys := new Key[maxChildLen + |parent.keys| as uint64];
    var cur_values := new Message[maxChildLen + |parent.keys| as uint64]((i) => defaultMessage);
    var cur_idx: uint64 := 0;

    var newParent_keys := new Key[|parent.keys| as uint64];
    var newParent_values := new Message[|parent.keys| as uint64]((i) => defaultMessage);
    var newParent_idx: uint64 := 0;

    var initChildrenWeight := computeWeightKMTSeq(children);
    kmtableSeqWeightEq(children);
    var weightSlack: uint64 := MaxTotalBucketWeight() as uint64 - initChildrenWeight;

    while childrenIdx < |children| as uint64
    invariant 0 <= parentIdx as int <= |parent.keys|
    invariant 0 <= childrenIdx as int <= |children|
    invariant (childrenIdx as int < |children| ==> 0 <= childIdx as int <= |children[childrenIdx].keys|)
    invariant 0 <= cur_idx
    invariant 0 <= newParent_idx <= parentIdx
    invariant childrenIdx as int < |children| ==> cur_idx as int <= parentIdx as int + childIdx as int
    invariant childrenIdx as int == |children| ==> cur_idx == 0
    invariant partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int)
        == partialFlush(parent, children, pivots)
    decreases |children| - childrenIdx as int
    decreases |parent.keys| - parentIdx as int +
        (if childrenIdx as int < |children| then |children[childrenIdx].keys| - childIdx as int else 0)
    {
      ghost var ghosty := true;
      if ghosty {
        if parentIdx as int < |parent.values| { WeightMessageBound(parent.values[parentIdx]); }
        if childIdx as int < |children[childrenIdx].values| { WeightMessageBound(children[childrenIdx].values[childIdx]); }
      }

      var child := children[childrenIdx];
      if parentIdx == |parent.keys| as uint64 {
        if childIdx == |child.keys| as uint64 {
          childrenIdx := childrenIdx + 1;
          childIdx := 0;
          acc := acc + [KMT(cur_keys[..cur_idx], cur_values[..cur_idx])];
          cur_idx := 0;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
        } else {
          cur_keys[cur_idx] := child.keys[childIdx];
          cur_values[cur_idx] := child.values[childIdx];
          assert append(KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), child.keys[childIdx], child.values[childIdx]) == KMT(cur_keys[..cur_idx+1], cur_values[..cur_idx+1]);
          childIdx := childIdx + 1;
          cur_idx := cur_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
        }
      } else {
        if childIdx == |child.keys| as uint64 {
          if childrenIdx == |children| as uint64 - 1 {
            var w := WeightKey(parent.keys[parentIdx]) as uint64 + WeightMessage(parent.values[parentIdx]) as uint64;
            if w <= weightSlack {
              cur_keys[cur_idx] := parent.keys[parentIdx];
              cur_values[cur_idx] := parent.values[parentIdx];
              assert append(KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), parent.keys[parentIdx], parent.values[parentIdx]) == KMT(cur_keys[..cur_idx+1], cur_values[..cur_idx+1]);
              weightSlack := weightSlack - w;
              parentIdx := parentIdx + 1;
              cur_idx := cur_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
            } else {
              newParent_keys[newParent_idx] := parent.keys[parentIdx];
              newParent_values[newParent_idx] := parent.values[parentIdx];

              assert append(KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), parent.keys[parentIdx], parent.values[parentIdx]) == KMT(newParent_keys[..newParent_idx+1], newParent_values[..newParent_idx+1]);

              parentIdx := parentIdx + 1;
              newParent_idx := newParent_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
            }
          } else {
            var c := cmp(parent.keys[parentIdx], pivots[childrenIdx]);
            if c < 0 {
              var w := WeightKey(parent.keys[parentIdx]) as uint64 + WeightMessage(parent.values[parentIdx]) as uint64;
              if w <= weightSlack {
                cur_keys[cur_idx] := parent.keys[parentIdx];
                cur_values[cur_idx] := parent.values[parentIdx];
                assert append(KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), parent.keys[parentIdx], parent.values[parentIdx]) == KMT(cur_keys[..cur_idx+1], cur_values[..cur_idx+1]);
                weightSlack := weightSlack - w;
                parentIdx := parentIdx + 1;
                cur_idx := cur_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
              } else {
                newParent_keys[newParent_idx] := parent.keys[parentIdx];
                newParent_values[newParent_idx] := parent.values[parentIdx];

                assert append(KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), parent.keys[parentIdx], parent.values[parentIdx]) == KMT(newParent_keys[..newParent_idx+1], newParent_values[..newParent_idx+1]);

                parentIdx := parentIdx + 1;
                newParent_idx := newParent_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
              }
            } else {
              acc := acc + [KMT(cur_keys[..cur_idx], cur_values[..cur_idx])];
              childrenIdx := childrenIdx + 1;
              childIdx := 0;
              cur_idx := 0;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
            }
          }
        } else {
          var c := cmp(child.keys[childIdx], parent.keys[parentIdx]);
          if c == 0 {
            var m := Merge(parent.values[parentIdx], child.values[childIdx]);
            if m == IdentityMessage() {
              weightSlack := weightSlack + WeightKey(child.keys[childIdx]) as uint64 + WeightMessage(child.values[childIdx]) as uint64;
              parentIdx := parentIdx + 1;
              childIdx := childIdx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
            } else {
              assume weightSlack <= 0x1_0000_0000;
              WeightMessageBound(m);

              if weightSlack + WeightMessage(child.values[childIdx]) as uint64 >= WeightMessage(m) as uint64 {
                cur_keys[cur_idx] := parent.keys[parentIdx];
                cur_values[cur_idx] := m;
                assert append(KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), parent.keys[parentIdx], m) == KMT(cur_keys[..cur_idx+1], cur_values[..cur_idx+1]);
                weightSlack := (weightSlack + WeightMessage(child.values[childIdx]) as uint64) - WeightMessage(m) as uint64;
                cur_idx := cur_idx + 1;
                parentIdx := parentIdx + 1;
                childIdx := childIdx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
              } else {
                cur_keys[cur_idx] := parent.keys[parentIdx];
                cur_values[cur_idx] := child.values[childIdx];

                newParent_keys[newParent_idx] := parent.keys[parentIdx];
                newParent_values[newParent_idx] := parent.values[parentIdx];

                assert append(KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), parent.keys[parentIdx], child.values[childIdx]) == KMT(cur_keys[..cur_idx+1], cur_values[..cur_idx+1]);
                assert append(KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), parent.keys[parentIdx], parent.values[parentIdx]) == KMT(newParent_keys[..newParent_idx+1], newParent_values[..newParent_idx+1]);

                newParent_idx := newParent_idx + 1;
                cur_idx := cur_idx + 1;
                parentIdx := parentIdx + 1;
                childIdx := childIdx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
              }
            }
          } else if c < 0 {
            cur_keys[cur_idx] := child.keys[childIdx];
            cur_values[cur_idx] := child.values[childIdx];
            assert append(KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), child.keys[childIdx], child.values[childIdx]) == KMT(cur_keys[..cur_idx+1], cur_values[..cur_idx+1]);
            childIdx := childIdx + 1;
            cur_idx := cur_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
          } else {
            var w := WeightKey(parent.keys[parentIdx]) as uint64 + WeightMessage(parent.values[parentIdx]) as uint64;
            if w <= weightSlack {
              cur_keys[cur_idx] := parent.keys[parentIdx];
              cur_values[cur_idx] := parent.values[parentIdx];
              assert append(KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), parent.keys[parentIdx], parent.values[parentIdx]) == KMT(cur_keys[..cur_idx+1], cur_values[..cur_idx+1]);
              weightSlack := weightSlack - w;
              parentIdx := parentIdx + 1;
              cur_idx := cur_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
            } else {
              newParent_keys[newParent_idx] := parent.keys[parentIdx];
              newParent_values[newParent_idx] := parent.values[parentIdx];

              assert append(KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), parent.keys[parentIdx], parent.values[parentIdx]) == KMT(newParent_keys[..newParent_idx+1], newParent_values[..newParent_idx+1]);

              parentIdx := parentIdx + 1;
              newParent_idx := newParent_idx + 1;
assert partialFlushIterate(parent, children, pivots, parentIdx as int, childrenIdx as int, childIdx as int, acc, KMT(cur_keys[..cur_idx], cur_values[..cur_idx]), KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]), weightSlack as int) == partialFlush(parent, children, pivots);
            }
          }
        }
      }
    }

    newChildren := acc;
    newParent := KMT(newParent_keys[..newParent_idx], newParent_values[..newParent_idx]);
  }
}
