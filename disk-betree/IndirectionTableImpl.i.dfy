include "../lib/Maps.s.dfy"
include "../lib/sequences.s.dfy"
include "../lib/Option.s.dfy"
include "../lib/NativeTypes.s.dfy"
include "../lib/LRU.i.dfy"
include "../lib/MutableMapModel.i.dfy"
include "../lib/MutableMapImpl.i.dfy"
include "PivotBetreeSpec.i.dfy"
include "AsyncSectorDiskModel.i.dfy"
include "BlockCacheSystem.i.dfy"
include "../lib/Marshalling/GenericMarshalling.i.dfy"
include "../lib/Bitmap.i.dfy"
include "IndirectionTableModel.i.dfy"

module IndirectionTableImpl {
  import opened Maps
  import opened Sets
  import opened Options
  import opened Sequences
  import opened NativeTypes
  import ReferenceType`Internal
  import BT = PivotBetreeSpec`Internal
  import BC = BetreeGraphBlockCache
  import LruModel
  import MutableMapModel
  import MutableMap
  import LBAType
  import opened GenericMarshalling
  import Bitmap
  import opened Bounds
  import IndirectionTableModel

  type HashMap = MutableMap.ResizingHashMap<IndirectionTableModel.Entry>

  // TODO move bitmap in here?
  class IndirectionTable {
    var t: HashMap;
    ghost var Repr: set<object>;

    protected predicate Inv()
    reads this, Repr
    ensures Inv() ==> this in Repr
    {
      && this in Repr
      && this.t in Repr
      && Repr == {this} + this.t.Repr
      && this !in this.t.Repr
      && t.Inv()
    }

    protected function I() : IndirectionTableModel.IndirectionTable
    reads this, Repr
    requires Inv()
    ensures IndirectionTableModel.Inv(I())
    {
      IndirectionTableModel.FromHashMap(t.I())
    }

    method GetEntry(ref: BT.G.Reference) returns (e : Option<IndirectionTableModel.Entry>)
    requires Inv()
    ensures e == IndirectionTableModel.GetEntry(I(), ref)
    {
      IndirectionTableModel.reveal_GetEntry();
      e := this.t.Get(ref);
    }

    method HasEmptyLoc(ref: BT.G.Reference) returns (b: bool)
    requires Inv()
    ensures b == IndirectionTableModel.HasEmptyLoc(I(), ref)
    {
      var entry := this.t.Get(ref);
      b := entry.Some? && entry.value.loc.None?;
    }

    method RemoveLocIfPresent(ref: BT.G.Reference)
    requires Inv()
    modifies Repr
    ensures Inv()
    ensures forall o | o in Repr :: fresh(o) || o in old(Repr)
    ensures I() == IndirectionTableModel.RemoveLocIfPresent(old(I()), ref)
    {
      IndirectionTableModel.reveal_RemoveLocIfPresent();

      assume this.t.Count as nat < 0x10000000000000000 / 8;
      var oldEntry := this.t.Get(ref);
      if oldEntry.Some? {
        this.t.Insert(ref, IndirectionTableModel.Entry(None, oldEntry.value.succs));
      }

      Repr := {this} + this.t.Repr;
    }

    method AddLocIfPresent(ref: BT.G.Reference, loc: BC.Location)
    returns (added : bool)
    requires Inv()
    modifies Repr
    ensures Inv()
    ensures forall o | o in Repr :: fresh(o) || o in old(Repr)
    ensures (I(), added) == IndirectionTableModel.AddLocIfPresent(old(I()), ref, loc)
    {
      IndirectionTableModel.reveal_AddLocIfPresent();

      assume this.t.Count as nat < 0x10000000000000000 / 8;
      var oldEntry := this.t.Get(ref);
      added := oldEntry.Some? && oldEntry.value.loc.None?;
      if added {
        this.t.Insert(ref, IndirectionTableModel.Entry(Some(loc), oldEntry.value.succs));
      }

      Repr := {this} + this.t.Repr;
    }

    method RemoveRef(ref: BT.G.Reference)
    returns (oldLoc : Option<BC.Location>)
    requires Inv()
    modifies Repr
    ensures Inv()
    ensures forall o | o in Repr :: fresh(o) || o in old(Repr)
    ensures (I(), oldLoc) == IndirectionTableModel.RemoveRef(old(I()), ref)
    {
      IndirectionTableModel.reveal_RemoveRef();

      var oldEntry := this.t.RemoveAndGet(ref);
      oldLoc := if oldEntry.Some? then oldEntry.value.loc else None;

      Repr := {this} + this.t.Repr;
    }

