include "ResourceSpec.s.dfy"
include "MapSpec.s.dfy"

abstract module ApplicationResourceSpec refines ResourceSpec {
  import Ifc = MapIfc

  function input_ticket(id: int, input: Ifc.Input) : R
  function output_stub(id: int, output: Ifc.Output) : R

  lemma NewTicketPreservesValid(r: R, id: int, input: Ifc.Input)
  requires Valid(r)
  ensures Valid(add(r, input_ticket(id, input)))

  /*predicate Inv(s: R)

  predicate NewTicket(s: R, s': R)
  {
    exists rid, input ::
      s' == add(s, input_ticket(rid, input))
  }

  predicate ConsumeStub(s: R, s': R)
  {
    exists rid, output ::
      s == add(s', output_stub(rid, output))
  }

  lemma UpdatePreservesInv(s: R, s': R)
  requires Inv(s)
  requires Update(s, s')
  ensures Inv(s')

  lemma NewTicketPreservesInv(s: R, s': R)
  requires Inv(s)
  requires NewTicket(s, s')
  ensures Inv(s')

  lemma ConsumeStubPreservesInv(s: R, s': R)
  requires Inv(s)
  requires ConsumeStub(s, s')
  ensures Inv(s')*/

  // refinement thm

  /*
  import AMS = AsyncSpec(MapIfc, MapSpec)

  function I(m: R) : AMS.Variables

  lemma InitRefines(s: R)
  requires Init(s)
  ensures AMS.Init(I(s))

  lemma NextRefines(s: R, s': R)
  requires Inv(s)
  requires Next(s, s')
  ensures AMS.Next(I(s), I(s'), AMS.Ifc.InternalOp)

  lemma NewTicketRefines(s: R, s': R)
  requires Inv(s)
  requires s' == s + {query_ticket(id, key)}
  ensures AMS.Next(I(s), I(s'), AMS.Ifc.Start(MapIfc.QueryRequest(key)))

  lemma EraseStubRefines(s: R, s': R)
  requires Inv(s)
  requires s == s' + {query_stub(id, value)}
  ensures AMS.Next(I(s), I(s'), AMS.Ifc.End(MapIfc.QueryResponse(value)))
  */
}
