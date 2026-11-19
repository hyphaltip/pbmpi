# Design note: running pb_mpi on Kubernetes

Status: planning only. No manifests or code written. Date: 2026-11-19.
Nothing here was run or measured. Statements about Kubernetes and networking come from general knowledge.

## 1. Goal

Run PhyloBayes chains on a Kubernetes cluster, for example for cloud bursting or for users without cluster access. This note covers what is useful and what is not.

## 2. Constraints from the code

- `pb_mpi` needs at least 2 MPI ranks (`PB.cpp:471-476`).
- Parallelism is across alignment sites within one chain. It sends many small blocking messages per cycle (`Parallel.h`, `PhyloProcess.cpp`).
- One chain is sequential. More machines do not speed up one chain beyond what the MPI site split gives.
- All ranks use the same seed, and the chain depends on the rank count (`PB.cpp:554-556`).
- RNG state is not in `.param`. A resumed chain differs from an unbroken one.
- Checkpoint files: `.param` (overwritten each cycle), `.chain`, `.trace`, `.treelist` (appended), `.run`.

## 3. Pattern A: one pod per chain (recommended)

Each pod runs one chain with all its ranks inside the pod.

- Controller: an Indexed Job. One index per chain.
- Pod resources: request and limit equal to the CPUs used (8 ranks = 8 CPUs, matching `bench.sbatch`). Memory limit set from a measured run. Do not guess; the 40x5000 CAT-GTR memory use is not recorded in this repo.
- Command: `mpirun -np <ranks>` inside the pod. MPI uses shared memory. No pod-to-pod traffic.
- Seed: derived from the job index. Record it in the output directory.
- Storage: a persistent volume per chain, or object storage with sync at each checkpoint. Do not use node-local ephemeral storage for results. Same principle as `/bigdata` against `$SCRATCH` on the HPCC.
- Result: `.trace`, `.treelist`, `.param`, and the container image digest, written to a per-chain folder.

Why it fits: chains are independent, so no coordination is needed. This is the same shape as the current Slurm runs.

## 4. Pattern B: one MPI job across pods (not recommended without data)

- Tool: Kubeflow MPI Operator (launcher pod plus worker pods).
- Problem: pod-to-pod latency is higher than an HPC interconnect, and `pb_mpi` is latency-sensitive. Scaling across nodes is unmeasured.
- If tried: set pod affinity to place all workers on one node. That reduces to Pattern A.
- Before any trial: measure with `scripts/bench/scaling.sbatch` and `-DPB_MPI_STATS` on the HPCC to see the share of time spent in messaging. If messaging is small, cross-node scaling may be worth testing. If large, drop it.

## 5. Preemption and restarts

Needed only on spot or preemptible nodes.

- Work unit: K cycles, then checkpoint, then resume.
- Each segment gets its own seed (RNG state is not saved). This defines the chain as a reseeded-restart chain. Whether that is statistically equivalent to an unbroken chain is tested in `docs/m0-native-shim-experiment.md`, Experiment B. Do not use this on spot nodes until that test passes.
- Make the checkpoint write atomic: write to a temp name, then rename. A pod killed during write must not leave a half file. (Design requirement; the current code writes `.param` in place, `Model.h:340`.)
- Set a termination grace period long enough for one cycle to finish. Cycle time is 12-15 s for 40x5000 CAT-GTR on `perf-opt` with 8 EPYC ranks (from `bench/*/walltime.txt`); other cases differ.
- Trusted nodes: no quorum validation and no confidentiality workaround, unlike the volunteer-browser idea.

## 6. Container image

- Build `pb_mpi` from a pinned git commit. Record the commit in the image label.
- Pin the compiler and MPI library versions. Different libm or MPI versions can change results; this repo's rule is identical results to `master` for the same seed.
- Use the same compiler flags as `bench.sbatch` for comparable timing. AVX2 is an optional flag; the image must run on the CPU types in the cluster. Build one image per instruction level, or detect at start.
- GPL v3: if the image is distributed, offer the corresponding source.
- Validate each image the way a build is validated now: `scripts/bench/bench.sbatch` and `compare_runs.sh` against `master`.

## 7. Operations

- Scheduling: requests equal limits, so pods get whole CPUs.
- Monitoring: the `.monitor` and `.trace` files show progress. Export iteration count and log-likelihood.
- Cost: not estimated. Cloud CPU price, storage and egress must be compared with free HPCC allocation. No data collected.
- Security: input alignments may be unpublished. Use private storage and a restricted namespace.

## 8. Is it useful?

- Pattern A: useful only if HPCC allocation is not available. It gives no speed gain per chain. It adds operations work.
- Pattern B: no evidence it helps.
- Greater gains for this project come from per-chain speed (`perf-opt`) and from running more chains.

## 9. Next steps (if wanted)
1. Run `scaling.sbatch` with message statistics to learn the messaging share. Read existing results first.
2. Record peak memory for representative runs.
3. Draft the Job manifest outline and image recipe after those two numbers exist.
