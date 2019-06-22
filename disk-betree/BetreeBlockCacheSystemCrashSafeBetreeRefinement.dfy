include "../lib/Maps.dfy"
include "../lib/sequences.dfy"
include "BetreeBlockCacheSystem.dfy"
include "CrashSafe.dfy"
include "DiskBetree.dfy"

module BetreeBlockCacheSystemCrashSafeBetreeRefinement {
  import opened Maps
  import opened Sequences
  import opened BetreeSpec`Spec

  import opened G = BetreeGraph
  import BBCS = BetreeBlockCacheSystem
  import BCS = BetreeGraphBlockCacheSystem
  import M = BetreeBlockCache
  import BC = BetreeGraphBlockCache
  import D = Disk
  import CSBT = CrashSafeDiskBetree
  import BT = DiskBetree
  import BI = BetreeBlockInterface
  import DBI = DiskBetreeInv
  import Ref = BlockCacheSystemCrashSafeBlockInterfaceRefinement

  type DiskOp = M.DiskOp

  function Ik(k: BBCS.Constants) : CSBT.Constants {
    BT.Constants(BI.Constants())
  }

  function I(k: BBCS.Constants, s: BBCS.Variables) : CSBT.Variables
  requires BBCS.Inv(k, s)
  {
    CSBT.Variables(
      BBCS.PersistentBetree(k, s),
      if s.machine.Ready? then BBCS.EphemeralBetree(k, s) else BBCS.PersistentBetree(k, s)
    )
  }

  lemma RefinesInit(k: BBCS.Constants, s: BBCS.Variables)
  requires BBCS.Init(k, s)
  ensures BBCS.Inv(k, s)
  ensures CSBT.Init(Ik(k), I(k, s))
  // TODO figure out how initial conditions are going to work
  // Right now the BlockCacheSystem assumes any valid disk
  // whereas the Betree requires the Betree to start empty

  lemma RefinesBetreeMoveStep(k: BBCS.Constants, s: BBCS.Variables, s': BBCS.Variables, dop: DiskOp, betreeStep: BetreeStep)
  requires BBCS.Inv(k, s)
  requires BBCS.Inv(k, s')
  requires M.BetreeMove(k.machine, s.machine, s'.machine, dop, betreeStep)
  requires D.Next(k.disk, s.disk, s'.disk, dop)
  ensures CSBT.Next(Ik(k), I(k, s), I(k, s'))
  {
    assert s.machine.Ready?;

    // TODO duplication with BetreeMoveStepPreservesInv

    var ops := BetreeStepOps(betreeStep);
    BCS.TransactionStepPreservesInvariant(k, s, s', D.NoDiskOp, ops);
    BBCS.PersistentGraphEqAcrossOps(k, s, s', ops); 
    Ref.RefinesOpTransaction(k, s, s', ops);
    DBI.BetreeStepPreservesInvariant(Ik(k), BBCS.EphemeralBetree(k, s), BBCS.EphemeralBetree(k, s'), betreeStep);

    assert I(k, s).persistent == I(k, s').persistent;
    assert BT.NextStep(Ik(k), I(k, s).ephemeral, I(k, s').ephemeral, BT.BetreeStep(betreeStep));
    assert CSBT.NextStep(Ik(k), I(k, s), I(k, s'), CSBT.EphemeralMoveStep);
  }

  lemma RefinesBlockCacheMoveStep(k: BBCS.Constants, s: BBCS.Variables, s': BBCS.Variables, dop: DiskOp, step: BC.Step)
  requires BBCS.Inv(k, s)
  requires BBCS.Inv(k, s')
  requires M.BlockCacheMove(k.machine, s.machine, s'.machine, dop, step)
  requires D.Next(k.disk, s.disk, s'.disk, dop)
  ensures CSBT.Next(Ik(k), I(k, s), I(k, s'))
  {
    match step {
    }
  }

  lemma RefinesMachineStep(k: BBCS.Constants, s: BBCS.Variables, s': BBCS.Variables, dop: DiskOp, step: M.Step)
  requires BBCS.Inv(k, s)
  requires BBCS.Inv(k, s')
  requires M.NextStep(k.machine, s.machine, s'.machine, dop, step)
  requires D.Next(k.disk, s.disk, s'.disk, dop)
  ensures CSBT.Next(Ik(k), I(k, s), I(k, s'))
  {
    match step {
      case BetreeMoveStep(betreeStep) => RefinesBetreeMoveStep(k, s, s', dop, betreeStep);
      case BlockCacheMoveStep(step) => RefinesBlockCacheMoveStep(k, s, s', dop, step);
    }
  }

  lemma RefinesMachine(k: BBCS.Constants, s: BBCS.Variables, s': BBCS.Variables, dop: DiskOp)
  requires BBCS.Inv(k, s)
  requires BBCS.Inv(k, s')
  requires M.Next(k.machine, s.machine, s'.machine, dop)
  requires D.Next(k.disk, s.disk, s'.disk, dop)
  ensures CSBT.Next(Ik(k), I(k, s), I(k, s'))
  {
    var step: M.Step :| M.NextStep(k.machine, s.machine, s'.machine, dop, step);
    RefinesMachineStep(k, s, s', dop, step);
  }

  lemma RefinesCrash(k: BBCS.Constants, s: BBCS.Variables, s': BBCS.Variables)
  requires BBCS.Inv(k, s)
  requires BBCS.Inv(k, s')
  requires M.Init(k.machine, s'.machine)
  requires s.disk == s'.disk
  ensures CSBT.Next(Ik(k), I(k, s), I(k, s'))
  {
    assert I(k, s').ephemeral == I(k, s).persistent;
    assert I(k, s').persistent == I(k, s).persistent;
    assert CSBT.NextStep(Ik(k), I(k, s), I(k, s'), CSBT.CrashStep);
  }

  lemma RefinesNextStep(k: BBCS.Constants, s: BBCS.Variables, s': BBCS.Variables, step: BBCS.Step)
  requires BBCS.Inv(k, s)
  requires BBCS.NextStep(k, s, s', step)
  ensures BBCS.Inv(k, s')
  ensures CSBT.Next(Ik(k), I(k, s), I(k, s'))
  {
    BBCS.NextPreservesInv(k, s, s');
    match step {
      case MachineStep(dop) => RefinesMachine(k, s, s', dop);
      case CrashStep => RefinesCrash(k, s, s');
    }
  }

  lemma RefinesNext(k: BBCS.Constants, s: BBCS.Variables, s': BBCS.Variables)
  requires BBCS.Inv(k, s)
  requires BBCS.Next(k, s, s')
  ensures BBCS.Inv(k, s')
  ensures CSBT.Next(Ik(k), I(k, s), I(k, s'))
  {
    var step :| BBCS.NextStep(k, s, s', step);
    RefinesNextStep(k, s, s', step);
  }

}
