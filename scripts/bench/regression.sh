#!/usr/bin/bash
# Regression test of an optimized ref against the reference implementation:
# for several models, build both refs, run the same fixed-seed chain with each,
# and (once the jobs are done) check that the chains are identical.
#
# usage (from repo root, on the HPCC):
#   scripts/bench/regression.sh submit [NEW_REF] [OLD_REF]   # default: perf-opt master
#   scripts/bench/regression.sh check                         # after the jobs have finished
#
# ONLY=<regex> restricts both commands to the models whose name matches.
# Outputs go to bench/reg_<model>_{old,new}/ (git-ignored, safe to delete).
set -uo pipefail
# name | number of cycles | data (in bench/data) | pb_mpi model flags
AA=sim40x5000.phy     # sbatch scripts/bench/make_testdata.sbatch
AASMALL=sim20x1000.phy # sbatch scripts/bench/make_testdata.sbatch 20 1000
CODON=codon20x1500.phy # sbatch scripts/bench/make_testdata.sbatch 20 1500 1 GY codon   (1500 nt = 500 codons)
MODELS=(
  "catgtr|20|$AA|-cat -gtr"
  "catpoisson|60|$AA|-cat -poisson"
  "ncat10gtr|15|$AA|-ncat 10 -gtr"
  "ncat10poisson|60|$AA|-ncat 10 -poisson"
  "lg|15|$AA|-ncat 1 -lg"
  "catgtr_nni|10|$AA|-cat -gtr -spr 2 -nni 2"
  "catpoisson_dc|30|$AA|-cat -poisson -dc"
  "stepping_catgtr|1000|$AASMALL|-cat -gtr -sis 1000 2 3"
  "stepping_catpoisson|1000|$AA|-cat -poisson -sis 1000 2 3"
  "mutsel_cat|8|$CODON|-mutsel -cat"
  "mutsel_ncat3|8|$CODON|-mutsel -ncat 3"
  "mutsel_freeomega|8|$CODON|-mutsel -cat -freeomega"
  "mutselc_cat|8|$CODON|-mutselc -cat"
  "mutselc_ncat3|8|$CODON|-mutselc -ncat 3"
)
case "${1:-}" in
submit)
  NEW=${2:-perf-opt}; OLD=${3:-master}
  for m in "${MODELS[@]}"; do
    IFS='|' read -r name n data flags <<< "$m"
    [ -n "${ONLY:-}" ] && [[ ! "$name" =~ $ONLY ]] && continue
    sbatch --parsable -J pb_reg scripts/bench/bench.sbatch "$OLD" "reg_${name}_old" "$n" 0 "bench/data/$data" $flags
    sbatch --parsable -J pb_reg scripts/bench/bench.sbatch "$NEW" "reg_${name}_new" "$n" 0 "bench/data/$data" $flags
  done ;;
check)
  rc=0
  for m in "${MODELS[@]}"; do
    IFS='|' read -r name n data flags <<< "$m"
    [ -n "${ONLY:-}" ] && [[ ! "$name" =~ $ONLY ]] && continue
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