    method UpdateAndRemoveLoc(ref: BT.G.Reference, succs: seq<BT.G.Reference>)
    returns (oldLoc : Option<BC.Location>)
    requires Inv()
    modifies Repr
    ensures Inv()
    ensures forall o | o in Repr :: fresh(o) || o in old(Repr)
    ensures (I(), oldLoc)  == IndirectionTableModel.UpdateAndRemoveLoc(old(I()), ref, succs)
    {
      IndirectionTableModel.reveal_UpdateAndRemoveLoc();

      assume this.t.Count as nat < 0x10000000000000000 / 8;
      var oldEntry := this.t.InsertAndGetOld(ref, IndirectionTableModel.Entry(None, succs));
      oldLoc := if oldEntry.Some? then oldEntry.value.loc else None;

      Repr := {this} + this.t.Repr;
    }

    // Parsing and marshalling

    static method {:fuel ValInGrammar,3} ValToHashMap(a: seq<V>) returns (s : Option<HashMap>)
    requires IndirectionTableModel.valToHashMap.requires(a)
    ensures s.None? ==> IndirectionTableModel.valToHashMap(a).None?
    ensures s.Some? ==> s.value.Inv()
    ensures s.Some? ==> Some(s.value.I()) == IndirectionTableModel.valToHashMap(a)
    ensures s.Some? ==> s.value.Count as nat == |a|
    ensures s.Some? ==> s.value.Count as nat < 0x1_0000_0000_0000_0000 / 8
    ensures s.Some? ==> fresh(s.value) && fresh(s.value.Repr)
    {
      assume |a| < 0x1_0000_0000_0000_0000;
      if |a| as uint64 == 0 {
        var newHashMap := new MutableMap.ResizingHashMap<IndirectionTableModel.Entry>(1024); // TODO(alattuada) magic numbers
        s := Some(newHashMap);
        assume s.value.Count as nat == |a|;
      } else {
        var res := ValToHashMap(a[..|a| as uint64 - 1]);
        match res {
          case Some(mutMap) => {
            var tuple := a[|a| as uint64 - 1];
            var ref := tuple.t[0 as uint64].u;
            var lba := tuple.t[1 as uint64].u;
            var len := tuple.t[2 as uint64].u;
            var succs := Some(tuple.t[3 as uint64].ua);
            match succs {
              case None => {
                s := None;
              }
              case Some(succs) => {
                var graphRef := mutMap.Get(ref);
                var loc := LBAType.Location(lba, len);
                if graphRef.Some? || lba == 0 || !LBAType.ValidLocation(loc) {
                  s := None;
                } else {
                  mutMap.Insert(ref, IndirectionTableModel.Entry(Some(loc), succs));
                  s := Some(mutMap);
                  assume s.Some? ==> s.value.Count as nat < 0x10000000000000000 / 8; // TODO(alattuada) removing this results in trigger loop
                  assume s.value.Count as nat == |a|;
                }
              }
            }
          }
          case None => {
            s := None;
          }
        }
      }
    }

