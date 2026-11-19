# SIMD analysis for pbmpi (perf-opt)

Status: analysis only. No code changed, nothing built. Date: 2026-11-19.
Source: Fable read-only review of the code, profiles and disassembly of existing bench binaries. Items marked "checked" I verified by hand.
Tags: [code] read in source, [profile] read in profile or bench output, [disasm] read in disassembly, [inference] not measured.

## 1. Answer in brief

- SIMD is already partly in use. Plain `-O3` gives SSE2 (2-wide) code. `-mavx2` gives AVX2 (4-wide) code. The compiler does this by autovectorization. `perf-opt` has no intrinsics. [disasm, checked: Makefile `ARCHFLAGS=` is empty by default]
- One kernel dominates: `MatrixSubstitutionProcess::PropagateImpl`, 47.8% of slave self time (checked). Its two matrix-vector loops are about 30.7% of slave cycles. [profile]
- Remaining gain from better SIMD on that kernel: about 1.11x to 1.23x overall, with a hard bound of 1.44x if the loops cost nothing. These are estimates, not measurements.
- Bit-identical results are possible if each SIMD lane runs the same scalar operation order and no FMA is used. Reordered sums are not identical and fall under the `CLAUDE.md` accuracy-versus-speed class.
- SIMD cannot help the MPI waiting share, the master, or the ordered reductions.

## 2. Profile coverage (important limit)

- Only CAT-GTR on `bench/data/sim40x5000.phy` (40 taxa, 5000 sites), 8 ranks, EPYC 7713. [profile]
- No profile exists for Poisson, LG, finite mixtures or codon models.
- The newest profile (`opt6_avx2_perf`) predates HEAD (later commits a183303, e62498b). Shares at HEAD are not measured.

Slave rank 1, `bench/opt6_avx2_perf/perf.1.flat.txt` (checked, top rows):

| Function | Self % |
|---|---|
| `MatrixSubstitutionProcess::PropagateImpl` | 47.82 |
| Open MPI polling (vader progress 9.88, opal_progress 2.44, timer 1.79) | about 14.7 total |
| `GetNstate` virtual thunk | 3.66 |
| `SubstitutionProcess::Multiply` | 3.26 |
| libm (exp/log) | about 5.1 summed |
| `LogStatProb` | 1.78 |
| `LinAlg::QR` | 1.55 |
| `LinAlg::DiagonalizeSymmetricMatrix` | 1.32 |
| `SubstitutionProcess::Offset` | 0.93 |

- Master rank 0: about 91% in MPI polling. Not a SIMD target. [profile]
- `bench/stats8/mpistats.1.txt`: slaves execute 86.4% of the time and wait 13.6%. [profile]
- Inside `PropagateImpl`, annotate shows the two matrix-vector loops at 39.6% and 24.7% of function samples (64%). The other 36% is hash lookup, virtual calls, checks and the exp cache. [profile]

## 3. The hot kernel

`sources/Propagate.cpp:108-223` [code, loops at 165-195 checked]

- Loops: sites, then rate categories (default 4), then two matrix-vector products in column (axpy) form. Inner trip count is nstate: 20 for amino acids, 61 for codons.
- Matrices are flat transposed arrays; pointers are `__restrict__`.
- Conditional likelihoods are `double***` pointers into one contiguous block per vector. Stride is nstate+1; the last slot holds the log offset (`SubstitutionProcess.cpp:90-121`). No explicit alignment.
- Each output lane `k` adds terms in order l = 0..nstate-1. No cross-lane dependence. This is why vectorizing across `k` keeps the exact scalar order.
- Disassembly: `bench/opt7` uses packed xmm (SSE2); `bench/opt7_avx2` uses packed ymm. Zero FMA in both. [disasm]
- Two weaknesses in the AVX2 code [disasm]:
  1. GCC 8.5 splits each unaligned 256-bit load and store into two 128-bit halves.
  2. The accumulator is loaded from and stored to memory on every `l` iteration.

## 4. Other kernels

| Kernel | Where | SIMD state | Note |
|---|---|---|---|
| `Multiply`, `Offset`, `MultiplyByStationaries` | `SubstitutionProcess.cpp:191-273` | Already vectorized | About 4% of time; at most 1.02x more |
| `ComputeLikelihood` | `SubstitutionProcess.cpp:296-315` | Scalar | Ordered sum; keep scalar for identity |
| Poisson `Propagate` | `PoissonSubstitutionProcess.cpp:36-66` | Dot product scalar, update vectorized | nstate varies per site |
| `LogStatProb` | `ExpoConjugateGTRMixtureProfileProcess.cpp:113-130` | Scalar | Ordered reduction over 20 terms |
| Eigen-decomposition | `linalg.cpp:26-110` | Partly vectorized | `double**` rows; column dot products are ordered; about 3% |
| Sufficient statistics | `ExpoConjugateGTRSubstitutionProcess.cpp:60-70` | None | Pointer chasing over `BranchSitePath` lists |

