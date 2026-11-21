# Pull request text: stepping-stone fixes

Text of the pull request of branch `fix-stepping-stone` (two commits on top of `master` 3c77656) to `bayesiancook/pbmpi`. This file stays on `perf-opt`; it is not part of that pull request. The background is in `bug-fixes.md` and `validation.md`, section 3.4.

---

## Title

Two fixes for stepping-stone runs (-sis)

## Description

1. `-cat -gtr -sis` aborted with `in Plink::SetRelativeTime: setting to nan`.
   `GTRProfileProcess::Create` allocated `emprralpha` and `emprrbeta` and never
   set them. `SteppingRun` sets the empirical fraction at every point, also
   when no empirical prior is loaded, so the relative rates were drawn from
   Gamma(0 + count, 0 + beta). Both arrays are now initialized to 1.0, as
   the other empirical-prior parameters already are.

2. The `logZ` and `effsize` columns of `.stepping` printed `-nan` when the first
   step had a very negative log-likelihood: the first rescaling of the
   running sums was `0 * exp(+large)`. The rescaling is now skipped while
   the sums are empty. The chain itself is unchanged.

Chains that do not use `-sis` are unaffected (identical `.treelist`, `.chain`
and `.trace` with the same seed, CAT-GTR and a finite GTR mixture).
Tested with GCC 8.5.0 and Open MPI 4.1.2.

---

## Status

Opened on 2026-11-20 as https://github.com/bayesiancook/pbmpi/pull/39 (head `hyphaltip:fix-stepping-stone` at aee5513, base `master` at 3c77656). The `Co-Authored-By` trailers were removed from the two commits, and the description starts with the line "Assisted by Claude Code, this PR is for stepping-stone improvement based on code audit in attempt to find performance improvements".
