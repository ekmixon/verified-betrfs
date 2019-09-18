include "ImplFlush.i.dfy"
include "ImplGrow.i.dfy"
include "ImplSplit.i.dfy"
include "ImplLeaf.i.dfy"
include "ImplEvict.i.dfy"
include "ImplModelFlushPolicy.i.dfy"

module ImplFlushPolicy {
  import opened Impl
  import opened ImplIO
  import opened ImplCache
  import opened ImplFlush
  import opened ImplGrow
  import opened ImplSplit
  import opened ImplLeaf
  import opened ImplEvict
  import ImplModelFlushPolicy
  import opened ImplState
  import opened MutableBucket

  import opened Sequences

  import opened Bounds
  import opened NativeTypes
  import opened BucketsLib
  import opened BucketWeights

  method biggestSlot(buckets: seq<MutBucket>) returns (res : (uint64, uint64))
  requires forall i | 0 <= i < |buckets| :: buckets[i].Inv()
  requires ImplModelFlushPolicy.biggestSlot.requires(MutBucket.ISeq(buckets))
  ensures res == ImplModelFlushPolicy.biggestSlot(old(MutBucket.ISeq(buckets)))
  {
    // It's in the reads clause of ISeq:
    MutBucket.reveal_ReprSeq();

    WeightBucketLeBucketList(MutBucket.ISeq(buckets), 0);
    var j := 1;
    var bestIdx := 0;
    var bestWeight := buckets[0].Weight;
    while j < |buckets| as uint64
    invariant ImplModelFlushPolicy.biggestSlotIterate.requires(MutBucket.ISeq(buckets), j, bestIdx, bestWeight)
    invariant ImplModelFlushPolicy.biggestSlotIterate(MutBucket.ISeq(buckets), j, bestIdx, bestWeight) == ImplModelFlushPolicy.biggestSlot(MutBucket.ISeq(buckets))
    {
      WeightBucketLeBucketList(MutBucket.ISeq(buckets), j as int);
      var w := buckets[j].Weight;
      if w > bestWeight {
        bestIdx := j;
        bestWeight := w;
      }
      j := j + 1;
    }

    return (bestIdx, bestWeight);
  }

  function method TotalCacheSize(s: ImplVariables) : (res : int)
  reads s, s.cache, s.cache.Repr
  requires s.cache.Inv()
  {
    s.cache.Count() as int + |s.outstandingBlockReads|
  }

  method getActionToSplit(k: ImplConstants, s: ImplVariables, stack: seq<BT.G.Reference>, slots: seq<uint64>, i: uint64) returns (action : ImplModelFlushPolicy.Action)
  requires 0 <= i as int < |stack|
  requires Inv(k, s)
  requires ImplModelFlushPolicy.ValidStackSlots(Ic(k), s.I(), stack, slots)
  ensures action == ImplModelFlushPolicy.getActionToSplit(Ic(k), s.I(), stack, slots, i)
  {
    ImplModelFlushPolicy.reveal_getActionToSplit();

    if i == 0 {
      // Can't split root until we grow it.
      if TotalCacheSize(s) <= MaxCacheSize() - 1 {
        action := ImplModelFlushPolicy.ActionGrow;
      } else {
        action := ImplModelFlushPolicy.ActionEvict;
      }
    } else {
      var nodePrev := s.cache.GetOpt(stack[i-1]);
      if |nodePrev.value.children.value| as uint64 < MaxNumChildren() as uint64 {
        var nodeThis := s.cache.GetOpt(stack[i]);
        if |nodeThis.value.buckets| as uint64 == 1 {
          action := ImplModelFlushPolicy.ActionRepivot(stack[i]);
        } else {
          if TotalCacheSize(s) <= MaxCacheSize() - 2 {
            action := ImplModelFlushPolicy.ActionSplit(stack[i-1], slots[i-1]);
          } else {
            action := ImplModelFlushPolicy.ActionEvict;
          }
        }
      } else {
        action := getActionToSplit(k, s, stack, slots, i-1);
      }
    }
  }

