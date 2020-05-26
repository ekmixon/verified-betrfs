#!/usr/bin/env python3

from __future__ import print_function
from __future__ import division

import sys
import os
import subprocess
import time
import datetime
import signal

def actuallyprint(msg):
    print(msg)
    sys.stdout.flush()

# def splice_value_into_bundle(name, value):
#   splice_successful = False
#   with open("build/Bundle.cpp") as f:
#     lineNum = 0
#     c = 0
#     lines = []
#     for line in f:
#       lineNum += 1
#       if line.strip() == "uint64 __default::" + name + "()":
#         c = 1
#       else:
#         if c == 1:
#           c = 2
#         elif c == 2:
#           line = "    return (uint64)" + value + "; /*hi mom*/\n"
#           splice_successful = True
#           #print("Splicing %s = %s at line %d" % (name, value, lineNum))
#           c = 0
#       lines.append(line)
#     cpp = "".join(lines)
#   assert splice_successful
# 
#   with open("build/Bundle.cpp","w") as f:
#     f.write(cpp)

def main():
  seed=None
  output=None

  print("arguments", sys.argv)

  for arg in sys.argv[1:]:
    if arg.startswith("seed="):
      seed = arg[len("seed=") : ]
    elif arg.startswith("output="):
      output = arg[len("output=") : ]
    elif arg.startswith("git_branch="):
      branch = arg[len("git_branch=") : ]
    else:
      assert False, "unrecognized argument: " + arg

  value_updates = []
  for (name, value) in value_updates:
    print("setting " + name + " to " + value)
    # splice_value_into_bundle(name, value)

  actuallyprint("Building executable...")
  sys.stdout.flush()

  dafny_cmd = None
  if branch == "eval-btree-linear":
    # dafny_cmd = ".dafny/dafny/Binaries/dafny /noVerify /spillTargetCode:3 /countVerificationErrors:0 /compileTarget:cpp lib/DataStructures/MutableBtree.i.dfy Lang/LinearExtern.h framework/Framework.h"
    pass
  elif branch == "eval-btree-master":
    dafny_cmd = ".dafny/dafny/Binaries/dafny /noVerify /spillTargetCode:3 /countVerificationErrors:0 /compileTarget:cpp lib/DataStructures/MutableMapImpl.i.dfy framework/NativeArithmetic.h framework/NativeArrays.h framework/LinearCongruentialGenerator.h"
  actuallyprint(dafny_cmd)
  ret = os.system(dafny_cmd)
  assert ret == 0

  dafny_cmd_2 = None
  if branch == "eval-btree-linear":
    # dafny_cmd_2 = ".dafny/dafny/Binaries/dafny /noVerify /spillTargetCode:3 /countVerificationErrors:0 /compileTarget:cpp lib/DataStructures/MutableBtree.i.dfy Lang/LinearExtern.h framework/Framework.h"
    pass
  elif branch == "eval-btree-master":
    dafny_cmd_2 = ".dafny/dafny/Binaries/dafny /noVerify /spillTargetCode:3 /countVerificationErrors:0 /compileTarget:cpp bench/MutableMap.dfy framework/NativeArithmetic.h framework/NativeArrays.h framework/LinearCongruentialGenerator.h"
  actuallyprint(dafny_cmd_2)
  ret = os.system(dafny_cmd_2)
  assert ret == 0

  cmd = None
  if branch == "eval-btree-linear":
    # cmd = "g++ -O3 lib/DataStructures/lib/DataStructures/MutableBtree.i.cpp bench/run-mutable-btree.cpp -o MutableBtreeBench -I .dafny/dafny/Binaries/ -I lib/DataStructures/ -Ilib -std=c++17 -I."
    pass
  elif branch == "eval-btree-master":
    cmd = "g++ -O3 bench/bench/MutableMap.cpp bench/run-mutable-map.cpp framework/NativeArithmetic.cpp -o MutableMapBench  -I .dafny/dafny/Binaries/ -I lib/DataStructures/ -I bench -Ilib -std=c++17 -I."
  actuallyprint(cmd)
  ret = os.system(cmd)
  assert ret == 0

  # bitmask indicating which CPUs we can use
  # See https://linux.die.net/man/1/taskset
  taskset_cmd = "taskset 4 "


  with open(output, 'w') as f:
      f.write("METADATA btree perf comparison\n")
      f.write("METADATA branch {}\n".format(branch))
      f.write("METADATA seed {}\n".format(seed))
      command = taskset_cmd + "./MutableMapBench {} false".format(str(seed))
      actuallyprint(command)
      sys.stdout.flush()

      result = subprocess.run(command, shell=True, preexec_fn=os.setsid,
              universal_newlines=True, stdout=subprocess.PIPE)
      f.write(result.stdout)
      f.flush()
      actuallyprint("done")

if __name__ == "__main__":
  main()
