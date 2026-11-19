# M0 design: native MPI shim and reseeded-restart experiment

Status: planning only. No code written. Date: 2026-11-19.
Parent document: `docs/wasm-volunteer-chains-plan.md` (stage M0).

## 1. Purpose

Test the two largest risks of the WASM idea without a WASM toolchain:

1. Can a replacement `mpi.h` (shared-memory, no OpenMPI) run `pb_mpi` and give the same chain as the OpenMPI `master` build?
2. Does a chain defined as "restart from `.param` every K cycles with a new seed" give the same posterior as one unbroken chain?

## 2. Background facts (from the source)

- `pb_mpi` uses 10 MPI functions: Init, Finalize, Comm_rank, Comm_size, Bcast, Send, Recv, Gather, Barrier, Wtime. `MPI_ANY_SOURCE` appears 17 times (Fable count, not re-checked by me).
- `PB.cpp:471-476` requires at least 2 ranks.
- All ranks get the same seed (`PB.cpp:554-556`). Slaves also draw random numbers. The chain depends on the rank count.
- The Mersenne Twister buffer is filled from libc `rand()` (`Random.cpp:73-77`). `mt_buffer` is `unsigned long` (`Random.h:83`).
- RNG state is not checkpointed. `.param` restarts do not continue the RNG stream.

## 3. Experiment A: shim equals OpenMPI

### Design
- Write a replacement `mpi.h` and runtime that implements the 10 functions over shared memory (threads or forked processes with shared segments). Keep it outside `sources/`; select it with a compiler include path.
- Pin `rand()` so that the RNG seeding does not depend on the system libc. Use one fixed, documented algorithm. The reference build must use the same pinned `rand()`, or the comparison measures the RNG and not the shim.
- Build three binaries from the same source:
  - R0: `master` with OpenMPI and glibc `rand()`. Reference for the project rule.
  - R1: `master` with OpenMPI and pinned `rand()`. Isolates the effect of the RNG change.
  - S1: `master` with the shim and pinned `rand()`.
- Run each with `-rnd 1`, the same rank count (start with 8, as in `bench.sbatch`), on the same CPU type (milan nodes).

### Comparisons
- R1 against S1: must be byte-identical in `.trace` (except the time column) and `.treelist`. This tests the shim.
- R0 against R1: expected to differ. Record how. This is the cost of pinning `rand()`.
- Use `scripts/bench/compare_runs.sh` for chain identity and speedup.

### Datasets
- `bench/data/sim40x5000.phy` is referenced by `bench.sbatch`; confirm it exists before use.
- Use a smaller case first (for example the CAT-Poisson regression in `scripts/bench/regression.sh`) so failures are cheap to debug.
- Cover at least: CAT-GTR, CAT-Poisson, one finite mixture. Add codon models only if the first three pass.

### Pass / fail
- Pass: R1 and S1 identical on all models tested.
- Fail: any difference. Then find the first differing cycle and the message that preceded it. Likely causes to check: message order with `MPI_ANY_SOURCE`, Gather ordering, uninitialized buffers.
- Report which validation level was reached, as `CLAUDE.md` rule 3 requires.

## 4. Experiment B: reseeded restarts

### Question
Is "restart every K cycles with seed s_i" statistically equivalent to one unbroken chain?

### Design
- Use `master` with OpenMPI so this test does not depend on Experiment A.
- Unbroken: N independent chains of L cycles, seeds 1..N.
- Restarted: N independent chains of L cycles, each stopped every K cycles and resumed from `.param` with a fresh seed.
- Choose K values that bracket real use (for example K = 5, 20, 100). K must be small enough that restarts occur many times in L.
- Keep rank count fixed in all runs.

### Comparisons
- Per-chain `.trace` summaries: log-likelihood, tree length, alpha, number of modes. Use `tracecomp` between the two sets.
- Topology: split frequencies with `bpcomp` between unbroken and restarted sets.
- Look for: shifts in mean, changed effective sample size, slower or faster burn-in.

### Pass / fail
- Pass: no difference beyond the spread seen between independent unbroken chains.
- Fail: a systematic shift. Then the restart scheme is not a safe work unit.

### Open questions
- Does restart reset any state that `.param` does not hold (the RNG is the known one)? Check what `Model(name,myid,nprocs)` re-initializes. I have not read this path in full.
- Does `.chain` append correctly across restarts?
- Cost of each restart (startup, reading `.param`). Measure; it sets the minimum useful K.

## 5. Deliverables
- A shim interface note listing the 10 functions and the semantics that `pb_mpi` relies on.
- A results table: model, rank count, R0/R1/S1 identity, restart statistics.
- A go/no-go statement for M1 (Emscripten under Node.js).

## 6. Effort and limits
- Estimate: 1-2 weeks (Fable, not measured).
- No claim about WASM speed or libm behavior comes from this stage. M1 covers those.
- Risks: HPCC queue time for long chains; rank-count sensitivity; MPI_ANY_SOURCE ordering.