    static method GraphClosed(table: HashMap) returns (result: bool)
      requires table.Inv()
      requires BC.GraphClosed.requires(IndirectionTableModel.IHashMap(table.I()).graph)
      ensures BC.GraphClosed(IndirectionTableModel.IHashMap(table.I()).graph) == result
    {
      var m := table.ToMap();
      var m' := map ref | ref in m :: m[ref].succs;
      result := BC.GraphClosed(m');
    }

    constructor(t: HashMap)
    ensures this.t == t
    {
      this.t := t;
    }

    static method ValToIndirectionTable(v: V)
    returns (s : IndirectionTable?)
    requires IndirectionTableModel.valToIndirectionTable.requires(v)
    ensures s != null ==> s.Inv()
    ensures s != null ==> fresh(s.Repr)
    ensures s == null ==> IndirectionTableModel.valToIndirectionTable(v).None?
    ensures s != null ==> IndirectionTableModel.valToIndirectionTable(v) == Some(s.I())
    {
      var res := ValToHashMap(v.a);
      match res {
        case Some(res) => {
          var rootRef := res.Get(BT.G.Root());
          var isGraphClosed := GraphClosed(res);
          if rootRef.Some? && isGraphClosed {
            s := new IndirectionTable(res);
            s.Repr := {s} + s.t.Repr;
          } else {
            s := null;
          }
        }
        case None => {
          s := null;
        }
      }
    }

    // To bitmap

    method InitLocBitmap()
    returns (success: bool, bm: Bitmap.Bitmap)
    requires Inv()
    requires BC.WFCompleteIndirectionTable(IndirectionTableModel.I(I()))
    ensures bm.Inv()
    ensures (success, bm.I()) == IndirectionTableModel.InitLocBitmap(old(I()))
    ensures fresh(bm.Repr)
    {
      IndirectionTableModel.reveal_InitLocBitmap();

      bm := new Bitmap.Bitmap(NumBlocksUint64());
      bm.Set(0);
      var it := t.IterStart();
      while it.next.Some?
      invariant t.Inv()
      invariant BC.WFCompleteIndirectionTable(IndirectionTableModel.I(I()))
      invariant bm.Inv()
      invariant MutableMapModel.WFIter(t.I(), it)
      invariant Bitmap.Len(bm.I()) == NumBlocks()
      invariant IndirectionTableModel.InitLocBitmapIterate(I(), it, bm.I())
             == IndirectionTableModel.InitLocBitmap(I())
      invariant fresh(bm.Repr)
      decreases it.decreaser
      {
        var kv := it.next.value;

        assert kv.0 in IndirectionTableModel.I(I()).locs;

        var loc: uint64 := kv.1.loc.value.addr;
        var locIndex: uint64 := loc / BlockSizeUint64();
        if locIndex < NumBlocksUint64() {
          var isSet := bm.GetIsSet(locIndex);
          if !isSet {
            it := t.IterInc(it);
            bm.Set(locIndex);
          } else {
            success := false;
            return;
          }
        } else {
          success := false;
          return;
        }
      }

      success := true;
    }
    
    ///// Dealloc stuff

    /*
    predicate deallocable(self: IndirectionTable, ref: BT.G.Reference)
    {
      && ref in I(self).graph
      && ref != BT.G.Root()
      && (forall r | r in I(self).graph :: ref !in I(self).graph[r])
    }

    function FindDeallocableIterate(self: IndirectionTable, ephemeralRefs: seq<BT.G.Reference>, i: uint64)
    : (ref: Option<BT.G.Reference>)
    requires 0 <= i as int <= |ephemeralRefs|
    requires |ephemeralRefs| < 0x1_0000_0000_0000_0000;
    decreases 0x1_0000_0000_0000_0000 - i as int
    {
      if i == |ephemeralRefs| as uint64 then (
        None
      ) else (
        var ref := ephemeralRefs[i];
        var isDeallocable := deallocable(self, ref);
        if isDeallocable then (
          Some(ref)
        ) else (
          FindDeallocableIterate(self, ephemeralRefs, i + 1)
        )
      )
    }

    function {:opaque} FindDeallocable(self: IndirectionTable)
    : (ref: Option<BT.G.Reference>)
    requires Inv(self)
    {
      // TODO once we have an lba freelist, rewrite this to avoid extracting a `map` from `s.ephemeralIndirectionTable`
      var ephemeralRefs := setToSeq(self.t.contents.Keys);

      assume |ephemeralRefs| < 0x1_0000_0000_0000_0000;

      FindDeallocableIterate(self, ephemeralRefs, 0)
    }

    lemma FindDeallocableIterateCorrect(self: IndirectionTable, ephemeralRefs: seq<BT.G.Reference>, i: uint64)
    requires Inv(self)
    requires 0 <= i as int <= |ephemeralRefs|
    requires |ephemeralRefs| < 0x1_0000_0000_0000_0000;
    requires ephemeralRefs == setToSeq(self.t.contents.Keys)
    requires forall k : nat | k < i as nat :: (
          && ephemeralRefs[k] in I(self).graph
          && !deallocable(self, ephemeralRefs[k]))
    ensures var ref := FindDeallocableIterate(self, ephemeralRefs, i);
        && (ref.Some? ==> ref.value in I(self).graph)
        && (ref.Some? ==> deallocable(self, ref.value))
        && (ref.None? ==> forall r | r in I(self).graph :: !deallocable(self, r))
    decreases 0x1_0000_0000_0000_0000 - i as int
    {
      if i == |ephemeralRefs| as uint64 {
        assert forall r | r in I(self).graph :: !deallocable(self, r);
      } else {
        var ref := ephemeralRefs[i];
        var isDeallocable := deallocable(self, ref);
        if isDeallocable {
        } else {
          FindDeallocableIterateCorrect(self, ephemeralRefs, i + 1);
        }
      }
    }

    lemma FindDeallocableCorrect(self: IndirectionTable)
    requires Inv(self)
    ensures var ref := FindDeallocable(self);
        && (ref.Some? ==> ref.value in I(self).graph)
        && (ref.Some? ==> deallocable(self, ref.value))
        && (ref.None? ==> forall r | r in I(self).graph :: !deallocable(self, r))
    {
      reveal_FindDeallocable();
      var ephemeralRefs := setToSeq(self.t.contents.Keys);
      assume |ephemeralRefs| < 0x1_0000_0000_0000_0000;
      FindDeallocableIterateCorrect(self, ephemeralRefs, 0);
    }
    */
  }
}
