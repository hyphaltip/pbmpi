#!/usr/bin/bash -l
#SBATCH -p short -C milan -N 1 -n 8 --mem 16G --time 1:00:00 -J pb_bench -o bench/logs/bench.%j.log
# Build pb_mpi from a given git ref and run a short fixed-seed chain, recording
# (All runs are pinned to the same CPU type, "milan" EPYC nodes, so timings compare.)
# wall time and (optionally) a perf profile. Everything lands in
# bench/<ID>/ which is git-ignored and safe to delete.
#
# usage (from repo root):
#   sbatch scripts/bench/bench.sbatch REF ID [NCYCLES] [PERF] [DATA] [MODEL...]
#     REF      git ref to build (e.g. master, perf-opt, a commit)
#     ID       name of the output folder under bench/
#     NCYCLES  number of saved MCMC cycles (default 20)
#     PERF     1 = wrap every rank in `perf record` (default 0)
#     DATA     alignment (default bench/data/sim40x5000.phy)
#     MODEL    pb_mpi model flags (default: -cat -gtr)
#   env: EXTRA_CPPFLAGS / MAKE_CPPFLAGS to change compiler flags.
#        MPIRUN_OPTS: extra mpirun options, e.g. "--bind-to core --map-by core" to pin each rank
#        to one core (then submit with sbatch --hint=nomultithread so that whole cores are allocated).
#
# The chain uses `-rnd 1`, so two builds that perform the same arithmetic give
# identical .trace/.treelist files; compare with scripts/bench/compare_runs.sh.
set -euo pipefail
REF=$1; ID=$2; NCYCLES=${3:-20}; PERF=${4:-0}; DATA=${5:-bench/data/sim40x5000.phy}
shift $(( $# < 5 ? $# : 5 ))
MODEL=${*:--cat -gtr}
module load openmpi
ROOT=$PWD
OUT=$ROOT/bench/$ID
rm -rf "$OUT"; mkdir -p "$OUT/src" "$ROOT/bench/logs"
git archive "$REF" sources | tar -x -C "$OUT/src"
git rev-parse "$REF" > "$OUT/git_ref.txt"
mkdir -p "$OUT/src/data"
cd "$OUT/src/sources"
CPPFLAGS=${MAKE_CPPFLAGS:--Wall -O3 -std=c++11 -g -fno-omit-frame-pointer ${EXTRA_CPPFLAGS:-}}
echo "CPPFLAGS=$CPPFLAGS" | tee "$OUT/build_flags.txt"
make -j 8 CPPFLAGS="$CPPFLAGS" ../data/pb_mpi > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
cd "$OUT"
cp "$ROOT/$DATA" data.phy
PB=$OUT/src/data/pb_mpi
RUN="$PB -d data.phy $MODEL -rnd 1 -x 1 $NCYCLES chain"
if [ "$PERF" = 1 ]; then
  cat > perfwrap.sh <<EOW
#!/usr/bin/bash
exec perf record -F 199 -g -o $OUT/perf.\${OMPI_COMM_WORLD_RANK}.data "\$@"
EOW
  chmod +x perfwrap.sh
  RUN="$OUT/perfwrap.sh $RUN"
fi
echo "host=$(hostname) cpu=$(lscpu | sed -n 's/Model name: *//p') ntasks=$SLURM_NTASKS"
START=$(date +%s.%N)
mpirun ${MPIRUN_OPTS:-} -np "$SLURM_NTASKS" $RUN > run.log 2>&1 || { tail -30 run.log; exit 1; }
END=$(date +%s.%N)
ls mpistats.*.txt > /dev/null 2>&1 && { echo "== per-message statistics, rank 1 (EXTRA_CPPFLAGS=-DPB_MPI_STATS)"; sort -t$'\t' -k4,4gr mpistats.1.txt | head -14; }
echo "$REF $ID ncycles=$NCYCLES wall_s=$(echo "$END - $START" | bc)" | tee walltime.txt
tail -3 chain.trace
if [ "$PERF" = 1 ]; then
  for r in 0 1; do
    perf report -i perf.$r.data --no-children --percent-limit 0.7 --stdio 2>/dev/null | grep -v '^$' > perf.$r.report.txt || true
    perf report -i perf.$r.data --no-children -g none --percent-limit 0.5 --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' > perf.$r.flat.txt || true
  done
  head -40 perf.1.flat.txt
fi
