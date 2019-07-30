include "../lib/NativeTypes.dfy"
include "../lib/total_order.dfy"
include "../lib/sequences.dfy"
include "../lib/Arrays.dfy"
include "../lib/Maps.dfy"

abstract module MutableBtree {
  import opened NativeTypes
  import opened Sequences
  import opened Maps
  import Arrays
  import Keys : Total_Order

  type Key = Keys.Element
  type Value
    
  datatype QueryResult =
    | Found(value: Value)
    | NotFound
    
  function method MaxKeysPerLeaf() : uint64
    ensures 1 < MaxKeysPerLeaf()

  function method MaxChildren() : uint64
    ensures 3 < MaxChildren()

  function method DefaultValue<Value>() : Value
  function method DefaultKey() : Key

  trait Node {
    ghost var subtreeObjects: set<object>
    ghost var allKeys: set<Key>
      
    predicate WF()
      reads this, subtreeObjects
      ensures WF() ==> this in subtreeObjects
      decreases subtreeObjects, 0

    function QueryDef(needle: Key) : QueryResult
      requires WF()
      reads this, subtreeObjects
      decreases subtreeObjects
      
    function Interpretation() : map<Key, Value>
      requires WF()
      ensures forall key :: QueryDef(key).Found? ==> MapsTo(Interpretation(), key, QueryDef(key).value)
      ensures forall key :: QueryDef(key).NotFound? ==> key !in Interpretation()
      reads this, subtreeObjects
      decreases subtreeObjects

    method Query(needle: Key) returns (result: QueryResult)
      requires WF()
      ensures result == QueryDef(needle)
      decreases subtreeObjects

    predicate method Full()
      requires WF()
      reads this, subtreeObjects
      
    method Insert(key: Key, value: Value)
      requires WF()
      requires !Full()
      ensures WF()
      ensures Interpretation() == old(Interpretation())[key := value]
      ensures allKeys == old(allKeys) + {key}
      ensures fresh(subtreeObjects-old(subtreeObjects))
      modifies this, subtreeObjects
      decreases subtreeObjects
      
    static function MergeMaps(left: map<Key, Value>, pivot: Key, right: map<Key, Value>) : map<Key, Value> {
      map key |
        && key in left.Keys + right.Keys
        && (|| (Keys.lt(key, pivot) && key in left)
           || (Keys.lte(pivot, key) && key in right))
         ::
         if Keys.lt(key, pivot) && key in left then left[key]
         else right[key]
    }
    
    predicate SplitEnsures(oldint: map<Key, Value>, pivot: Key, rightnode: Node)
      reads this, subtreeObjects
      reads rightnode, rightnode.subtreeObjects
    {
      && WF()
      && !Full()
      && rightnode.WF()
      && !rightnode.Full()
      && MergeMaps(Interpretation(), pivot, rightnode.Interpretation()) == oldint
      && (forall key :: key in allKeys ==> Keys.lt(key, pivot))
      && (forall key :: key in rightnode.allKeys ==> Keys.lte(pivot, key))
    }
      
    method Split() returns (ghost wit: Key, pivot: Key, rightnode: Node)
      requires WF()
      requires Full()
      ensures SplitEnsures(old(Interpretation()), pivot, rightnode)
      ensures allKeys <= old(allKeys)
      ensures rightnode.allKeys <= old(allKeys)
      ensures pivot in old(allKeys)
      ensures wit in old(allKeys)
      ensures Keys.lt(wit, pivot)
      ensures subtreeObjects <= old(subtreeObjects)
      ensures subtreeObjects !! rightnode.subtreeObjects
      ensures fresh(rightnode.subtreeObjects - old(subtreeObjects))
      modifies this
  }
    
  class Leaf extends Node {
    var nkeys : uint64
    var keys: array<Key>
    var values: array<Value>

