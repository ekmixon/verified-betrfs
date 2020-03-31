include "DeallocModel.i.dfy"
include "SyncModel.i.dfy"

module EvictModel {
  import opened StateModel
  import opened IOModel
  import opened BookkeepingModel
  import opened DeallocModel
  import opened SyncModel
  import opened InterpretationDiskOps
  import opened ViewOp

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets

  import opened Bounds

  import opened NativeTypes

  import LruModel

  function Evict(k: Constants, s: BCVariables, ref: BT.G.Reference) : (s' : BCVariables)
  requires s.Ready?
  requires ref in s.cache
  {
    s.(cache := MapRemove1(s.cache, ref))
     .(lru := LruModel.Remove(s.lru, ref))
  }

  predicate NeedToWrite(s: BCVariables, ref: BT.G.Reference)
  requires s.Ready?
  {
    || (
      && ref in s.ephemeralIndirectionTable.graph
      && ref !in s.ephemeralIndirectionTable.locs
    )
    || (
      && s.frozenIndirectionTable.Some?
      && ref in s.frozenIndirectionTable.value.graph
      && ref !in s.frozenIndirectionTable.value.locs
    )
  }

  predicate CanEvict(s: BCVariables, ref: BT.G.Reference)
  requires s.Ready?
  requires ref in s.ephemeralIndirectionTable.graph ==>
      ref in s.ephemeralIndirectionTable.locs
  {
    && (ref in s.ephemeralIndirectionTable.graph ==>
      && BC.OutstandingWrite(ref, s.ephemeralIndirectionTable.locs[ref]) !in s.outstandingBlockWrites.Values
    )
  }

  predicate EvictOrDealloc(k: Constants, s: BCVariables, io: IO,
      s': BCVariables, io': IO)
  requires BCInv(k, s)
  requires s.Ready?
  requires io.IOInit?
  requires |s.cache| > 0
  {
    var ref := FindDeallocable(s);
    FindDeallocableCorrect(s);

    if ref.Some? then (
      // If we can deallocate something, just do that.
      (s', io') == Dealloc(k, s, io, ref.value)
    ) else (
      var ref := LruModel.Next(s.lru);
      if ref == BT.G.Root() then (
        && s' == s
        && io' == io
      ) else if NeedToWrite(s, ref) then (
        if && s.outstandingIndirectionTableWrite.None? then (
          && TryToWriteBlock(k, s, io, ref, s', io')
        ) else (
          && s' == s
          && io' == io
        )
      ) else if CanEvict(s, ref) then (
        && s' == Evict(k, s, ref)
        && io' == io
      ) else (
        && s' == s
        && io' == io
      )
    )
  }

  lemma EvictOrDeallocCorrect(k: Constants, s: BCVariables, io: IO,
      s': BCVariables, io': IO)
  requires EvictOrDealloc.requires(k, s, io, s', io')
  requires EvictOrDealloc(k, s, io, s', io')
  ensures WFBCVars(s')
  ensures ValidDiskOp(diskOp(io'))
  ensures
    || BBC.Next(Ik(k).bc, IBlockCache(s), IBlockCache(s'), IDiskOp(diskOp(io')).bdop, StatesInternalOp)
    || BBC.Next(Ik(k).bc, IBlockCache(s), IBlockCache(s'), IDiskOp(diskOp(io')).bdop, AdvanceOp(UI.NoOp, false))
  {
    var ref := FindDeallocable(s);
    FindDeallocableCorrect(s);

    if ref.Some? {
      DeallocCorrect(k, s, io, ref.value);
    } else {
      var ref := LruModel.Next(s.lru);
      if ref == BT.G.Root() {
        assert noop(k, IBlockCache(s), IBlockCache(s));
      } else if (NeedToWrite(s, ref)) {
        if s.outstandingIndirectionTableWrite.None? {
          TryToWriteBlockCorrect(k, s, io, ref, s', io');
        } else {
          assert noop(k, IBlockCache(s), IBlockCache(s));
        }
      } else if CanEvict(s, ref) {
        LruModel.LruRemove(s.lru, ref);
        assert WFBCVars(s');
        assert stepsBC(k, IBlockCache(s), IBlockCache(s'), StatesInternalOp, io', BC.EvictStep(ref));
      } else {
        assert noop(k, IBlockCache(s), IBlockCache(s));
      }
    }
  }

  predicate {:opaque} PageInNodeReqOrMakeRoom(
      k: Constants, s: BCVariables, io: IO, ref: BT.G.Reference,
      s': BCVariables, io': IO)
  requires BCInv(k, s)
  requires s.Ready?
  requires io.IOInit?
  requires ref in s.ephemeralIndirectionTable.graph
  requires ref !in s.cache
  {
    if TotalCacheSize(s) <= MaxCacheSize() - 1 then (
      (s', io') == PageInNodeReq(k, s, io, ref)
    ) else if |s.cache| > 0 then (
      EvictOrDealloc(k, s, io, s', io')
    ) else (
      s' == s && io' == io
    )
  }

  lemma PageInNodeReqOrMakeRoomCorrect(
      k: Constants, s: BCVariables, io: IO, ref: BT.G.Reference,
      s': BCVariables, io': IO)
  requires PageInNodeReqOrMakeRoom.requires(k, s, io, ref, s', io')
  requires PageInNodeReqOrMakeRoom(k, s, io, ref, s', io')
  ensures WFBCVars(s')
  ensures ValidDiskOp(diskOp(io'))
  ensures
    || BBC.Next(Ik(k).bc, IBlockCache(s), IBlockCache(s'), IDiskOp(diskOp(io')).bdop, StatesInternalOp)
    || BBC.Next(Ik(k).bc, IBlockCache(s), IBlockCache(s'), IDiskOp(diskOp(io')).bdop, AdvanceOp(UI.NoOp, false))
  {
    reveal_PageInNodeReqOrMakeRoom();

    if TotalCacheSize(s) <= MaxCacheSize() - 1 {
      PageInNodeReqCorrect(k, s, io, ref);
    } else if |s.cache| > 0 {
      EvictOrDeallocCorrect(k, s, io, s', io');
    } else {
      assert noop(k, IBlockCache(s), IBlockCache(s));
    }
  }
}
