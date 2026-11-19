# Parallelization strategies for PhyloBayes: record of ideas

Status: discussion record. No code written. Date: 2026-11-19.
Related: `docs/wasm-volunteer-chains-plan.md`, `docs/m0-native-shim-experiment.md`, `docs/kubernetes-design.md`.

## 1. Baseline

- Today's parallelism: MPI master/slave over alignment sites inside one chain. Many small blocking messages per cycle.
- Measured on UCR HPCC, 40 taxa x 5000 aa sites, CAT-GTR, 8 ranks, EPYC 7713: `master` 900-954 s for 20 saved cycles; `perf-opt` about 240-300 s (`bench/*/walltime.txt`).
- Hard limit: one chain is sequential. Options either speed up each step or add more chains.

## 2. Strategies

| # | Strategy | Gain | Status | Correctness class (per `CLAUDE.md`) |
|---|---|---|---|---|
| 1 | Independent chains (different `-rnd`) | More samples, convergence checks | Works today | Identical per chain |
| 2 | Threads inside one process, replacing MPI slaves on a node | Removes message copies on one node | Not started. Invasive: master and slave share classes split by `myid`; `rnd` is a global static | Should be identical if rank-count semantics are preserved |
| 3 | Explicit SIMD | Faster per core | Not started. `perf-opt` has no intrinsics; AVX2 is only an optional compiler flag | Identical or rounding-level; must be shown |
| 4 | GPU likelihood (BEAGLE style) | Faster likelihood | Not started. CAT mixtures have a per-site profile, so fit is poor | Rounding-level at best |
| 5 | Parallel tempering (heated chains with swaps) | Better mixing, parallel across chains | Not in pbmpi | Approximate class: explicit tradeoff, off by default |
| 6 | Fewer messages (batching) | Less latency cost | Done in part: `BATCH` message, commit 182d90b | Identical (verified by chain comparison) |
| 7 | Browser WASM volunteers | More chains from many devices | Feasibility study only | See `wasm-volunteer-chains-plan.md` |
| 8 | Kubernetes pods | Same as Slurm, different platform | Design only | See `kubernetes-design.md` |

## 3. Observations
- Strategies 7 and 8 add chains; they do not speed up a chain.
- Strategy 2 would also simplify a WASM or container port, because MPI would be gone. It is large work. No measurement shows messaging is the bottleneck. `-DPB_MPI_STATS` (commit 72311b3) can show it.
- Whether the bottleneck is messaging or arithmetic decides between strategies 2, 3, 4 and 6. This is currently unmeasured in this record. Reading existing `mpistats` output is the first step.

## 4. Decisions so far
- No code is to be written for these ideas yet.
- Suggested order if work resumes: (a) measure messaging share; (b) M0 experiment; (c) Kubernetes only if HPCC capacity is short.

## 5. Open questions
- Does a reseeded restart preserve the posterior? (M0, Experiment B.)
- How much memory does a representative run use?
- Does the same seed on a different rank count give a statistically equivalent chain?
