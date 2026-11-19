# Thought experiment: PhyloBayes in WebAssembly for browser volunteer computing

Status: planning only. No code was written or built. Date: 2026-11-19.
Branch reviewed: `perf-opt`. Advice source: a Fable review of the code, checked in part by hand (see "Evidence").

## 1. The idea

Compile PhyloBayes to WebAssembly (WASM). Volunteer browsers fetch a work unit from a central server, run MCMC cycles, and upload the result. This is volunteer computing in the style of BOINC.

## 2. Short answer

- A WASM build is technically feasible. Effort is medium.
- The only workable work unit is "run K cycles, resumed from a checkpoint". Whole chains and per-site sub-tasks do not work.
- Volunteers add more chains. They do not make one chain faster.
- Identical results to the HPCC `master` build are not achievable without extra work. Identity to a pinned native build is achievable.
- The scientific value is doubtful for large analyses. It is plausible for teaching, outreach and small public datasets.
- Measured speed is the missing fact. No WASM number exists yet. Do the experiments in section 8 before any server work.

## 3. What the code is (facts from the source)

| Fact | Where |
|---|---|
| `pb_mpi` exits if fewer than 2 MPI processes run | `sources/PB.cpp:471-476` |
| Parallelism is master/slave over alignment sites inside ONE chain | `sources/PhyloProcess.cpp`, `sources/Parallel.h` |
| 69 command messages; about 150 MPI lines in `PhyloProcess.cpp` | `sources/Parallel.h:24` |
| Only 10 MPI functions are used (Init, Finalize, Comm_rank, Comm_size, Bcast, Send, Recv, Gather, Barrier, Wtime) | whole tree |
| Independent chains are separate runs with different `-rnd` seeds | `sources/PB.cpp` |
| Checkpoint is text: `.param` (full state, overwritten each cycle), `.chain` (appended), `.trace`, `.treelist` | `sources/Model.h:327-348` |
| Restart from `.param` | `sources/Model.h:187` |
| Measured: 40 taxa x 5000 aa sites, CAT-GTR, 8 ranks on EPYC 7713: master about 45-48 s per saved cycle; `perf-opt` about 12-15 s | `bench/*/walltime.txt` |
| `.param` is about 224 KB for that dataset | `bench/base_a/chain.param` |

Implication: one MCMC cycle needs many blocking messages between master and slaves. Latency matters. Splitting a chain across the internet is not workable.

## 4. Reproducibility obstacles

These matter because `CLAUDE.md` requires identical results to `master` for the same seed.

1. **RNG seeding.** The Mersenne Twister buffer is filled from libc `rand()` after `srand(seed)` (`sources/Random.cpp:73-77`). glibc and Emscripten (musl) give different `rand()` streams. Same `-rnd` gives a different chain unless a glibc-compatible `rand()` is supplied. Verified by reading the code.
2. **Word width.** `mt_buffer` is `unsigned long` (`sources/Random.h:83`). It is 64-bit on the HPCC and 32-bit on wasm32. The twist may still produce the same values. Not tested.
3. **Rank count changes the chain.** Every rank is seeded the same (`rnd::init(1,randfix)`, `sources/PB.cpp:554-556`). Slaves also draw random numbers, and sites are split by rank. A WASM run must emulate the same number of ranks as its reference. (Fable cites `SubstitutionProcess.cpp:454-522`, `PhyloProcess.cpp:936-944`. I did not read those lines.)
4. **RNG state is not checkpointed.** A chain resumed from `.param` does not equal an uninterrupted chain. Each work unit needs its own seed.
5. **libm.** Many calls to `exp`, `log`, `pow` and gamma functions. The Emscripten libm can differ from glibc by a few ulps. Not measured.
6. **Pointer-keyed maps.** `map<pair<Link*,Link*>,double>` (`sources/PhyloProcess.h:544-547`). Iteration order depends on addresses. Not checked whether it changes results.

Realistic target: WASM output is byte-identical to a native build of the same source with pinned `rand()` and libm. That native build is then validated against `master` under `CLAUDE.md` rule 3. Report which validation level was reached (per-step log-likelihood agreement, then posterior agreement between independent chains).

## 5. Architecture options

### 5.1 Getting MPI out of the way

| Option | Verdict |
|---|---|
| Replacement `mpi.h`; one WASM instance per rank, each in a Web Worker; messages via SharedArrayBuffer and `Atomics.wait` | **Recommended.** About 500-1000 lines of shim and JS (estimate). No change to `sources/` except the compiler. Needs COOP/COEP headers on the page. |
| Single-process mode with master and slaves as objects | Not recommended. Master and slave are the same classes split by `myid` tests (about 150 lines), and `rnd` is a global static (`Random.cpp:29-30`). Invasive refactor. |
| Existing `NonMPIGibbsSPR` code | Not a path. It is used by the `*Gene*` classes only. No evidence of a working single-process path. |

