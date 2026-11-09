# PowerFLOW

[PowerFLOW](https://www.3ds.com/products/simulia/powerflow) is a Lattice-Boltzmann CFD solver from [Dassault Systèmes](https://www.3ds.com/) (SIMULIA), widely used for vehicle aerodynamics and aeroacoustics.

> **Status:** draft. [`PowerFlow.sbatch`](PowerFlow.sbatch) has not yet been run end to end.

## How the script runs PowerFLOW

`exaqsub` can submit its own Slurm job through the site's queue-system scripts (`site/queue_systems/slurm`). On AWS, run it inside the Slurm job instead:

```bash
exaqsub -nolock -foreground --impi -mpirsh ssh -mpifile <hostfile> -simulate --nprocs <SPs> case.cdi
```

A nested submission costs a second queue wait, while the first job holds its node idle. On dynamic nodes it also waits for the new instances to boot. The nested job gets no `--exclusive`, and it only inherits the MPI and EFA settings through sbatch's default environment export. With `-foreground`, one job owns the nodes and its environment.

The hostfile puts the CP on the first node and `SP_PER_NODE` SPs on every node:

```
cp  <node1>
120 <node1>
120 <node2>
```

## Usage

```bash
cd /fsx/cases/my_case
PF_VERSION=6-2026-R2 PF_CASE=my_case.cdi DSLS_POWERFLOW_LICENSE=<port>@<license-server> \
    SP_PER_NODE=144 sbatch --nodes=2 /path/to/apps/PowerFlow/PowerFlow.sbatch
```

| Variable | Effect |
|---|---|
| `PF_ROOT` | Directory holding the PowerFLOW installs; default `/fsx/powerflow` |
| `PF_VERSION` | Install under `PF_ROOT`, e.g. `6-2026-R2` (required) |
| `PF_CASE` | The `.cdi` file (required) |
| `DSLS_POWERFLOW_LICENSE` | DSLS license servers, `<port>@<server>[,...]` (required) |
| `MODE` | `simulate` (default), `discretize`, or `all` |
| `SP_PER_NODE` | SP ranks per node; default all cores |
| `DISC_NPROCS` | Discretizer processes; default 8 |
| `USE_BUNDLED_IMPI=1` | Keep the Intel MPI bundled with PowerFLOW instead of the system one |

## Settings that matter

- **Intel MPI over EFA.** Set `I_MPI_OFI_LIBRARY_INTERNAL=0`, `I_MPI_FABRICS=shm:ofi`, `I_MPI_OFI_PROVIDER=efa`, `FI_EFA_FORK_SAFE=1` and `FI_MR_CACHE_MONITOR=memhooks`. With `I_MPI_DEBUG=5`, the start of `simulator.log` shows the libfabric provider. On a multi-node run it must be `efa`.
- **`EXA_ALT_IMPI_ROOT` must be exported.** If it is only set as a shell variable, `exaqsub` silently uses the Intel MPI bundled with PowerFLOW.
- **ssh launcher.** `-mpirsh ssh` needs passwordless ssh between compute nodes. Unset `HYDRA_BOOTSTRAP` and `HYDRA_LAUNCHER_EXTRA_ARGS` if the cluster sets them for the Slurm launcher.
- **Pinning.** Bind one rank per core. Avoid `I_MPI_PIN_DOMAIN=numa`, which lets ranks move across a whole NUMA domain. On hpc8a.96xlarge and hpc7a.96xlarge, use 120, 144, 168 or 192 SPs per node ([flexible cores](../../Utils/flexible-cores)).
- **Scratch.** Set `EXA_TMPDIR` to the shared file system, not `/tmp` on the root EBS volume.
- **Remove `--debug`** from `exaqsub` options for performance runs.

## Storage (LGI read and decomposition)

The discretizer writes the LGI file and the decomposer reads it, so both stages are bound by storage. On FSx for Lustre:

- Spread large files across storage servers before they are written: `lfs setstripe -c -1 <run dir>`. Check an existing file with `lfs getstripe <file>.lgi`.
- If the file system is linked to S3, the first read of a file loads it from S3. Preload inputs with `lfs hsm_restore <file>`.
- Check in CloudWatch whether `DataReadBytes` is flat at the file system's throughput limit during the read. If it is, raise the throughput tier or the capacity. [IOR](../../Utils/IOR) measures what the file system delivers.

For multi-node runs, use a cluster placement group and a security group that allows all traffic to and from itself (required by EFA).
