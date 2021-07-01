// Copyright 2018-2021 VMware, Inc., Microsoft Inc., Carnegie Mellon University, ETH Zurich, and University of Washington
// SPDX-License-Identifier: BSD-2-Clause

include "../lib/Base/Sequences.i.dfy"
include "../lib/Base/Maps.i.dfy"
include "Spec.s.dfy"
include "MsgHistory.i.dfy"
include "IndirectionTable.i.dfy"
include "AllocationTable.i.dfy"
include "AllocationTableMachine.i.dfy"
include "../lib/Base/KeyType.s.dfy"

/*
Okay I think we need to just talk about DiskViews at this layer. Well, no, a cache that
always has CanRead true. We still need to negotiate disjoint write Ops.
At this layer, in the IOSystem machine, we'll need a model for how crashes replace the
cache contents.
This is all good; it's just an infinitely-big cache that never needs to evict.

At the next layer down, we'll talk about interactions betwixt the Cache and the Disk.
So the trick there will be showing that transitions obey constraints that require testing
pages that aren't in the cache. That is, we know some sufficient predicate on those
pages that lets us ghostily know that the transition is valid despite not being
able to evaluate it directly at runtime. Let's enumerate the affected transitions.
*/

// NB the journal needs a smaller-sized-write primitive. If we get asked to sync
// frequently, we don't want to burn an AU on every journal write. Maybe not even
// a CU. Hrmm.
module JournalMachineMod {
  import opened Options
  import opened Sequences
  import opened Maps
  import opened ValueMessage
  import opened KeyType
  import opened InterpMod
  import opened CrashTolerantMapSpecMod
  import opened MsgHistoryMod
  import opened DiskTypesMod
  import opened AllocationMod
  import AllocationTableMachineMod
  import CacheIfc

  datatype Superblock = Superblock(
    freshestCU: Option<CU>,
    boundaryLSN : LSN)

  // On-disk JournalRecords
  datatype JournalRecord = JournalRecord(
    messageSeq: MsgSeq,
    priorCU: Option<CU>   // linked list pointer
  )
  {
    predicate WF()
    {
      messageSeq.WF()
    }

    function priorSB(sb: Superblock) : Superblock
    {
      Superblock(priorCU, sb.boundaryLSN)
    }
  }

  datatype Variables = Variables(
    boundaryLSN: LSN,
      // The (exclusive) upper bound of LSNs reachable from the
      // last-known-committed superblock; earlier LSNs have already been
      // garbage-collected. (There may be leftover records with smaller LSNs in
      // a journal record, but the superblock says to ignore them.)
      // We need to track this value to disallow the Betree from moving backwards,
      // which would prevent us from recovering after a crash.

    persistentLSN: LSN,
      // The (exclusive) upper bound of LSNs known to be persistent on the on-disk journal.
      // We may need to track this value to ensure commit doesn't go backwards.
      // (maybe invariant-able)

    cleanLSN: LSN,
      // The (exclusive) upper bound of LSNs that could be made persistent with
      // a superblock write. They're covered by marshalled pages that are
      // "clean" (have been written back to the disk), but aren't yet linked to
      // the superblock. These pages aren't "durable" or "persistent", because if there
      // were a crash right now, they'd be unallocated garbage after the crash.

    marshalledLSN: LSN,
      // The (exclusive) upper bound of LSNs that have been marshalled into cache
      // blocks.

    unmarshalledTail: seq<KeyedMessage>,
      // The rest of the in-memory journal

    syncReqs: map<SyncReqId, LSN>,
      // The LSN each outstanding SyncRequest was created at. The sync request may be
      // completed when the corresponding LSN <= persistentLSN.

    lsnToCU: map<LSN, CU>
      // We imagine that the journal can keep track of the entire mapping from LSN to CUs.
      // That's not really how the impl will work; it'll maintain some sort of summary, and
      // we'll refine from the disk state to get this field.
  )
  {
    // A "public" method for Program to inquire where Journal begins
    function JournalBeginsLSNInclusive() : LSN { boundaryLSN }

    // The (exclusive) upper bound of LSNs that have been journaled (in this epoch;
    // after a crash we can lose LSNs that weren't made persistent).
    function unmarshalledLSN() : LSN
    {
      marshalledLSN + |unmarshalledTail|
    }

    predicate WF() {
      && boundaryLSN <= persistentLSN <= cleanLSN <= marshalledLSN
      && (forall lsn :: boundaryLSN <= lsn < marshalledLSN <==> lsn in lsnToCU)
    }
  }

