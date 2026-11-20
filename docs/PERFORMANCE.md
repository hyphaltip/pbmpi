# Performance work on PhyloBayes-MPI: results and how to reproduce them

This is the entry point for the performance documentation of the `perf-opt` branch. It states what was changed, what speed-up was measured, how reliable the numbers are, and where to read more.

| Document | Content |
|---|---|
| `PERFORMANCE.md` (this file) | results, history, scaling, limits |
| `code-optimizations.md` | each code change: what, why, why the result is unchanged, risks |
| `build-and-compiler-options.md` | compiler flags, what they do, what was measured |
| `pinning-and-cpu-affinity.md` | why one rank per physical core matters; how to do it |
| `validation.md` | the identical-results rule, tests, results, gaps |

## 1. Summary

- The optimized code (`perf-opt`, commit 312c2bd and the later script-only commits) follows **exactly the same Markov chain as `master`** for the same data, model, seed and number of ranks. Tested on 13 model configurations. `validation.md` gives the evidence and the gaps.
- Speed-up in wall time, measured against `master` in the same batch of jobs (8 ranks, unpinned, default flags, one run each): **4.4x** for CAT-GTR, up to **5.1x** for LG, **2.0x to 2.6x** for CAT-Poisson, **1.2x to 2.1x** for codon models. One configuration (`-mutsel -ncat 3`) was **slower** (0.83x) in a single short run that has not been repeated.
- Speed-up at production size: 38 taxa x 59,994 amino-acid sites, CAT-GTR, 64 ranks, pinned: **16.35 s per cycle** against **71.28 s** for `master` (4.36x).
- **Pinning each rank to its own physical core is worth about 1.5x by itself**, more than any compiler flag tested. It changes no result. See `pinning-and-cpu-affinity.md`.
- The optimizations do not change the arithmetic. They remove repeated work, avoid allocation, cache values that were recomputed, and let the compiler use vector registers.
- All numbers come from one cluster (AMD EPYC 7713), one compiler (GCC 8.5.0) and one MPI (Open MPI 4.1.2). Most timings are single runs with 6% to 21% run-to-run spread.

## 2. What was done, in one paragraph per area

1. **Less repeated work in the pruning (likelihood) code.** The slaves ran two full likelihood passes where one was enough. Several moves recomputed the whole tree after changing one branch. Conditional likelihoods are now recomputed only where needed.
2. **Faster matrix-vector kernel.** The kernel that propagates conditional likelihoods through a branch (`MatrixSubstitutionProcess::PropagateImpl`) is the largest single cost. It now uses contiguous transposed matrices, shared exponentials, a leaf shortcut and a register-blocked vector loop. Each output element still receives its terms in the original order.
3. **Cached logarithms in the mixture moves.** Allocation and Dirichlet-weight moves recomputed `log` and `lgamma` values that depend only on the component. They are now computed once per component.
4. **Memory layout.** Each conditional-likelihood vector is one contiguous block, and a small scratch buffer replaces a large allocation per call.
5. **Optional diagnostics.** `-DPB_MPI_STATS` records per-message execution and wait time on every slave.
6. **Tooling.** Slurm scripts for benchmarking, fixed-seed regression against `master`, a regression for `readpb_mpi`, a pinned-install script and a rank-scaling benchmark.

`code-optimizations.md` describes each change in detail.

## 3. Results

### 3.1 All models, 312c2bd against `master` (same batch)

Conditions: 8 ranks, unpinned, default flags, simulated alignments (40 taxa x 5000 amino-acid sites; 20 codon taxa x 500 codons for `mutsel`), `-rnd 1`. One run per cell. Wall time includes MPI start-up and program set-up.

| Model flags | Cycles | master (s) | optimized (s) | Ratio | Chain identical |
|---|---|---|---|---|---|
| `-cat -gtr` | 20 | 739.2 | 167.8 | 4.40x | yes |
| `-cat -gtr -spr 2 -nni 2` | 10 | 242.1 | 62.9 | 3.85x | yes |
| `-ncat 10 -gtr` | 15 | 359.5 | 72.3 | 4.96x | yes |
| `-ncat 1 -lg` | 15 | 319.6 | 63.0 | 5.07x | yes |
| `-cat -poisson` | 60 | 361.6 | 174.6 | 2.07x | yes |
| `-cat -poisson -dc` | 30 | 179.4 | 69.5 | 2.58x | yes |
| `-ncat 10 -poisson` | 60 | 242.7 | 124.3 | 1.95x | yes |
| `-cat -poisson -sis 1000 2 3` | 1000 | 235.9 | 143.1 | 1.64x | yes |
| `-mutselc -cat` | 8 | 309.1 | 147.0 | 2.10x | yes |
| `-mutselc -ncat 3` | 8 | 56.8 | 41.6 | 1.36x | yes |
| `-mutsel -cat` | 8 | 81.8 | 63.5 | 1.28x | yes |
| `-mutsel -cat -freeomega` | 8 | 72.7 | 62.1 | 1.17x | yes |
| `-mutsel -ncat 3` | 8 | 56.1 | 67.2 | **0.83x** | yes |

