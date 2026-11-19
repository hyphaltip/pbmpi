# pbmpi (PhyloBayes MPI) — performance work

Fork of `bayesiancook/pbmpi`. The `perf-opt` branch carries speed optimizations.
`master` is the reference ("original") implementation.

## Correctness rule for every optimization (owner: Jason Stajich, set 2026-11-19)

The optimized tool must produce the same results as the original source code, and
this must be validated, not assumed.

1. **Default: identical results.** With the same data, model and `-rnd` seed, the
   optimized build must follow the same chain as `master` (same `.treelist`, same
   `.trace` apart from the time column). Small floating-point rounding differences
   may be allowed, but only when they are identified, explained and shown to be
   rounding-level (not a logic change).
2. **Shortcut / approximate optimizations are a separate class.** Anything that
   changes the arithmetic or skips work in a way that can change results must be
   presented as an explicit accuracy-versus-speed tradeoff, with both sides
   measured, and should be off unless chosen.
3. **Validate against the original.** Every change is compared with a `master`
   build on the HPCC before it is called done:
   `scripts/bench/bench.sbatch` (build a ref, run a fixed-seed chain, time it) and
   `scripts/bench/compare_runs.sh` (chain identity + speedup). When a change cannot
   be bit-identical, validate numerically (per-step log-likelihood agreement) and
   statistically (posterior summaries from independent chains agree), and report
   which level of validation was achieved.

## Layout

- `sources/` — C++ code, `make` there builds into `../data/` (git-ignored).
- `scripts/bench/` — benchmark, test-data and regression scripts (Slurm, HPCC).
- `bench/` — git-ignored outputs, one folder per run; safe to delete.
- HPCC checkout: `~/projects/pbmpi` (ssh host `hpcc2`); the laptop pushes the
  branch there with `git push hpcc perf-opt`. Jobs go to the `short` partition.