  datatype InitSkolems = InitSkolems(rawJournalRec: UninterpretedDiskPage)

  function MkfsSuperblock() : Superblock
  {
    Superblock(None, 0)
  }

  predicate Init(v: Variables, sb: Superblock, cacheIfc: CacheIfc.Variables, sk: InitSkolems)
  {
    // Can't proceed if there's a freshestCU but we can't read or parse it
    && sb.freshestCU.Some? ==> (
      && CacheIfc.Read(cacheIfc, sb.freshestCU.value, sk.rawJournalRec)
      && parse(sk.rawJournalRec).Some?
      )

    // Figure out where journal ends
    && var lastLSN :=
      if sb.freshestCU.None?
      then
        sb.boundaryLSN
      else
        parse(sk.rawJournalRec).value.messageSeq.seqEnd;

    && v.boundaryLSN == sb.boundaryLSN == 0
    && v.persistentLSN == v.cleanLSN == v.marshalledLSN == lastLSN == 0
    && v.unmarshalledTail == []
    && v.syncReqs == map[]
    && v.lsnToCU == map[] // TODO this fails WF! And will require cache to decode
  }

  // Recovery coordination
  predicate MessageSeqMatchesJournalAt(v: Variables, puts: MsgSeq)
  {
    true  // TODO THAT'S not likely to prove :)
  }

