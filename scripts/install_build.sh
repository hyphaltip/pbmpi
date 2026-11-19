#!/usr/bin/bash -l
#SBATCH -p short -N 1 -n 1 -c 8 --mem 8G --time 0:30:00 -J pb_install -o builds/install.%j.log
# Build a pinned, self-described install of the PhyloBayes MPI programs from a git ref.
#
# usage (from repo root, on the HPCC; `mkdir -p builds` first when using sbatch):
#   sbatch scripts/install_build.sh REF [ARCHFLAGS] [SUFFIX] [REGRESSION_IDS]
#     REF            git ref to build (branch, tag or commit)
#     ARCHFLAGS      extra CPU flags (default "-mavx2"; "" or "none" for a portable build)
#     SUFFIX         appended to the folder name (default: avx2 when ARCHFLAGS contains -mavx2, else generic)
#     REGRESSION_IDS free text recorded in BUILD_INFO: the regression runs this commit passed
#
# result: builds/<shortsha>-<SUFFIX>/{pb_mpi,readpb_mpi,bpcomp,tracecomp,BUILD_INFO}
#   BUILD_INFO is tab-separated "key<TAB>value" lines: commit, ref, archflags, cppflags,
#   compiler, mpi_module (exact `module load` name to use at run time), ymm_instructions,
#   built_on, date, regression_ids.
# builds/ is git-ignored and is NOT under bench/, so purging bench/ does not remove installs.
set -euo pipefail
REF=$1; ARCH=${2--mavx2}; [ "$ARCH" = none ] && ARCH=""
case "$ARCH" in *-mavx2*) DEF=avx2 ;; *) DEF=generic ;; esac
SUFFIX=${3:-$DEF}; REGIDS=${4:-none recorded}
module load openmpi
MPIMOD=$(module -t list 2>&1 | grep -m1 '^openmpi/' | sed 's/(default)//')
ROOT=$PWD
SHA=$(git rev-parse "$REF"); SHORT=$(git rev-parse --short=7 "$REF")
DEST=$ROOT/builds/$SHORT-$SUFFIX
[ -e "$DEST/BUILD_INFO" ] && { echo "$DEST already exists: remove it first to rebuild"; exit 1; }
TMP=$(mktemp -d "${SCRATCH:-${TMPDIR:-/tmp}}/pbmpi_build.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
git archive "$SHA" sources | tar -x -C "$TMP"
mkdir -p "$TMP/data" "$DEST"
CPPFLAGS="-Wall -O3 -std=c++11 $ARCH"
( cd "$TMP/sources" && make -j 8 CPPFLAGS="$CPPFLAGS" ../data/pb_mpi ../data/readpb_mpi ../data/bpcomp ../data/tracecomp ) > "$DEST/build.log" 2>&1 || { tail -30 "$DEST/build.log"; exit 1; }
cp "$TMP"/data/{pb_mpi,readpb_mpi,bpcomp,tracecomp} "$DEST/"
YMM=$(objdump -d "$DEST/pb_mpi" | grep -c '%ymm' || true)
{
  printf 'commit\t%s\n' "$SHA"
  printf 'ref\t%s\n' "$REF"
  printf 'archflags\t%s\n' "$ARCH"
  printf 'cppflags\t%s\n' "$CPPFLAGS"
  printf 'compiler\t%s\n' "$(mpic++ --version | head -1)"
  printf 'mpi_module\t%s\n' "$MPIMOD"
  printf 'ymm_instructions\t%s\n' "$YMM"
  printf 'built_on\t%s (%s)\n' "$(hostname)" "$(lscpu | sed -n 's/Model name: *//p')"
  printf 'date\t%s\n' "$(date -Is)"
  printf 'regression_ids\t%s\n' "$REGIDS"
} > "$DEST/BUILD_INFO"
echo "installed $DEST"; cat "$DEST/BUILD_INFO"
