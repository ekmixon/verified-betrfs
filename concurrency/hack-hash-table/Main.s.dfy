include "HTResource.i.dfy"

abstract module Main {
  import ARS = HTResource
  import Ifc = MapIfc

  type Object(==,!new)
  predicate Inv(o: Object)

  method init(linear i: ARS.R)
  returns (o: Object)
  requires ARS.Init(i)
  ensures Inv(o)

  method call(o: Object, input: Ifc.Input,
      rid: int, linear ticket: ARS.R)
  returns (output: Ifc.Output, linear stub: ARS.R)
  requires Inv(o)
  requires ticket == ARS.input_ticket(rid, input)
  ensures stub == ARS.output_stub(rid, output)
}

