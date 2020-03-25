include "PackedStringArray.i.dfy"
include "../Base/total_order_impl.i.dfy"
include "BucketsLib.i.dfy"

module PackedKV {
  import PSA = PackedStringArray
  import opened NativeTypes
  import Keyspace = Lexicographic_Byte_Order_Impl
  import opened KeyType
  import opened ValueType`Internal
  import opened ValueMessage
  import opened BucketsLib
  import opened Options
  import opened Sequences
  
  datatype Pkv = Pkv(
      keys: PSA.Psa,
      messages: PSA.Psa)

  predicate ValidKeyByteString(s: seq<byte>)
  {
    |s| <= KeyType.MaxLen() as int
  }

  predicate ValidMessageByteString(s: seq<byte>)
  {
    |s| <= ValueType.MaxLen() as int
  }

  predicate ValidStringLens<A>(strs: seq<seq<A>>, upper_bound: nat)
  {
    forall i | 0 <= i < |strs| :: |strs[i]| <= upper_bound
  }

  predicate ValidKeyLens<A>(strs: seq<seq<A>>)
  {
    ValidStringLens(strs, KeyType.MaxLen() as nat)
  }

  predicate ValidMessageLens<A>(strs: seq<seq<A>>)
  {
    ValidStringLens(strs, ValueType.MaxLen() as nat)
  }

  function method byteString_to_Message(s: seq<byte>) : Message
  requires |s| < 0x1_0000_0000
  {
    if |s| as uint64 <= ValueType.MaxLen() then (
      Define(s)
    ) else (
      // NOTE(travis)
      // It's just convenient to make this function total, so
      // we just do this if the byte string is invalid.
      Define(ValueType.DefaultValue())
    )
  }

  function IKeys(psa: PSA.Psa) : (res : seq<Key>)
  requires PSA.WF(psa)
  requires ValidStringLens(PSA.I(psa), KeyType.MaxLen() as nat)
  {
    PSA.I(psa)
  }

  function {:opaque} psaSeq_Messages(psa: PSA.Psa, i: int) : (res : seq<Message>)
  requires PSA.WF(psa)
  requires 0 <= i <= |psa.offsets|
  ensures |res| == i
  ensures forall j | 0 <= j < i :: res[j] == byteString_to_Message(PSA.psaElement(psa, j as uint64))
  {
    if i == 0 then [] else psaSeq_Messages(psa, i-1) + [
        byteString_to_Message(PSA.psaElement(psa, (i-1) as uint64))]
  }

  function IMessages(psa: PSA.Psa) : (res : seq<Message>)
  requires PSA.WF(psa)
  {
    psaSeq_Messages(psa, |psa.offsets|)
  }

  predicate WF(pkv: Pkv) {
    && PSA.WF(pkv.keys)
    && PSA.WF(pkv.messages)
    && |pkv.keys.offsets| == |pkv.messages.offsets|
    && ValidStringLens(PSA.I(pkv.keys), KeyType.MaxLen() as nat)
    && ValidStringLens(PSA.I(pkv.messages), ValueType.MaxLen() as nat)
    && IdentityMessage() !in IMessages(pkv.messages)
  }

  function IMap(pkv: Pkv) : (bucket : BucketMap)
  requires WF(pkv)
  ensures WFBucketMap(bucket)
  {
    assert IdentityMessage() !in Set(IMessages(pkv.messages));
    BucketMapOfSeq(IKeys(pkv.keys), IMessages(pkv.messages))
  }

  predicate SortedKeys(pkv: Pkv)
  requires WF(pkv)
  {
    Keyspace.Ord.IsStrictlySorted(IKeys(pkv.keys))
  }

  function I(pkv: Pkv) : (bucket : Bucket)
  requires WF(pkv)
  ensures WFBucket(bucket)
  {
    // Note that this might not be WellMarshalled
    BucketMapWithSeq(IMap(pkv), IKeys(pkv.keys), IMessages(pkv.messages))
  }

  method ComputeValidStringLens(psa: PSA.Psa, upper_bound: uint64)
  returns (b: bool)
  requires PSA.WF(psa)
  ensures b == ValidStringLens(PSA.I(psa), upper_bound as nat)
  {
    var i: uint64 := 0;

    while i < PSA.psaNumStrings(psa)
      invariant i <= PSA.psaNumStrings(psa)
      invariant forall j | 0 <= j < i :: |PSA.I(psa)[j]| <= upper_bound as nat
    {
      assert |PSA.I(psa)[i]| == PSA.psaEnd(psa, i) as nat - PSA.psaStart(psa, i) as nat;
      if upper_bound < PSA.psaEnd(psa, i) as uint64 - PSA.psaStart(psa, i) as uint64 {
        b := false;
        return;
      }
      i := i + 1;
    }
    
    return true;
  }

  function SizeOfPkv(pkv: Pkv) : int
  {
    PSA.SizeOfPsa(pkv.keys) + PSA.SizeOfPsa(pkv.messages)
  }

  function method SizeOfPkvUint64(pkv: Pkv) : uint64
  requires WF(pkv)
  {
    PSA.SizeOfPsaUint64(pkv.keys) + PSA.SizeOfPsaUint64(pkv.messages)
  }

  function method WeightPkv(pkv: Pkv) : uint64
  requires WF(pkv)
  {
    4 * |pkv.keys.offsets| as uint64 + |pkv.keys.data| as uint64 +
    4 * |pkv.messages.offsets| as uint64 + |pkv.messages.data| as uint64
  }

  // I don't think we need these if we use the generic marshaling code. -- rob
  
  // function parse_Pkv(data: seq<byte>) : (res : (Option<Pkv>, seq<byte>))
  // ensures res.0.Some? ==> WF(res.0.value)
  // {
  //   var (keys, rest1) := PSA.parse_Psa(data);
  //   if keys.Some? then (
  //     if ValidKeyLens(PSA.I(keys.value)) then (
  //       var (messages, rest2) := PSA.parse_Psa(rest1);
  //       if messages.Some?
  //           && |keys.value.offsets| == |messages.value.offsets| then (
  //         var res := Pkv(keys.value, messages.value);
  //         (Some(res), rest2)
  //       ) else (
  //         (None, [])
  //       )
  //     ) else (
  //       (None, [])
  //     )
  //   ) else (
  //     (None, [])
  //   )
  // }

  // method Parse_Pkv(data: seq<byte>, index:uint64)
  // returns (pkv: Option<Pkv>, rest_index: uint64)
  // requires index as int <= |data|
  // requires |data| < 0x1_0000_0000_0000_0000
  // ensures rest_index as int <= |data|
  // ensures var (pkv', rest') := parse_Pkv(data[index..]);
  //     && pkv == pkv'
  //     && data[rest_index..] == rest'
  // {
  //   var keys, rest1 := PSA.Parse_Psa(data, index);
  //   if keys.Some? {
  //     // TODO we iterate twice, once to check sortedness, another
  //     // to check lengths, we could consolidate.
  //     var isValidKeyLens := ComputeValidStringLens(keys.value, KeyType.MaxLen());
  //     if isValidKeyLens {
  //       var messages, rest2 := PSA.Parse_Psa(data, rest1);
  //       if messages.Some?
  //           && |keys.value.offsets| as uint64 == |messages.value.offsets| as uint64 {
  //         pkv := Some(Pkv(keys.value, messages.value));
  //         rest_index := rest2;
  //       } else {
  //         pkv := None;
  //         rest_index := |data| as uint64;
  //       }
  //     } else {
  //       pkv := None;
  //       rest_index := |data| as uint64;
  //     }
  //   } else {
  //     pkv := None;
  //     rest_index := |data| as uint64;
  //   }
  // }

  function method FirstKey(pkv: Pkv) : Key
  requires WF(pkv)
  requires |pkv.keys.offsets| > 0
  {
    assert PSA.FirstElement(pkv.keys) == PSA.I(pkv.keys)[0];
    PSA.FirstElement(pkv.keys)
  }

  function method LastKey(pkv: Pkv) : Key
  requires WF(pkv)
  requires |pkv.keys.offsets| > 0
  {
    assert PSA.LastElement(pkv.keys) == Last(PSA.I(pkv.keys));
    PSA.LastElement(pkv.keys)
  }

  function method GetKey(pkv: Pkv, i: uint64) : Key
  requires WF(pkv)
  requires 0 <= i as int < |pkv.keys.offsets|
  {
    assert PSA.psaElement(pkv.keys, i) == PSA.I(pkv.keys)[i];
    PSA.psaElement(pkv.keys, i)
  }

  function method GetMessage(pkv: Pkv, i: uint64) : Message
  requires WF(pkv)
  requires 0 <= i as int < |pkv.messages.offsets|
  {
    byteString_to_Message(PSA.psaElement(pkv.messages, i))
  }

  function binarySearchPostProc(lo: nat, sub: Option<nat>) : Option<nat>
  {
    if sub.Some? then
      Some(lo + sub.value)
    else
      None
  }
  
  method BinarySearchQuery(pkv: Pkv, key: Key)
  returns (msg: Option<Message>)
  requires WF(pkv)
  ensures msg == bucketBinarySearchLookup(I(pkv), key)
  {
    ghost var keys := I(pkv).keys;
    
    var lo: uint64 := 0;
    var hi: uint64 := |pkv.keys.offsets| as uint64;

    assert keys == keys[lo..hi];
    
    while lo < hi
      invariant lo <= hi <= |pkv.keys.offsets| as uint64
      invariant binarySearch(keys, key) == binarySearchPostProc(lo as nat, binarySearch(keys[lo..hi], key))
    {
      var mid: uint64 := (lo + hi) / 2;
      var c := Keyspace.cmp(key, GetKey(pkv, mid));
      if c == 0 {
        msg := Some(GetMessage(pkv, mid));
        return;
      } else if (c < 0) {
        ghost var rkeys := keys[lo..hi];
        ghost var rmid := |rkeys| / 2;
        hi := mid;
        assert keys[lo..hi] == rkeys[..rmid];
      } else {
        lo := mid + 1;
      }
    }

    msg := None;
  }
}
