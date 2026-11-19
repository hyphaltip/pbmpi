#!/usr/bin/bash
# Regression check: do two bench runs (same data, model and -rnd seed) follow
# the same chain?  Compares the sampled trees exactly and the trace columns
# other than the time column (column 2), and prints the wall-time ratio.
#
# usage: scripts/bench/compare_runs.sh bench/<ID_A> bench/<ID_B>
# exit status 0 = identical chains, 1 = chains differ.
set -uo pipefail
A=$1; B=$2; rc=0
if cmp -s "$A/chain.treelist" "$B/chain.treelist"; then echo "treelist: identical"; else echo "treelist: DIFFER"; rc=1; fi
if diff -q <(cut -f1,3- "$A/chain.trace") <(cut -f1,3- "$B/chain.trace") >/dev/null; then
  echo "trace:    identical"
else
  echo "trace:    DIFFER (first differing line below)"; rc=1
  diff <(cut -f1,3- "$A/chain.trace") <(cut -f1,3- "$B/chain.trace") | head -4
fi
wa=$(sed 's/.*wall_s=//' "$A/walltime.txt"); wb=$(sed 's/.*wall_s=//' "$B/walltime.txt")
echo "wall: $A ${wa}s   $B ${wb}s   speedup $(echo "scale=2; $wa / $wb" | bc)x"
exit $rc