## 5. Options for the hot kernel

| Option | Identical results? | Verdict |
|---|---|---|
| Register accumulators for nstate = 20 (5 ymm in registers across the `l` loop) | Yes, same operation order [inference] | **Do first.** Main remaining gain. |
| Flags `-mno-avx256-split-unaligned-load/store` | Yes (code generation only) | Cheap test. |
| Pad stride 21 to 24, align to 32 bytes | Yes | Local to `CreateConditionalLikelihoodVector` (lines 104-118). Other code assuming the 21 stride was not checked. 61 states need 64. |
| Vectorize across the 4 rate categories | Yes if each lane keeps its order [inference] | Large layout change; extra gain unknown. |
| Vectorize across sites | Yes in principle | Poor fit: per-site matrix under CAT-GTR needs gathers; Poisson has per-site nstate. |
| Vectorize ordered reductions across states | **No** (reordered sum) | Approximate class; off by default. |
| FMA (`-mfma`, `-march=native`) | **No** unless `-ffp-contract=off` | The Makefile already warns about this. |
| Vector libm, `-ffast-math` | **No** | Do not use. |
| BLAS GEMM | **No**; 20x20 is small against call overhead | Reject as default. |

## 6. Implementation route

1. Restructure the loops and let the compiler vectorize (compile-time nstate = 20 specialization, local accumulators). Check the disassembly that GCC 8.5 keeps accumulators in registers.
2. If that fails, write intrinsics for the single `PropagateImpl` kernel, behind a compile-time switch, scalar path kept. Intrinsics map to SSE2, AVX2, NEON and WASM SIMD128 (2-wide, no FMA).
3. Wrapper libraries: `std::experimental::simd` needs C++17 and a newer GCC than 8.5. xsimd and Highway C++11 status not verified. Each adds a dependency for one kernel.
4. EPYC 7713 (Zen 3) has no AVX-512, so AVX-512 cannot be tested on the pinned bench nodes. [inference]

## 7. Speed estimates (not measurements)

- Amdahl base: loops are about 30.7% of slave cycles (CAT-GTR only).
- Loops 1.5x to 2.5x faster: 1.11x to 1.23x overall.
- Hard bound if loops were free: 1.44x.
- Already-vectorized `Multiply`/`Offset`: at most 1.02x more.
- Ordered reductions, QR and libm (about 10%): no gain without reordering.
- MPI polling and waiting (about 14.7% of cycles; 13.6% wait): untouched by SIMD.
- Existing AVX2 evidence is noisy: `opt5` to `opt5_avx2` 1.10x; `opt7` to `opt7_avx2` 1.27x; `opt6` to `opt6_avx2_perf` 0.90x (perf on for only one run). Same-build replicates differ by 6% to 21% (`base_a`/`base_b` 954/900 s). Single runs cannot settle a gain below about 20%.
- Existing identity evidence: `compare_runs.sh` reported identical treelist, chain and trace for `opt5` vs `opt5_avx2`, `opt6` vs `opt6_avx2_perf`, `opt7` vs `opt7_avx2`. So `-mavx2` autovectorization has kept the chain identical in these cases.

## 8. Validation (per `CLAUDE.md`)

- Each variant: `bench.sbatch` with `-rnd 1`, then `compare_runs.sh` against a `master` build. Require identical treelist, chain and trace.
- Run `scripts/bench/regression.sh` across all models, including codon (61 states) and Poisson.
- At least 3 replicates per timing.
- A variant that is not identical is class 2: per-step log-likelihood agreement plus posterior agreement across independent chains, and off by default.

## 9. First experiment (1 to 3 days)

1. At HEAD, via `EXTRA_CPPFLAGS`: `-mavx2` against `-mavx2 -mno-avx256-split-unaligned-load -mno-avx256-split-unaligned-store`. Three replicates each; one with PERF=1. Check identity.
2. Prototype the nstate = 20 register-accumulator kernel. Check disassembly, chain identity and time.
3. Re-profile HEAD to refresh the Amdahl share, and profile at least one Poisson and one codon case.

## 10. Risks and rules

- No `-ffast-math`, `-march=native`, `-mfma` without `-ffp-contract=off`, vector libm or BLAS in the default build.
- Do not vectorize ordered reductions across states by default.
- Do not start with AVX-512 or cross-site layouts.
- A non-baseline x86-64 build needs a per-CPU binary or runtime dispatch.
- Padding changes memory use and any code that assumes the nstate+1 stride.
- GCC 8.5 code generation may differ from newer compilers; verify identity per compiler.
- FMA default contraction in GCC for C++ is from compiler documentation, not verified on this compiler.

## 11. Link to other ideas
- WASM (`wasm-volunteer-chains-plan.md`): the earlier note that `perf-opt` has no SIMD to port is confirmed. An intrinsics kernel would need a WASM SIMD128 variant.
- Parallelization (`parallelization-strategies.md`): SIMD speeds each step; it does not change the sequential chain limit.
