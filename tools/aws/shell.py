#!/usr/bin/python3

import sys
from automation import *


#>def ssh_cmd_for_worker(worker):

def main():
    target = sys.argv[1]
    workers = retrieve_running_workers()
    matches = [w for w in workers if target in w["Name"]]
    if len(matches)==0:
        sys.stderr.write("No running worker matches '%s':\n" % target)
        sys.stderr.write(" ".join([w["Name"] for w in workers])+"\n")
        sys.exit(-1)
    if len(matches)>1:
        sys.stderr.write("Multiple running workers match '%s':\n" % target)
        sys.stderr.write(" ".join([w["Name"] for w in matches])+"\n")
        sys.exit(-1)
    worker = matches[0]
    subprocess.call(ssh_cmd_for_worker(worker))

main()