  method getActionToFlush(k: ImplConstants, s: ImplVariables, stack: seq<BT.G.Reference>, slots: seq<uint64>) returns (action : ImplModelFlushPolicy.Action)
  requires |stack| <= 40
  requires Inv(k, s)
  requires ImplModelFlushPolicy.ValidStackSlots(Ic(k), s.I(), stack, slots)
  decreases 0x1_0000_0000_0000_0000 - |stack|
  modifies s.Repr()
  ensures WellUpdated(s)
  ensures s.ready
  ensures (s.I(), action) == ImplModelFlushPolicy.getActionToFlush(Ic(k), old(s.I()), stack, slots)
  {
    ImplModelFlushPolicy.reveal_getActionToFlush();

    if |stack| as uint64 == 40 {
      action := ImplModelFlushPolicy.ActionFail;
    } else {
      var ref := stack[|stack| as uint64 - 1];
      var nodeOpt := s.cache.GetOpt(ref);
      var node := nodeOpt.value;
      MutBucket.reveal_ReprSeq();
      if node.children.None? || |node.buckets| == MaxNumChildren() {
        action := getActionToSplit(k, s, stack, slots, |stack| as uint64 - 1);
      } else {
        var bs := biggestSlot(node.buckets);
        var (slot, slotWeight) := bs;
        //if slotWeight >= FlushTriggerWeight() as uint64 then (
        if |node.buckets| < 8 {
          var childref := node.children.value[slot];
          var childOpt := s.cache.GetOpt(childref);
          if childOpt.Some? {
            s.cache.LemmaNodeReprLeRepr(childref);
            var child := childOpt.value;
            assume MutBucket.ReprSeq(child.buckets) <= child.Repr;
            //assert forall i | 0 <= i < |child.buckets| ensures child.buckets[i].Repr !! s.lru.Repr;
            assert forall i | 0 <= i < |child.buckets| :: child.buckets[i].Inv();
            s.lru.Use(childref);
            assert forall i | 0 <= i < |child.buckets| :: child.buckets[i].Inv();
            LruModel.LruUse(old(s.lru.Queue), childref);

            var childTotalWeight: uint64 := MutBucket.computeWeightOfSeq(child.buckets);

            if childTotalWeight + FlushTriggerWeight() as uint64 <= MaxTotalBucketWeight() as uint64 {
              if TotalCacheSize(s) <= MaxCacheSize() - 1 {
                action := ImplModelFlushPolicy.ActionFlush(ref, slot);
              } else {
                action := ImplModelFlushPolicy.ActionEvict;
              }
            } else {
              action := getActionToFlush(k, s, stack + [childref], slots + [slot]);
            }
          } else {
            if TotalCacheSize(s) <= MaxCacheSize() - 1 {
              action := ImplModelFlushPolicy.ActionPageIn(childref);
            } else {
              action := ImplModelFlushPolicy.ActionEvict;
            }
          }
        } else {
          action := getActionToSplit(k, s, stack, slots, |stack| as uint64 - 1);
        }
      }
    }
  }

  method runFlushPolicy(k: ImplConstants, s: ImplVariables, io: DiskIOHandler)
  requires Inv(k, s)
  requires io.initialized()
  requires s.ready
  requires BT.G.Root() in s.cache.I()
  requires io !in s.Repr()
  modifies io
  modifies s.Repr()
  ensures WellUpdated(s)
  ensures s.ready
  ensures ImplModelFlushPolicy.runFlushPolicy(Ic(k), old(s.I()), old(IIO(io)), s.I(), IIO(io))
  {
    ImplModelFlushPolicy.reveal_runFlushPolicy();

    LruModel.LruUse(s.lru.Queue, BT.G.Root());
    s.lru.Use(BT.G.Root());
    assert IM.IVars(s.I()) == old(IM.IVars(s.I()));

    ImplModelFlushPolicy.getActionToFlushValidAction(Ic(k), s.I(), [BT.G.Root()], []);
    var action := getActionToFlush(k, s, [BT.G.Root()], []);

    match action {
      case ActionPageIn(ref) => {
        PageInReq(k, s, io, ref);
      }
      case ActionSplit(parentref, slot) => {
        var parent := s.cache.GetOpt(parentref);
        doSplit(k, s, parentref, parent.value.children.value[slot], slot as int);
      }
      case ActionRepivot(ref) => {
        var node := s.cache.GetOpt(ref);
        repivotLeaf(k, s, ref, node.value);
      }
      case ActionFlush(parentref, slot) => {
        var parent := s.cache.GetOpt(parentref);
        var childref := parent.value.children.value[slot];
        var child := s.cache.GetOpt(childref);
        flush(k, s, parentref, slot as int, 
            parent.value.children.value[slot],
            child.value);
      }
      case ActionGrow => {
        grow(k, s);
      }
      case ActionEvict => {
        EvictOrDealloc(k, s, io);
      }
      case ActionFail => {
        print "ActionFail\n";
      }
    }
  }
}