Read the table with care:

- `master` timings vary between batches. For CAT-GTR on this alignment, `master` took 739 s here, and 954 s and 900 s in two earlier runs. The ratio in the first row is therefore uncertain by tens of percent.
- The speed-up is largest for CAT-GTR and LG and smallest for the codon (`mutsel`) models. The likely reason is that the optimized code paths (the amino-acid pruning kernel and the mixture moves) are a smaller share of the time in the codon models. The codon models were not profiled, so this is an inference.
- The `-mutsel -ncat 3` result is a single short unpinned run and has not been repeated. Do not conclude that the model is slower until it is.

### 3.2 Production-size data set, pinned

Data: 38 taxa, 59,994 amino-acid sites; model CAT-GTR; a chain resumed from one saved state with the same seed; AVX2 builds; 64 ranks, pinned to cores.

| Build | Cycles run | Seconds per cycle (mean) |
|---|---|---|
| `master` (3c77656) | 8 | 71.28 |
| `master` without AVX2 flags | 8 | 69.67 (median 63.67) |
| 312c2bd | 20 | 16.35 (median 16.39) |

Ratio 71.28 / 16.35 = 4.36x. The first 8 cycles of `.trace` are identical between `master` and 312c2bd (see `validation.md`, section 3.2). One run per row.

### 3.3 History: where the speed came from

Cumulative, one run each unless stated, CAT-GTR, 40x5000, 8 ranks, unpinned, default flags, 20 cycles, wall seconds. Each row includes all earlier commits.

| Run | Commit | What the commit adds | Wall (s) |
|---|---|---|---|
| base_a, base_b | 3c77656 (`master`) | none | 954, 900 |
| opt1 | d2456fc | Unfold: one likelihood pass instead of two | 648 |
| opt2 | 9cb60c2 | Propagate: small scratch, shared exponentials, leaf shortcut | 683 |
| opt3 | f56c1f7 | cache `log(profile)` per component | 533 |
| opt4 | 288cc6e | drop redundant full updates in GibbsSPR (276960e) | 509 |
| opt5 | 14297a9 | column-wise matrix-vector products, hoisted virtual calls | 335 |
| opt6 | 81ad2c2 | one contiguous block per conditional-likelihood vector | 344 |
| opt7 | a183303 | partial post-order updates in GibbsSPR | 304 |
| `cmp_base0` (3 runs) | 31a9b87 | adds e62498b (cached logs in the weight move) | 309, 255, 233 |
| `cmp_mine0` (3 runs) | 312c2bd | register-blocked Propagate kernel, leaf cache, hash-free exp cache | 179, 170, 162 |

Notes:

- These are cumulative times. **No single change was measured on its own.** The commit that adds the most visible speed in this series is 14297a9 (508 s to 335 s), but one run per row cannot separate the effect of a change from run-to-run variation (6% to 21% for identical builds). Changes of less than about 20% between adjacent rows are not meaningful.
- opt2 is slower than opt1 (683 s against 648 s) although it removes work. This is within the noise, and it shows how coarse the series is.
- The last two rows come from a different batch and different node load from the first rows.

### 3.4 Where the time goes now

A `perf` profile of a slave rank on the 40x5000 CAT-GTR run at 312c2bd gave these shares of self time (recorded in the shared coordination notes of an earlier session; not re-measured for this document):

| Function | Share |
|---|---|
| `MatrixSubstitutionProcess::PropagateImpl` | 31% |
| MPI polling (idle waiting) | 9% |
| `SubstitutionProcess::Multiply` | 8% |
| QR and diagonalization (`LinAlg`) | 7% |
| `LogStatProb` | 4% |

The master spends about 91% of its time in MPI polling (from an earlier profile). It is mostly idle while the slaves work. A profile of an earlier commit (81ad2c2, unpinned) showed `PropagateImpl` at 48%, so the kernel work reduced its share.

### 3.5 Scaling with the number of ranks

Data: 38 taxa x 59,994 sites, CAT-GTR, pinned. Each row is one run of 20 cycles, resumed from the same saved state. All rows except the last used the **earlier build 31a9b87**. Speed-up and efficiency are relative to 16 ranks. One rank is the master and does little work.