    predicate WF()
      reads this, subtreeObjects
      ensures WF() ==> this in subtreeObjects
      decreases subtreeObjects, 0
    {
      && subtreeObjects == {this, keys, values}
      && keys != values
      && keys.Length == MaxKeysPerLeaf() as int
      && values.Length == MaxKeysPerLeaf() as int
      && 0 <= nkeys <= keys.Length as uint64
      && Keys.IsStrictlySorted(keys[..nkeys])
      && allKeys == set key | key in multiset(keys[..nkeys])
    }

    function QueryDef(needle: Key) : (result: QueryResult)
      requires WF()
      reads subtreeObjects
    {
      var pos: int := Keys.LargestLt(keys[..nkeys], needle);
      if (pos + 1) as uint64 < nkeys && keys[pos+1] == needle then Found(values[pos+1])
      else NotFound
    }
    
    function Interpretation() : map<Key, Value>
      requires WF()
      ensures forall key :: QueryDef(key).Found? ==> MapsTo(Interpretation(), key, QueryDef(key).value)
      ensures forall key :: QueryDef(key).NotFound? ==> key !in Interpretation()
      reads this, subtreeObjects
      decreases subtreeObjects
    {
      Keys.reveal_IsStrictlySorted();
      map k | (k in multiset(keys[..nkeys])) :: values[IndexOf(keys[..nkeys], k)]
    }


    method Query(needle: Key) returns (result: QueryResult)
      requires WF()
      ensures result == QueryDef(needle)
      decreases subtreeObjects
    {
      Keys.reveal_IsStrictlySorted();
      var pos: int := Keys.ArrayLargestLte(keys, 0, nkeys as int, needle);
      if 0 <= pos && keys[pos] == needle {
        result := Found(values[pos]);
      } else {
        result := NotFound;
      }
    }

    predicate method Full()
      requires WF()
      reads this, subtreeObjects
    {
      nkeys >= MaxKeysPerLeaf()
    }
    
    method Insert(key: Key, value: Value)
      requires WF()
      requires !Full()
      ensures WF()
      ensures Interpretation() == old(Interpretation())[key := value]
      ensures allKeys == old(allKeys) + {key}
      ensures fresh(subtreeObjects-old(subtreeObjects))
      modifies this, subtreeObjects
      decreases subtreeObjects
    {
      var pos: int := Keys.ArrayLargestLte(keys, 0, nkeys as int, key);

      if 0 <= pos && keys[pos] == key {
        values[pos] := value;
      } else {
        ghost var oldkeys := keys[..nkeys];
        Arrays.Insert(keys, nkeys as int, key, pos + 1);
        Arrays.Insert(values, nkeys as int, value, pos + 1);
        nkeys := nkeys + 1;
        allKeys := allKeys + {key};

        InsertMultiset(oldkeys, key, pos+1); // OBSERVE
        Keys.strictlySortedInsert(oldkeys, key, pos); // OBSERVE
      }
    }

    method Split() returns (ghost wit: Key, pivot: Key, rightnode: Node)
      requires WF()
      requires Full()
      ensures SplitEnsures(old(Interpretation()), pivot, rightnode)
      ensures allKeys <= old(allKeys)
      ensures rightnode.allKeys <= old(allKeys)
      ensures pivot in old(allKeys)
      ensures wit in old(allKeys)
      ensures Keys.lt(wit, pivot)
      ensures subtreeObjects <= old(subtreeObjects)
      ensures subtreeObjects !! rightnode.subtreeObjects
      ensures fresh(rightnode.subtreeObjects - old(subtreeObjects))
      modifies this
    {
      Keys.reveal_IsStrictlySorted();
      var right := new Leaf();
      var boundary := nkeys/2;
      Arrays.Memcpy(right.keys, 0, keys[boundary..nkeys]); // FIXME: remove conversion to seq
      Arrays.Memcpy(right.values, 0, values[boundary..nkeys]); // FIXME: remove conversion to seq
      right.nkeys := nkeys - boundary;
      nkeys := boundary;
      allKeys := set key | key in multiset(keys[..nkeys]);
      right.allKeys := set key | key in multiset(right.keys[..right.nkeys]);
      wit := keys[0];
      pivot := right.keys[0];
      rightnode := right;
    }
      
