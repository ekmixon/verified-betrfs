include "Journal.i.dfy"
include "JournalInterp.i.dfy"
include "Betree.i.dfy"
include "CacheIfc.i.dfy"

// TODO first prove that a Program with a simple-policy cache works?

// The "Program" is the complete model of the program state, with all of the components
// (Journal, Betree, Cache).
// It has an interface to a disk, but can't actually see inside the disk (that's for the IOSystem).

module ProgramMachineMod {
  import AllocationTableMod
  import AllocationTableMachineMod
  import BetreeMachineMod
  import JournalMachineMod
  import opened AllocationMod
  import opened DeferredWriteMapSpecMod
  import opened InterpMod
  import opened MessageMod
  import opened MsgSeqMod
  import opened Options
  import CacheIfc

  datatype Superblock = Superblock(
    serial: nat,
    journal: JournalMachineMod.Superblock,
    betree: BetreeMachineMod.Superblock)

  function parseSuperblock(b: UninterpretedDiskPage) : Option<Superblock>

  function marshalSuperblock(sb: Superblock) : (b: UninterpretedDiskPage)
    ensures parseSuperblock(b) == Some(sb)

  function SUPERBLOCK_ADDRESS(): CU
  {
    CU(0, 0)
  }

  datatype Variables = Variables(
    stableSuperblock: Superblock,
    cache: CacheIfc.Variables,
    journal: JournalMachineMod.Variables,
    betree: BetreeMachineMod.Variables,
    inFlightSuperblock: Option<Superblock>
    )
  {
    predicate WF() {
      true
    }
  }

  predicate Init(s: Variables)
  {
    false
  }

