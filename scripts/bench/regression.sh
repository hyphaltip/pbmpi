#!/usr/bin/bash
# Regression test of an optimized ref against the reference implementation:
# for several models, build both refs, run the same fixed-seed chain with each,
# and (once the jobs are done) check that the chains are identical.
#
# usage (from repo root, on the HPCC):
#   scripts/bench/regression.sh submit [NEW_REF] [OLD_REF]   # default: perf-opt master
#   scripts/bench/regression.sh check                         # after the jobs have finished
#
# Outputs go to bench/reg_<model>_{old,new}/ (git-ignored, safe to delete).
set -uo pipefail
# name | number of cycles | pb_mpi model flags
MODELS=(
  "catgtr|20|-cat -gtr"
  "catpoisson|60|-cat -poisson"
  "ncat10gtr|15|-ncat 10 -gtr"
  "ncat10poisson|60|-ncat 10 -poisson"
  "lg|15|-ncat 1 -lg"
)
case "${1:-}" in
submit)
  NEW=${2:-perf-opt}; OLD=${3:-master}
  for m in "${MODELS[@]}"; do
    IFS='|' read -r name n flags <<< "$m"
    sbatch --parsable -J pb_reg scripts/bench/bench.sbatch "$OLD" "reg_${name}_old" "$n" 0 bench/data/sim40x5000.phy $flags
    sbatch --parsable -J pb_reg scripts/bench/bench.sbatch "$NEW" "reg_${name}_new" "$n" 0 bench/data/sim40x5000.phy $flags
  done ;;
check)
  rc=0
  for m in "${MODELS[@]}"; do
    IFS='|' read -r name n flags <<< "$m"
    echo "== $name ($flags, $n cycles)"
    if [ ! -f "bench/reg_${name}_old/walltime.txt" ] || [ ! -f "bench/reg_${name}_new/walltime.txt" ]; then
      echo "MISSING (job failed or still running)"; rc=1; continue
    fi
    scripts/bench/compare_runs.sh "bench/reg_${name}_old" "bench/reg_${name}_new" || rc=1
  done
  [ $rc = 0 ] && echo "ALL IDENTICAL" || echo "SOME RUNS DIFFER OR ARE MISSING"
  exit $rc ;;
*) sed -n 2,10p "$0"; exit 1 ;;
esac