  // advances tailLSN forward by adding a message
  predicate Append(s: Variables, s': Variables, message: KeyedMessage)
  {
    && s' == s.(unmarshalledTail := s.unmarshalledTail + [message])
  }

  // TODO marshalling
  function parse(b: UninterpretedDiskPage) : (jr: Option<JournalRecord>)
    ensures jr.Some? ==> jr.value.WF()
  function marshal(jr: JournalRecord) : UninterpretedDiskPage

  function TailToMsgSeq(s: Variables) : (result : MsgSeq)
    ensures result.WF()
  {
    var start := s.marshalledLSN;
    var end := s.unmarshalledLSN();
    if start==end
    then MsgHistoryMod.Empty()
    else MsgSeq(map i: LSN | start <= i < end :: s.unmarshalledTail[i - start], start, end)
  }

  // lsnToCU reflects a correct reading of the sb chain, I guess?
  // TODO It's broken to be demanding that we actually can read this stuff out
  // of the cache; we really want this to be a ghosty property in the next
  // layer down. Not sure yet how to make that work.
  function {:opaque} MappingFor(cache: CacheIfc.Variables, sb: Superblock) : (lsnToCU: map<LSN, CU>)
  {
    var cr := ChainFrom(cache.dv, sb);
    if cr.chain.None?
    then map[]
    else
      var chain := cr.chain.value;
      map lsn:LSN | lsn in chain.locate ::
        var idx := chain.locate[lsn]; CUForChainIdx(chain, idx)
  }

  // advances marshalledLSN forward by marshalling a batch of messages into a dirty cache page
  predicate AdvanceMarshalled(s: Variables, s': Variables, cache: CacheIfc.Variables, cacheOps: CacheIfc.Ops, newCU: CU)
  {
    && s.WF()

    // newCU is an unused CU.
    // That could be because the impl has freshly reserved a chunk of CUs from the outer
    // program, or because it's using up a CU from a prior reserved chunk. The impl will
    // batch allocations so it can avoid needing to rewrite the marshaled allocation before
    // commiting a fresh superblock (on sync). Thus "unused" may be computed as "reserved
    // but known not to be in use in the current JournalChain".

    // Marshal and write the current record out into the cache. (This doesn't issue
    // a disk write, it just dirties a page.)
    && var priorCU := if s.marshalledLSN == s.boundaryLSN then None else Some(s.lsnToCU[s.marshalledLSN-1]);
    && var jr := JournalRecord(TailToMsgSeq(s), priorCU);
    && cacheOps == [CacheIfc.Write(newCU, marshal(jr))]

    // Record the changes to the marshalled, unmarshalled regions, and update the allocation.
    && s' == s.(
      // Open a new, empty record to absorb future journal Appends
      marshalledLSN := s.unmarshalledLSN(),
      unmarshalledTail := [],
      lsnToCU := s'.lsnToCU  // Tautology to defer this constraint to next predicate
      )
    // constructive: (map lsn:LSN | 0 <= lsn < s.unmarshalledLSN() :: if lsn < s.marshalledLSN then s.lsnToCU[lsn] else newCU),
    // predicate:
    && s'.lsnToCU == MappingFor(cache, Superblock(Some(newCU), s.boundaryLSN))
  }

  // advances cleanLSN forward by learning that the cache has written back a contiguous
  // sequence of pages starting at last cleanLSN
  predicate AdvanceClean(s: Variables, s': Variables, cache: CacheIfc.Variables, cacheOps: CacheIfc.Ops, newClean: nat)
  {
    && s.WF()
    && s.cleanLSN < newClean <= s.marshalledLSN
    && (forall lsn | s.cleanLSN <= lsn < newClean :: && CacheIfc.IsClean(cache, s.lsnToCU[lsn]))
    && s' == s.(cleanLSN := newClean)
    && cacheOps == []
  }

  predicate Reallocate(s: Variables, s': Variables)
  {
    // TODO Allocation isn't what we want, yet. It's tight, so we have to write
    // a new allocation table every time we change the superblock. That's no
    // good!
    && false // does something with allocation table?
  }

  function FreshestCleanCU(v: Variables) : Option<CU>
    requires v.WF()
  {
    if v.cleanLSN == v.boundaryLSN
    then None
    else Some(v.lsnToCU[v.cleanLSN-1])
  }

  // Agrees to advance persistentLSN (to cleanLSN) and firstLSN (to newBoundary, coordinated
  // with BeTree) as part of superblock writeback.
  predicate CommitStart(v: Variables, v': Variables, cache: CacheIfc.Variables, sb: Superblock, newBoundaryLSN: LSN, alloc: AllocationTableMachineMod.Variables)
  {
    && v.WF()
    // This is the stuff we'll get to garbage collect when the sb commit completes.
    && v.boundaryLSN <= newBoundaryLSN // presumably provable from Inv

    // These are the LSNs whose syncs will complete when the sb commit completes.
    && v.persistentLSN <= v.cleanLSN  // presumably provable from Inv

    // The allocation we actually commit to is a superset of the allocation we're using.
    && (forall cu | cu in v.lsnToCU.Values :: cu in alloc.table)

    // This is the superblock that's going to become persistent.
    && sb == Superblock(FreshestCleanCU(v), newBoundaryLSN)
    && v' == v
  }

  //////////////////////////////////////////////////////////////////////////////
  // JournalChain

  // Monoid-friendly (quantified-list) definition
  datatype JournalChain = JournalChain(sb: Superblock, recs:seq<JournalRecord>,
    locate:map<LSN,nat>, interp: MsgSeq)
  {
    // Synthesize a superblock that reflects the tail of the chain (cutting
    // off the first rec), propagating along boundaryLSN.
    function priorSB() : Superblock
      requires 0<|recs|
    {
      recs[0].priorSB(sb)
    }
  }

  predicate IsLastLink(i: nat, chain: JournalChain)
    requires 0<=i<|chain.recs|
  {
    chain.recs[i].messageSeq.seqStart <= chain.sb.boundaryLSN
  }

  predicate LSNinChain(chain: JournalChain, lsn: LSN)
  {
    && 0 < |chain.recs|
    && chain.sb.boundaryLSN <= lsn < chain.recs[0].messageSeq.seqEnd
  }

  predicate WFChainBasic(chain: JournalChain)
  {
    // Sowmya made this change
    // jonh changed it back -- I think I need <==>, so I'm gonna figure out
    // why you didn't want <==.
    && (chain.sb.freshestCU.None? <==> 0 == |chain.recs|)
    //&& (chain.sb.freshestCU.None? ==> 0 == |chain.recs|)
    && (forall i | 0<=i<|chain.recs| :: i==|chain.recs|-1 <==> IsLastLink(i, chain))
    && (forall i | 0<=i<|chain.recs|-1 :: chain.recs[i].priorCU.Some?)
  }

  predicate RecordSupportsMessage(rec: JournalRecord, lsn: LSN, message: KeyedMessage)
  {
    && rec.messageSeq.WF()
    && rec.messageSeq.seqStart <= lsn < rec.messageSeq.seqEnd
    && rec.messageSeq.msgs[lsn] == message
  }

  predicate WFChainInterp(chain: JournalChain)
  {
    && WFChainBasic(chain)
    && chain.interp.WF()
    && (|chain.recs| == 0 <==> chain.interp.IsEmpty())
    && (0 < |chain.recs| ==> chain.recs[0].messageSeq.seqEnd == chain.interp.seqEnd)  // could prove from WFChainInner order relation on the chain, but easier to simply add as a conjunct.
    // locate,interp domains match exactly the set of LSNs covered by this chain
    && (forall lsn :: LSNinChain(chain, lsn) <==> lsn in chain.locate)
    && (forall lsn :: LSNinChain(chain, lsn) <==> chain.interp.Contains(lsn))
    // locate range points only at valid chain record indices
    && (forall lsn | LSNinChain(chain, lsn) :: 0 <= chain.locate[lsn] < |chain.recs|)
    // and then finally the interp Messages are supported by the actual JournalRecords.
    && (forall lsn | LSNinChain(chain, lsn) ::
          RecordSupportsMessage(chain.recs[chain.locate[lsn]], lsn, chain.interp.msgs[lsn]))
    // interp bounds
    && (0<|chain.recs| ==>
        && chain.interp.seqEnd == chain.recs[0].messageSeq.seqEnd
        && chain.interp.seqStart == chain.sb.boundaryLSN
      )
  }

  predicate {:opaque} WFChainInner(chain: JournalChain)
    requires WFChainBasic(chain)
  {
    && (forall i | 0<=i<|chain.recs|-1 ::
      chain.recs[i].messageSeq.seqStart == chain.recs[i+1].messageSeq.seqEnd)
  }

  predicate WFChain(chain: JournalChain)
  {
    && WFChainBasic(chain)
    && WFChainInner(chain)
    && WFChainInterp(chain)
  }

  function CUForChainIdx(chain: JournalChain, idx: nat) : CU
    requires WFChain(chain)
    requires 0 <= idx < |chain.recs|
  {
    if idx == 0
    then chain.sb.freshestCU.value
    else chain.recs[idx-1].priorCU.value
  }

  function CUsForChain(chain: JournalChain) : (cus: seq<CU>)
    requires WFChain(chain)
    ensures |cus| == |chain.recs|
  {
    seq(|chain.recs|, i => CUForChainIdx(chain, i))
  }

  predicate RecordOnDisk(dv: DiskView, cu: CU, journalRecord: JournalRecord)
  {
    && cu in dv
    && parse(dv[cu]) == Some(journalRecord)
  }

  predicate {:opaque} ChainMatchesDiskView(dv: DiskView, chain: JournalChain)
    requires WFChain(chain)
  {
    // chain corresponds to stuff in the DiskView starting at freshestCU.
    && var cus := CUsForChain(chain);
    && (forall i | 0<=i<|chain.recs| :: RecordOnDisk(dv, cus[i], chain.recs[i]))
  }

  // Describe a valid chain.
  predicate ValidJournalChain(dv: DiskView, chain: JournalChain)
  {
    && WFChain(chain)
    && ChainMatchesDiskView(dv, chain)
  }

  function EmptyChain(sb: Superblock) : ( chain : JournalChain)
    requires sb.freshestCU.None?
    ensures WFChain(chain)
  {
    reveal_WFChainInner();
    JournalChain(sb, [], map[], MsgHistoryMod.Empty())
  }

  lemma ValidEmptyChain(dv: DiskView, sb: Superblock)
    requires sb.freshestCU.None?
    ensures ValidJournalChain(dv, EmptyChain(sb))
  {
    reveal_WFChainInner();
    reveal_ChainMatchesDiskView();
  }

  function {:timeLimitMultiplier 4} ExtendChain(sb: Superblock, rec: JournalRecord, innerchain: JournalChain)
    : (chain: JournalChain)
    requires sb.freshestCU.Some?
    requires rec.messageSeq.WF()
    requires sb.boundaryLSN < rec.messageSeq.seqStart; // proves !IsLastLink(0, chain)
    requires innerchain.sb == rec.priorSB(sb);
    requires 0 < |innerchain.recs|
    requires rec.messageSeq.seqStart == innerchain.recs[0].messageSeq.seqEnd
    requires WFChain(innerchain)
    ensures WFChain(chain)
    ensures 0 < |chain.recs|
    ensures chain.recs[0] == rec
    ensures chain.interp.seqEnd == rec.messageSeq.seqEnd
  {
    var locate0 := map lsn | lsn in rec.messageSeq.LSNSet() && sb.boundaryLSN <= lsn :: 0;
    var locateCdr := map lsn | lsn in innerchain.locate :: innerchain.locate[lsn] + 1;
    var locate := MapDisjointUnion(locate0, locateCdr);
    var interp := innerchain.interp.Concat(rec.messageSeq);
    var chain := JournalChain(sb, [rec] + innerchain.recs, locate, interp);
    assert WFChainBasic(chain) by {
      forall i | 0<=i<|chain.recs| && i==|chain.recs|-1 ensures IsLastLink(i, chain)
      {
        assert IsLastLink(i-1, innerchain); //trigger
      }
      forall i | 0<=i<|chain.recs| && IsLastLink(i, chain) ensures i==|chain.recs|-1
      {
        if 0<i<|chain.recs|-1 {
          assert !IsLastLink(i-1, innerchain);  // trigger
        }
      }
    }
    assert WFChainInner(chain) by { reveal_WFChainInner(); }
    chain
  }

  // Define reading a chain recursively. Returns None if any of the
  // CUs point to missing blocks from the dv, or if the block can't
  // be parsed.
  // Return the set of readCUs visited. We may read six CUs before returning
  // a None chain. We have to know that to show how related dvs produce identical
  // results (even when they're broken).
  datatype ChainResult = ChainResult(chain: Option<JournalChain>, readCUs:seq<CU>)

  // NOTE: Chain from by itself has no bounds on the ending LSN
  function ChainFrom(dv: DiskView, sb: Superblock) : (r:ChainResult)
    ensures r.chain.Some? ==> ValidJournalChain(dv, r.chain.value)
    decreases |dv.Keys|
  {
    reveal_ChainMatchesDiskView();
    if sb.freshestCU.None? then
      // Superblock told the whole story; nothing to read.
      ValidEmptyChain(dv, sb);
      ChainResult(Some(EmptyChain(sb)), [])
    else if sb.freshestCU.value !in dv then
      // !RecordOnDisk: tried to read freshestCU and failed
      ChainResult(None, [sb.freshestCU.value])
    else
      var firstRec := parse(dv[sb.freshestCU.value]);
      if firstRec.None? then
        // !RecordOnDisk: read freshestCU, but it was borked
        ChainResult(None, [sb.freshestCU.value])
      else if firstRec.value.messageSeq.seqEnd <= sb.boundaryLSN then
        // This isn't an invariant disk state: if we're in the initial call,
        // the superblock shouldn't point to a useless JournalRecord; if we're
        // in a recursive call with correctly-chained records, we should have
        // already ignored this case.
        ChainResult(None, [sb.freshestCU.value])
      else if firstRec.value.messageSeq.seqStart <= sb.boundaryLSN then
        // Glad we read this record, but we don't need to read anything beyond.
        var rec := firstRec.value;
        var locate0 := map lsn : LSN | sb.boundaryLSN <= lsn < rec.messageSeq.seqEnd :: 0;
        var interp0 := rec.messageSeq.Behead(sb.boundaryLSN);
        var chain := JournalChain(sb, [rec], locate0, interp0);
        assert WFChain(chain) by {
          reveal_WFChainInner();
          forall lsn | LSNinChain(chain, lsn) ensures chain.interp.Contains(lsn) {}
          forall lsn | chain.interp.Contains(lsn) ensures LSNinChain(chain, lsn) {}
        }
        ChainResult(Some(chain), [sb.freshestCU.value])
      else if firstRec.value.priorCU.None? then
        // we need more messages, but the pointer is dead! We can't build a chain that
        // satisfies IsLastLink.
        assert sb.boundaryLSN < firstRec.value.messageSeq.seqStart;
        ChainResult(None, [sb.freshestCU.value])
      else
        var inner := ChainFrom(MapRemove1(dv, sb.freshestCU.value), firstRec.value.priorSB(sb));
        if inner.chain.None? // tail didn't decode or
          // tail decoded but head doesn't stitch to it (a cross-crash invariant)
          || (0<|inner.chain.value.recs|
              && firstRec.value.messageSeq.seqStart != inner.chain.value.recs[0].messageSeq.seqEnd)
        then
          // failure in recursive call.
          // We read our cu plus however far the recursive call reached.
          ChainResult(None, [sb.freshestCU.value] + inner.readCUs)
        else
          var chain := ExtendChain(sb, firstRec.value, inner.chain.value);
          ChainResult(Some(chain), [sb.freshestCU.value] + inner.readCUs)
  }

  // JournalChain
  //////////////////////////////////////////////////////////////////////////////

  // TODO recovery time action!

  // Learns that coordinated superblock writeback is complete; updates persistentLSN & firstLSN.
  predicate CommitComplete(s: Variables, s': Variables, cache: CacheIfc.Variables, sb: Superblock)
  {
    && s.WF()

    && s'.boundaryLSN == sb.boundaryLSN

    // Update s'.persistentLSN so that it reflects a persisted LSN (something in the last block,
    // ideally the last LSN in that block). NB This gives impl freedom to not
    // record the latest persistent LSN in the freshestCU block, which would be
    // kind of dumb (it would hold up syncs for no reason), but not unsafe.
    && (if sb.freshestCU.None?
        then s'.persistentLSN == sb.boundaryLSN
        else
          && s'.persistentLSN - 1 in s.lsnToCU
          && s.lsnToCU[s'.persistentLSN - 1] == sb.freshestCU.value
        )
    && s'.cleanLSN == s.cleanLSN
    && s'.marshalledLSN == s.marshalledLSN
    && s'.unmarshalledTail == s.unmarshalledTail
    && s'.syncReqs == s.syncReqs
    && s'.lsnToCU == MappingFor(cache, sb)
  }

  predicate ReqSync(s: Variables, s': Variables, syncReqId: SyncReqId)
  {
    && 0 < s.unmarshalledLSN()
    && syncReqId !in s.syncReqs.Keys
    && s' == s.(syncReqs := s.syncReqs[syncReqId := s.unmarshalledLSN()-1])
  }

  predicate CompleteSync(s: Variables, s': Variables, syncReqId: SyncReqId)
  {
    && syncReqId in s.syncReqs.Keys
    && s.syncReqs[syncReqId] < s.persistentLSN
    && s' == s.(syncReqs := MapRemove1(s.syncReqs, syncReqId))
  }

  datatype Skolem =
    | AdvanceMarshalledStep(newCU: CU)
    | AdvanceCleanStep(newClean: nat)

  predicate Internal(s: Variables, s': Variables, cache: CacheIfc.Variables, cacheOps: CacheIfc.Ops, sk: Skolem) {
    match sk {
      case AdvanceMarshalledStep(newCU) => AdvanceMarshalled(s, s', cache, cacheOps, newCU)
      case AdvanceCleanStep(newClean) => AdvanceClean(s, s', cache, cacheOps, newClean)
//      case _ => false
    }
  }

  function Alloc(s: Variables) : set<CU> {
    {} // TODO
  }
}
