include "KVTypes.dfy"
include "Disk.dfy"

module DatumDisk refines Disk {
import opened KVTypes
datatype Sector = Superblock(logSize:int) | Datablock(datum:Datum)
}

module CrashSafeLog {
import opened KVTypes
import Disk = DatumDisk

type LBA = Disk.LBA

// The "program counter" for IO steps.
datatype Mode = Reboot | Recover(next:LBA) | Running

datatype Constants = Constants(disk:Disk.Constants)
datatype Variables = Variables(
    // Actual disk state. We get to keep only this state across a crash.
    disk:Disk.Variables,
    // Operating mode, so we can keep track of a recovery read.
    mode:Mode,
    // How much of the disk log is "committed": synced with the value in the log superblock.
    // Drives refinement to abstract 'persistent' state, since this is what we'll see on a recovery.
    diskCommittedSize:LBA,
    // How much of the disk log agrees with the memlog. May exceed diskCommittedSize if we've
    // done PushLogData but not yet PushLogMetadata. We need this pointer to drag the synchrony invariant
    // forward from some PushLogDatas to a PushLogMetadata that updates diskCommittedSize.
    diskPersistedSize:LBA,
    // The memory image of the log. Its prefix agrees with the disk.
    memlog:seq<Datum>)

function SuperblockLogSize(sector:Disk.Sector) : int
{
    match sector {
        case Superblock(logSize) => logSize
        case Datablock(datum) => -1
    }
}

// The superblock's idea of how big the disk is
function DiskLogSize(k:Disk.Constants, s:Disk.Variables) : int
    requires 1 <= k.size
    requires Disk.WF(k, s)
{
    SuperblockLogSize(s.sectors[0])
}

// Returns the LBA for an index in the log.
function DiskLogAddr(index:int) : LBA
{
    // +1 to skip superblock.
    index + 1
}

predicate Init(k:Constants, s:Variables)
{
    // By saying nothing about the other variables, they can "havoc" (take
    // on arbitrary values).
    && Disk.Init(k.disk, s.disk)
    // need a minimum-size disk
    && 1 <= k.disk.size
    // Assume the disk has been mkfs'ed:
    && DiskLogSize(k.disk, s.disk) == 0
    && s.mode.Running?
    && s.diskCommittedSize == 0
    && s.diskPersistedSize == 0
    && s.memlog == []
}

// This organization hides the crash operation in unchecked code, which
// is a little fishy. If I were to add '&&false' in here, the rest of 
// the spec could be totally crash-unsafe, and we'd never know. Perhaps the
// right alternative would be to have the disk belong to a higher-level
// trusted component, the way we do networks in distributed systems.
predicate CrashAndRecover(k:Constants, s:Variables, s':Variables)
{
    && s'.mode.Reboot?
    // By saying nothing about the other variables, they can "havoc" (take
    // on arbitrary values). So clearly we're not relying on memlog.
    && s'.disk == s.disk
}

// Read the superblock, which gives the size of the valid log on disk.
predicate ReadSuperblock(k:Constants, s:Variables, s':Variables)
{
    exists sector ::
        && s.mode.Reboot?
        && Disk.Read(k.disk, s.disk, s'.disk, 0, sector)
        && 0 <= SuperblockLogSize(sector)
        && s'.mode == Recover(0)
        && s'.diskCommittedSize == SuperblockLogSize(sector)
        && s'.diskPersistedSize == SuperblockLogSize(sector)
        && s'.memlog == []
}

// Pull blocks off the disk until we've read them all.
// Here's a PC-less event-driven thingy. Sorry.
predicate ScanDiskLog(k:Constants, s:Variables, s':Variables)
{
    exists sector ::
        && s.mode.Recover?
        && Disk.Read(k.disk, s.disk, s'.disk, DiskLogAddr(s.mode.next), sector)
        && s.mode.next + 1 <= s.diskCommittedSize
        && s'.mode == Recover(s.mode.next + 1)
        && s'.diskCommittedSize == s.diskCommittedSize
        && s'.diskPersistedSize == s.diskPersistedSize
        && sector.Datablock?
        && s'.memlog == s.memlog + [sector.datum]
}

// We've got all the blocks. Switch to Running mode.
predicate TerminateScan(k:Constants, s:Variables, s':Variables)
{
    && s.mode.Recover?
    && Disk.Idle(k.disk, s.disk, s'.disk)
    && s.mode.next == s.diskCommittedSize   // Nothing more to read
    && s'.mode == Running
    && s'.diskCommittedSize == s.diskCommittedSize
    && s'.diskPersistedSize == s.diskPersistedSize
    && s'.memlog == s.memlog
}

// In-memory append.
predicate Append(k:Constants, s:Variables, s':Variables, datum:Datum)
{
    && s.mode.Running?
    && Disk.Idle(k.disk, s.disk, s'.disk)
    && s'.mode == s.mode
    && s'.diskCommittedSize == s.diskCommittedSize
    && s'.diskPersistedSize == s.diskPersistedSize
    && s'.memlog == s.memlog + [datum]
}

function {:opaque} FindIndexInLog(log:seq<Datum>, key:Key) : (index:Option<int>)
    ensures index.Some? ==>
        && 0<=index.t<|log|
        && log[index.t].key == key
        && (forall j :: index.t < j < |log| ==> log[j].key != key)
    ensures index.None? ==> forall j :: 0 <= j < |log| ==> log[j].key != key
{
    if |log| == 0
        then None
    else if log[|log|-1].key == key
        then Some(|log|-1)
    else
        FindIndexInLog(log[..|log|-1], key)
}

function EvalLog(log:seq<Datum>, key:Key) : Datum
{
    var index := FindIndexInLog(log, key);
    if index.Some?
    then log[index.t]
    else Datum(key, EmptyValue())
}

predicate Query(k:Constants, s:Variables, s':Variables, datum:Datum)
{
    && s.mode.Running?
    && datum == EvalLog(s.memlog, datum.key)
    && s'.mode == s.mode
    && s'.diskCommittedSize == s.diskCommittedSize
    && s'.diskPersistedSize == s.diskPersistedSize
    && s'.memlog == s.memlog
    && Disk.Idle(k.disk, s.disk, s'.disk)
}

predicate PushLogData(k:Constants, s:Variables, s':Variables)
{
    var idx := s.diskPersistedSize;   // The log index to flush out.
    && s.mode.Running?
    && 0 <= idx < |s.memlog| // there's a non-durable suffix to write
    && Disk.Write(k.disk, s.disk, s'.disk, DiskLogAddr(idx), Disk.Datablock(s.memlog[idx]))
    && s'.mode == s.mode
    && s'.diskCommittedSize == s.diskCommittedSize
    && s'.diskPersistedSize == idx + 1    // Now idx is durable, too
    && s'.memlog == s.memlog
}

predicate PushLogMetadata(k:Constants, s:Variables, s':Variables, persistentCount:int)
{
    && s.mode.Running?
    // It's okay to bump the metadata forwards even if we don't get it all the
    // way to the end.  Not sure *why* we'd do that, but it will likely be
    // helpful if we later enhance the disk model to be asynchronous (presently
    // the write is atomic).
    && s.diskCommittedSize < persistentCount <= s.diskPersistedSize
    && Disk.Write(k.disk, s.disk, s'.disk, 0, Disk.Superblock(persistentCount))
    && s'.mode == s.mode
    && s'.diskCommittedSize == persistentCount   // drives the refinement to PersistWrites
    && s'.diskPersistedSize == s.diskPersistedSize
    && s'.memlog == s.memlog
}

// TODO: fsysc() can only return once we quiesce the disk. Perhaps write SyncUpTo.
predicate CompleteSync(k:Constants, s:Variables, s':Variables)
{
    && s.mode.Running?
    && s.diskCommittedSize == |s.memlog|
    && s'.mode == s.mode
    && s'.diskCommittedSize == s.diskCommittedSize
    && s'.diskPersistedSize == s.diskPersistedSize
    && s'.memlog == s.memlog
    && Disk.Idle(k.disk, s.disk, s'.disk)
}

datatype Step = 
      CrashAndRecover
    | ReadSuperblock
    | ScanDiskLog
    | TerminateScanStep
    | AppendStep(datum: Datum)
    | Query(datum: Datum)
    | PushLogDataStep
    | PushLogMetadataStep(persistentCount:int)
    | CompleteSync

predicate NextStep(k:Constants, s:Variables, s':Variables, step:Step)
{
    match step {
        case CrashAndRecover => CrashAndRecover(k, s, s')
        case ReadSuperblock => ReadSuperblock(k, s, s')
        case ScanDiskLog => ScanDiskLog(k, s, s')
        case TerminateScanStep => TerminateScan(k, s, s')
        case AppendStep(datum) => Append(k, s, s', datum)
        case Query(datum) => Query(k, s, s', datum)
        case PushLogDataStep => PushLogData(k, s, s')
        case PushLogMetadataStep(persistentCount) => PushLogMetadata(k, s, s', persistentCount)
        case CompleteSync => CompleteSync(k, s, s')
    }
}

predicate Next(k:Constants, s:Variables, s':Variables)
{
    exists step:Step :: NextStep(k, s, s', step)
}

} // module LogImpl
