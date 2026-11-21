#!/usr/bin/bash
# Regression check: do two bench runs (same data, model and -rnd seed) follow
# the same chain?  Compares, when present: the sampled trees (.treelist), the
# trace columns other than the two timing columns (time, topo: columns 2-3),
# the saved parameter states (.chain) and the stepping-stone output (.stepping).
# Prints the wall-time ratio.
#
# usage: scripts/bench/compare_runs.sh bench/<ID_A> bench/<ID_B>
# exit status 0 = identical chains, 1 = chains differ (or nothing to compare).
set -uo pipefail
A=$1; B=$2; rc=0; n=0
for ext in treelist chain stepping; do
  [ -s "$A/chain.$ext" ] || [ -s "$B/chain.$ext" ] || continue
  n=$((n+1))
  if cmp -s "$A/chain.$ext" "$B/chain.$ext"; then echo "$ext: identical"
  elif [ $ext = stepping ] && paste -d '\n' "$A/chain.$ext" "$B/chain.$ext" | awk -F'\t' '
      # allowed difference: a logZ or effsize column (3, 8; 9 and 14 with -maxvar) that is nan on one side only.
      # master prints nan there when the first step is very negative; fixed in perf-opt (docs/bug-fixes.md).
      NR%2 {n=split($0,a,FS); next}
      { if (NF!=n) bad=1
        for (i=1;i<=NF;i++) if (($i "") != (a[i] "")) {   # as strings: awk reads "nan" as a number
          if ((i==3||i==8||i==9||i==14) && ((a[i]~/nan/)!=($i~/nan/))) c++; else bad=1 } }
      END { if (bad || NR%2 || c==0) exit 1; exit 0 }'; then
    echo "$ext: identical apart from logZ/effsize, which are nan on one side (see docs/bug-fixes.md)"
  else echo "$ext: DIFFER"; rc=1; fi
done
if [ -s "$A/chain.trace" ] || [ -s "$B/chain.trace" ]; then
  n=$((n+1))
  if diff -q <(cut -f1,4- "$A/chain.trace") <(cut -f1,4- "$B/chain.trace") >/dev/null 2>&1; then
    echo "trace: identical ($(( $(wc -l < "$A/chain.trace") - 1 )) points)"
  else
    echo "trace: DIFFER (first differing line below)"; rc=1
    diff <(cut -f1,4- "$A/chain.trace") <(cut -f1,4- "$B/chain.trace") | head -4
  fi
fi
[ $n -gt 0 ] || { echo "nothing to compare"; rc=1; }
wa=$(sed 's/.*wall_s=//' "$A/walltime.txt"); wb=$(sed 's/.*wall_s=//' "$B/walltime.txt")
echo "wall: $A ${wa}s   $B ${wb}s   speedup $(echo "scale=2; $wa / $wb" | bc)x"
exit $rc