    constructor()
      ensures WF()
      ensures Interpretation() == map[]
      ensures !Full()
      ensures fresh(keys)
      ensures fresh(values)
    {
      nkeys := 0;
      keys := new Key[MaxKeysPerLeaf()](_ => DefaultKey());
      values := new Value[MaxKeysPerLeaf()](_ => DefaultValue());
      allKeys := {};
      subtreeObjects := {this, keys, values};
    }
  }

  class Index extends Node {
    var nchildren: uint64
    var pivots: array<Key>
    var children: array<Node?>

    predicate WF()
      reads this, subtreeObjects
      ensures WF() ==> this in subtreeObjects
      decreases subtreeObjects, 0
    {
      && {this, pivots, children} <= subtreeObjects
      && pivots != children
      && pivots.Length == (MaxChildren() as int) - 1
      && children.Length == MaxChildren() as int
      && 1 <= nchildren <= MaxChildren()
      && Keys.IsStrictlySorted(pivots[..nchildren-1])
      && (forall i :: 0 <= i < nchildren ==> children[i] != null)
      && (forall i :: 0 <= i < nchildren ==> children[i] in subtreeObjects)
      && (forall i :: 0 <= i < nchildren ==> children[i].subtreeObjects < subtreeObjects)
      && (forall i :: 0 <= i < nchildren ==> {this, pivots, children} !! children[i].subtreeObjects)
      && (forall i :: 0 <= i < nchildren ==> children[i].WF())
      && (forall i, j :: 0 <= i < j < nchildren ==> children[i].subtreeObjects !! children[j].subtreeObjects)
      && (forall i, key :: 0 <= i < nchildren-1 && key in children[i].allKeys ==> Keys.lt(key, pivots[i]))
      && (forall i, key :: 0 < i < nchildren   && key in children[i].allKeys ==> Keys.lte(pivots[i-1], key))
    }

    function QueryDef(needle: Key) : QueryResult
      requires WF()
      reads this, subtreeObjects
      decreases subtreeObjects
    {
      var pos := Keys.LargestLte(pivots[..nchildren-1], needle);
      children[pos + 1].QueryDef(needle)
    }
    
    function Interpretation() : (result: map<Key, Value>)
      requires WF()
      ensures forall key :: QueryDef(key).Found? ==> MapsTo(result, key, QueryDef(key).value)
      ensures forall key :: QueryDef(key).NotFound? ==> key !in Interpretation()
      reads this, subtreeObjects
      decreases subtreeObjects
    {
      // This is just to prove finiteness.  Thanks to James Wilcox for the trick:
      // https://stackoverflow.com/a/47585360
      var allkeys := set key, i | 0 <= i < nchildren && key in children[i].Interpretation() :: key;
      var result := map key |
        && key in allkeys
        && key in children[Keys.LargestLte(pivots[..nchildren-1], key) + 1].Interpretation()
        :: children[Keys.LargestLte(pivots[..nchildren-1], key) + 1].Interpretation()[key];

      assert forall key :: QueryDef(key).Found? ==> key in children[Keys.LargestLte(pivots[..nchildren-1], key)+1].Interpretation();
        
      result
    }

    method Query(needle: Key) returns (result: QueryResult)
      requires WF()
      ensures result == QueryDef(needle)
      decreases subtreeObjects
    {
      var pos := Keys.ArrayLargestLte(pivots, 0, (nchildren as int)-1, needle);
      result := children[pos + 1].Query(needle);
    }

    predicate Full()
      requires WF()
      reads this, subtreeObjects
    {
      nchildren == MaxChildren()
    }

    // static lemma ChildSplitPreservesWF(
    //   oldpivots: seq<Key>,
    //   oldchildren: seq<Node?>,
    //   oldsubtreeObjects: set<object>,
    //   pos: int,
    //   newpivots: seq<Key>,
    //   newchildren: seq<Node?>,
    //   newsubtreeObjects: seq<object>)
    //   requires 

