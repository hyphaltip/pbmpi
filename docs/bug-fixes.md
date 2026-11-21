# Corrections to the original code

The `perf-opt` branch carries two corrections of errors that are also in `master` (3c77656). They are not speed optimizations. Both affect only stepping-stone runs (`pb_mpi -sis`). Chains that do not use `-sis` are unchanged by them. The speed changes are described in `code-optimizations.md`.

| Commit | File | Error in `master` | Correction |
|---|---|---|---|
| 9f2a6fc | `sources/GTRProfileProcess.cpp` (8 lines) | `-cat -gtr -sis` aborts with `in Plink::SetRelativeTime: setting to nan`. The arrays `emprralpha` and `emprrbeta` were allocated and never given values. | Both arrays are set to 1.0, the ordinary prior. |
| db61cc5 | `sources/Model.h` (16 lines) | The `logZ` and `effsize` columns of `.stepping` print `-nan` when the first step has a very negative log-likelihood. The first rescaling of the running sums was `0 * exp(+large)`. | The rescaling is skipped while the running sums are empty. |

The same two corrections exist as separate branches off `master`, for a pull request that is independent of the speed work: `fix-sis-gtr-nan` and `fix-stepping-logz-nan`.

## Evidence

Cause, fix and validation of both are in `validation.md`, section 3.4. In short:

- **9f2a6fc.** The failing case exits 0 with the fix and exited 1 without it. Fixed `master` and unfixed `master` give identical chains for models without `-sis`.
- **db61cc5.** The chain is not changed. For stepping CAT-Poisson, the `.stepping` files with and without the fix differ only in the two columns that were `-nan`.

## Known open point

Stepping-stone with CAT-GTR gave a second, different result in 4 of 52 runs with the same data, seed, rank count and flags. It was not reproduced in 23 later runs, and no cause was found. It is not caused by either correction. See `validation.md`, section 3.5.

## Other behavior differences

Three small behavior differences came with the speed changes (a return value of `GibbsSPR(0)`, the choice of a fatal-error message, and `CachedLogGamma(-1.0)`). None occurs in a normal run. They are listed in `code-optimizations.md`, section 13.
