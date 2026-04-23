# STAR-CCM+ Submit Scripts for AWS ParallelCluster

Customer-ready SLURM submit scripts for running STAR-CCM+ on AWS HPC instances
with EFA networking. Organised by STAR-CCM+ version and architecture.

## Directory Structure

```
submit/
├── 18.06/                    # STAR-CCM+ 18.06 (works on AL2, AL2023, RHEL8, Ubuntu)
│   ├── x86/
│   │   ├── submit_batch.sbatch    # Headless batch run (Intel MPI)
│   │   └── submit_server.sbatch   # Interactive server mode (Intel MPI)
│   ├── gpu/
│   │   ├── submit_batch.sbatch    # GPU batch (p4d/p5)
│   │   └── submit_server.sbatch   # GPU server mode
│   └── arm/
│       ├── submit_batch.sbatch    # Graviton batch (OpenMPI)
│       └── submit_server.sbatch   # Graviton server mode
└── 21.02/                    # STAR-CCM+ 21.02 (requires glibc >= 2.28)
    ├── x86/                  # OpenMPI (recommended for 21.x on all platforms)
    ├── gpu/
    └── arm/
```

## Usage

```bash
# Basic batch run (uses defaults — version 21.02.007, solves the sim)
sbatch submit_batch.sbatch -s /fsx/simulations/model.sim

# Specify version and sim file
sbatch submit_batch.sbatch -v 21.02.007 -s /fsx/simulations/model.sim

# With a macro
sbatch submit_batch.sbatch -v 21.02.007 -s /fsx/simulations/model.sim -m RunAndTimeSimulation.java

# Chain commands: run a macro, then mesh, then solve
sbatch submit_batch.sbatch -v 21.02.007 -s model.sim -m "macro.java,mesh,run"

# With an explicit license key
sbatch submit_batch.sbatch -v 21.02.007 -s model.sim -l "your-pod-key"

# Server mode (connect via STAR-CCM+ GUI)
sbatch submit_server.sbatch -v 21.02.007 -s /fsx/simulations/model.sim
```

### Flags

| Flag | Description | Default if no selection made |
|------|-------------|---------|
| `-v` | STAR-CCM+ version | Script-specific (e.g. `21.02.007`) |
| `-s` | Simulation file path | `/fsx/simulations/model.sim` |
| `-m` | Batch command: a `.java` macro, `run`, `mesh`, `step`, or a comma-separated combination | `run` _(solves the sim)_ |
| `-l` | PoD license key | `$PODLIC` env var |

## MPI Selection by Version and Architecture

| Version | x86 | GPU | Arm |
|---------|-----|-----|-----|
| 18.06 | Intel MPI | Intel MPI | OpenMPI |
| 21.02+ | OpenMPI | OpenMPI | OpenMPI |

OpenMPI is the recommended MPI for Linux per the Siemens STAR-CCM+ 2602 user
guide. Intel MPI is unsupported on AMD and crashes on 21.02+ during mesh
repartitioning on AMD Turin/Genoa. All 21.02 scripts use OpenMPI.

For 18.06, Intel MPI is retained as it works reliably across all tested
platforms and versions prior to 21.x.

## Key Differences by Architecture

| | x86 (21.02) | x86 (18.06) | GPU (21.02) | Arm |
|---|-------------|-------------|-------------|-----|
| MPI | OpenMPI | Intel MPI | OpenMPI | OpenMPI |
| STAR-CCM+ flag | `-mpi openmpi` | `-mpi intel` | `-mpi openmpi` | `-mpi openmpi` |
| EFA config | `FI_EFA_FORK_SAFE=1` | `I_MPI_*` env vars | `FI_EFA_FORK_SAFE=1` | `FI_EFA_FORK_SAFE=1` |
| Extra flags | `-xsystemlibfabric` | `-xsystemlibfabric` | `-gpgpu file:` | `-xsystemlibfabric` |
| SLURM mode | `-bs slurm` | `-bs slurm` | `-machinefile` (no `-bs slurm`) | `-bs slurm` |
| Instances | hpc6a, hpc7a, hpc8a | hpc6a, hpc7a | g6e, p4d, p5, p5en, g7e | hpc7g, c7gn |

## CPU Binding

No `-cpubind` flag is needed in the submit scripts. STAR-CCM+ defaults to
`-cpubind bandwidth` which maximises memory bandwidth across NUMA nodes.
Benchmarking confirmed this is 42-45% faster than `-cpubind off` on AMD
multi-CCD architectures (hpc8a, hpc7a).

## OS Compatibility

| STAR-CCM+ Version | Amazon Linux 2 | AL2023 | RHEL8 | Ubuntu 20+ |
|-------------------|:-:|:-:|:-:|:-:|
| 18.06 (x86/GPU) | ✓ | ✓ | ✓ | ✓ |
| 18.06 (Arm) | ✗ | ✓ | ✓ | ✓ |
| 21.02+ (all) | ✗ | ✓ | ✓ | ✓ |

STAR-CCM+ 21.02 and later require glibc >= 2.28. Amazon Linux 2 has glibc 2.26.

## License

Set the `PODLIC` environment variable before submitting:

```bash
export PODLIC="your-pod-key-here"
sbatch submit_batch.sbatch
```

Or edit the `LICENSEOPTS` line in the script to use a license server instead.

## Customisation

- Edit `#SBATCH --nodes=` for your node count
- Edit `#SBATCH --partition=` to match your cluster's partition name
- Add `#SBATCH --time=HH:MM:SS` for a wall time limit
- Add `#SBATCH --ntasks-per-node=N` for undersubscription testing
