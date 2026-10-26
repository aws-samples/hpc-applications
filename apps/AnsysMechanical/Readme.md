# Ansys Mechanical (MAPDL)

Ansys [Mechanical](https://www.ansys.com/products/structures/ansys-mechanical) is a
finite element analysis (FEA) solver for structural, thermal and coupled-field
simulation. This page covers running the Mechanical APDL (MAPDL) solver on AWS
with the distributed-memory parallel (DMP) solver under a job scheduler.

# Versions

Everything here was tested on **2026 R1** (`v261`, `ansys261`). The general
guidance — DMP invocation, EFA settings, memory sizing, scratch placement, judging
success from the output rather than the exit status — should apply to 2023 and
newer, but **verify the release-specific details** rather than assuming they carry
over. Two things in particular are version-sensitive:

  * **The output-verdict logic depends on exact solver output text.** The success
    markers and the wording of the benign fixed-iteration termination are matched
    literally (see [Exit codes](#exit-codes-do-not-use-them-to-decide-success)).
    If a release words them differently, a valid run is rejected until the pattern
    is extended — deliberately fail-closed, but it does mean re-checking.
  * **The library paths below embed both the version directory (`v261`) and a
    bundled component version (`polyflow26.1.0`)**, which change every release.

Treat the library paths as verified for 2026 R1 only and re-derive them for other
releases (the [recipe](#required-os-libraries-on-amazon-linux-2023) shows how).

# Installation

MAPDL ships inside the Ansys `FLUIDSTRUCTURES` package, so the same unattended
installer used for Fluent installs it — see
[Fluent-Install.sh](https://github.com/aws-samples/hpc-applications/blob/main/apps/Fluent/Fluent-Install.sh):

```
./Fluent-Install.sh /fsx s3://your_bucket/FLUIDSTRUCTURES_2026R1_LINX64.tgz
```

The solver then lives at `/fsx/ansys_inc/v261/ansys/bin/` (`mapdl`, `ansys261`).
For multi-node runs it **must** be installed on a shared filesystem; we
recommend [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/).

## Required OS libraries on Amazon Linux 2023

`ansys.e` links a legacy X11/Motif stack that **Amazon Linux 2023 does not ship**
(most of it was dropped after RHEL 7). Nothing warns you up front — the job just
dies with `error while loading shared libraries`, and each missing library only
surfaces after you fix the previous one. Ansys bundles all of them except one:

| Library | In AL2023? | Where to get it |
|---|---|---|
| `libGLU.so.1` | no | `sudo dnf -y install mesa-libGLU` |
| `libXp.so.6` | no | bundled: `ansys/syslib/ubuntu/` |
| `libXm.so.4` (Motif) | no | bundled: `polyflow/polyflow26.1.0/lnamd64/libs/` |
| `libxcb-xlib.so.0` | no | bundled: `commonfiles/MainWin/linx64/mw/lib-amd64_linux/X11SLES/` |
| `libxcb-sync.so.0` | no | same `X11SLES` directory |
| `libxcb-xevie.so.0` | no | same `X11SLES` directory |
| `libxcb-xprint.so.0` | no | same `X11SLES` directory |
| `libjpeg.so.62` | **yes** | already provided by libjpeg-turbo |
| `libpng12.so.0` | no | **not bundled and not in any AL2023 repo — must be built** |

Link only the missing ones into a single directory and prepend it, so no system
library is shadowed. The paths below are the ones **verified on 2026 R1**; the
component version in the `polyflow` path in particular moves with each release,
so on another release locate the libraries first rather than assuming:

```bash
# Re-derive the bundled paths for your release before copying the block below:
V=/fsx/ansys_inc/v261        # <- your version directory
find $V -name 'libXm.so.4' -o -name 'libXp.so.6' -o -name 'libxcb-xlib.so.0' 2>/dev/null
```

```bash
COMPAT=/fsx/ansys_compat; mkdir -p $COMPAT; V=/fsx/ansys_inc/v261
ln -sf $V/ansys/syslib/ubuntu/libXp.so.6                    $COMPAT/
ln -sf $V/polyflow/polyflow26.1.0/lnamd64/libs/libXm.so.4   $COMPAT/
X11=$V/commonfiles/MainWin/linx64/mw/lib-amd64_linux/X11SLES
for l in libxcb-xlib.so.0 libxcb-sync.so.0 libxcb-xevie.so.0 libxcb-xprint.so.0; do
    ln -sf $X11/$l $COMPAT/
done
export LD_LIBRARY_PATH=$COMPAT:$LD_LIBRARY_PATH
```

### Building `libpng12` (the one library nobody ships)

`libpng12.so.0` is required by the bundled Motif and has to be built once.

> **Understand the trade-off before you do this.** libpng 1.2 reached
> end-of-life in 2015 and receives **no security updates**. You are introducing
> an unmaintained image-decoding library to satisfy a link-time dependency of
> Ansys's bundled Motif. Keep it scoped: install it to its own prefix, expose it
> only through the `LD_LIBRARY_PATH` used to launch MAPDL (as above — never
> system-wide in `/usr/lib64` or via `ldconfig`), and do not let anything else on
> the host resolve against it. On compute nodes that only run batch solves this
> is a contained risk; on an interactive/multi-user host, weigh it accordingly.
> If your policy forbids EOL libraries, run MAPDL from a container image where
> this dependency is isolated instead.

Verify what you downloaded before building it:

```bash
# Prerequisites: sudo dnf -y install gcc make tar zlib-devel
# Needs write permission on the install prefix (/fsx/... on a shared filesystem).
curl -fsSLO https://download.sourceforge.net/libpng/libpng-1.2.59.tar.gz

# Integrity check — do NOT build if this does not match.
echo "4bd4b5ce04ce634c281ae76174714fa02b053b573ac2181c985db06aa57e1e9e  libpng-1.2.59.tar.gz" \
    | sha256sum -c - || { echo "CHECKSUM MISMATCH - do not use this tarball"; exit 1; }

tar xzf libpng-1.2.59.tar.gz && cd libpng-1.2.59
./configure --prefix=/fsx/libpng12 --disable-static && make -j && make install
ln -sf /fsx/libpng12/lib/libpng12.so.0 $COMPAT/libpng12.so.0
```

That digest matches the value published in SourceForge's file metadata for
`libpng-1.2.59.tar.gz`. Stronger still, the project publishes a detached GPG
signature next to the tarball — prefer it if you have the maintainer's key, since
a signature verifies authorship rather than just matching a hash copied into a
document:

```bash
curl -fsSLO https://download.sourceforge.net/libpng/libpng-1.2.59.tar.gz.asc
gpg --verify libpng-1.2.59.tar.gz.asc libpng-1.2.59.tar.gz
```

**Why not just install these with dnf?** Only `mesa-libGLU` is packaged for
AL2023. The others are not available from the package manager: `libXp` and
Motif (`libXm`) are not in the AL2023 repositories (`dnf provides` returns no
match), `libpng12` is end-of-life and likewise absent, and the four `libxcb-*`
sonames were removed from libxcb upstream years ago, so no current distribution
packages them. AL2023 does not support EPEL, so there is no supported extra
repository to add. Using the libraries Ansys ships also has an operational
advantage on ParallelCluster: the compat directory lives on the shared
filesystem, so ephemeral compute nodes need no per-node package installation —
`mesa-libGLU` is the only per-node install required.

Three traps worth knowing:

  * **Do not** satisfy `libGLU.so.1` from the copy Ansys bundles under
    `CFD-Post/tools/Mesa-7.1/`. That is a Mesa 7.1-era library whose own
    dependencies pull in `libpng12`, turning one missing library into two.
    Install the distro `mesa-libGLU` package instead.
  * Prefer the `polyflow` `libXm.so.4` over the copy in
    `Electronics/Linux64/defer/` — it has the smaller dependency closure.
  * `libpng12` **cannot** be faked with a symlink to `libpng16`. That gets past
    the "not found" error and then fails with ``version `PNG12_0' not found``,
    because libpng uses versioned symbols specifically to prevent ABI mixing.

# Running under a job scheduler

See [AnsysMechanical.sbatch](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/AnsysMechanical.sbatch)
for a complete example. The essentials:

```bash
# MAPDL takes the total core count from the -machines list, NOT from -np.
# Take the per-host counts from Slurm instead of dividing --ntasks by --nodes:
# SLURM_TASKS_PER_NODE reflects the placement Slurm actually made ("64(x2)",
# "43,42", ...). Dividing only agrees with reality when the allocation is
# homogeneous AND divisible — floor division silently drops ranks, ceiling
# division oversubscribes the nodes and over-draws licence tokens.
mapfile -t hosts < <(scontrol show hostnames=$SLURM_JOB_NODELIST)
read -r -a tpn <<< "$(echo $SLURM_TASKS_PER_NODE | \
    awk -F, '{for(i=1;i<=NF;i++){n=$i;r=1;if(match(n,/\(x[0-9]+\)/)){r=substr(n,RSTART+2,RLENGTH-3);n=substr(n,1,RSTART-1)};for(j=0;j<r;j++)printf "%s ",n}}')"

machines=""
for i in "${!hosts[@]}"; do machines="$machines:${hosts[$i]}:${tpn[$i]}"; done
machines=${machines:1}

mapdl -b -dis -mpi intelmpi -ssh -machines $machines -i input.dat -o output.log
```

The recommended layouts further down are all homogeneous and divisible, so this
reduces to the obvious `cores/nodes` result — it just stays correct when an
allocation is not. If you would rather keep the simple division, then **require**
divisible placement explicitly (`--nodes=N --ntasks-per-node=C` rather than a
bare `--ntasks`), and fail the job when `ntasks % nodes != 0` instead of rounding
in either direction.

Two rules worth keeping whichever way you build the list:

  * **If Slurm's placement cannot be read, fail — do not redistribute the tasks
    yourself.** Spreading `--ntasks` evenly over the node list when
    `SLURM_TASKS_PER_NODE` is missing or unparseable *invents* a placement rather
    than learning it, and a wrong guess oversubscribes nodes and over-draws licence
    tokens. Aborting with an actionable message is cheaper than a silently bad run.
  * **Check the total.** Assert that the `-machines` counts sum to `SLURM_NPROCS`
    before launching, and stop if they do not.
  * **Do not report an uneven layout as a single "cores per node" value.** For a
    `43,42` allocation there is no such number; recording one node's share as if it
    applied to all of them misdescribes the run. Record the layout instead.
    Watch for this being re-introduced downstream: anything that fills in a missing
    `cores_per_node` as `cores / nodes` will happily turn 85 cores over 2 nodes back
    into "43". Derive it only when the division is exact, and never when an explicit
    layout has already been recorded.

  * `-dis` selects the distributed-memory (DMP) solver, `-mpi intelmpi` the MPI
    implementation. Intel MPI was the faster of the two options in our testing on
    AWS, and it is the one whose EFA path we verified — see
    [EFA settings](#efa-settings).
  * **Do not run the job as root.** `-ssh` launches the remote ranks over SSH
    using the *submitting user's* SSH identity, and on AWS ParallelCluster only
    the default user (`ec2-user`) holds the inter-node key pair — root has an
    `authorized_keys` file but no private key, so the remote ranks never start.
    Least privilege applies independently of that: a solver has no need for root.
    If you drive submission from automation that runs as root (Systems Manager,
    cron), submit with `sudo -u ec2-user`.
  * **`HOME` must be set, and for multi-node runs it must be the user's real
    home.** MAPDL writes preferences under `$HOME`, and the `-ssh` start method
    reads the inter-node identity from `$HOME/.ssh`. Pointing `HOME` at a fresh
    temporary directory therefore satisfies "writable" and *still* breaks
    multi-node startup with a confusing authentication error. If `HOME` is unset
    in a bare batch environment, recover the account's real home (e.g.
    `getent passwd "$(id -un)" | cut -d: -f6`) rather than creating a scratch one;
    a temporary `HOME` is only safe for a genuinely single-node run.
  * In a non-login shell, `module` is undefined, so `module load intelmpi` fails
    silently. Guard it with
    `command -v module >/dev/null || source /etc/profile.d/modules.sh`.
  * On Amazon Linux 2023 use `dnf` rather than `yum` for the `mesa-libGLU`
    prerequisite. ParallelCluster compute nodes are ephemeral, so install it per
    job (or bake it into a post-install script / custom AMI).

## EFA settings

```bash
export I_MPI_OFI_LIBRARY_INTERNAL=0
module load intelmpi
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
export FI_EFA_FORK_SAFE=1
module load libfabric-aws
```

Confirm EFA is actually in use — set `I_MPI_DEBUG=5` and look for
`libfabric provider: efa` in the output.

Two distinct cases worth separating, because they fail in opposite ways:

  * **With `I_MPI_OFI_PROVIDER=efa` set (as above), provider selection is
    fail-closed.** If EFA is unavailable — missing interface, no security-group
    rule for self-referencing traffic, a libfabric without the `efa` provider —
    Intel MPI errors out rather than falling back. That is what you want while
    benchmarking: a hard failure beats a quiet 10-20% slower number that looks
    like a real EFA result.
  * **Without that variable, the fallback is silent.** libfabric picks whatever
    provider it can, typically `tcp`, and nothing in the normal output says so.
    This is the case that quietly corrupts a comparison, and the reason to pin
    the provider explicitly.

If you deliberately want the fallback (e.g. a mixed fleet where some nodes lack
EFA), leave the provider unpinned but then always check the `I_MPI_DEBUG=5` line
before trusting a timing.

# Key settings & tips (performance related ones)

  * **MAPDL is memory bound, and for the sparse direct solver memory capacity
    decides everything.** Each benchmark/model has a documented memory
    requirement. If the *aggregate* RAM of the job does not exceed it with room
    to spare (for the V26 Cluster models, about 1.5 times: the instance memory
    in GiB over the figure in GB that `JOBS.CONFIG` lists), MAPDL falls back to
    an **out-of-core** mode that does heavy I/O, and runtime can more than
    double. Size the job to fit in memory first; only then optimise for cores.
  * **Check which memory mode you got.** MAPDL states it on the `Memory Option:`
    line of the solver statistics at the end of its output (`In-Core` or
    `Optimal Out-of-Core`) — it is the first thing to look at when a run is
    unexpectedly slow. Read that line rather than searching the whole file: every
    sparse-direct run also prints `Equation solver memory required for
    out-of-core mode`, so a search for "out-of-core" labels in-core runs
    out-of-core. In the 94 sparse-direct V26 Cluster outputs we archived, MAPDL
    reported In-Core for 45, and a whole-file search labelled all 94 out-of-core.
    The iterative solvers (PCG, JCG) print no `Memory Option:` line. The line is
    verified on 2026 R1 only: on a release that does not print it, the sbatch
    records the memory mode as `unknown`.
  * **Size the memory from what MAPDL prints.** Before the factorisation, the
    sparse solver prints a memory summary, out-of-core runs included:
    `Equation solver memory required for in-core mode` for rank 0, for the
    busiest node (on more than one node) and summed over all ranks (under
    `Total memory summed across all MPI ranks`). An out-of-core run also says
    so in a WARNING whose text begins
    `The Distributed Sparse Matrix Solver is running in out-of-core memory`, so
    the output of one run tells you what in-core needs. Each process needs
    memory beyond the solver's: in our in-core runs the total allocated was 1.1
    to 1.6 times the summed in-core figure, more with more ranks. Every
    sparse-direct run of ours with at least 1.52 times that figure in physical
    memory ran in-core (MAPDL's closing `Physical memory available`, on more
    than one node its `Physical memory available on all compute nodes` line);
    from 1.46 to 1.51 times, V26direct-5 did on one hpc6id.32xlarge and
    V26direct-6 did not on two hpc8a.96xlarge. Plan for about twice it.
    Where the V26 Cluster models ran in-core is in
    [Memory mode and node count](#memory-mode-and-node-count).
  * Because DMP aggregates memory across nodes, **adding a node can be far more
    effective than adding cores**: it raises the memory ceiling as well as the
    core count. Moving a model that is out-of-core on one node onto two nodes
    (so it fits in aggregate RAM) can improve runtime by far more than the added
    parallelism alone would explain — the speedup is the memory mode changing,
    not parallel efficiency.
  * **Once the model fits in memory, choose the instance for speed, not for more
    memory.** In the configurations we measured, with the same CPU and more
    memory the results were mixed (see
    [Intel instance types](#intel-instance-types)). Size for the documented
    requirement plus headroom rather than buying the largest memory footprint
    available.
  * **Instance selection.** The notes below reflect the V26 Cluster models on the
    configurations we tested; treat them as a starting point and verify against
    your own models rather than as a general ranking. The measurements are in
    [Instance types](#instance-types).
      * [Hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) /
        [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) — 4 GB/core but
        high memory bandwidth and core count. Of the AMD types we tried, Hpc8a
        was the quickest per node; Hpc7a took 1.15-1.59x as long at the same
        layout. Their 768 GiB per node is what to plan around: V26direct-5 needs
        two nodes to run in-core.
      * [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6id/) — 16 GB/core,
        a cost-effective way to buy memory capacity, **plus 15.2 TB of local
        NVMe** for solver scratch (see below), and the reference configuration in
        the sbatch. One node holds V26direct-5 in-core, where one c8i.96xlarge
        (768 GiB) does not, which pays off when the job stays on one node.
      * R-family ([r7i](https://aws.amazon.com/ec2/instance-types/r7i/) /
        [r8i](https://aws.amazon.com/ec2/instance-types/r8i/), or
        [r8id](https://aws.amazon.com/ec2/instance-types/r8id/) /
        [i7ie](https://aws.amazon.com/ec2/instance-types/i7ie/) for local
        NVMe) — worth it mainly when a single node must hold a very large model:
        one r8i.96xlarge ran V26direct-6 in-core, while two Hpc6id nodes ran it
        faster, in-core as well. Per core, r7i and r8i cost the most of the
        Intel types we ran, and in our runs they were not faster than
        c8i.96xlarge once the model already fit in memory.
  * **Under-population raises memory per core.** Running fewer cores per node
    gives each rank more memory *and* more bandwidth, which is often a better
    trade than filling the node. See
    [Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores)
    for the pinning lists — and note that lowering `--ntasks-per-node` alone is
    not enough: without explicit pinning the ranks pack onto the first socket and
    you lose half the cache and memory controllers.

## Scratch space and concurrency

Out-of-core solves write a large amount of scratch to the working directory —
**about 0.5-1.2 TB per job** for the V26 Cluster sparse-direct models, against
0.01-0.23 TB when the same models run in-core. MAPDL reports it in its closing
statistics as `Sum of disk space used on all processes`, and on more than one
node the busiest node's as `Maximum disk space used on any compute node`
(`Sum Scratch Used(All)` in the closing box is scratch *memory*, and it is
largest for in-core runs). Every accepted V26 Cluster run we archived, in
MAPDL's GB (GiB):

| Model | MAPDL memory mode | Runs | Whole job | Busiest node, on two nodes |
|---|---|--:|--:|--:|
| V26direct-4 | In-Core | 18 | 10.8-12.0 GB | 6.3-7.2 GB |
| V26direct-4 | Optimal Out-of-Core | 4 | 502.6-530.4 GB | |
| V26direct-5 | In-Core | 20 | 50.6-55.0 GB | 36.5-37.5 GB |
| V26direct-5 | Optimal Out-of-Core | 23 | 700.5-724.5 GB | |
| V26direct-6 | In-Core | 7 | 229.8-231.3 GB | 169.5 GB |
| V26direct-6 | Optimal Out-of-Core | 19 | 749.2-1,210.6 GB | 579.7-651.7 GB |
| V26iter-4 | none (JCG) | 23 | 36.4-44.9 GB | 31.1-31.2 GB |
| V26iter-5 | none (PCG) | 37 | 196.2-203.0 GB | |
| V26iter-6 | none (PCG) | 26 | 192.0-196.5 GB | 110.8-112.1 GB |

On one node the memory mode set the size, not the rank count: V26direct-6 wrote
1,199.5-1,210.6 GB out-of-core at every count we ran, 16 to 96 ranks. On two
hpc8a.96xlarge nodes it wrote 1,201.1 GB at 48 cores per node and 1,153.2 GB at
96, one run each; the table's 749.2 GB (579.7 GB on the busiest node) is one run
at 64 cores per node, not one of the balanced counts (see
[Benchmarks](#benchmarks)). On two nodes the busiest node held 51-86% of the
whole job's. On a shared filesystem the whole job's scratch is a hard planning
constraint:

  * Size the filesystem for `concurrent_jobs x per_job_scratch`, not for the
    input data.
  * **Cap how many out-of-core jobs run at once.** Running many out-of-core
    solves concurrently can exhaust even a multi-terabyte shared filesystem in
    hours. When that happens the jobs typically do **not** fail cleanly — they
    hang on I/O and have to be cancelled, leaving their scratch behind to be
    reclaimed manually.
  * Heavy sharing distorts timings. Watch **`MetadataOperations`** and burst
    throughput in CloudWatch rather than average throughput: a filesystem can
    look nearly idle on average bandwidth while elevated metadata rates and
    throughput bursts are significantly inflating individual run times.
    Benchmark numbers collected under that load are not trustworthy — validate
    any surprising result with an isolated re-run before acting on it.
  * **Prefer local NVMe instance store for the solver scratch when the instance
    has it.** [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6id/)
    (15.2 TB per node), r8id and the i-family carry instance-store NVMe
    that is both faster (local, no network round-trip) and effectively free
    compared to shared-filesystem capacity and throughput. AWS ParallelCluster
    formats and mounts the instance store at **`/scratch`** automatically (the
    sbatch reads the mount point from `SCRATCH_ROOT`, default `/scratch`, for
    clusters that mount it elsewhere). Run
    the solve with its working directory on `/scratch` — MAPDL writes its
    scratch files to the working directory, and this works **multi-node**
    (verified): in DMP every rank resolves the same path locally on its own
    node, so each node uses its own NVMe. Three mechanics to get right:
    **create** the working directory on every node before launching (e.g.
    `srun --ntasks-per-node=1 mkdir -p $workdir`), keep the input `.dat`/`.db`
    on the shared filesystem (only the master rank reads them — symlinks into
    the workdir suffice), and at the end copy the output file (written on the
    master node) back to the shared filesystem, then **reclaim** `/scratch` on
    every node (`srun --ntasks-per-node=1 rm -rf $workdir`) — warm nodes are
    reused between jobs and leftover scratch accumulates. Before the reclaim,
    copy MAPDL's error logs off every node as well: each process writes its own
    `file<N>.err` on its own node, and the reclaim deletes them (the sbatch puts
    them in the run directory, where a shared-filesystem run has them, and under
    `<host>/` when two nodes hold the same name).
    **Check that the copy succeeded before you delete anything.** Once the solve
    runs on instance store, that copy is the only lasting record of it, so a
    `cp` whose result is discarded followed by an unconditional `rm -rf` destroys
    the solver log outright whenever the shared filesystem is full, read-only or
    briefly unavailable — precisely the situation the NVMe scratch was adopted to
    avoid. Verify the destination exists and is non-empty (matching byte counts is
    cheap), and on failure keep `/scratch`, print the node name and path so the
    log can be recovered by hand, and fail the job. Instance store is ephemeral:
    the recovery window closes when the node scales down. This removes
    out-of-core I/O from the shared filesystem entirely — the concurrency cap
    and contention concerns above then apply only to input staging, and
    out-of-core solves stop competing with each other. Remember instance store
    is ephemeral: anything not copied back is lost when the node scales down.
    The [AnsysMechanical.sbatch](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/AnsysMechanical.sbatch)
    in this directory implements all of this (`SCRATCH_MODE=auto|nvme|shared`).
    It is a benchmark launcher: before the reclaim it copies back MAPDL's output
    and error logs, not its results files (`file*.rst`) or database (`file.db`),
    so for a production solve copy those as well, or use `SCRATCH_MODE=shared`.
  * **Check that `/scratch` is local instance store, with room, before using
    it.** A writable `/scratch` proves neither: on an instance type without
    instance store it can be a plain directory on the root EBS volume, and the
    solve then writes its scratch there. With `SCRATCH_MODE=auto` (the default)
    or `nvme`, the sbatch first checks on every node that `SCRATCH_ROOT` is a
    mount point (`findmnt`), that every disk under it is local NVMe instance
    storage (`lsblk -s` reports each one's model as `Amazon EC2 NVMe Instance
    Storage`), that the job user can write it, and that it has at least
    `SCRATCH_MIN_FREE_GIB` free (`df`). It uses NVMe only when every node passes,
    counted by distinct host name, and otherwise runs from the shared filesystem,
    with each node's reason in the job log; `nvme` also prints a warning, and
    `shared` never checks. `SCRATCH_ROOT` must be the mount point itself: a
    directory below it, such as `/scratch/$USER`, is refused. The default
    minimum, 300 GiB, holds the whole of every in-core sparse-direct V26 Cluster
    solve we ran (at most 231 GiB) on one node. An
    out-of-core solve writes several times more (see above), and a node that runs
    out of scratch space fails the run, so for an out-of-core model set
    `SCRATCH_MIN_FREE_GIB` to what the model writes on a node. MAPDL reports the
    whole job's as `Sum of disk space used on all processes`, which is also the
    most any one node can need, and on more than one node the busiest node's as
    `Maximum disk space used on any compute node` (the last column of the table
    at the top of this section).

## Exit codes: do not use them to decide success

Several standard benchmark models are configured to stop after a fixed number of
iterations. MAPDL then prints

```
*** ERROR ***  The number of iterations exceeds 1.
               The run is terminated at the user's request.
```

and **exits non-zero even though the run completed normally** (the output still
contains `RUN COMPLETED` and the full statistics block). Ansys's own `runBench.py`
post-processes the output files rather than checking exit status, and automation
should do the same: treat the presence of `RUN COMPLETED` and a final
`Elapsed Time (sec)` as the success signal. Gating on the exit code silently
discards valid results.

That said, do still scan the log for **genuine** errors rather than ignoring
`*** ERROR ***` lines wholesale. The fixed-iteration termination above is
expected on those models, but other errors — license checkout failures, MPI
communication aborts, insufficient memory or disk — are real and must fail the
run. A robust success test is therefore: `RUN COMPLETED` present, a final
`Elapsed Time (sec)` present **and positive**, **and** no `*** ERROR ***` block
other than the expected iteration-limit termination.

A full disk shows why the error blocks are the test that matters. When the shared
filesystem holding the scratch filled up during our V26 Cluster runs, MAPDL
stopped the sparse factorisation with "An input/output error has occurred ...
Please check to see if the disk containing the working directory ... is full",
then still printed `RUN COMPLETED` and a positive `Elapsed Time (sec)`, and
exited 1 (one node) or 255 (two nodes): the statuses the fixed-iteration stop
also returns. Only the error block says that the solve never finished
([tests/fixtures/disk-full-abort.log](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/tests/fixtures/disk-full-abort.log)).

Getting that test right is fiddlier than it looks, and the failure modes are
silent in both directions. Four traps we hit:

  * **Match error *blocks*, not lines, and ignore indentation.** A MAPDL error is
    a header line plus continuation lines. Filtering out the line that contains
    `iterations exceeds` leaves the `*** ERROR ***` header behind, so a naive
    "count the headers that survive the filter" test rejects the very run it was
    meant to accept. Anchoring on `^ \*\*\* ERROR` (exactly one leading space) is
    the mirror-image bug: a column-zero or differently-indented real error
    becomes invisible and the failed run is accepted.
  * **Match the whole block, anchored at both ends — not a substring.** Only the
    iteration-limit/user-request termination is benign, and only when that is *all*
    the block says. A substring match accepts a block that carries the expected
    phrases plus a second, genuine failure:

    ```
    *** ERROR ***
    The number of iterations exceeds 25 and the run was terminated at the
    user's request.
    The results database also failed to write and output is incomplete.
    ```

    That run lost its results file and must fail. A benign block and a real error
    in *separate* blocks must fail too.
  * **Match the wording literally — `user.?s` is not a possessive.** In an extended
    regular expression `.?` is *any* single character, so a pattern written that way
    also accepts malformed text like `userXs request`. Use a real apostrophe (or an
    explicit two-character class if you see both the ASCII `'` and a typographic
    `’`).
  * **Normalise whitespace the same way everywhere, and trim both ends.** MAPDL pads
    its output lines with trailing spaces, so an anchored pattern applied to an
    untrimmed block rejects a perfectly good run. If you have more than one place
    that classifies these blocks — a launcher and a result recorder, say — they must
    normalise identically, or the same output is accepted in one path and rejected
    in the other.
  * **Normalise a non-zero status only when it is explained, and only to the
    statuses that termination actually produces.** Forcing the status to 0 whenever
    the output looks complete swallows unrelated failures (a rank that died with
    status 42 after the solve finished writing). Clear the status only when the
    benign signature, `RUN COMPLETED` and a positive elapsed time are all present
    **and** the status is one the fixed-iteration stop is known to return. Across
    our V26 Cluster runs that set is `{0, 1, 255}`; a status outside it stays as-is
    even when a benign block is present.
  * **A zero exit status is not proof of anything.** A truncated log with rc=0
    must fail. If output verification does not pass, synthesise a non-zero job
    status — otherwise the scheduler records success for a run nobody verified.
  * **Only record a benchmark result for a run you accepted overall.** It is
    tempting to gate result recording on "the output looks complete", but a job
    that exits non-zero must not contribute a row to any dataset, or failures
    quietly become training data. Gate recording on the *final* verdict —
    verified output, a zero final status, and a durable copy of the log.

When parsing that timing line, note the format —

```
|   Elapsed Time (sec) =    1327.590    Date  =  08/29/2026   |
```

take the number immediately after the `=`; a trailing regex match will pick the
year out of the `Date` field. Require the result to be **> 0**: an interrupted run
can report `0.000`, and recording that as a solve time silently corrupts any
dataset built from these runs.

The implementation of all of the above lives in
[lib/mapdl-verdict.sh](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/lib/mapdl-verdict.sh),
sourced by the sbatch, with each trap pinned by a fixture in
[tests/](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/tests/).
The tests need no scheduler, no licensed solver and no AWS credentials:

```bash
apps/AnsysMechanical/tests/run-tests.sh
```

# Benchmarks

Ansys publishes standard benchmark sets for Mechanical. The **V26 Cluster** set
contains six models designed for multi-node runs — three sparse-direct and three
iterative (PCG/JCG) — and ships `JOBS.CONFIG` with each model's size in millions
of DOF and its memory requirement, which is what you need to size the job:

| Job | Model | Analysis | Solver | MDOF | Memory |
|---|---|---|---|--:|--:|
| V26direct-4 | Peltier Cooling Block | static, nonlinear, thermal-electric | sparse, non-symmetric | 5.7 | 510 GB |
| V26direct-5 | Turbine | static, nonlinear, structural | sparse, symmetric | 20.7 | 710 GB |
| V26direct-6 | Speaker | harmonic, linear, structural | sparse, complex | 15.8 | 1100 GB |
| V26iter-4 | Power Supply Module | static, linear, thermal | JCG | 45.0 | 165 GB |
| V26iter-5 | Tractor Rear Axle | static, linear, structural | PCG | 105.0 | 260 GB |
| V26iter-6 | Engine Block | static, linear, structural | PCG | 185.0 | 550 GB |

The package's default core increments are **16, 32, 64, 128** — Mechanical is a
comparatively low-core-count workload, so scaling studies should focus there
rather than on the thousands of cores typical of CFD.

Note that those default increments do **not** map well onto the CPU topology of
the AWS HPC instances: Hpc7a/Hpc8a.96xlarge have **24 CCDs of 8 cores each**
(192 physical cores, one L3 cache per CCD), and 16/32/64 spread unevenly across
24 CCDs while 128 does not divide 192 at all. For even CCD loading — every L3
cache carrying the same number of ranks — prefer increments of
**24, 48, 96, 192** (1, 2, 4, 8 cores per CCD), set via the `INCREMENT LIST`
line in `DMPJOBS.DAT`, combined with the explicit pinning from
[Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores).

Note that the bundled `runBench.py` is explicitly *not* intended for scheduler
environments. Run the models under your scheduler using the command line it
prints:

```
ansys261 -b nolist -perf on -dis -machines <host:cores:...> -nt 1 -mpi intelmpi \
         -i <job>.dat -o <job>_DMP__np<N>.out
```

Each `.dat` resumes a matching `<job>geom.db`, so both files (and `checkver.mac`)
must be present in the run directory.

# Recording results

[dynamodb/record-benchmark.sh](https://github.com/aws-samples/hpc-applications/blob/main/apps/AnsysMechanical/dynamodb/record-benchmark.sh)
records a run into the shared AI-Powered HPC dataset. Beyond the auto-detected
fields, `--mdofs` (model size) is the key size driver and worth always passing.
There is no dedicated flag for the solver family, so record it as a
characteristic — for example
`--char solver_type=sparse-direct-symmetric` or `--char solver_type=pcg-iterative`,
and `--char memory_mode=InCore|OutOfCore` — since those two attributes explain
most of the runtime variation between otherwise identical configurations.

# Performance

Measured on AWS with the V26 Cluster models and MAPDL 2026 R1 (`v261`), launched
with the command line `runBench.py` prints (see [Benchmarks](#benchmarks)), Intel
MPI over EFA, in eu-north-1. Scratch is the working directory on FSx for Lustre
unless stated. Under-populated Hpc8a/Hpc7a nodes were pinned with the lists from
[Utils/flexible-cores](https://github.com/aws-samples/hpc-applications/tree/main/Utils/flexible-cores)
(`I_MPI_PIN_PROCESSOR_LIST`, checked in Intel MPI's pinning table with
`I_MPI_DEBUG=5`), and those of the other types with an even stride over all
their cores. On hpc6a.48xlarge that stride does not balance the 16 and 32 cores
per node of the tables below: its 96 cores share 12 L3 caches, so balanced
counts there are multiples of 12 (the flexible-cores page, "Other AMD instance
types"). The runs are from 2026-08-29 to 2026-10-04, each with at most three
other MAPDL solves of the campaign running at the same time
([Shared-filesystem contention](#shared-filesystem-contention) shows what more
did). Treat the numbers as measurements of these models on these
configurations, not as a general ranking.

> Every figure below is relative performance, computed from MAPDL's own
> `Elapsed Time (sec)`: the reference's time divided by each configuration's, so
> the reference is 1.00 and higher is faster. A cell is one run unless it gives a
> run count, and then the median of those runs. Each instance table holds one
> CPU vendor's instance types, against a reference of the same vendor. These
> models ran at most 96 cores per node, so the first AMD instance table uses one
> hpc7a.96xlarge node at 96 cores as its reference, not a fully populated node,
> and the core-count table and the second AMD table one hpc8a.96xlarge node at
> 96 cores. The first Intel table uses one c8i.96xlarge node at 32 cores, a
> layout every Intel type ran, and the second one hpc6id.32xlarge node at 64
> cores. The NVMe and contention tables state their own reference below them,
> and the contention table lists each shared run.

## Balanced core counts on Hpc8a

Every layout below gives each of the 24 CCDs the same number of ranks. The runs
are from 2026-10-04, with at most two other MAPDL solves running at the same time.
The 1 x 96 cells marked * are earlier runs (2026-08-31): V26iter-5 ran alone,
V26iter-4 with at most two other solves, and V26iter-6 is the median of two
runs, one alone and one with at most two others.

Core counts and nodes on hpc8a.96xlarge, each model against one node at 96 cores
= 1.00:

| Model | 1 x 24 | 1 x 48 | 1 x 96 | 2 x 48 | 2 x 96 |
|---|--:|--:|--:|--:|--:|
| V26direct-4 | 0.37 | 0.69 | 1.00 | 1.01 | 1.20 |
| V26direct-5 | 0.65 | 0.91 | 1.00 | 2.92 | 3.65 |
| V26direct-6 | 0.52 | 0.80 | 1.00 | 1.47 | 1.97 |
| V26iter-4 | 0.76 | 0.97 | 1.00* | 1.22 | 1.23 |
| V26iter-5 | 0.80 | 0.94 | 1.00* | | |
| V26iter-6 | 0.66 | 0.86 | 1.00* (2 runs) | 1.23 | 1.21 |

Nodes x cores per node; relative performance, higher is faster.

  * On one node, 96 cores was the fastest of the three counts for every model.
  * On two nodes, the iterative models ran as fast at 48 cores per node as at 96
    (V26iter-6: 1.23 and 1.21; V26iter-4: 1.22 and 1.23), while the sparse-direct
    models still gained from 96 (V26direct-6: 1.47 to 1.97).
  * The memory mode explains the largest steps. V26direct-5 ran Optimal
    Out-of-Core on one hpc8a.96xlarge and In-Core on two, so 2 x 48 was 2.9x
    faster than 1 x 96 on the same 96 cores. V26direct-6 stayed out-of-core on
    two hpc8a nodes, and V26direct-4 was in-core throughout (see
    [Memory mode and node count](#memory-mode-and-node-count)).
  * **Where a second node pays.** At 96 cores per node, a second node ran
    V26direct-6 1.97x as fast (98% parallel efficiency), and V26direct-5, which
    it brought in-core, 3.65x (182%). For V26direct-4, V26iter-4 and V26iter-6,
    which already fit on one node, it bought 20-23%, at 60-62% efficiency.

## Instance types

The tables below give every instance type we ran the V26 Cluster models on, each
CPU vendor's types against a reference of the same vendor. "in" and "out" give
MAPDL's memory mode (In-Core, Optimal Out-of-Core), and "NVMe" marks scratch on
local instance store.

### AMD instance types

V26direct-5, which fits in memory on only some of these configurations, and
V26iter-5, which fits on all of them, each against one hpc7a.96xlarge node at 96
cores = 1.00:

| Instance | Nodes x cores per node | V26direct-5 | V26iter-5 (PCG) |
|---|---|--:|--:|
| hpc7a.96xlarge | 1 x 24 | 0.47 out | 0.83 |
| hpc7a.96xlarge | 1 x 48 | 0.76 out | 0.96 |
| hpc7a.96xlarge | 1 x 96 | 1.00 out | 1.00 (2 runs) |
| hpc8a.96xlarge | 1 x 24 | 0.75 out | 0.99 |
| hpc8a.96xlarge | 1 x 48 | 1.04 out | 1.17 |
| hpc8a.96xlarge | 1 x 96 | 1.15 out | 1.24 |
| hpc8a.96xlarge | 2 x 48 | 3.35 in | |
| hpc8a.96xlarge | 2 x 96 | 4.19 in | |
| hpc6a.48xlarge | 1 x 32 | | 0.74 |

V26direct-4, V26iter-4 and V26iter-6 on hpc6a.48xlarge, each against one
hpc8a.96xlarge node at 96 cores = 1.00 (their hpc8a layouts are in
[Balanced core counts on Hpc8a](#balanced-core-counts-on-hpc8a); V26direct-6 ran
on no other AMD type):

| Instance | Nodes x cores per node | V26direct-4 | V26iter-4 | V26iter-6 |
|---|---|--:|--:|--:|
| hpc6a.48xlarge | 1 x 16 | 0.10 out | 0.36 | |
| hpc6a.48xlarge | 1 x 32 | 0.13 out | 0.50 | |
| hpc6a.48xlarge | 2 x 32 | 0.35 in (2 runs) | | 0.69 |

Nodes x cores per node; relative performance, higher is faster.

  * **Hpc8a was the fastest per node of the AMD types.** At the same layout it
    was 1.15-1.59x as fast as hpc7a.96xlarge (13-37% less time), and one
    hpc8a.96xlarge at 24 cores ran V26iter-5 faster than one hpc6a.48xlarge at
    32 (0.99 against 0.74).
  * **Two hpc8a nodes hold V26direct-5 in-core.** One hpc8a.96xlarge or
    hpc7a.96xlarge (768 GiB) ran it out-of-core, and two hpc8a.96xlarge in-core
    (4.19 against 1.15 at 96 cores per node).
  * **Hpc6a was slower per core.** With the model in-core, two hpc6a.48xlarge at
    32 cores per node ran V26direct-4 at about the speed of one hpc8a.96xlarge at
    24 (0.35 against 0.37), a count that loads hpc6a's L3 caches unevenly (see
    [Performance](#performance)).

### Intel instance types

V26direct-5 and V26iter-5, each against one c8i.96xlarge node at 32 cores =
1.00:

| Instance | Nodes x cores per node | V26direct-5 | V26iter-5 (PCG) |
|---|---|--:|--:|
| c8i.96xlarge | 1 x 32 | 1.00 out | 1.00 |
| c8i.96xlarge | 1 x 96 | 1.29 out | 1.24 |
| hpc6id.32xlarge | 1 x 16 | 0.84 in | 0.70 |
| hpc6id.32xlarge | 1 x 32 | 1.29 in | 0.91 |
| hpc6id.32xlarge | 1 x 64 | 1.97 in, NVMe | 1.00 |
| hpc6id.32xlarge | 2 x 64 | 3.02 in | |
| c7i.48xlarge | 1 x 32 | | 0.89 |
| m7i.48xlarge | 1 x 32 | | 0.93 |
| r7i.48xlarge | 1 x 32 | | 0.98 |
| r8i.96xlarge | 1 x 32 | | 0.93 |

V26direct-6, against one hpc6id.32xlarge node at 64 cores = 1.00:

| Instance | Nodes x cores per node | V26direct-6 |
|---|---|--:|
| hpc6id.32xlarge | 1 x 16 | 0.33 out |
| hpc6id.32xlarge | 1 x 32 | 0.55 out |
| hpc6id.32xlarge | 1 x 64 | 1.00 out, NVMe (2 runs) |
| hpc6id.32xlarge | 2 x 64 | 2.12 in, NVMe (2 runs) |
| r8i.96xlarge | 1 x 64 | 1.39 in |

Nodes x cores per node; relative performance, higher is faster. V26direct-4,
V26iter-4 and V26iter-6 ran on one Intel configuration each, one hpc6id.32xlarge
node at 64 cores, so these tables leave them out; V26direct-4 ran in-core there
(see [Memory mode and node count](#memory-mode-and-node-count)).

  * **Memory per node sets the node count of a sparse-direct model.** One
    hpc6id.32xlarge (1,024 GiB) holds V26direct-5 in-core, where one
    c8i.96xlarge (768 GiB) does not: at 64 cores it ran V26direct-5 1.53x as
    fast as one c8i.96xlarge at 96 cores (1.97 against 1.29). One r8i.96xlarge
    (3,072 GiB) holds V26direct-6 in-core, where one hpc6id.32xlarge does not
    (1.39 against 1.00, at 64 cores each), and two hpc6id.32xlarge, in-core as
    well, ran it 1.53x as fast as the r8i.96xlarge node (2.12 against 1.39).
  * **No Intel type with more memory per core beat c8i.96xlarge on a model that
    fit.** On V26iter-5, which fits on every one of these nodes, one
    c8i.96xlarge at 32 cores (1.00) was faster than every other Intel type at 32
    cores (0.89-0.98), the large-memory r7i.48xlarge and r8i.96xlarge included.
    With the same CPU and more memory the results were mixed, one run each: at
    32 cores, c7i, m7i and r7i.48xlarge (1, 2 and 4 times the memory) ran at
    0.89, 0.93 and 0.98, and c8i.96xlarge and r8i.96xlarge (1 and 4 times) at
    1.00 and 0.93.
  * **Hpc6id was slower per core than c8i.96xlarge on a model that fit.** On
    V26iter-5, one hpc6id.32xlarge at 32 cores ran at 0.91, and with all 64 of
    its cores at about the speed of one c8i.96xlarge at 32 (1.00).

## Memory mode and node count

MAPDL's memory mode for the three sparse-direct models in every run we archived,
from its `Memory Option:` line, against the job's memory (the instance's memory
in GiB, as EC2 lists it, times the nodes) and that memory over the figure in GB
that `JOBS.CONFIG` lists:

| Model (`JOBS.CONFIG`) | In-Core | Optimal Out-of-Core |
|---|---|---|
| V26direct-4 (510 GB) | 1 x hpc8a.96xlarge or 2 x hpc6a.48xlarge, 768 GiB (1.51x); 1 x hpc6id.32xlarge, 1,024 GiB (2.01x); 2 x hpc8a.96xlarge, 1,536 GiB (3.01x) | 1 x hpc6a.48xlarge, 384 GiB (0.75x) |
| V26direct-5 (710 GB) | 1 x hpc6id.32xlarge, 1,024 GiB (1.44x); 2 x hpc8a.96xlarge, 1,536 GiB (2.16x); 2 x hpc6id.32xlarge, 2,048 GiB (2.88x) | 1 x hpc8a.96xlarge, hpc7a.96xlarge or c8i.96xlarge, 768 GiB (1.08x) |
| V26direct-6 (1,100 GB) | 2 x hpc6id.32xlarge, 2,048 GiB (1.86x); 1 x r8i.96xlarge, 3,072 GiB (2.79x) | 1 x hpc8a.96xlarge, 768 GiB (0.70x); 1 x hpc6id.32xlarge, 1,024 GiB (0.93x); 2 x hpc8a.96xlarge, 1,536 GiB (1.40x) |

Every configuration with at least 1.44 times the `JOBS.CONFIG` figure ran
in-core, and every one with 1.40 times or less out-of-core, at every rank count
we ran (16 to 192): the memory mode followed the job's memory, not its ranks. So
read that figure as a floor, plan for about 1.5 times it, and add nodes to get
there. The ratios divide the instance's GiB by `JOBS.CONFIG`'s GB, each as its
source lists it, and the advice holds in those units. This rule of thumb, and
the one for MAPDL's printed in-core figure under
[Key settings](#key-settings--tips-performance-related-ones) (about twice it),
rest on these three models and the nine combinations of instance type and node
count in the table: check your own model's memory mode on its first run.

## Scratch on local NVMe vs FSx for Lustre

hpc6id.32xlarge at 64 cores per node. Each pair ran back to back, with no other
MAPDL, CFX or Fluent solve of our benchmark campaigns running at the same time: the
working directory, and so MAPDL's scratch, on FSx for Lustre first, then on the
instance-store NVMe ParallelCluster mounts at `/scratch` (what
`SCRATCH_MODE=shared` and `SCRATCH_MODE=nvme` select in the sbatch).

| Model | Nodes | MAPDL memory mode | Date | FSx for Lustre | NVMe | Time on NVMe vs FSx |
|---|--:|---|---|--:|--:|--:|
| V26direct-6 | 1 | Optimal Out-of-Core | 2026-09-01 | 1.00 | 1.27 | -21.0% |
| V26direct-6 | 1 | Optimal Out-of-Core | 2026-10-04 | 1.00 | 1.27 | -21.4% |
| V26direct-6 | 2 | In-Core | 2026-09-01 | 1.00 | 1.06 | -6.1% |
| V26direct-6 | 2 | In-Core | 2026-10-04 | 1.00 | 1.06 | -5.8% |
| V26direct-5 | 1 | In-Core | 2026-10-04 | 1.00 | 1.03 | -2.8% |

Relative performance, the FSx for Lustre run of each pair = 1.00. Local NVMe
saved about 21% when MAPDL ran out-of-core and
3-6% in-core, and the two A/B tests a month apart agree within half a point. That
is the case for the default `SCRATCH_MODE=auto`, which runs from `/scratch` when
every node has it on local instance storage with at least `SCRATCH_MIN_FREE_GIB`
free (see [Scratch space and concurrency](#scratch-space-and-concurrency)). The
default minimum is sized for in-core solves, so raise it for an out-of-core model:
V26direct-6 out-of-core wrote about 1.2 TB on one node (MAPDL's `Sum of disk space
used on all processes`).

## Shared-filesystem contention

The same configurations alone, and while other MAPDL solves of the same campaign
shared the FSx for Lustre file system (2026-08-29):

| Model | Nodes x cores per node | Alone | Shared | Other MAPDL solves at the same time |
|---|---|--:|--:|--:|
| V26iter-5 | 1 x 96, hpc8a.96xlarge | 1.00 | 0.50 / 0.33 / 0.30 | up to 23 |
| V26iter-6 | 1 x 96, hpc8a.96xlarge | 1.00 | 0.50 / 0.33 / 0.32 | up to 23 |
| V26direct-5 | 2 x 64, hpc6id.32xlarge | 1.00 | 0.96 / 0.82 / 0.74 | 10-11 |

Relative performance, the run alone = 1.00; the runs alone are from 2026-08-31
and 2026-10-03. Sharing
made the same solve up to 3.3x slower, which is why the advice above is to cap
concurrent solves and to re-run a surprising result alone.

## Which time to compare

The sbatch records two times: the wall clock around the `mapdl` command
(`time_to_solution_seconds`) and MAPDL's own `Elapsed Time (sec)`
(`mapdl_elapsed_seconds`). Compare runs on MAPDL's. The difference is the time
spent outside MAPDL's own clock, and it is not constant: for V26direct-5 on
2 x hpc6id.32xlarge the wall clock was 9% longer than MAPDL's time when the solve
ran alone, and 8% to 137% longer on the shared file system above (2.4x MAPDL's
time at worst). Over the 66 runs of the core-count and instance tables above,
it was 0.5% to 16% longer, 2% at the median.

## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
