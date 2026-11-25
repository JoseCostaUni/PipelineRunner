#!/bin/sh
# The capacity the Slurm plugin reports for the virtual node (its ResourceScriptPath). A fixed one:
# plugin 0.6.3 otherwise reports the free memory it sees on the login node, which fell below one pod's
# request on the testbed and left pods Pending. Slurm, not this number, decides what runs.
echo '{"status":"ok","resources":{"cpu":"100","memory":"3T","pods":"10k"}}'
