#!/usr/bin/bash -l
#SBATCH -p short -N 1 -n 1 -c 2 --mem 4G --time 0:20:00 -J pb_simdata -o bench/data/make_testdata.%j.log
# Simulate a reproducible protein alignment under a site-heterogeneous
# profile mixture (LG+C20+G4) on a random Yule-Harding tree, for use as a
# benchmark / regression input for pb_mpi.
#
# usage (from repo root):  sbatch scripts/bench/make_testdata.sbatch [NTAXA] [NSITES] [SEED]
# output: bench/data/sim<NTAXA>x<NSITES>.phy  (bench/ is git-ignored, safe to delete)
set -euo pipefail
NTAXA=${1:-40}; NSITES=${2:-5000}; SEED=${3:-1}
module load iqtree/2.2.2.6
mkdir -p bench/data
OUT=bench/data/sim${NTAXA}x${NSITES}
iqtree2 --alisim $OUT -m LG+C20+G4 -t "RANDOM{yh/$NTAXA}" --length $NSITES --seed $SEED --out-format phylip -nt 2
ls -l $OUT*
