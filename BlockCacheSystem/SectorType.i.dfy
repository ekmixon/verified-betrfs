include "JournalRange.i.dfy"
include "DiskLayout.i.dfy"
include "../PivotBetree/PivotBetreeSpec.i.dfy"

module SectorType {
  import opened NativeTypes
  import opened Journal
  import opened JournalRanges
  import opened DiskLayout
  import opened PivotBetreeGraph

  datatype Superblock = Superblock(
      counter: uint64,
      journalStart: uint64,
      journalLen: uint64,
      indirectionTableLoc: Location)

  datatype Sector =
    | SectorSuperblock(superblock: Superblock)
    | SectorJournal(journal: JournalRange)
    | SectorNode(block: Node)
    | SectorIndirectionTable(indirectionTable: IndirectionTable)
}
