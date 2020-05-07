#!/usr/bin/env python3
import matplotlib
import matplotlib.pyplot as plt
import numpy as np
import sys
import operator
import bisect
from parser import Experiment
from PlotHelper import *
from TimeSeries import *

output_filename = "compare.png"

def plot_perf_compare(experiments):
    plotHelper = PlotHelper(6, scale=2, columns=1)

    try: plotThroughput(plotHelper.nextAxis(depth=2), experiments)
    except: raise
    
    try: plotGrandUnifiedMemory(plotHelper.nextAxis(depth=2), experiments)
    except: raise

    try: plotRocksIo(plotHelper.nextAxis(depth=2), experiments)
    except: raise

    plotHelper.save(output_filename)

experiments = []
for arg in sys.argv[1:]:
    nick,fn = arg.split("=")
    if nick=="output":
        output_filename = fn
    else:
        exp = Experiment(fn, nick)
        #exp.sortedOpns = exp.sortedOpns[:-5]    # hack: truncate teardown tail of completed exp where memory all goes to 0
        experiments.append(exp)
plot_perf_compare(experiments)
