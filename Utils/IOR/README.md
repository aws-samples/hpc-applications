# IOR — Parallel I/O Benchmark

[IOR](https://github.com/hpc/ior) (Interleaved or Random) is the de-facto standard benchmark for parallel filesystems. It uses MPI to coordinate many processes that read and write a dataset in parallel, and reports the **aggregate throughput** (MiB/s) and IOPS. On AWS it is the right tool to characterise **Amazon FSx for Lustre** (and other shared filesystems such as Amazon EFS or a self-managed parallel filesystem).

The repository also bundles **mdtest**, which measures **metadata** performance — file/directory create, stat, and remove rates — which is often the limiting factor for workloads with many small files.

- Project homepage / docs: <https://ior.readthedocs.io/en/latest/>
- Source: <https://github.com/hpc/ior>
- Summary slides (LLNL): <https://asc.llnl.gov/sites/asc/files/2020-06/IOR_Summary_v1.0.pdf>
- Lustre tuning wiki: <https://wiki.lustre.org/IOR>

## What it measures

| Pattern | IOR flag | What it tells you |
|---------|----------|-------------------|
| File-per-process (fpp) | `-F` | Peak aggregate bandwidth — each rank owns its own file, the easiest case for Lustre to stripe and the usual headline number |
| Single-shared-file (ssf) | *(no `-F`)* | Shared-file bandwidth — all ranks write one file; stresses OST striping and shared-file locking |
| Sequential vs random | `-z` | Large sequential transfers (default) vs random offsets |
| Metadata (mdtest) | n/a | File/dir create, stat, and remove operations per second |

## Build

Two build scripts are provided — one per MPI stack, mirroring the OSU and HPL utilities in this repo. Both download the official IOR **4.0.0** release tarball (which ships a pre-generated `configure`, so no autotools step is needed), compile the POSIX and MPI-IO back-ends, and install `ior` and `mdtest` to the shared filesystem.

**OpenMPI** (the default AWS EFA stack):

```bash
bash build_ior_openmpi.sh      # → /fsx/IOR-OpenMPI/install/bin/{ior,mdtest}
```

**Intel MPI:**

```bash
bash build_ior_intelmpi.sh     # → /fsx/IOR-IntelMPI/install/bin/{ior,mdtest}
```

To build a different release, override `IOR_VERSION` at the top of the script.

## Run

The launcher [`ior.sbatch`](ior.sbatch) is fully parametric — every IOR and filesystem setting is an environment variable with a sensible default:

```bash
# Defaults: OpenMPI, POSIX, file-per-process, 2 nodes, 12 ranks/node
sbatch ior.sbatch

# Single shared file, MPI-IO back-end, 4 MiB transfers
IOR_FILEMODE=ssf IOR_API=MPIIO IOR_TRANSFER=4m sbatch ior.sbatch

# Scale out to 8 nodes and push more ranks per node
sbatch -N 8 --export=ALL,IOR_TASKS_PER_NODE=16 ior.sbatch

# Use Intel MPI
IOR_MPI=intelmpi sbatch ior.sbatch

# Also run the mdtest metadata benchmark
IOR_MDTEST=1 sbatch ior.sbatch
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IOR_MPI` | `openmpi` | MPI stack / install to use: `openmpi` or `intelmpi` |
| `IOR_API` | `POSIX` | I/O back-end: `POSIX` or `MPIIO` |
| `IOR_FILEMODE` | `fpp` | `fpp` (file-per-process) or `ssf` (single shared file) |
| `IOR_BLOCK` | `4g` | Per-task block size (`-b`). Aggregate data = ranks × block × segments |
| `IOR_TRANSFER` | `1m` | Size of each read/write call (`-t`). 1–16 MiB is the Lustre sweet spot |
| `IOR_SEGMENTS` | `1` | Segments per task (`-s`) |
| `IOR_ITER` | `3` | Iterations / repetitions (`-i`) |
| `IOR_TASKS_PER_NODE` | `12` | MPI ranks per node. I/O saturates well before all cores; 8–16 is typical |
| `IOR_DIR` | `/fsx/ior-test` | Test directory on the shared filesystem |
| `IOR_STRIPE_COUNT` | `-1` | Lustre stripe count (`-1` = all OSTs) applied to `IOR_DIR` |
| `IOR_STRIPE_SIZE` | `1M` | Lustre stripe size applied to `IOR_DIR` |
| `IOR_MDTEST` | `0` | Set to `1` to also run the mdtest metadata benchmark |
| `IOR_EXTRA` | *(empty)* | Extra arguments appended to the `ior` command line |

The number of nodes and the partition/constraint come from the usual SBATCH directives (`-N`, `--partition`, `--constraint`); edit the defaults at the top of `ior.sbatch` for your cluster.

## Amazon FSx for Lustre best practices

These are baked into `ior.sbatch` and worth understanding when interpreting results:

1. **Stripe the test directory across all OSTs.** The launcher runs `lfs setstripe -c -1 -S 1M` on `IOR_DIR` so every file created under it is spread across all Object Storage Targets. Without striping, a single-shared-file test is bottlenecked on one OST. Match `IOR_STRIPE_COUNT` to your filesystem's OST count.
2. **Size the dataset to defeat the client cache.** Each FSx for Lustre client caches data in node RAM. The launcher (a) drops the page cache on every node before the read phase, and (b) passes `-C` so each rank reads a file written by a *different* node. For a fully cache-immune read, also make the aggregate dataset (ranks × block × segments) larger than the total client RAM.
3. **Use large transfers.** `-t 1m` (up to `4m`–`16m`) aligns with Lustre RPC sizes and amortises per-call overhead. Tiny transfers measure latency, not bandwidth.
4. **`fsync` after write (`-e`).** Ensures written data reaches the filesystem rather than sitting in the client cache, so the reported write bandwidth is real.
5. **Right-size ranks per node.** Storage bandwidth (and the EFA/network path to FSx) saturates well before you use every core; 8–16 ranks/node is usually optimal. More ranks add contention without more throughput.
6. **Provision the filesystem for the test.** FSx for Lustre throughput scales with provisioned capacity and the per-TiB throughput tier. A small filesystem will cap aggregate bandwidth regardless of how many clients you add.

## Metrics

IOR prints a summary table at the end of the run. The headline numbers are:

```
Operation   Max(MiB)   Min(MiB)  Mean(MiB) ...
write        12345.6     ...
read         23456.7     ...
```

- **`Max Write` / `Max Read` (MiB/s)** — aggregate throughput across all ranks. The primary result.
- **IOPS** — reported when transfers are small; relevant for small-I/O workloads.
- **mdtest** (when `IOR_MDTEST=1`) reports **creates/sec, stats/sec, removes/sec** for files and directories.

## Files

| File | Description |
|------|-------------|
| `build_ior_openmpi.sh` | Download and build IOR + mdtest 4.0.0 against OpenMPI → `/fsx/IOR-OpenMPI/install` |
| `build_ior_intelmpi.sh` | Download and build IOR + mdtest 4.0.0 against Intel MPI → `/fsx/IOR-IntelMPI/install` |
| `ior.sbatch` | Parametric Slurm launcher — write/read throughput with Lustre striping, page-cache dropping, and an optional mdtest metadata run |
