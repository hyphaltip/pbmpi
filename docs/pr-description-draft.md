# Draft pull request description

Delete this file before the pull request is opened, or keep it only on the PR branch. It is a text to paste into the pull request.

---

## Title

Speed up the likelihood code and mixture moves (4x on CAT-GTR) without changing results

## Summary

This pull request makes `pb_mpi` faster. For the same data, model, `-rnd` seed and number of MPI ranks, it produces the **same chain as the current `master`**: the same `.treelist`, `.chain` and `.trace` (except the timing columns), byte for byte, on 12 model configurations. Two stepping-stone configurations give the same `.stepping` file apart from two columns that `master` prints as `-nan`.

- Wall time against `master` on 8 pinned ranks (two runs each): 4.2x to 5.0x for CAT-GTR (40 taxa x 5000 sites), up to 5.5x for LG, 2.1x to 3.4x for CAT-Poisson, 1.1x to 2.2x for the codon models.
- At production size (38 taxa x 59,994 sites, CAT-GTR, 64 pinned ranks): 16.35 s per cycle against 71.28 s (4.36x).
- Running one rank per physical core ("pinning") gives a further 1.5x on shared-core allocations. It is a run-time setting and needs no code change.

No option, default or output format changes. The new compile-time options (`ARCHFLAGS`, `-DPB_MPI_STATS`, `-DPB_NO_VECTOR_KERNEL`) are off by default.

## What changed

See `docs/code-optimizations.md` for the detail of each change. In short:

1. Fewer repeated likelihood computations (Unfold, GibbsSPR).
2. A faster `Propagate` kernel: transposed contiguous matrices, shared `exp` values, a leaf shortcut, and a register-blocked vector loop with the original order of additions.
3. Cached `log(profile)` and log-gamma values in the allocation and Dirichlet-weight moves.
4. One contiguous block for each conditional-likelihood vector; a small scratch buffer instead of a large allocation per call.
5. Optional per-message timing on the slaves (`-DPB_MPI_STATS`).
6. Slurm scripts for benchmarking and regression, in `scripts/`.

## Why the results are unchanged

Each change keeps the same arithmetic in the same order and the same sequence of random numbers. The argument for each change is in `docs/code-optimizations.md`. The evidence is in `docs/validation.md`. The vector kernel adds terms in the original order and uses separate multiply and add instructions, so it gives the same value as the plain loops.

## How it was tested

- `scripts/bench/regression.sh`: 14 model configurations against `master`, same seed and rank count, run twice. The 12 without `-sis` give identical chains. Stepping CAT-Poisson is identical apart from the two corrected columns. Stepping CAT-GTR cannot be compared against the current `master`, because `master` aborts with NaN; it is compared against `master` with the small fix described below.
- `scripts/bench/readpb_regression.sbatch`: `readpb_mpi` analyses against `master` (30 analyses, all identical for an earlier candidate; to be re-run on the final commit, see below).
- A production-size resumed chain: first 8 cycles identical.
- Compiler flags: `-mavx2` does not change the chain of `master` or of the optimized code.

## Known gaps (please read)

- Validated only with the same number of ranks for both builds, on GCC 8.5.0, Open MPI 4.1.2, AMD EPYC 7713.
- Stepping-stone with CAT-GTR: `master` aborts. The cause is an uninitialized array (see `docs/validation.md`, section 3.4). The fix is an independent 8-line change in `sources/GTRProfileProcess.cpp`. With the fix, the optimized code gives the same `.stepping` file as the fixed `master` for one stepping point on a 20x1000 alignment. The `logZ` and `effsize` columns printed `-nan` for large steps, in `master` too; a second fix (16 lines in `sources/Model.h`) corrects this. **Submit both fixes as a separate small pull request to `master` first** (branches `fix-sis-gtr-nan` and `fix-stepping-logz-nan`; see `docs/bug-fixes.md`).
- Stepping-stone with CAT-GTR gave a second, different result in 4 of 52 runs with identical inputs. It was not reproduced in 23 later runs and has no known cause (`docs/validation.md`, section 3.5). Fixed `master` gave the usual result in all 8 of its runs.
- The codon model `-mutsel -ncat 3` gains little (about 1.15x in 3 pinned runs of 30 cycles).
- The model timings are two pinned runs per cell, and one cell can differ by up to about 30% between the runs. See `docs/PERFORMANCE.md`, section 4.
- The vector kernel uses GCC and clang vector extensions. Other compilers use the plain loops. Not tested on ARM or with clang.

## For reviewers

Suggested reading order:

1. `docs/PERFORMANCE.md`
2. `docs/code-optimizations.md`
3. `docs/validation.md`
4. `sources/Propagate.cpp` (the main kernel), then `sources/SubstitutionProcess.cpp` and `sources/PhyloProcess.cpp`

Things to check closely (details in `docs/code-optimizations.md`, section 12):

- **Two new MPI messages** (`UPDATE_POSTORDER`, `UPDATE_PARTIAL`) are appended to the enum in `Parallel.h`. Master and slaves must be the same build, as always.
- **Caches with manual invalidation:** the log-profile cache (`PrepareLogProfileCache` / `ReleaseLogProfileCache`) and the exponential and leaf caches in `Propagate.cpp`. Check that nothing changes a profile between Prepare and Release, and that two process objects never share one `SubMatrix` (the per-matrix stamp would collide).
- **Skipped updates** rely on the next step being a collapse (`GlobalUnfoldBeforeCollapse`) or on a full update having run earlier (`GibbsSPR` with partial updates).
- **Behavior differences:** `GibbsSPR(0)` returns 0 instead of NaN; the choice of fatal-error message in `PropagateImpl` can differ; `CachedLogGamma(-1.0)` returns 0 instead of exiting. None occurs in normal runs.
- **Known small defects to fix before merging:** a `-Wreorder` warning in `MixtureProfileProcess.h` (87 warning lines, none in `master`), an outdated comment at `PhyloProcess.cpp:652-654`, and a leftover `BATCH` name in `pb_message_names`.

## How to reproduce

```
# build
cd sources && make ARCHFLAGS=-mavx2

# regression against master (Slurm)
PREFIX=pr scripts/bench/regression.sh submit <this-commit> master
PREFIX=pr scripts/bench/regression.sh check
```

Details in `docs/PERFORMANCE.md`, section 5.

## Files in this pull request

- Source changes under `sources/` (the optimizations).
- Documentation under `docs/` (six files listed in `README.md`).
- Scripts under `scripts/bench/` and `scripts/install_build.sh` (Slurm scripts written for the UCR HPCC; they need small edits for other clusters).

Left out of the pull request (project-internal): `CLAUDE.md` and the exploratory planning notes in `docs/` (`wasm-volunteer-chains-plan.md`, `m0-native-shim-experiment.md`, `kubernetes-design.md`, `parallelization-strategies.md`, `simd-analysis.md`).
