include "ImplModelCache.i.dfy"

module ImplModelDealloc { 
  import opened ImplModel
  import opened ImplModelIO
  import opened ImplModelCache
  import opened Bounds

  import opened Options
  import opened Maps
  import opened Sequences
  import opened Sets

  import opened NativeTypes

  import LruModel

  predicate deallocable(s: Variables, ref: BT.G.Reference)
  {
    && s.Ready?
    && ref in IIndirectionTable(s.ephemeralIndirectionTable).graph
    && ref != BT.G.Root()
    && forall r | r in IIndirectionTable(s.ephemeralIndirectionTable).graph :: ref !in IIndirectionTable(s.ephemeralIndirectionTable).graph[r]
  }

  function {:opaque} Dealloc(k: Constants, s: Variables, io: IO, ref: BT.G.Reference)
  : (res : (Variables, IO))
  requires Inv(k, s)
  requires io.IOInit?
  requires deallocable(s, ref)
  {
    if (
      && s.frozenIndirectionTable.Some?
      && ref in s.frozenIndirectionTable.value.contents
      && var entry := s.frozenIndirectionTable.value.contents[ref];
      && var (loc, _) := entry;
      && loc.None?
    ) then (
      (s, io)
    ) else if !BC.OutstandingBlockReadsDoesNotHaveRef(s.outstandingBlockReads, ref) then (
      (s, io)
    ) else (
      var (eph, oldEntry) := MutableMapModel.RemoveAndGet(s.ephemeralIndirectionTable, ref);

      lemmaIndirectionTableLocIndexValid(k, s, ref);

      var blockAllocator' := if oldEntry.Some? && oldEntry.value.0.Some?
        then ImplModelBlockAllocator.MarkFreeEphemeral(s.blockAllocator, oldEntry.value.0.value.addr as int / BlockSize())
        else s.blockAllocator;

      var s' := s
        .(ephemeralIndirectionTable := eph)
        .(cache := MapRemove(s.cache, {ref}))
        .(lru := LruModel.Remove(s.lru, ref))
        .(blockAllocator := blockAllocator');
      (s', io)
    )
  }

  lemma DeallocCorrect(k: Constants, s: Variables, io: IO, ref: BT.G.Reference)
  requires Inv(k, s)
  requires io.IOInit?
  requires deallocable(s, ref)
  ensures var (s', io') := Dealloc(k, s, io, ref);
      && WFVars(s')
      &&  M.Next(Ik(k), IVars(s), IVars(s'), UI.NoOp, diskOp(io'))
  {
    reveal_Dealloc();
    var (s', io') := Dealloc(k, s, io, ref);

    LruModel.LruRemove(s.lru, ref);

    if (
      && s.frozenIndirectionTable.Some?
      && ref in s.frozenIndirectionTable.value.contents
      && var entry := s.frozenIndirectionTable.value.contents[ref];
      && var (loc, _) := entry;
      && loc.None?
    ) {
      assert noop(k, IVars(s), IVars(s'));
      return;
    }

    if !BC.OutstandingBlockReadsDoesNotHaveRef(s.outstandingBlockReads, ref) {
      assert noop(k, IVars(s), IVars(s'));
      return;
    }

    lemmaIndirectionTableLocIndexValid(k, s, ref);

    var (eph, oldEntry) := MutableMapModel.RemoveAndGet(s.ephemeralIndirectionTable, ref);

    var blockAllocator' := if oldEntry.Some? && oldEntry.value.0.Some?
      then ImplModelBlockAllocator.MarkFreeEphemeral(s.blockAllocator, oldEntry.value.0.value.addr as int / BlockSize())
      else s.blockAllocator;

    freeIndirectionTableLocCorrect(k, s, s', ref,
      if oldEntry.Some? && oldEntry.value.0.Some?
      then Some(oldEntry.value.0.value.addr as int / BlockSize())
      else None);
    reveal_ConsistentBitmap();

    assert WFVars(s');

    var iDiskOp := M.IDiskOp(diskOp(io));
    assert BC.Unalloc(Ik(k), IVars(s), IVars(s'), iDiskOp, ref);
    assert BBC.BlockCacheMove(Ik(k), IVars(s), IVars(s'), UI.NoOp, iDiskOp, BC.UnallocStep(ref));
    assert stepsBC(k, IVars(s), IVars(s'), UI.NoOp, io, BC.UnallocStep(ref));
    // assert M.NextStep(Ik(k), IVars(s), IVars(s'), UI.NoOp, io.diskOp(), M.Step(BBC.BlockCacheMoveStep(BC.UnallocStep(ref))));
  }

  function FindDeallocableIterate(s: Variables, ephemeralRefs: seq<BT.G.Reference>, i: uint64)
  : (ref: Option<Reference>)
  requires 0 <= i as int <= |ephemeralRefs|
  requires |ephemeralRefs| < 0x1_0000_0000_0000_0000;
  decreases 0x1_0000_0000_0000_0000 - i as int
  {
    if i == |ephemeralRefs| as uint64 then (
      None
    ) else (
      var ref := ephemeralRefs[i];
      var isDeallocable := deallocable(s, ref);
      if isDeallocable then (
        Some(ref)
      ) else (
        FindDeallocableIterate(s, ephemeralRefs, i + 1)
      )
    )
  }

  function {:opaque} FindDeallocable(s: Variables)
  : (ref: Option<Reference>)
  requires WFVars(s)
  requires s.Ready?
  {
    // TODO once we have an lba freelist, rewrite this to avoid extracting a `map` from `s.ephemeralIndirectionTable`
    var ephemeralRefs := setToSeq(s.ephemeralIndirectionTable.contents.Keys);

    assume |ephemeralRefs| < 0x1_0000_0000_0000_0000;

    FindDeallocableIterate(s, ephemeralRefs, 0)
  }

  lemma FindDeallocableIterateCorrect(s: Variables, ephemeralRefs: seq<BT.G.Reference>, i: uint64)
  requires 0 <= i as int <= |ephemeralRefs|
  requires |ephemeralRefs| < 0x1_0000_0000_0000_0000;
  requires s.Ready?
  requires ephemeralRefs == setToSeq(s.ephemeralIndirectionTable.contents.Keys)
  requires forall k : nat | k < i as nat :: (
        && ephemeralRefs[k] in IIndirectionTable(s.ephemeralIndirectionTable).graph
        && !deallocable(s, ephemeralRefs[k]))
  ensures var ref := FindDeallocableIterate(s, ephemeralRefs, i);
      && (ref.Some? ==> ref.value in IIndirectionTable(s.ephemeralIndirectionTable).graph)
      && (ref.Some? ==> deallocable(s, ref.value))
      && (ref.None? ==> forall r | r in IIndirectionTable(s.ephemeralIndirectionTable).graph :: !deallocable(s, r))
  decreases 0x1_0000_0000_0000_0000 - i as int
  {
    if i == |ephemeralRefs| as uint64 {
      assert forall r | r in IIndirectionTable(s.ephemeralIndirectionTable).graph :: !deallocable(s, r);
    } else {
      var ref := ephemeralRefs[i];
      var isDeallocable := deallocable(s, ref);
      if isDeallocable {
      } else {
        FindDeallocableIterateCorrect(s, ephemeralRefs, i + 1);
      }
    }
  }

  lemma FindDeallocableCorrect(s: Variables)
  requires WFVars(s)
  requires s.Ready?
  ensures var ref := FindDeallocable(s);
      && (ref.Some? ==> ref.value in IIndirectionTable(s.ephemeralIndirectionTable).graph)
      && (ref.Some? ==> deallocable(s, ref.value))
      && (ref.None? ==> forall r | r in IIndirectionTable(s.ephemeralIndirectionTable).graph :: !deallocable(s, r))
  {
    reveal_FindDeallocable();
    var ephemeralRefs := setToSeq(s.ephemeralIndirectionTable.contents.Keys);
    assume |ephemeralRefs| < 0x1_0000_0000_0000_0000;
    FindDeallocableIterateCorrect(s, ephemeralRefs, 0);
  }

}
