#!/usr/bin/bash -l
#SBATCH -p short -N 1 -n 1 -c 2 --mem 4G --time 0:20:00 -J pb_simdata -o bench/data/make_testdata.%j.log
# Simulate a reproducible protein alignment under a site-heterogeneous
# profile mixture (LG+C20+G4) on a random Yule-Harding tree, for use as a
# benchmark / regression input for pb_mpi.
#
# usage (from repo root):  sbatch scripts/bench/make_testdata.sbatch [NTAXA] [NSITES] [SEED] [MODEL] [PREFIX]
#   MODEL  : IQ-TREE model to simulate under (default LG+C20+G4; e.g. GY for a codon alignment,
#            in which case NSITES is a number of codons)
#   PREFIX : output name prefix (default sim)
# output: bench/data/<PREFIX><NTAXA>x<NSITES>.phy  (bench/ is git-ignored, safe to delete)
set -euo pipefail
NTAXA=${1:-40}; NSITES=${2:-5000}; SEED=${3:-1}; MODEL=${4:-LG+C20+G4}; PREFIX=${5:-sim}
module load iqtree/2.2.2.6
mkdir -p bench/data
OUT=bench/data/${PREFIX}${NTAXA}x${NSITES}
iqtree2 --alisim $OUT -m "$MODEL" -t "RANDOM{yh/$NTAXA}" --length $NSITES --seed $SEED -nt 2
ls -l $OUT*