| Ranks | Seconds per cycle | Speed-up vs 16 | Efficiency | Core-seconds per cycle |
|---|---|---|---|---|
| 16 | 53.96 | 1.00x | 100% | 863 |
| 24 | 38.15 | 1.41x | 94% | 916 |
| 32 | 32.92 | 1.64x | 82% | 1053 |
| 48 | 25.35 | 2.13x | 71% | 1217 |
| 64 | 20.75 | 2.60x | 65% | 1328 |
| 96 | 14.83 | 3.64x | 61% | 1424 |
| 128 | 14.15 | 3.81x | 48% | 1811 |
| 64 (312c2bd) | 16.35 | n/a | n/a | 1046 |

What this means:

- Going from 96 to 128 ranks adds 33% more cores and reduces the time per cycle by 5%.
- A cycle costs about 1.7x more core time at 128 ranks than at 32 ranks.
- Fewer ranks is the better choice for total throughput. More ranks (up to about 64 to 96) is the better choice for the wall time of one chain.
- The scaling table was **not repeated with the current build**, except at 64 ranks. The kernel work moves time from computation to communication, so the scaling curve of 312c2bd is probably different. Re-measure before choosing a rank count for a new project.
- Each row is a single run.

### 3.6 What did not help (not merged)

| Idea | Result | Where |
|---|---|---|
| Send the elementary branch-length commands in batches (182d90b) | chains identical, **no speed-up** at 8 and 64 ranks; reverted in 7683baa | branch `mpi-batching` |
| Ask for the number of states once per site in the pruning helpers (5941ab9) | about 8% on shared cores, **nothing measurable on pinned cores** (95.0 s against 95.9 s), validated only for CAT-GTR | branch `hoist-nstate` |
| A first register-accumulator prototype (22ccd4d) | 1.2x over the previous code, superseded by the kernel of 312c2bd | branch `simd-proto-other-agent` |
| `-mtune=znver1`, `-mno-avx256-split-unaligned-*` | no gain separable from noise (unpinned) | `build-and-compiler-options.md` |

## 4. Reliability of the numbers

- **Run-to-run spread.** Identical builds on identical settings differ by 6% to 21% (for example 954 s and 900 s for `master`; 288 s and 262 s for one optimized build). Single-run differences below that range are not evidence.
- **Pinned and unpinned runs are not comparable.** Unpinned 8-rank runs use 4 physical cores and are about 1.5x slower. Most of the early history in section 3.3 and the table in section 3.1 are unpinned. Use them to see the size of the effect, not to rank small variants.
- **One data set family.** The timing data come from simulated alignments of 40 taxa x 5000 sites, one real data set of 38 taxa x 59,994 sites, and short codon runs. Other shapes (many taxa, few sites, very large alignments) were not measured.
- **Ratios against `master` depend on `master` timings that vary** from batch to batch.
- **Not measured:** peak memory (the optimized code adds small per-matrix caches and a scratch buffer, and stores each conditional-likelihood vector in one block; the change in memory was not measured), start-up cost, and behavior with a different MPI library.

## 5. How to reproduce

All scripts run from the repository root on a Slurm cluster. Output goes to `bench/`, which is git-ignored.

```
# 1. Build and time a fixed-seed chain. Pinned, whole cores:
MPIRUN_OPTS="--bind-to core --map-by core" \
  sbatch --hint=nomultithread scripts/bench/bench.sbatch <ref> <id> 20

# 2. Compare two runs: chain identity and speed-up
scripts/bench/compare_runs.sh bench/<idA> bench/<idB>

# 3. Regression against master for 14 model configurations
PREFIX=<name> scripts/bench/regression.sh submit <ref> master
PREFIX=<name> scripts/bench/regression.sh check

# 4. Regression for readpb_mpi
sbatch scripts/bench/readpb_regression.sbatch <ref> master

# 5. Install a pinned build with a record of how it was made
sbatch scripts/install_build.sh <ref>

# 6. Rank scaling from a saved chain state
sbatch -n <ranks> --mem <mem> scripts/bench/scaling.sbatch <build dir> <id> <ncycles> <.param> <alignment>
```

`scripts/bench/make_testdata.sbatch` makes the simulated alignments. Edit the `-C milan` and partition lines in the scripts for another cluster.

## 6. Open items

1. Re-measure the rank-scaling table with the current build.
2. Repeat `-mutsel -ncat 3` (pinned, at least 3 runs) to find out whether it is slower than `master`.
3. Pinned test of the compiler flags in `build-and-compiler-options.md`.
4. `pb_mpi -cat -gtr -sis` aborts with a NaN in `master` itself. This blocks validation of stepping-stone sampling with CAT-GTR.
5. Remaining hot spots: `Multiply`, QR and diagonalization, `LogStatProb`, and idle time waiting for the master.
