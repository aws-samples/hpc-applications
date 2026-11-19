# PowerFLOW

[PowerFLOW](https://www.3ds.com/products/simulia/powerflow) is a Lattice-Boltzmann CFD solver from [Dassault Systèmes](https://www.3ds.com/) (SIMULIA), widely used for vehicle aerodynamics and aeroacoustics.

> **Status:** The launch path (exaqsub in the foreground inside one Slurm job, Intel MPI with the EFA provider, the CP/SP hostfile) has run end to end on one hpc8a.96xlarge node. Runs on more than one node, `MODE=discretize` and `MODE=all` have not run with PowerFLOW yet. Neither have these parts of [`PowerFlow.sbatch`](PowerFlow.sbatch): the default number of SPs per node, the explicit core list, the module order that gives Intel MPI the EFA installer's libfabric, the core count from `lscpu`, the checks of the variables below and the library search path. Check your first run as [Checking a run](#checking-a-run) describes.

## How the script runs PowerFLOW

`exaqsub` can submit its own Slurm job through the site's queue-system scripts (`site/queue_systems/slurm`). On AWS, run it inside the Slurm job instead:

```bash
exaqsub -nolock -foreground -impi -mpirsh ssh -mpifile <hostfile> -simulate --nprocs <SPs> case.cdi
```

A nested submission costs a second queue wait, while the first job holds its node idle. On dynamic nodes it also waits for the new instances to boot. The nested job gets no `--exclusive`, and it only inherits the MPI and EFA settings through sbatch's default environment export. With `-foreground`, one job owns the nodes and its environment.

The hostfile puts the CP on the first node and `SP_PER_NODE` SPs on every node:

```
cp  <node1>
144 <node1>
144 <node2>
```

## Usage

```bash
cd /fsx/cases/my_case
PF_VERSION=<version> PF_CASE=my_case.cdi DSLS_POWERFLOW_LICENSE=<server>:<port> \
    SP_PER_NODE=144 sbatch --nodes=2 /path/to/apps/PowerFlow/PowerFlow.sbatch
```

Set the script's `#SBATCH --partition` and `--constraint` lines to your cluster's queue and instance type first. The job runs in the directory it is submitted from, and writes `simulator.log`, `discretizer.log` and `hostfile.<job id>` there. PowerFLOW's temporary files go to `exa_tmp_<job id>` in the same directory, which the script removes when exaqsub ends. The job ends with exaqsub's exit status.

| Variable | Effect |
|---|---|
| `PF_ROOT` | Directory holding the PowerFLOW installs; default `/fsx/powerflow` |
| `PF_VERSION` | The install's directory under `PF_ROOT`, which holds `bin/exaqsub` and `dist/x86_linux/lib` (required) |
| `PF_CASE` | The `.cdi` file (required) |
| `DSLS_POWERFLOW_LICENSE` | DSLS license servers, `<server>:<port>[,<server>:<port>...]` (required) |
| `MODE` | `simulate` (default), `discretize`, or `all` |
| `SP_PER_NODE` | SP ranks per node, from 1 to the node's physical cores; default one per physical core but one (191 on hpc8a.96xlarge), not yet benchmarked against the other counts |
| `DISC_NPROCS` | Discretizer processes, from 1 to the job's cores; default 8 |
| `USE_BUNDLED_IMPI=1` | Keep the Intel MPI bundled with PowerFLOW instead of the system one |
| `PIN_EXPLICIT=0` | Leave rank placement to Intel MPI instead of the flexible-cores list |

The script stops with an error message before it starts PowerFLOW when a required variable is unset, when `SP_PER_NODE` or `DISC_NPROCS` is not a whole number in its range, when `USE_BUNDLED_IMPI` or `PIN_EXPLICIT` is set to anything but 0 or 1, or when `exaqsub` is not in `PF_ROOT/PF_VERSION/bin`.

## Settings that matter

- **Intel MPI over EFA.** Export `I_MPI_OFI_LIBRARY_INTERNAL=0` before `module load intelmpi`, and load `libfabric-aws` after it, so that Intel MPI uses the EFA installer's libfabric rather than its own copy. Set `I_MPI_FABRICS=shm:ofi`, `I_MPI_OFI_PROVIDER=efa`, `FI_EFA_FORK_SAFE=1` and `FI_MR_CACHE_MONITOR=memhooks`.
- **`EXA_ALT_IMPI_ROOT` must be exported.** If it is only set as a shell variable, `exaqsub` silently uses the Intel MPI bundled with PowerFLOW.
- **ssh launcher.** `-mpirsh ssh` needs passwordless ssh between compute nodes. Slurm or the cluster's profile can set `HYDRA_BOOTSTRAP`, `HYDRA_LAUNCHER_EXTRA_ARGS`, `I_MPI_HYDRA_BOOTSTRAP` and `I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS` for the Slurm launcher, and Intel MPI would then hand `--external-launcher` to ssh. The script unsets the first two and the last, and sets `I_MPI_HYDRA_BOOTSTRAP=ssh`.
- **SPs per node.** By default the script runs one SP per physical core but one. On the first node the CP takes the remaining core, and Intel MPI places the ranks, one per core. Every node runs the same number of SPs, so on the other nodes one core stays idle. The default is not yet benchmarked against the other counts. The script counts the node's physical cores with `lscpu`, so an exported `OMP_NUM_THREADS` changes neither the default nor the pinning, and with SMT on the default counts cores, not threads.
- **Pinning.** Bind one rank per core. Avoid `I_MPI_PIN_DOMAIN=numa`, which lets ranks move across a whole NUMA domain. On hpc8a.96xlarge and hpc7a.96xlarge (24 CCDs of 8 cores), 24, 48, 72, 96, 120, 144 and 168 SPs per node give every CCD the same number of SPs ([flexible cores](../../Utils/flexible-cores)). At those counts the script sets `I_MPI_PIN_PROCESSOR_LIST` to core 191 followed by the flexible-cores list, because Intel MPI's own placement can load the CCDs unevenly below 192 ranks per node. Core 191, a core of the last CCD that the flexible-cores list leaves free, is there because the first node also runs the CP: with one core more than SPs per node in the list, every process gets a core of its own on every node. Every CCD holds the same number of SPs on every node when the CP is one of the last k ranks on its node, with k = `SP_PER_NODE` / 24 ([Checking a run](#checking-a-run) shows how to see each process's core). With 192 SPs per node the CP shares a core with an SP. Any other count runs on Intel MPI's own placement, with a WARNING. `PIN_EXPLICIT=0` leaves the placement to Intel MPI.
- **Scratch.** Set `EXA_TMPDIR` to the shared file system, not `/tmp` on the root EBS volume.
- **Remove `--debug`** from `exaqsub` options for performance runs.

## Checking a run

- **libfabric and the provider.** With `I_MPI_DEBUG=5`, the script's default, the start of `simulator.log` shows the libfabric version and provider. On a multi-node run the provider must be `efa`.
- **The placement.** The "CPU pinning" table at the start of `simulator.log` shows each rank's core, but not which rank is the CP. During the run, `ps -eo pid,psr,args` on the first node shows the core (`psr`) and the command line of each PowerFLOW process.
- **More than one node.** Before the first multi-node run, check that ssh between the job's nodes needs no password.

## Storage (LGI read and decomposition)

The discretizer writes the LGI file and the decomposer reads it, so both stages are bound by storage. On FSx for Lustre:

- Spread large files across storage servers before they are written: `lfs setstripe -c -1 <run dir>`. Check an existing file with `lfs getstripe <file>.lgi`.
- If the file system is linked to S3, the first read of a file loads it from S3. Preload inputs with `lfs hsm_restore <file>`.
- Check in CloudWatch whether `DataReadBytes` is flat at the file system's throughput limit during the read. If it is, raise the throughput tier or the capacity. [IOR](../../Utils/IOR) measures what the file system delivers.

For multi-node runs, use a cluster placement group and a security group that allows all traffic to and from itself (required by EFA).
