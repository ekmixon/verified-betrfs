include "AsyncDiskModel.s.dfy"
include "../BlockCacheSystem/BetreeBlockCache.i.dfy"
include "Marshalling.i.dfy"
//
// Wraps a BetreeBlockCache (which does I/O in high-level Node sectors) into
// a state machine that is an AsyncDiskMachine: a client of a disk that does
// I/O in bytes.
//
// You (or past Jon) might ask: why do we refine Betree and BlockCache mostly
// separately, but join them up at the Pivot level, even though we still have
// a layer of refinement (pivot->byte) to go? The answer is that we never have
// a "byte betree block cache" in memory; we want our program to manipulate
// cooked data structures, not have to unmarshall every time we inspect a block
// of bytes from the cache. We want the parsing step to be specific to the
// memory->disk boundary, rather than having a refinement layer that eliminates
// the Pivot Node data structure entirely.
//

module ByteBetreeBlockCache refines AsyncDiskMachine {
  import opened NativeTypes
  import opened Options

  import BBC = BetreeBlockCache
  import Marshalling

  import SD = AsyncSectorDisk
  import opened DiskLayout

  type Constants = BBC.Constants
  type Variables = BBC.Variables

  function BlockSize() : int { 8 * 1024 * 1024 }

  function {:opaque} Parse(sector: seq<byte>) : Option<BBC.Sector>
  requires |sector| <= BlockSize() - 32
  {
    Marshalling.parseSector(sector)
  }

  predicate {:opaque} ValidCheckedBytes(sector: seq<byte>)
  requires 32 <= |sector|
  requires |sector| <= BlockSize()
  {
    && D.ChecksumChecksOut(sector)
    && Parse(sector[32..]).Some?
  }

  predicate ValidBytes(sector: seq<byte>)
  {
    && 32 <= |sector|
    && |sector| <= BlockSize()
    && ValidCheckedBytes(sector)
  }

  // There's some complexity here because we have to deal with
  // journal blocks.

  function {:opaque} JournalRangeOfByteSeq(s: seq<byte>): JournalRange
  {
    if s == [] then
      []
    else if |s| >= 4096 && D.ChecksumChecksOut(s[0..4096]) then (
      var rest := JournalRangeOfByteSeq(s[4096..]);
      if rest.Some? then (
        Some([s[32..4096]] + rest.value)
      ) else (
        None
      )
    )
    else (
      None
    )
  }

  predicate ValidJournalBytes(bytes: seq<byte>)
  {
    && JournalRangeOfByteSeq(bytes).Some?
  }

  predicate ValidLocationAndBytes(loc: Location, bytes: seq<byte>)
  {
    && loc.len as int == |bytes|
    && ValidLocation(loc)
    && (ValidJournalLocation(loc) ==> (
      ValidJournalBytes(bytes)
    ))
    && (ValidJournalLocation(loc) ==> (
      ValidBytes(bytes)
    ))
  }

  function {:opaque} IBytes(loc: Location, bytes: seq<byte>) : BBC.Sector
  requires ValidLocationAndBytes(loc, bytes)
  {
    if ValidJournalLocation(loc) then (
      JournalRangeOfByteSeq(bytes).value
    ) else (
      reveal_ValidCheckedBytes();
      Parse(sector[32..]).value
    )
  }

  function IBytesOpt(loc: Location, bytes: seq<byte>) : Option<BBC.Sector>
  {
    if ValidLocationAndBytes(loc, bytes) then
      Some(IBytes(loc, bytes))
    else
      None
  }

  predicate ValidReqRead(reqRead: D.ReqRead)
  {
    && ValidLocation(Location(reqRead.addr, reqRead.len))
  }

  predicate ValidReqWrite(reqWrite: D.ReqWrite)
  {
    && ValidLocationAndBytes(
        Location(reqWrite.addr, |reqWrite.bytes| as uint64),
        reqWrite.bytes
       )
  }

  predicate ValidRespRead(respRead: D.RespRead) { true }
  predicate ValidRespWrite(respWrite: D.RespWrite) { true }
  predicate ValidDiskOp(dop: D.DiskOp)
  {
    match dop {
      case ReqReadOp(id, reqRead) => ValidReqRead(reqRead)
      case ReqWriteOp(id, reqWrite) => ValidReqWrite(reqWrite)
      case RespReadOp(id, respRead) => ValidRespRead(respRead)
      case RespWriteOp(id, respWrite) => ValidRespWrite(respWrite)
      case NoDiskOp => true
    }
  }

  function IReqRead(reqRead: D.ReqRead) : SD.ReqRead
  requires ValidReqRead(reqRead)
  {
    SD.ReqRead(Location(reqRead.addr, reqRead.len))
  }
  function IReqWrite(reqWrite: D.ReqWrite) : SD.ReqWrite<BBC.Sector>
  requires ValidReqWrite(reqWrite)
  {
    SD.ReqWrite(Location(reqWrite.addr, |reqWrite.bytes| as uint64), IBytes(reqWrite.bytes))
  }
  function IRespRead(respRead: D.RespRead) : SD.RespRead<BBC.Sector>
  {
    SD.RespRead(IBytesOpt(respRead.bytes))
  }
  function IRespWrite(respWrite: D.RespWrite) : SD.RespWrite
  requires ValidRespWrite(respWrite)
  {
    SD.RespWrite
  }

  function IDiskOp(diskOp: D.DiskOp) : SD.DiskOp<BBC.Sector>
  requires ValidDiskOp(diskOp)
  {
    match diskOp {
      case ReqReadOp(id, reqRead) => SD.ReqReadOp(id, IReqRead(reqRead))
      case ReqWriteOp(id, reqWrite) => SD.ReqWriteOp(id, IReqWrite(reqWrite))
      case RespReadOp(id, respRead) => SD.RespReadOp(id, IRespRead(respRead))
      case RespWriteOp(id, respWrite) => SD.RespWriteOp(id, IRespWrite(respWrite))
      case NoDiskOp => SD.NoDiskOp
    }
  }

  predicate Init(k: Constants, s: Variables)
  {
    BBC.Init(k, s)
  }

  datatype Step = Step(step: BBC.Step)

  predicate NextStep(k: Constants, s: Variables, s': Variables, uiop: UIOp, dop: DiskOp, step: Step)
  {
    && ValidDiskOp(dop)
    && BBC.NextStep(k, s, s', uiop, IDiskOp(dop), step.step)
  }

  predicate Next(k: Constants, s: Variables, s': Variables, uiop: UIOp, dop: DiskOp)
  {
    exists step :: NextStep(k, s, s', uiop, dop, step)
  }
}
