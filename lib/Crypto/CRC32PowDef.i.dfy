module CRC32PowDef {
  predicate pow(n: nat,
      a0: bool, a1: bool, a2: bool, a3: bool, a4: bool, a5: bool, a6: bool, a7: bool, a8: bool, a9: bool, a10: bool, a11: bool, a12: bool, a13: bool, a14: bool, a15: bool, a16: bool, a17: bool, a18: bool, a19: bool, a20: bool, a21: bool, a22: bool, a23: bool, a24: bool, a25: bool, a26: bool, a27: bool, a28: bool, a29: bool, a30: bool, a31: bool)
  {
    if n == 0 then (
      a0 && !a1 && !a2 && !a3 && !a4 && !a5 && !a6 && !a7 && !a8 && !a9 && !a10 && !a11 && !a12 && !a13 && !a14 && !a15 && !a16 && !a17 && !a18 && !a19 && !a20 && !a21 && !a22 && !a23 && !a24 && !a25 && !a26 && !a27 && !a28 && !a29 && !a30 && !a31
    ) else (
      if !a0 then (
        pow(n-1, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24, a25, a26, a27, a28, a29, a30, a31, false)
      ) else (
        pow(n-1, a1, a2, a3, a4, a5, !a6, a7, !a8, !a9, !a10, !a11, a12, !a13, !a14, a15, a16, a17, !a18, !a19, !a20, a21, !a22, !a23, a24, !a25, !a26, !a27, !a28, a29, a30, a31, true)
      )
    )
  }
}
