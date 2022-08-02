#!/usr/bin/env python3

# Copyright 2018-2021 VMware, Inc., Microsoft Inc., Carnegie Mellon University, ETH Zurich, and University of Washington
# SPDX-License-Identifier: BSD-2-Clause

# Create the build/ directory, generate the initial build/makefile

import os
import re
import sys
import glob
from lib_deps import *

def deps(iref):
    return target(iref, ".deps")

BUILD_DIR = "build" # The build dir; make clean = rm -rf $BUILD_DIR
DIR_DEPS = "dir.deps"   # The per-directory dependencies file

class Veridepend:
    def __init__(self, dafnyRoots):
        self.dafnyRoots = dafnyRoots
        self.targetIrefs = depsFromDfySources(self.dafnyRoots)
        output = self.gatherDeps()
        self.writeDepsFile(output)
        self.graph = {}

    def gatherDeps(self):
        output = []
        for iref in toposortGroup(self.targetIrefs):
            output += self.generateDepsForIref(iref)
        return output

    def generateDepsForIref(self, iref):
        output = ["", f"# deps from {iref}"]
        for dep in childrenForIref(iref):
            output.extend(
                f"{targetName(iref, fromType)}: {targetName(dep, toType)}"
                for fromType, toType in (
                    (".dummydep", ".dummydep"),
                    (".synchk", ".dummydep"),
                    (".verchk", ".dummydep"),
                    (".cs", ".dummydep"),
                    (".lc", ".dummydep"),
                    (".cpp", ".cpp"),
                    (".verified", ".verified"),
                    (".syntax", ".syntax"),
                    (".okay", ".okay"),
                    (".lcreport", ".lcreport"),
                    (".o", ".o"),
                    (".cpp", ".o"),
                )
            )

            # dependencies from this file to type parents
            output.append(f'{targetName(iref, ".verified")}: {targetName(dep, ".verchk")}')
            output.append(f'{targetName(iref, ".syntax")}: {targetName(dep, ".synchk")}')
            output.append(f'{targetName(iref, ".lcreport")}: {targetName(dep, ".lc")}')
        # The dirDeps file depends on each target it describes.
        output.append(f"{self.depFilename()}: {iref.normPath}")
        return output

    def depFilename(self):
        return "build/deps"

    def writeDepsFile(self, outputLines):
        with open(self.depFilename(), "w") as outfp:
            for line in outputLines:
                outfp.write(line + "\n")

if (__name__=="__main__"):
    Veridepend(sys.argv[1:])
