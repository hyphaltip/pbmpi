#!/usr/bin/bash -l
#SBATCH -p short -C milan -N 1 --hint=nomultithread --time 2:00:00 -J pb_scale -o bench/logs/scale.%j.log
# One point of a rank-scaling benchmark: resume a chain from a saved state (.param file)
# with an installed build, for a fixed number of cycles and a fixed seed, on N ranks.
#
# usage (from repo root):
#   sbatch -n NRANKS --mem <mem> scripts/bench/scaling.sbatch BUILD_DIR ID NCYCLES PARAM DATA
#     BUILD_DIR  install made by scripts/install_build.sh (contains pb_mpi and BUILD_INFO)
#     ID         output folder under bench/
#     NCYCLES    number of cycles to add to the chain
#     PARAM      .param file of the chain to resume from (it is copied, never modified)
#     DATA       alignment of that chain (copied; the copy of the .param is pointed to it)
# output: bench/<ID>/ with chain.trace (new cycles only, no header; column 2 = seconds per cycle)
#         and percycle.txt: nranks, cycles, mean and median seconds per cycle, wall time.
set -euo pipefail
BUILD=$(realpath "$1"); ID=$2; NCYCLES=$3; PARAM=$(realpath "$4"); DATA=$(realpath "$5")
module load "$(awk -F'\t' '$1=="mpi_module"{print $2}' "$BUILD/BUILD_INFO")"
OUT=$PWD/bench/$ID; rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"
cp "$DATA" data.phy
cp "$BUILD/BUILD_INFO" .
# the alignment path is the first line of the .param that names an existing file: point it to the copy
awk -v new="$OUT/data.phy" -v old="$DATA" 'BEGIN{done=0} {if (!done && $0==old) {print new; done=1} else print}' "$PARAM" > chain.param
grep -q -x "$OUT/data.phy" chain.param || { echo "could not find the alignment path $DATA in $PARAM"; exit 1; }
SIZE=$(sed -n 2p chain.param | cut -f3)
UNTIL=$((SIZE + NCYCLES))
echo "host=$(hostname) ranks=$SLURM_NTASKS resume at $SIZE points, run until $UNTIL"
START=$(date +%s.%N)
mpirun --bind-to core --map-by core -np "$SLURM_NTASKS" "$BUILD/pb_mpi" -rnd 1 -x 1 $UNTIL chain > run.log 2>&1 || { tail -30 run.log; exit 1; }
END=$(date +%s.%N)
N=$(wc -l < chain.trace)
MEAN=$(awk '{s+=$2} END{printf "%.2f", s/NR}' chain.trace)
MED=$(cut -f2 chain.trace | sort -g | awk '{a[NR]=$1} END{printf "%.2f", (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
printf 'ranks\t%s\tcycles\t%s\tmean_s_per_cycle\t%s\tmedian_s_per_cycle\t%s\twall_s\t%.0f\thost\t%s\n' "$SLURM_NTASKS" "$N" "$MEAN" "$MED" "$(echo "$END - $START" | bc)" "$(hostname)" | tee percycle.txt
tail -n 2 chain.trace | cut -f1-7