    method SplitChild(key: Key, childidx: uint64) returns (newchildidx: uint64)
      requires WF()
      requires !Full()
      requires childidx as int == 1 + Keys.LargestLte(pivots[..nchildren-1], key)
      requires children[childidx].Full()
      ensures WF()
      ensures Interpretation() == old(Interpretation())
      ensures newchildidx as int == 1 + Keys.LargestLte(pivots[..nchildren-1], key)
      ensures !children[newchildidx].Full()
      ensures allKeys == old(allKeys)
      ensures fresh(subtreeObjects-old(subtreeObjects))
      modifies this, subtreeObjects
    {
        var wit, pivot, right := children[childidx].Split();
        Arrays.Insert(pivots, (nchildren as int)-1, pivot, childidx as int);
        Arrays.Insert(children, nchildren as int, right, childidx as int +1);
        nchildren := nchildren + 1;
        subtreeObjects := subtreeObjects + right.subtreeObjects;
        if Keys.lte(pivot, key) {
          newchildidx := childidx + 1;
        } else {
          newchildidx := childidx;
        }
        assume false;
        
    //     Keys.strictlySortedInsert(old(pivots[..nchildren-1]), pivot, childidx-1);
    //     assert Keys.IsStrictlySorted(pivots[..nchildren-1]);
    //     forall i: int | 0 <= i < nchildren as int
    //       ensures children[i] != null
    //       ensures children[i] in subtreeObjects
    //       ensures children[i].subtreeObjects < subtreeObjects
    //       ensures {this, pivots, children} !! children[i].subtreeObjects
    //     {
    //       if childidx + 1 < i {
    //         assert children[i] == old(children[i-1]);
    //       }
    //     }
    //     forall i: int | 0 <= i < nchildren as int
    //       ensures children[i].WF()
    //     {
    //       if i < childidx + 1 {
    //         assert children[i] == old(children[i]);
    //       } else if childidx + 1 < i {
    //         assert children[i] == old(children[i-1]);
    //       }
    //     }
    //     forall i: int, j: int | 0 <= i < j < nchildren as int
    //       ensures children[i].subtreeObjects !! children[j].subtreeObjects
    //     {
    //       if j < childidx + 1 {
    //       } else if j == childidx + 1 {
    //       } else if i < childidx + 1 < j {
    //         assert childidx + 1 < j;
    //         assert children[j] == old(children[j-1]);
    //       } else if i == childidx + 1 {
    //         assert childidx + 1 < j;
    //         assert children[j] == old(children[j-1]);
    //       } else if childidx + 1 < i {
    //         assert children[i] == old(children[i-1]);
    //         assert childidx + 1 < j;
    //         assert children[j] == old(children[j-1]);
    //       }
    //     }
    //     forall i: int, key | 0 <= i < (nchildren as int)-1 && key in children[i].allKeys
    //       ensures Keys.lt(key, pivots[i])
    //     {
    //       if childidx + 1 < i {
    //         assert children[i] == old(children[i-1]);
    //       }
    //     }
    //     forall i: int, key | 0 < i < nchildren as int && key in children[i].allKeys
    //       ensures Keys.lt(pivots[i-1], key)
    //     {
    //       if childidx + 1 < i {
    //         assert children[i] == old(children[i-1]);
    //       }
    //     }
    //     assert WF();
    //     //assert Interpretation() == old(Interpretation());

    }
    
    method Insert(key: Key, value: Value)
      requires WF()
      requires !Full()
      ensures WF()
      ensures Interpretation() == old(Interpretation())[key := value]
      ensures allKeys == old(allKeys) + {key}
      ensures fresh(subtreeObjects - old(subtreeObjects))
      modifies this, subtreeObjects
      decreases subtreeObjects
    {
      var pos: int := Keys.ArrayLargestLte(pivots, 0, (nchildren as int)-1, key);
      var childidx := (pos + 1) as uint64;
      if children[pos+1].Full() {
        childidx := SplitChild(key, childidx);
      }
      assume children[childidx].subtreeObjects < old(subtreeObjects);
      children[childidx].Insert(key, value);
      subtreeObjects := subtreeObjects + children[childidx].subtreeObjects;
      allKeys := allKeys + {key};
      assume false;
    }