### 5.2 Work unit

| Unit | Verdict | Reason |
|---|---|---|
| (a) whole chain | No | Real chains take hours to days. A tab can close at any time. |
| (b) K cycles resumed from `.param`, own seed per unit, fixed rank count | **Yes** | Survives tab loss. Upload is small (about 224 KB `.param` plus about 225 KB per saved cycle for the 40x5000 case). |
| (c) per-site or per-slave sub-tasks | No | Many blocking messages per cycle. Internet latency dominates. |

Chain definition under (b): "restart every K cycles with seed s_i". This is a different Markov chain definition from one unbroken chain. A native build can run the same schedule, so comparison stays possible. It must be tested (M0).

Size K for 10-30 minutes of volunteer work. For the 40x5000 CAT-GTR case that is few cycles.

### 5.3 Server side

- Work queue with leases and timeouts.
- Signed manifest: hashes of WASM binary, alignment, input `.param`, seed, K, rank count.
- Object storage for inputs and results (presigned URLs).
- Validator. WASM arithmetic is deterministic for one binary. Two volunteers running one unit should return byte-identical `.param`, `.trace`, `.treelist`. Use a quorum of 2 plus a tie-breaker. This at least doubles compute. Without it, forged posterior samples cannot be detected.
- Platform: a small custom service is the simplest fit. BOINC has a good validation model to copy. I do not know of an official BOINC browser/WASM client. Not verified.
- Existing HPCC point: compute nodes may have no internet, so the server is separate from the cluster.

## 6. Constraints and risks

- **Speed (unmeasured).** General WASM benchmarks put WASM at about 1.2-2x slower than native (from memory, not measured for this code). A volunteer device has fewer and slower cores than an EPYC node. Redundancy doubles cost. Each chain pays full burn-in.
- **No SIMD to port.** `perf-opt` uses no intrinsics (grep found none). AVX2 is only an optional compiler flag in the Makefile. WASM SIMD would be new work.
- **Memory.** Each rank has a 4 GB wasm32 limit in the worker-per-rank design. Conditional-likelihood size was not computed.
- **Confidentiality.** Volunteers receive the full alignment. Unpublished data is excluded.
- **GPL v3.** Serving the WASM is conveying object code. Offer corresponding source, including the MPI shim and build scripts.
- **Browser requirement.** Cross-origin isolation (COOP/COEP) for SharedArrayBuffer.

## 7. Scientific fit

- Realistic (inference): public or published alignments; up to about 1000 sites and 20-50 taxa; cheap models (CAT-Poisson, fixed matrices); teaching and demonstration.
- Out of reach: supermatrices; CAT-GTR on thousands of sites; codon mutation-selection models. At 12-15 s per cycle on 8 EPYC ranks, such a chain takes days on one volunteer, before the WASM penalty and redundancy.
- Likely outcome: one HPCC node beats many volunteers per chain. Volunteers help only where many independent chains or many small datasets are wanted.
- No data on what share of users could use public data only.

## 8. Staged roadmap (effort figures are estimates)

| Stage | Work | Effort | Go / no-go |
|---|---|---|---|
| M0 (first experiment) | Native only. Shared-memory `mpi.h` shim, pinned `rand()`. Run `scripts/bench/compare_runs.sh` against `master`. Test "restart every K cycles with seed s_i" on `master` against one unbroken chain. | 1-2 weeks | Shim chain identical to OpenMPI `master`. Restart schedule gives statistically equal posteriors. |
| M1 | Emscripten build under Node.js with worker threads. Measure seconds per cycle against native at the same rank count. Diff `.trace`. | 2-3 weeks | Slowdown 2.5x or less. Divergence source identified. |
| M2 | Browser run, OPFS checkpoints, kill and resume. | 2-3 weeks | Two different browsers give byte-identical unit output. |
| M3 | Server, quorum validator, one public dataset. | 4-6 weeks | Honest throughput against one HPCC node. |

M0 gives the most information for least cost. It needs no WASM toolchain. It tests the two largest risks: the shim design and the reseeded-restart chain definition.

## 9. What not to do

- Do not distribute site-level work to volunteers.
- Do not refactor to a single-process mode.
- Do not promise bit-identity with glibc `master`.
- Do not accept unvalidated results.
- Do not accept unpublished data.
- Do not start the server before M1 gives a measured speed.

## 10. Evidence and its limits

- Code facts: read in `sources/` on `perf-opt`. Spot-checked by hand: RNG seeding via `rand()`, `unsigned long` buffer, same seed on every rank, no SIMD intrinsics.
- Not checked by me: Fable's line citations for slave RNG use and site splitting; the `map` ordering question.
- Timings: from `bench/*/walltime.txt` (HPCC, EPYC 7713, 8 ranks).
- All WASM speed, libm and BOINC statements come from memory. `emcc` is not installed on the HPCC host. Nothing was built or measured.