  predicate Recover(s: Variables, s': Variables)
  {
    false
  }

  predicate Query(s: Variables, s': Variables, k: Key, v: Value, sk: BetreeMachineMod.Skolem)
  {
    && s.WF()
    && s'.journal == s.journal
    && BetreeMachineMod.Query(s.betree, s'.betree, s.cache, k, v, sk)
    && s'.cache == s.cache  // no cache writes
  }

  predicate Put(s: Variables, s': Variables, k: Key, v: Value, sk: BetreeMachineMod.Skolem)
  {
    && s.WF()
    && JournalMachineMod.Append(s.journal, s'.journal, MessagePut(k, v))
    && BetreeMachineMod.Put(s.betree, s'.betree, k, v, sk)
    && s'.cache == s.cache  // no cache writes
  }

  // TODO move to Sets.i
  predicate SetsMutuallyDisjoint<T>(sets: seq<set<T>>) {
    forall i, j | 0<=i<|sets| && 0<=j<|sets| && i!=j :: sets[i] !! sets[j]
  }

  predicate AllocsDisjoint(s: Variables)
  {
    SetsMutuallyDisjoint([
      {SUPERBLOCK_ADDRESS().au},
      JournalMachineMod.Alloc(s.journal),
      BetreeMachineMod.Alloc(s.betree)
      ])
  }

  predicate WritesOkay(cacheOps: CacheIfc.Ops, alloc: set<AU>)
  {
    forall op | op in cacheOps :: op.cu.au in alloc
  }
  
  // How do the subsystems negotiate for more alloc?
  // They're always free to write into their existing alloc -- Journal is going to want
  // to do that all the time, maintaining its own internal allocation tracker, to avoid
  // writing out new allocation bitmap summaries. In principle, Journal can ask to grow
  // its alloc.
  // Betree, on the other hand: it's gonna alloc all the darn time. We need to make
  // sure that when it does, the new AUs are disjoint with our alloc (the superblocks)
  // and the Journal's existing alloc.
  // So how do we record each system's current alloc?
  // Do subsystems "know" their current alloc? I guess they do, ghostily --
  // when BeTree.B+tree links a new AU into an in-progress B+tree, it claims another AU,
  // and updates its ghost alloc -- oh, that's just a function over all reachable state on
  // disk!
  // At sb time, that's the alloc it publishes to a marshalled alloc record on the disk.
  // (Do we need to do that here, if the physical thing isn't gonna do that? Hrm.)
  // So at Journal-alloc time, we just test against the betree's ghost alloc?
  //
  // The real system would have ghost views of subsystem allocs, a single physical alloc bitmap,
  // and an invariant that the physical alloc bitmap is the union of the ghosty ones.
  // NO that's not right! They need separate allocs so they can record them precisely (and
  // separately, since they update out of sync), so that crashes correctly reflect what has
  // changed.
  // Well, maybe they don't need to be recorded separately. Maybe it's okay if the sb always
  // points to a single alloc that's an precise union of the underlying subsystems.
  // When journal wants to grow, it allocates AU from the central allocator.
  // When Betree wants to grow, it allocates AU from the central allocator.
  // These only affect in-memory state.
  // When sb commits, it includes the state of ... uh oh, which betree? Ephemeral or frozen?
  // so I guess we need to track them separately, so that we can record the frozen's allocation
  // to the sb, while still tracking the ephemeral alloc in memory (for next freeze).
  // At that point we COULD write frozen-alloc UNION journal-alloc to the sb, but is that
  // a false economy? I guess not -- we have to coordinate across subsystems, and they share
  // an invariant that makes them reduntant anyway. Hrmm.

  predicate JournalInternal(s: Variables, s': Variables, cacheOps: CacheIfc.Ops, sk: JournalMachineMod.Skolem)
  {
    && s.WF()
    && JournalMachineMod.Internal(s.journal, s'.journal, s.cache, cacheOps, sk)
    && s'.betree == s.betree
    && CacheIfc.ApplyWrites(s.cache, s'.cache, cacheOps)
    && WritesOkay(cacheOps, JournalMachineMod.Alloc(s'.journal))
    && AllocsDisjoint(s')
  }

  predicate BetreeInternal(s: Variables, s': Variables, cacheOps: CacheIfc.Ops, sk: BetreeMachineMod.Skolem)
  {
    && s.WF()
    && s'.journal == s.journal
    && BetreeMachineMod.Internal(s.betree, s'.betree, s.cache, cacheOps, sk)
    && CacheIfc.ApplyWrites(s.cache, s'.cache, cacheOps)
  }

  predicate ReqSync(s: Variables, s': Variables, syncReqId: SyncReqId)
  {
    && s.WF()
    && JournalMachineMod.ReqSync(s.journal, s'.journal, syncReqId)
    && s'.betree == s.betree
  }
 
  predicate CompleteSync(s: Variables, s': Variables, syncReqId: SyncReqId)
  {
    && s.WF()
    && JournalMachineMod.CompleteSync(s.journal, s'.journal, syncReqId)
    && s'.betree == s.betree
  }

  // At some lower layer, where we duplicate the superblock to protect against disk sector
  // corruption, the Commit sequence looks like this:
  //   write sb0
  //   complete: ensure sb0 has hit the disk successfully before writing sb1, which might tear
  //   write sb1
  //   complete: Tell subsystems the commit is done. Can't acknowledge a sync dependent on this sb
  //     until sb1 commits, lest sb0 get lost before sb1 is successfully written and the "synced"
  //     data gets lost
  // At this layer, we abbreviate that to "write sb" and "write sb complete".
  predicate CommitStart(s: Variables, s': Variables, seqBoundary: LSN)
  {
    && s.inFlightSuperblock.None?
    && s'.inFlightSuperblock.Some?
    && var sb := s'.inFlightSuperblock.value;
    && (exists alloc :: JournalMachineMod.CommitStart(s.journal, s'.journal, s.cache, sb.journal, seqBoundary, alloc))
    && BetreeMachineMod.CommitStart(s.betree, s'.betree, s.cache, sb.betree, seqBoundary)
//    && sb.serial == s.stableSuperblock.serial + 1 // I think this isn't needed until duplicate-superblock code
    && CacheIfc.ApplyWrites(s.cache, s'.cache, [CacheIfc.Write(SUPERBLOCK_ADDRESS(), marshalSuperblock(sb))])
  }

  predicate CommitComplete(s: Variables, s': Variables)
  {
    && s.inFlightSuperblock.Some?
    && CacheIfc.IsClean(s.cache, SUPERBLOCK_ADDRESS())

    && var sb := s.inFlightSuperblock.value;
    && s'.stableSuperblock == sb
    && JournalMachineMod.CommitComplete(s.journal, s'.journal, s.cache, sb.journal)
    && BetreeMachineMod.CommitComplete(s.betree, s'.betree, s.cache, sb.betree)
    && s'.cache == s.cache
    && s'.inFlightSuperblock.None?  // Yay! Done writing.
  }

  datatype Step =
    | RecoverStep()
    | QueryStep(k: Key, v: Value, bsk: BetreeMachineMod.Skolem)
    | PutStep(k: Key, v: Value, bsk: BetreeMachineMod.Skolem)
    | JournalInternalStep(jsk: JournalMachineMod.Skolem)
    | BetreeInternalStep(BetreeMachineMod.Skolem)
    | ReqSyncStep(syncReqId: SyncReqId)
    | CompleteSyncStep(syncReqId: SyncReqId)
    | CommitStartStep(seqBoundary: LSN)
    | CommitCompleteStep()
    
  predicate NextStep(s: Variables, s': Variables, cacheOps: CacheIfc.Ops, step: Step) {
    && match step {
      case RecoverStep() => Recover(s, s')
      case QueryStep(k, v, sk) => Query(s, s', k, v, sk)
      case PutStep(k, v, sk) => Put(s, s', k, v, sk)
      case JournalInternalStep(sk) => JournalInternal(s, s', cacheOps, sk)
      case BetreeInternalStep(sk) => BetreeInternal(s, s', cacheOps, sk)
      case ReqSyncStep(syncReqId) => ReqSync(s, s', syncReqId)
      case CompleteSyncStep(syncReqId) => CompleteSync(s, s', syncReqId)
      case CommitStartStep(seqBoundary) => CommitStart(s, s', seqBoundary)
      case CommitCompleteStep() => CommitComplete(s, s')
    }
  }

  predicate Next(s: Variables, s': Variables) {
    exists cacheOps,step ::
      && NextStep(s, s', cacheOps, step)
      //&& AllocationTableMachineMod.Disjoint(s'.journal.allocation, s'.betree.allocation)
  }
}

module ProgramInterpMod {
  import opened Options
  import opened MessageMod
  import opened InterpMod
  import opened AllocationMod
  import opened MsgSeqMod
  import AllocationTableMod
  //import JournalMod
  import BetreeInterpMod
  import JournalInterpMod
  import opened ProgramMachineMod

  function ISuperblock(dv: DiskView) : Option<Superblock>
  {
    var bcu0 := CU(0, 0);
    var bcu1 := CU(0, 1);
    if bcu0 in dv && bcu1 in dv
    then
      var sb0 := parseSuperblock(dv[bcu0]);
      var sb1 := parseSuperblock(dv[bcu1]);
      if sb0.Some? && sb1.Some? && sb0.value.serial == sb1.value.serial
      then
        sb0
      else
        None  // Stop! Recovery should ... copy the newer one?
          // well I think I() of that should be the newer one, but we should just
          // not be allowed to write anything until we've got them back in sync.
    else
      None  // silly expression: DV has holes in it
  }

  function ISuperblockReads(dv: DiskView) : seq<AU>
  {
    [ SUPERBLOCK_ADDRESS().au ]
  }
 
  // Program will have a runtime view of what (ghost) alloc each subsystem thinks it's using,
  // and use that to filter the dvs here.
  // Those ghost views will invariantly match the IReads functions of the actual disk -- that is,
  // * if we were to recover after a crash (when the physical alloc is empty), we'd fault in
  // an alloc table for the subsystem.
  // * that alloc table would invariantly match IReads.
  //
  // IM == Interpret as InterpMod
  // Oh man we're gonna have a family of IReads predicates that capture the
  // heapiness of DiskView, aren't we?
  function IM(dv: DiskView) : (i:Interp)
    ensures i.WF()
  {
    var sb := ISuperblock(dv);
    if sb.Some?
    then
      var betreeInterp := BetreeInterpMod.IM(dv, sb.value.betree);
      var journalMsgSeq := JournalInterpMod.IM(dv, sb.value.journal);
      if journalMsgSeq.Some? && betreeInterp.seqEnd == journalMsgSeq.value.seqStart
      then
        Concat(betreeInterp, journalMsgSeq.value)
      else
        InterpMod.Empty()
    else
      InterpMod.Empty()
  }

  function IMReads(dv: DiskView) : seq<AU> {
    var sbreads := ISuperblockReads(dv);
    var sb := ISuperblock(dv);
    if sb.Some?
    then
      sbreads + JournalInterpMod.IReads(dv, sb.value.journal.core) + BetreeInterpMod.IReads(dv, sb.value.betree)
    else
      sbreads
  }

  function IReads(dv: DiskView) : seq<AU> {
    IMReads(dv)
  }

  lemma Framing(dv0: DiskView, dv1: DiskView)
    requires DiskViewsEquivalentForSet(dv0, dv1, IReads(dv0))
    ensures IM(dv0) == IM(dv1)
  {
    assert ISuperblock(dv0) == ISuperblock(dv1);
    var sb := ISuperblock(dv0);
    if sb.Some? {
      BetreeInterpMod.Framing(sb.value.betree, dv0, dv1);
      JournalInterpMod.Framing(sb.value.journal.core, dv0, dv1);
    }
  }
}

/*
Okay, so the magic is going to be that
- most of the time when we change a block in RAM we'll prove that it's
  not in use in any other view
  - that'll depend on an invariant between the allocation table
    and the IReads functions
  - And we'll need a proof that, if IReads doesn't change, I doesn't
    change, of course.
- when we write a non-superblock back to disk, we inherit that no-change
  property; the persistent view doesn't change because the thing
  we wrote back was dirty and hence outside of the IReads of the
  persistent view.
- when we update the superblock, we're creating a frozen view.
- when we write a superblock back, it's easy again, because the persistent
  view just vanishes, replaced by the frozen view.
  The vanishing old persistent view implicitly creates some free nodes,
  which can be detected because the available nodes are computed at
  runtime by reading the active AllocationTables, and one just became
  empty.
  (that is, the union of allocationTables will cover the IReads sets.)
*/
