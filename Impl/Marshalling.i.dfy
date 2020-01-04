include "../lib/Marshalling/GenericMarshalling.i.dfy"
include "../PivotBetree/PivotBetreeSpec.i.dfy"
include "../lib/Base/Message.i.dfy"
include "../lib/Base/Crypto.s.dfy"
include "../lib/Base/Option.s.dfy"
include "../BlockCacheSystem/BlockCache.i.dfy"
include "KVList.i.dfy"

//
// Raises ImpLMarshallingModel by converting indirection table sectors
// up from IndirectionTableModel.IndirectionTable to
// BlockCache.IndirectionTable (and leaving pivot node sectors alone).
// (This gets used as part of the interpretation function in a refinement
// proof.)
//
// TODO(thance): This structure is convoluted. Travis has some ideas
// for rearranging it. In particular, we might want to make the on-disk
// representation stand alone, so that we could later prove properties
// about version mutationts in the file system: that you can read old disks.
//

module Marshalling {
  import opened GenericMarshalling
  import opened Options
  import opened NativeTypes
  import opened Sequences
  import opened BucketsLib
  import opened BucketWeights
  import BC = BetreeGraphBlockCache
  import BT = PivotBetreeSpec`Internal
  import M = ValueMessage`Internal
  import Pivots = PivotsLib
  import KVList
  import Keyspace = Lexicographic_Byte_Order
  import SeqComparison
  import opened Bounds
  import LBAType
  import ReferenceType`Internal
  import Crypto

  type Reference = BC.Reference
  type LBA = BC.LBA
  type Location = BC.Location
  type Sector = BC.Sector
  type Node = BT.G.Node

  /////// Grammar

  function method BucketGrammar() : G
  ensures ValidGrammar(BucketGrammar())
  {
    GTuple([
      GKeyArray,
      GMessageArray
    ])
  }

  function method PivotNodeGrammar() : G
  ensures ValidGrammar(PivotNodeGrammar())
  {
    GTuple([
        GKeyArray, // pivots
        GUint64Array, // children
        GArray(BucketGrammar()) 
    ])
  }

  function method IndirectionTableGrammar() : G
  ensures ValidGrammar(IndirectionTableGrammar())
  {
    // (Reference, address, len, successor-list) triples
    GArray(GTuple([GUint64, GUint64, GUint64, GUint64Array]))
  }

  function method SectorGrammar() : G
  ensures ValidGrammar(SectorGrammar())
  {
    GTaggedUnion([IndirectionTableGrammar(), PivotNodeGrammar()])    
  }

  /////// Conversion to PivotNode

  predicate isStrictlySortedKeySeqIterate(a: seq<Key>, i: int)
  requires 1 <= i <= |a|
  decreases |a| - i
  ensures isStrictlySortedKeySeqIterate(a, i) <==> Keyspace.IsStrictlySorted(a[i-1..])
  {
    Keyspace.reveal_IsStrictlySorted();

    if i == |a| then (
      true
    ) else (
      if (Keyspace.lt(a[i-1], a[i])) then (
        isStrictlySortedKeySeqIterate(a, i+1)
      ) else (
        false
      )
    )
  }


  predicate {:opaque} isStrictlySortedKeySeq(a: seq<Key>)
  ensures isStrictlySortedKeySeq(a) <==> Keyspace.IsStrictlySorted(a)
  {
    Keyspace.reveal_IsStrictlySorted();

    if |a| >= 2 then (
      isStrictlySortedKeySeqIterate(a, 1)
    ) else (
      true
    )
  }

  function valToStrictlySortedKeySeq(v: V) : (s : Option<seq<Key>>)
  requires ValidVal(v)
  requires ValInGrammar(v, GKeyArray)
  ensures s.Some? ==> Keyspace.IsStrictlySorted(s.value)
  ensures s.Some? ==> |s.value| == |v.baa|
  decreases |v.baa|
  {
    if isStrictlySortedKeySeq(v.baa) then
      var blah : seq<Key> := v.baa;
      Some(v.baa)
    else
      None
  }

  function valToPivots(v: V) : (s : Option<seq<Key>>)
  requires ValidVal(v)
  requires ValInGrammar(v, GKeyArray)
  ensures s.Some? ==> Pivots.WFPivots(s.value)
  ensures s.Some? ==> |s.value| == |v.baa|
  {
    var s := valToStrictlySortedKeySeq(v);
    if s.Some? && (|s.value| > 0 ==> |s.value[0]| != 0) then (
      if |s.value| > 0 then (
        SeqComparison.reveal_lte();
        Keyspace.IsNotMinimum([], s.value[0]);
        s
      ) else (
        s
      )
    ) else (
      None
    )
  }

  function {:fuel ValInGrammar,2} valToMessageSeq(v: V) : (s : Option<seq<Message>>)
  requires ValidVal(v)
  requires ValInGrammar(v, GMessageArray)
  ensures s.Some? ==> forall i | 0 <= i < |s.value| :: s.value[i] != M.IdentityMessage()
  ensures s.Some? ==> |s.value| == |v.ma|
  decreases |v.ma|
  {
    assert forall i | 0 <= i < |v.ma| :: ValidMessage(v.ma[i]);
    Some(v.ma)
  }

  function {:fuel ValInGrammar,2} valToBucket(v: V, pivotTable: seq<Key>, i: int) : (s : Option<KVList.Kvl>)
  requires ValidVal(v)
  requires ValInGrammar(v, BucketGrammar())
  requires Pivots.WFPivots(pivotTable)
  requires 0 <= i <= |pivotTable|
  {
    var keys := valToStrictlySortedKeySeq(v.t[0]);
    var values := valToMessageSeq(v.t[1]);

    if keys.Some? && values.Some? then (
      var kvl := KVList.Kvl(keys.value, values.value);

      if KVList.WF(kvl) && WFBucketAt(KVList.I(kvl), pivotTable, i) then
        Some(kvl)
      else
        None
    ) else (
      None
    )
  }

  function valToBuckets(a: seq<V>, pivotTable: seq<Key>) : (s : Option<seq<Bucket>>)
  requires Pivots.WFPivots(pivotTable)
  requires forall i | 0 <= i < |a| :: ValidVal(a[i])
  requires forall i | 0 <= i < |a| :: ValInGrammar(a[i], BucketGrammar())
  requires |a| <= |pivotTable| + 1
  ensures s.Some? ==> |s.value| == |a|
  ensures s.Some? ==> forall i | 0 <= i < |s.value| :: WFBucketAt(s.value[i], pivotTable, i)
  {
    if |a| == 0 then
      Some([])
    else (
      match valToBuckets(DropLast(a), pivotTable) {
        case None => None
        case Some(pref) => (
          match valToBucket(Last(a), pivotTable, |pref|) {
            case Some(bucket) => Some(pref + [KVList.I(bucket)])
            case None => None
          }
        )
      }
    )
  }

  function method valToChildren(v: V) : Option<seq<Reference>>
  requires ValInGrammar(v, GUint64Array)
  {
    Some(v.ua)
  }

  function {:fuel ValInGrammar,2} valToNode(v: V) : (s : Option<Node>)
  requires ValidVal(v)
  requires ValInGrammar(v, PivotNodeGrammar())
  // Pivots.NumBuckets(node.pivotTable) == |node.buckets|
  ensures s.Some? ==> BT.WFNode(s.value)
  {
    assert ValidVal(v.t[0]);
    assert ValidVal(v.t[1]);
    assert ValidVal(v.t[2]);
    var pivots_len := |v.t[0].baa| as uint64;
    var children_len := |v.t[1].ua| as uint64;
    var buckets_len := |v.t[2].a| as uint64;

    if (
       && pivots_len <= MaxNumChildrenUint64() - 1
       && (children_len == 0 || children_len == pivots_len + 1)
       && buckets_len == pivots_len + 1
    ) then (
      assert ValidVal(v.t[0]);
      match valToPivots(v.t[0]) {
        case None => None
        case Some(pivots) => (
          match valToChildren(v.t[1]) {
            case None => None
            case Some(children) => (
              assert ValidVal(v.t[2]);
              match valToBuckets(v.t[2].a, pivots) {
                case None => None
                case Some(buckets) => (
                  if WeightBucketList(buckets) <= MaxTotalBucketWeight() then (
                    var node := BT.G.Node(
                      pivots,
                      if |children| == 0 then None else Some(children),
                      buckets);
                    Some(node)
                  ) else (
                    None
                  )
                )
              }
            )
          }
        )
      }
    ) else (
      None
    )
  }

  function {:fuel ValInGrammar,3} valToIndirectionTableMaps(a: seq<V>) : (s : Option<BC.IndirectionTable>)
  requires |a| <= IndirectionTableMaxSize()
  requires forall i | 0 <= i < |a| :: ValidVal(a[i])
  requires forall i | 0 <= i < |a| :: ValInGrammar(a[i], GTuple([GUint64, GUint64, GUint64, GUint64Array]))
  ensures s.Some? ==> |s.value.graph| as int == |a|
  ensures s.Some? ==> s.value.graph.Keys == s.value.locs.Keys
  ensures s.Some? ==> forall v | v in s.value.locs.Values :: BC.ValidLocationForNode(v)
  ensures s.Some? ==> forall ref | ref in s.value.graph :: |s.value.graph[ref]| <= MaxNumChildren()
  {
    if |a| == 0 then
      Some(BC.IndirectionTable(map[], map[]))
    else (
      var res := valToIndirectionTableMaps(DropLast(a));
      match res {
        case Some(table) => (
          var tuple := Last(a);
          var ref := tuple.t[0].u;
          var lba := tuple.t[1].u;
          var len := tuple.t[2].u;
          var succs := Some(tuple.t[3].ua);
          match succs {
            case None => None
            case Some(succs) => (
              var loc := LBAType.Location(lba, len);
              if ref in table.graph || lba == 0 || !LBAType.ValidLocation(loc) || |succs| as int > MaxNumChildren() then (
                None
              ) else (
                Some(BC.IndirectionTable(table.locs[ref := loc], table.graph[ref := succs]))
              )
            )
          }
        )
        case None => None
      }
    )
  }

  function valToIndirectionTable(v: V) : (s : Option<BC.IndirectionTable>)
  requires ValidVal(v)
  requires ValInGrammar(v, IndirectionTableGrammar())
  ensures s.Some? ==> BC.WFCompleteIndirectionTable(s.value)
  {
    if |v.a| <= IndirectionTableMaxSize() then (
      var t := valToIndirectionTableMaps(v.a);
      match t {
        case Some(res) => (
          if BT.G.Root() in res.graph && BC.GraphClosed(res.graph) then (
            Some(res)
          ) else (
            None
          )
        )
        case None => None
      }
    ) else (
      None
    )
  }

  function valToSector(v: V) : (s : Option<Sector>)
  requires ValidVal(v)
  requires ValInGrammar(v, SectorGrammar())
  {
    if v.c == 0 then (
      match valToIndirectionTable(v.val) {
        case Some(s) => Some(BC.SectorIndirectionTable(s))
        case None => None
      }
    ) else (
      match valToNode(v.val) {
        case Some(s) => Some(BC.SectorBlock(s))
        case None => None
      }
    )
  }

  /////// Marshalling and de-marshalling

  function {:opaque} parseSector(data: seq<byte>) : (s : Option<Sector>)
  //ensures s.Some? ==> SM.WFSector(s.value)
  {
    if |data| < 0x1_0000_0000_0000_0000 then (
      match parse_Val(data, SectorGrammar()).0 {
        case Some(v) => valToSector(v)
        case None => None
      }
    ) else (
      None
    )
  }
}
