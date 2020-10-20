include "/home/rob/projects/veribetrfs/lib/Lang/NativeTypes.s.dfy"

module StaticallySizedMarshalling {
import opened NativeTypes
  
datatype StaticallySizedGrammar =
    SSGUint32
  | SSGUint64
  | SSGArray(len: nat, elt: StaticallySizedGrammar)
  | SSGTuple(t: seq<StaticallySizedGrammar>, names: seq<string>)
  | SSGByteArray(len: nat)
  | SSGUint32Array(len: nat)
  | SSGUint64Array(len: nat)
  | SSGTaggedUnion(cases: seq<StaticallySizedGrammar>, names: seq<string>)
  | SSGPadded(size: nat, delt: G)
  
datatype G = StaticallySizedElement(g: StaticallySizedGrammar)
           | GArray(elt:G)
           | GSSArray(selt: StaticallySizedGrammar)
           | GTuple(t:seq<G>)
           | GByteArray
           | GUint32Array
           | GUint64Array
           | GTaggedUnion(cases:seq<G>)

datatype V = VUint32(v:uint32)
           | VUint64(u:uint64)
           | VArray(a:seq<V>)
           | VTuple(t:seq<V>)
           | VByteArray(b:seq<byte>)
           | VUint32Array(va:seq<uint32>)
           | VUint64Array(ua:seq<uint64>)
           | VCase(c:uint64, val:V)

function SizeOfStaticallySizedGrammarSeq(grammars: seq<StaticallySizedGrammar>) : nat
{
  if |grammars| == 0 then 0
  else SizeOfStaticallySizedGrammarSeq(grammars[..|grammars|-1]) + SizeOfStaticallySizedGrammar(grammars[|grammars|-1])
}

function MaxStaticallySizedGrammar(grammars: seq<StaticallySizedGrammar>) : nat
{
  if |grammars| == 0 then 0
  else
    var prefixMax := SizeOfStaticallySizedGrammarSeq(grammars[..|grammars|-1]);
    var last := SizeOfStaticallySizedGrammar(grammars[|grammars|-1]);
    if prefixMax < last then last
    else prefixMax
}

function SizeOfStaticallySizedGrammar(grammar: StaticallySizedGrammar) : nat
{
  match grammar
    case SSGUint32 => 4
    case SSGUint64 => 8
    case SSGArray(len, elt) =>  len * SizeOfStaticallySizedGrammar(elt)
    case SSGTuple(t, names) =>  SizeOfStaticallySizedGrammarSeq(t)
    case SSGByteArray(len)   => len
    case SSGUint32Array(len) => 4 * len
    case SSGUint64Array(len) => 8 * len
    case SSGTaggedUnion(cases, names) => MaxStaticallySizedGrammar(cases)
    case SSGPadded(size, delt) => size
}

function SizeOfVSeq(vals: seq<V>, grammar: G) : nat
  requires forall i | 0 <= i < |vals| :: ValInGrammar(vals[i], grammar)
  decreases grammar, vals, 1
{
  if |vals| == 0 then 0
  else SizeOfVSeq(vals[..|vals|-1], grammar) + SizeOfV(vals[|vals|-1], grammar)
}

function SizeOfVGSeq(vals: seq<V>, grammars: seq<G>) : nat
  requires |vals| == |grammars|
  requires forall i | 0 <= i < |vals| :: ValInGrammar(vals[i], grammars[i])
  decreases grammars, vals, 1
{
  if |vals| == 0 then 0
  else SizeOfVGSeq(vals[..|vals|-1], grammars[..|grammars|-1]) + SizeOfV(vals[|vals|-1], grammars[|grammars|-1])
}

function SizeOfV(val:V, grammar: G) : nat
  requires ValInGrammar(val, grammar)
  decreases grammar, val, 1
{
  match grammar
    case StaticallySizedElement(g) => SizeOfStaticallySizedGrammar(g)
    case GArray(elt)    => 8 + 8 * |val.a| + SizeOfVSeq(val.a, elt)
    case GSSArray(selt) => |val.a| * SizeOfStaticallySizedGrammar(selt)
    case GTuple(t)      => 8 * |t| + SizeOfVGSeq(val.t, t)
    case GByteArray     => |val.b|
    case GUint32Array   => 4 * |val.va|
    case GUint64Array   => 8 * |val.ua|
    case GTaggedUnion(cases) => 8 + SizeOfV(val.val, cases[val.c])
}
           
predicate ValInStaticallySizedGrammar(val:V, grammar:StaticallySizedGrammar)
  decreases grammar
{
  match grammar
    case SSGUint32 => val.VUint32?
    case SSGUint64 => val.VUint64?
    case SSGArray(len, elt) =>
      && val.VArray?
      && |val.a| == len
      && (forall v :: v in val.a ==> ValInStaticallySizedGrammar(v, grammar.elt))
    case SSGTuple(t, names) =>
      && val.VTuple?
      && |val.t| == |t|
      && forall i :: 0 <= i < |t| ==> ValInStaticallySizedGrammar(val.t[i], t[i])
      
    case SSGByteArray(len)   => val.VByteArray? && |val.b| == len
    case SSGUint32Array(len) => val.VUint32Array? && |val.va| == len
    case SSGUint64Array(len) => val.VUint64Array? && |val.ua| == len

    case SSGTaggedUnion(cases, names) =>
      && val.VCase?
      && (val.c as int) < |cases|
      && ValInStaticallySizedGrammar(val.val, cases[val.c])
    case SSGPadded(size, delt) =>
      && ValInGrammar(val, delt)
      && SizeOfV(val, delt) <= size
}

predicate ValInGrammar(val:V, grammar:G)
  decreases grammar, val, 0
{
  match grammar
    case StaticallySizedElement(g) => ValInStaticallySizedGrammar(val, g)
    case GArray(elt) => val.VArray? && forall v :: v in val.a ==> ValInGrammar(v, elt)
    case GSSArray(selt) => val.VArray? && forall v :: v in val.a ==> ValInStaticallySizedGrammar(v, selt)
    case GTuple(t) =>
      && val.VTuple?
      && |t| == |val.t|
      && forall i :: 0 <= i < |t| ==> ValInGrammar(val.t[i], t[i])
    case GByteArray => val.VByteArray?
    case GUint32Array => val.VUint32Array?
    case GUint64Array => val.VUint64Array?
    case GTaggedUnion(cases) =>
      && val.VCase?
      && (val.c as int) < |cases| &&
      ValInGrammar(val.val, cases[val.c])
}

}
