include "../lib/NativeTypes.s.dfy"
include "../lib/MutableMap.i.dfy"

module GraphSpec {
  import opened NativeTypes

  type Reference = uint64

  datatype Constants = Constants
  datatype Variables = Variables(graph: map<Reference, set<Reference>>)

  function method Root(): Reference { 0 }

  predicate Inv(k: Constants, s: Variables)
  {
    && Root() in s.graph
    && forall r | r in s.graph :: forall p | p in s.graph[r] :: p in s.graph
  }

  predicate Init(k: Constants, s': Variables)
  {
    && s' == Variables(map[Root() := {}])
  }

  predicate Alloc(k: Constants, s: Variables, s': Variables, ref: Reference)
  {
    && ref !in s.graph
    && ref as nat < 0x1_0000_0000_0000_0000

    && s' == s.(graph := s.graph[ref := {}])
  }

  predicate Dealloc(k: Constants, s: Variables, s': Variables, ref: Reference)
  {
    && ref in s.graph
    && forall r | r in s.graph :: ref !in s.graph[r]

    && s' == s.(graph := map r | r in s.graph && r != ref :: r := s.graph[r])
  }

  predicate Attach(k: Constants, s: Variables, s': Variables, parent: Reference, ref: Reference)
  {
    && parent in s.graph
    && ref in s.graph
    && ref !in s.graph[parent]

    && s' == s.(graph := s.graph[parent := (s.graph[parent] + {ref})])
  }

  predicate Detach(k: Constants, s: Variables, s': Variables, parent: Reference, ref: Reference)
  {
    && parent in s.graph
    && ref in s.graph
    && ref in s.graph[parent]

    && s' == s.(graph := s.graph[parent := (s.graph[parent] - {ref})])
  }

  datatype Step =
    | AllocStep(ref: Reference) 
    | DeallocStep(ref: Reference)
    | AttachStep(parent: Reference, ref: Reference)
    | DetachStep(parent: Reference, ref: Reference)

  predicate NextStep(k: Constants, s: Variables, s': Variables, step: Step)
  {
    match step {
      case AllocStep(ref) => Alloc(k, s, s', ref)
      case DeallocStep(ref) => Dealloc(k, s, s', ref)
      case AttachStep(parent, ref) => Attach(k, s, s', parent, ref)
      case DetachStep(parent, ref) => Detach(k, s, s', parent, ref)
    }
  }

  predicate Next(k: Constants, s: Variables, s': Variables)
  {
    exists step: Step :: NextStep(k, s, s', step)
  }
}

module FunctionalGraph /* refines GraphSpec */ {
  import S = GraphSpec

  type Reference = S.Reference

  datatype Constants = Constants

  datatype GraphValue = GraphValue(adjList: set<Reference>, rc: int)
  datatype Variables = Variables(
      graph: map<Reference, GraphValue>,
      invRc: map<int, set<Reference>>,
      nextRef: Reference)

  function Ik(k: Constants): S.Constants
  {
    S.Constants()
  }

  function I(k: Constants, s: Variables): S.Variables
  {
    S.Variables(map k | k in s.graph :: k := s.graph[k].adjList)
  }

  predicate Inv(k: Constants, s: Variables)
  {
    && S.Inv(Ik(k), I(k, s))

    && (forall r | r in s.graph :: (
      && var c := s.graph[r].rc;
      && c in s.invRc
      && r in s.invRc[c]))
    && (forall c | c in s.invRc :: forall r | r in s.invRc[c] :: r in s.graph)
    && (forall c | c in s.invRc :: forall r | r in s.invRc[c] :: s.graph[r].rc == c)
  }

  function Init(k: Constants): (s': Variables)
  {
    Variables(map[S.Root() := GraphValue({}, 0)], map[], 1)
  }

  datatype AllocResult = AllocResult(s': Variables, ref: Reference)
  function Alloc(k: Constants, s: Variables): (result: AllocResult)
  requires Inv(k, s)
  requires s.nextRef as nat < 0x1_0000_0000_0000_0000 - 1
  // ensures S.Alloc(Ik(k), I(k, s), I(k, result.s'), result.ref)
  {
    AllocResult(
      s
        .(graph := s.graph[s.nextRef := GraphValue({}, 0)])
        .(nextRef := s.nextRef + 1),
      s.nextRef)
  }

  lemma RefinesAlloc(k: Constants, s: Variables, s': Variables) returns (ref: Reference)
  requires Inv(k, s)
  requires s.nextRef as nat < 0x1_0000_0000_0000_0000 - 1
  requires s' == Alloc(k, s).s'
  ensures ref == Alloc(k, s).ref
  ensures Inv(k, s')
  ensures S.Alloc(Ik(k), I(k, s), I(k, s'), ref)
  {
    ref := Alloc(k, s).ref;
    assume S.Inv(Ik(k), I(k, s'));
    assume (forall r | r in s'.graph :: (
      && var c := s'.graph[r].rc;
      && c in s'.invRc
      && r in s'.invRc[c]));
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: r in s'.graph;
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: s'.graph[r].rc == c;
    assert Inv(k, s');
    assume ref !in s.graph;
    assert S.Alloc(Ik(k), I(k, s), I(k, s'), Alloc(k, s).ref);
  }

  function Dealloc(k: Constants, s: Variables, ref: Reference): (s': Variables)
  requires Inv(k, s)
  requires ref in s.graph
  requires 0 in s.invRc && ref in s.invRc[0]
  // ensures S.Dealloc(Ik(k), I(k, s), I(k, s'), ref)
  {
    s
      .(graph := map r | r in s.graph && r != ref :: r := s.graph[r])
      .(invRc := s.invRc[0 := s.invRc[0] - {ref}])
  }

  lemma RefinesDealloc(k: Constants, s: Variables, s': Variables, ref: Reference)
  requires Inv(k, s)
  requires ref in s.graph
  requires 0 in s.invRc && ref in s.invRc[0]
  requires s' == Dealloc(k, s, ref)
  ensures Inv(k, s')
  ensures S.Dealloc(Ik(k), I(k, s), I(k, s'), ref)
  {
    assume S.Inv(Ik(k), I(k, s'));
    assume (forall r | r in s'.graph :: (
      && var c := s'.graph[r].rc;
      && c in s'.invRc
      && r in s'.invRc[c]));
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: r in s'.graph;
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: s'.graph[r].rc == c;
    assert Inv(k, s');
    assume forall r | r in I(k, s).graph :: ref !in I(k, s).graph[r];
    assert S.Dealloc(Ik(k), I(k, s), I(k, s'), ref);
  }

  function Attach(k: Constants, s: Variables, parent: Reference, ref: Reference): (s': Variables)
  requires Inv(k, s)
  requires parent in s.graph
  requires ref in s.graph
  requires ref !in s.graph[parent].adjList
  // ensures S.Attach(Ik(k), I(k, s), I(k, s'), parent, ref)
  {
    var rc := s.graph[ref].rc;
    s
      .(graph := s.graph
        [parent := s.graph[parent].(adjList := (s.graph[parent].adjList + {ref}))]
        [ref := s.graph[ref].(rc := (s.graph[ref].rc + 1))]
      )
      .(invRc := s.invRc
        [rc := s.invRc[rc] - {ref}]
        [(rc + 1) := (if (rc + 1) in s.invRc then s.invRc[rc + 1] else {}) + {ref}]
      )
  }

  lemma RefinesAttach(k: Constants, s: Variables, s': Variables, parent: Reference, ref: Reference)
  requires Inv(k, s)
  requires parent in s.graph
  requires ref in s.graph
  requires ref !in s.graph[parent].adjList
  requires s' == Attach(k, s, parent, ref)
  ensures Inv(k, s')
  ensures S.Attach(Ik(k), I(k, s), I(k, s'), parent, ref)
  {
    assume S.Inv(Ik(k), I(k, s'));
    assume (forall r | r in s'.graph :: (
      && var c := s'.graph[r].rc;
      && c in s'.invRc
      && r in s'.invRc[c]));
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: r in s'.graph;
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: s'.graph[r].rc == c;
    assert Inv(k, s');
    assume I(k, s').graph == I(k, s).graph[parent := (I(k, s).graph[parent] + {ref})];
    assert S.Attach(Ik(k), I(k, s), I(k, s'), parent, ref);
  }

  function Detach(k: Constants, s: Variables, parent: Reference, ref: Reference): (s': Variables)
  requires Inv(k, s)
  requires parent in s.graph
  requires ref in s.graph
  requires ref in s.graph[parent].adjList
  // ensures S.Detach(Ik(k), I(k, s), I(k, s'), parent, ref)
  {
    var rc := s.graph[ref].rc;
    s
      .(graph := s.graph
        [parent := s.graph[parent].(adjList := (s.graph[parent].adjList - {ref}))]
        [ref := s.graph[ref].(rc := (s.graph[ref].rc - 1))]
      )
      .(invRc := s.invRc
        [rc := s.invRc[rc] - {ref}]
        [(rc - 1) := (if (rc - 1) in s.invRc then s.invRc[rc - 1] else {}) + {ref}]
      )
  }

  lemma RefinesDetach(k: Constants, s: Variables, s': Variables, parent: Reference, ref: Reference)
  requires Inv(k, s)
  requires parent in s.graph
  requires ref in s.graph
  requires ref in s.graph[parent].adjList
  requires s' == Detach(k, s, parent, ref)
  ensures Inv(k, s')
  ensures S.Detach(Ik(k), I(k, s), I(k, s'), parent, ref)
  {
    assume S.Inv(Ik(k), I(k, s'));
    assume (forall r | r in s'.graph :: (
      && var c := s'.graph[r].rc;
      && c in s'.invRc
      && r in s'.invRc[c]));
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: r in s'.graph;
    assume forall c | c in s'.invRc :: forall r | r in s'.invRc[c] :: s'.graph[r].rc == c;
    assert Inv(k, s');
    assume I(k, s').graph == I(k, s).graph[parent := (I(k, s).graph[parent] - {ref})];
    assert S.Detach(Ik(k), I(k, s), I(k, s'), parent, ref);
  }

  datatype Step =
    | AllocStep() 
    | DeallocStep(ref: Reference)
    | AttachStep(parent: Reference, ref: Reference)
    | DetachStep(parent: Reference, ref: Reference)

  predicate Admissible(k: Constants, s: Variables, step: Step)
  {
    match step {
      case AllocStep() => (
        && s.nextRef as nat < 0x1_0000_0000_0000_0000 - 1
      )
      case DeallocStep(ref) => (
        && ref in s.graph
        && 0 in s.invRc && ref in s.invRc[0]
      )
      case AttachStep(parent, ref) => (
        && parent in s.graph
        && ref in s.graph
        && ref !in s.graph[parent].adjList
      )
      case DetachStep(parent, ref) => (
        && parent in s.graph
        && ref in s.graph
        && ref in s.graph[parent].adjList
      )
    }
  }

  predicate NextStep(k: Constants, s: Variables, s': Variables, step: Step)
  {
    && Inv(k, s)
    && Admissible(k, s, step)
    && s' == match step {
      case AllocStep() => Alloc(k, s).s'
      case DeallocStep(ref) => Dealloc(k, s, ref)
      case AttachStep(parent, ref) => Attach(k, s, parent, ref)
      case DetachStep(parent, ref) => Detach(k, s, parent, ref)
    }
  }

  predicate Next(k: Constants, s: Variables, s': Variables)
  {
    exists step: Step :: NextStep(k, s, s', step)
  }

  lemma RefinesNextStep(k: Constants, s: Variables, s': Variables, step: Step)
  requires Inv(k, s)
  requires NextStep(k, s, s', step)
  ensures Inv(k, s')
  ensures S.Next(Ik(k), I(k, s), I(k, s'))
  {
    match step {
      case AllocStep() => {
        var ref := RefinesAlloc(k, s, s');
        assert S.NextStep(Ik(k), I(k, s), I(k, s'), S.AllocStep(ref));
      }
      case DeallocStep(ref) => {
        RefinesDealloc(k, s, s', ref);
        assert S.NextStep(Ik(k), I(k, s), I(k, s'), S.DeallocStep(ref));
      }
      case AttachStep(parent, ref) => {
        RefinesAttach(k, s, s', parent, ref);
        assert S.NextStep(Ik(k), I(k, s), I(k, s'), S.AttachStep(parent, ref));
      }
      case DetachStep(parent, ref) => {
        RefinesDetach(k, s, s', parent, ref);
        assert S.NextStep(Ik(k), I(k, s), I(k, s'), S.DetachStep(parent, ref));
      }
    }
  }

  lemma RefinesNext(k: Constants, s: Variables, s': Variables)
  requires Inv(k, s)
  requires Next(k, s, s')
  ensures Inv(k, s')
  ensures S.Next(Ik(k), I(k, s), I(k, s'))
  {
    var step :| NextStep(k, s, s', step);
    RefinesNextStep(k, s, s', step);
  }
}
