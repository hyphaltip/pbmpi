#!/usr/bin/bash -l
#SBATCH -p short -C milan -N 1 -n 8 --mem 16G --time 1:30:00 -J pb_readpb -o bench/logs/readpb.%j.log
# Regression test of readpb_mpi: build two refs, produce one short chain per
# model with the OLD pb_mpi, then run each readpb_mpi analysis with both builds
# on copies of that chain and compare every output file.
#
# usage (from repo root): sbatch scripts/bench/readpb_regression.sbatch [NEW_REF] [OLD_REF]
# output: bench/readpb/ (git-ignored); summary at the end of the log, exit 1 if anything differs.
#
# readpb_mpi has no -rnd option: it seeds its random generator from the microseconds
# of gettimeofday. So that stochastic analyses (-ppred, -map, ...) can be compared,
# both builds are run under a small LD_PRELOAD shim that fixes that microsecond field.
set -uo pipefail
NEW=${1:-perf-opt}; OLD=${2:-master}
module load openmpi
ROOT=$PWD; OUT=$ROOT/bench/readpb
rm -rf "$OUT"; mkdir -p "$OUT"
for which in old new; do
  ref=$OLD; [ $which = new ] && ref=$NEW
  mkdir -p "$OUT/src_$which/data"
  git archive "$ref" sources | tar -x -C "$OUT/src_$which"
  ( cd "$OUT/src_$which/sources" && make -j 8 ../data/pb_mpi ../data/readpb_mpi > "$OUT/build_$which.log" 2>&1 ) || { tail -20 "$OUT/build_$which.log"; exit 1; }
done
cat > "$OUT/fixusec.c" <<'EOC'
#define _GNU_SOURCE
#include <sys/time.h>
#include <dlfcn.h>
int gettimeofday(struct timeval* restrict tv, struct timezone* restrict tz) {
    static int (*real)(struct timeval*, struct timezone*) = 0;
    if (!real) real = (int (*)(struct timeval*, struct timezone*)) dlsym(RTLD_NEXT, "gettimeofday");
    int r = real(tv, tz);
    if (tv) tv->tv_usec = 424242;
    return r;
}
EOC
gcc -std=gnu99 -O2 -shared -fPIC -o "$OUT/fixusec.so" "$OUT/fixusec.c" -ldl || exit 1
DATA=$ROOT/bench/data/sim40x5000.phy
rc=0
run_model() {   # name, pb_mpi flags, then readpb analyses (one string each)
  local name=$1 flags=$2; shift 2
  mkdir -p "$OUT/$name/chain" && cd "$OUT/$name/chain"
  cp "$DATA" data.phy
  mpirun -np "$SLURM_NTASKS" "$OUT/src_old/data/pb_mpi" -d data.phy $flags -rnd 1 -x 1 12 chain > pb.log 2>&1 || { echo "$name: pb_mpi FAILED"; rc=1; return; }
  for analysis in "$@"; do
    local tag=$(echo "x$analysis" | tr -c 'A-Za-z0-9\n' '_')
    for which in old new; do
      local d=$OUT/$name/${tag}_$which
      cp -r "$OUT/$name/chain" "$d"; cd "$d"
      mpirun -np "$SLURM_NTASKS" -x LD_PRELOAD="$OUT/fixusec.so" "$OUT/src_$which/data/readpb_mpi" -x 2 1 $analysis chain > readpb.out 2> readpb.err
      echo "exit=$?" >> readpb.out
    done
    if diff -r -q "$OUT/$name/${tag}_old" "$OUT/$name/${tag}_new" > "$OUT/$name/${tag}.diff" 2>&1; then
      echo "$name  readpb_mpi $analysis : identical ($(ls "$OUT/$name/${tag}_new" | wc -l) files, $(tail -n 1 "$OUT/$name/${tag}_new/readpb.out"))"
    else
      echo "$name  readpb_mpi $analysis : DIFFER"; sed 's/^/     /' "$OUT/$name/${tag}.diff" | head -5; rc=1
    fi
  done
}
COMMON=("" "-sitelogl" "-anc" "-r" "-ss" "-ppred" "-allppred" "-comp" "-div" "-map" "-jointcv data.phy" "-sitecv data.phy")
run_model catgtr "-cat -gtr" "${COMMON[@]}" "-rr" "-siteprofilesuffstat"
run_model catpoisson "-cat -poisson" "${COMMON[@]}"
run_model ncat10gtr "-ncat 10 -gtr" "" "-sitelogl" "-ppred" "-r"
[ $rc = 0 ] && echo "ALL IDENTICAL" || echo "SOME ANALYSES DIFFER OR FAILED"
exit $rc
