include "../lib/Base/Option.s.dfy"
include "../lib/Base/SeqComparison.s.dfy"
include "../MapSpec/UI.s.dfy"
include "../MapSpec/UIStateMachine.s.dfy"

module MapSpec refines UIStateMachine {
  import opened ValueType
  import opened KeyType
  import SeqComparison
  import Options

  import UI

  // Users must provide a definition of EmptyValue
  function EmptyValue() : Value {
    ValueType.DefaultValue()
  }

  datatype Constants = Constants()
  type View = imap<Key, Value>
  datatype Variables = Variables(ghost view:View)

  predicate ViewComplete(view:View)
  {
    forall k :: k in view
  }

  predicate WF(s:Variables)
  {
    && ViewComplete(s.view)
  }

  // Dafny black magic: This name is here to give EmptyMap's forall something to
  // trigger on. (Eliminates a /!\ Warning.)
  predicate InDomain(k:Key)
  {
    true
  }

  function EmptyMap() : (zmap : imap<Key,Value>)
      ensures ViewComplete(zmap)
  {
    imap k | InDomain(k) :: EmptyValue()
  }

  predicate Init(k:Constants, s:Variables)
      ensures Init(k, s) ==> WF(s)
  {
    s == Variables(EmptyMap())
  }

  // Can collapse key and result; use the ones that came in uiop for free.
  predicate Query(k:Constants, s:Variables, s':Variables, uiop: UIOp, key:Key, result:Value)
  {
    && uiop == UI.GetOp(key, result)
    && WF(s)
    && result == s.view[key]
    && s' == s
  }

  predicate LowerBound(start: UI.RangeStart, key: Key)

  predicate UpperBound(key: Key, end: UI.RangeEnd)

  predicate InRange(start: UI.RangeStart, key: Key, end: UI.RangeEnd)

  predicate NonEmptyRange(start: UI.RangeStart, end: UI.RangeEnd)

  predicate Succ(k: Constants, s: Variables, s': Variables, uiop: UIOp,
      start: UI.RangeStart, results: seq<UI.SuccResult>, end: UI.RangeEnd)

  predicate Write(k:Constants, s:Variables, s':Variables, uiop: UIOp, key:Key, new_value:Value)
      ensures Write(k, s, s', uiop, key, new_value) ==> WF(s')
  {
    && uiop == UI.PutOp(key, new_value)
    && WF(s)
    && WF(s')
    && s'.view == s.view[key := new_value]
  }

  predicate Stutter(k:Constants, s:Variables, s':Variables, uiop: UIOp)
  {
    && uiop.NoOp?
    && s' == s
  }

  // uiop should be in here, too.
  datatype Step =
      | QueryStep(key: Key, result: Value)
      | WriteStep(key: Key, new_value: Value)
      | SuccStep(start: UI.RangeStart, results: seq<UI.SuccResult>, end: UI.RangeEnd)
      | StutterStep

  predicate NextStep(k:Constants, s:Variables, s':Variables, uiop: UIOp, step:Step)
  {
    match step {
      case QueryStep(key, result) => Query(k, s, s', uiop, key, result)
      case WriteStep(key, new_value) => Write(k, s, s', uiop, key, new_value)
      case SuccStep(start, results, end) => Succ(k, s, s', uiop, start, results, end)
      case StutterStep() => Stutter(k, s, s', uiop)
    }
  }

  predicate Next(k:Constants, s:Variables, s':Variables, uiop: UIOp)
  {
    exists step :: NextStep(k, s, s', uiop, step)
  }

  predicate Inv(k:Constants, s:Variables)
  {
    WF(s)
  }

  lemma InitImpliesInv(k: Constants, s: Variables)
    requires Init(k, s)
    ensures Inv(k, s)
  {
  }

  lemma NextPreservesInv(k: Constants, s: Variables, s': Variables, uiop: UIOp)
    requires Inv(k, s)
    requires Next(k, s, s', uiop)
    ensures Inv(k, s')
  {
  }
}
