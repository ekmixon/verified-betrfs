linear datatype ASDF = ASDF(a: int)
linear datatype QWER = QWER(linear asdf: ASDF)

// method {:axiom} drop<V>(linear v: V)

method linlin(linear inout c: ASDF) returns (linear oo: ASDF)
requires old_c.a == 31 // use old(c)
ensures c.a == old_c.a + 1
ensures oo == old_c
{
  var oldA := c.a;
  oo := c;
  c := ASDF(oldA + 1);
}

method {:axiom} Imagine<V>(ghost v: V) returns (linear v2: V)
ensures v == v2

method asdf() {
  linear var q := QWER(ASDF(31));

  // linlin(inout q.asdf);

  // linear var tmp_q_asdf := linlin(inout q.asdf); drop(tmp_q_asdf);
  linear var c := linlin(inout q.asdf);
  // linlin(inout q.asdf);
  // q := Imagine(q.(asdf := _inout_tmp_0));

  // var tmp_q_asdf := linlin(inout q.asdf);
  // q := q.(asdf := tmp_q_asdf);

  assert q.asdf.a == 32;
  linear var QWER(asdf) := q;
  linear var ASDF(_) := asdf;
  linear var ASDF(_) := c;
}
