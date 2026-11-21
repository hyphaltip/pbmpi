# Pull request texts: performance work (three pull requests)

Texts for three pull requests to `bayesiancook/pbmpi`. This file stays on `perf-opt`; it is not part of the pull requests. It replaces `pr-description-draft.md`, which described the work as one pull request.

All three branches start from `fix-stepping-stone` (pull request 39), not from `master`. Until 39 is merged, each pull request also shows the two commits of 39. The branches do not depend on each other and can be merged in any order. Validation: `validation.md`, section 3.6.

| Pull request | Branch (`hyphaltip/pbmpi`) | Head | Commits on top of 39 |
|---|---|---|---|
| A | `perf-pruning` | 4fccecb | 6 |
| B | `perf-kernels` | eac9772 | 6 (5 code, 1 documentation) |
| C | `perf-mixture` | c7dca93 | 3 |

Status: branches pushed to the fork on 2026-11-21. Nothing is opened upstream yet.

---

## A. Title

Fewer conditional-likelihood updates in Unfold and GibbsSPR (same chains)

## A. Description

Assisted by Claude Code. This PR removes repeated likelihood updates found in a code audit for performance. It depends on #39 and shows its two commits until #39 is merged.

The chain is unchanged: with the same data, model, seed and number of ranks, `.treelist`, `.chain` and `.trace` (apart from the time columns) are identical to the base on 14 model configurations (CAT-GTR, CAT-Poisson, finite mixtures, LG, `-dc`, NNI, stepping-stone, four codon models).

1. `Unfold` computed the conditional likelihoods twice. It now computes them once, and only the post-order pass before a collapse.
2. `GibbsSPR(nrep)` did a full update before and after the series of SPR moves. Each move already starts with one, so both are removed.
3. After detaching and attaching a subtree, only the vectors on the path to the root are recomputed (new messages `UPDATE_POSTORDER` and `UPDATE_PARTIAL`, appended to the message list).
4. Optional: `-DPB_MPI_STATS` makes each slave write the number of messages and the time per message type. Off by default.

One behavior difference: `GibbsSPR(0)` returned 0/0 (NaN) and now returns 0. `MoveTopo` does not call it with 0 in the default settings.

Wall time, 8 ranks, one rank per core, 40 taxa x 5000 amino-acid sites, single runs: CAT-GTR 525 s to 308 s, LG 259 s to 108 s, CAT-GTR with NNI 185 s to 110 s. CAT-Poisson, 3 runs each: 265 to 297 s for the base, 229 to 234 s with this branch. The codon models change little (`-mutselc -cat`, 3 runs each: 250 to 253 s and 241 to 243 s).

Tested with GCC 8.5.0 and Open MPI 4.1.2 on AMD EPYC 7713. Not tested: other compilers, fixed-topology options, `-catfix`. Related pull requests: likelihood kernels (B), mixture-move caches (C). If B is merged as well, the partial update can use its leaf shortcut (a 4-line follow-up; the result is the same).

---

## B. Title

Faster Propagate and pruning kernels for matrix models (same chains), with documentation

## B. Description

Assisted by Claude Code. This PR speeds up the likelihood kernels found to dominate the run time in a code audit for performance. It depends on #39 and shows its two commits until #39 is merged.

The chain is unchanged: identical `.treelist`, `.chain` and `.trace` (apart from the time columns) on the same 14 model configurations as in A. The order of the floating-point operations is kept, so the results are bit-identical and not only close.

1. Matrix `Propagate`: one small scratch buffer instead of an allocation per call, `exp(t * eigenvalue)` computed once per rate and matrix, and a shortcut for leaves with an observed state.
2. Pruning kernels: column-wise matrix times vector products, virtual calls moved out of the site loops.
3. Each conditional-likelihood vector is one contiguous block.
4. The matrix times vector product keeps its accumulators in vector registers (GCC and clang vector extensions; plain loops with `-DPB_NO_VECTOR_KERNEL` or other compilers).
5. `make ARCHFLAGS=-mavx2` is supported. Flags that allow fused multiply-add (`-mfma`, `-march=native`) change rounding and therefore the chain, unless `-ffp-contract=off` is added. This is documented in the Makefile.

Wall time, 8 ranks, one rank per core, 40 taxa x 5000 amino-acid sites, single runs: CAT-GTR 525 s to 250 s, LG 259 s to 50 s, finite GTR mixture 169 s to 54 s, CAT-GTR with NNI 185 s to 78 s. Poisson and codon models gain less.

With A and C together (two runs per model, against `master`): 4.2x to 5.0x for CAT-GTR, up to 5.5x for LG, 2.1x to 3.4x for CAT-Poisson, 1.1x to 2.2x for codon models. At 38 taxa x 59,994 sites, CAT-GTR, 64 ranks: 16.35 s per cycle against 71.28 s.

This PR also adds five documents under `docs/` (start with `docs/PERFORMANCE.md`). They describe all three pull requests: results, each code change with the reason why the result is unchanged, compiler options, CPU pinning (about 1.5x by itself), and what was and was not validated. Commit names in them refer to the development branch `perf-opt` of `hyphaltip/pbmpi`, which also has the benchmark scripts.

Tested with GCC 8.5.0 and Open MPI 4.1.2 on AMD EPYC 7713. Not tested: clang, other GCC versions, AArch64.

---

## C. Title

Cache log(profile) in the allocation and weight moves (same chains)

## C. Description

Assisted by Claude Code. This PR caches logarithms that were recomputed in the mixture moves, found in a code audit for performance. It depends on #39 and shows its two commits until #39 is merged.

The chain is unchanged: identical `.treelist`, `.chain` and `.trace` (apart from the time columns) on the same 14 model configurations as in A.

1. Allocation moves: `log(profile)` is computed once per mixture component instead of once per site and component.
2. `MoveDirWeights`: `log(profile)` and the log-gamma terms are cached.
3. The member initializers of `MixtureProfileProcess` follow the declaration order (no `-Wreorder` warning).

Wall time, 8 ranks, one rank per core, single runs: CAT-GTR (40 x 5000 amino acids) 525 s to 296 s, CAT-Poisson with `-dc` 148 s to 90 s, `-mutselc -cat` (20 x 1500 codons) 202 s to 113 s. Finite mixtures with few components do not change (finite Poisson mixture, 3 runs each: 148 to 216 s for both).

Tested with GCC 8.5.0 and Open MPI 4.1.2 on AMD EPYC 7713. Related pull requests: A (fewer updates), B (likelihood kernels).