    function UnionSubtreeObjects() : set<object>
      requires nchildren as int <= children.Length
      requires forall i :: 0 <= i < nchildren ==> children[i] != null
      reads this, children, children[..nchildren]
    {
      set o, i | 0 <= i < nchildren && o in children[i].subtreeObjects :: o
    }
    
    method Split() returns (ghost wit: Key, pivot: Key, rightnode: Node)
      requires WF()
      requires Full()
      ensures SplitEnsures(old(Interpretation()), pivot, rightnode)
      ensures allKeys <= old(allKeys)
      ensures rightnode.allKeys <= old(allKeys)
      ensures pivot in old(allKeys)
      ensures wit in old(allKeys)
      ensures Keys.lt(wit, pivot)
      ensures subtreeObjects <= old(subtreeObjects)
      ensures subtreeObjects !! rightnode.subtreeObjects
      ensures fresh(rightnode.subtreeObjects - old(subtreeObjects))
      modifies this
    {
      var right := new Index();
      var boundary := nchildren/2;
      Arrays.Memcpy(right.pivots, 0, pivots[boundary..nchildren-1]); // FIXME: remove conversion to seq
      Arrays.Memcpy(right.children, 0, children[boundary..nchildren]); // FIXME: remove conversion to seq
      right.nchildren := nchildren - boundary;
      nchildren := boundary;
      subtreeObjects := {this, pivots, children} + UnionSubtreeObjects();
      right.subtreeObjects := right.subtreeObjects + right.UnionSubtreeObjects();

      wit := right.pivots[0];
      pivot := pivots[boundary-1];
      rightnode := right;
      assume false;
      
      // Keys.reveal_IsStrictlySorted();
      // assert WF();
      // assert rightnode.WF();
      // assert MergeMaps(Interpretation(), pivot, rightnode.Interpretation()) == old(Interpretation());
    }

    constructor()
      ensures nchildren == 0
      ensures pivots.Length == (MaxChildren() as int)-1
      ensures children.Length == (MaxChildren() as int)
      ensures forall i :: 0 <= i < children.Length ==> children[i] == null
      ensures subtreeObjects == {this, pivots, children}
      ensures allKeys == {}
      ensures fresh(pivots)
      ensures fresh(children)
    {
      pivots := new Key[MaxChildren()-1](_ => DefaultKey());
      children := new Node?[MaxChildren()](_ => null);
      nchildren := 0;
      subtreeObjects := {this, pivots, children};
      allKeys := {};
    }
  }

  class MutableBtree {
    var root: Node

    function Interpretation() : map<Key, Value>
      requires root.WF()
      reads this, root, root.subtreeObjects
    {
      root.Interpretation()
    }

    method Query(needle: Key) returns (result: QueryResult)
      requires root.WF()
      ensures result == NotFound ==> needle !in Interpretation()
      ensures result.Found? ==> needle in Interpretation() && Interpretation()[needle] == result.value
    {
      result := root.Query(needle);
    }

    method Insert(key: Key, value: Value)
      requires root.WF()
      ensures root.WF()
      ensures Interpretation() == old(Interpretation())[key := value]
      modifies this, root, root.subtreeObjects
    {
      if root.Full() {
        var newroot := new Index();
        newroot.children[0] := root;
        newroot.nchildren := 1;
        newroot.subtreeObjects := newroot.subtreeObjects + root.subtreeObjects;
        newroot.allKeys := root.allKeys;
        root := newroot;
      }
      assume false;
      root.Insert(key, value);
    }
    
    constructor()
      ensures root.WF()
      ensures Interpretation() == map[]
    {
      root := new Leaf();
    }
  }
}
