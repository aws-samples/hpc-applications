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
    requirement. If the *aggregate* RAM of the job is below it, MAPDL falls back
    to an **out-of-core** mode that does heavy I/O, and runtime can more than
    double. Size the job to fit in memory first; only then optimise for cores.
  * **Check which memory mode you got.** MAPDL states it on the `Memory Option:`
    line of the solver statistics at the end of its output (`In-Core` or
    `Optimal Out-of-Core`) — it is the first thing to look at when a run is
    unexpectedly slow. Read that line rather than searching the whole file: every
    sparse-direct run also prints `Equation solver memory required for
    out-of-core mode`, so a search for "out-of-core" labels in-core runs
    out-of-core. In the 94 sparse-direct V26 Cluster outputs we archived, MAPDL
    reported In-Core for 45, and a whole-file search labelled all 94 out-of-core.
    The iterative solvers (PCG, JCG) print no `Memory Option:` line.
  * Because DMP aggregates memory across nodes, **adding a node can be far more
    effective than adding cores**: it raises the memory ceiling as well as the
    core count. Moving a model that is out-of-core on one node onto two nodes
    (so it fits in aggregate RAM) can improve runtime by far more than the added
    parallelism alone would explain — the speedup is the memory mode changing,
    not parallel efficiency.
  * **Once the model fits in memory, adding more memory stopped helping** in the
    configurations we measured — memory bandwidth and clock speed dominate from
    there. Size for the documented requirement plus headroom rather than buying
    the largest memory footprint available.
  * **Instance selection.** The notes below reflect the V26 Cluster models on the
    configurations we tested; treat them as a starting point and verify against
    your own models rather than as a general ranking. Quantitative comparisons
    will land in [Performance](#performance).
      * [Hpc6id](https://aws.amazon.com/ec2/instance-types/hpc6id/) — 16 GB/core,
        a cost-effective way to buy memory capacity, **plus 15.2 TB of local
        NVMe** for solver scratch (see below). A good fit for the large
        sparse-direct models, and the reference configuration in the sbatch.
      * [Hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/) /
        [Hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) — 4 GB/core but
        high memory bandwidth and core count; these were the quickest of the
        instances we tried on models that already fit in memory.
      * R-family ([r7i](https://aws.amazon.com/ec2/instance-types/r7i/) /
        [r8i](https://aws.amazon.com/ec2/instance-types/r8i/), or
        [r7id](https://aws.amazon.com/ec2/instance-types/r7id/) /
        [r8id](https://aws.amazon.com/ec2/instance-types/r8id/) /
        [i7ie](https://aws.amazon.com/ec2/instance-types/i7ie/) for local
        NVMe) — worth it mainly when a single node must hold a very large model.
        Per-unit cost is comparatively high, and in our runs they were not faster
        than the HPC instances once the model already fit in memory.
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
0.01-0.23 TB when the same models run in-core. MAPDL reports it as
`Sum of disk space used on all processes` in its I/O statistics (`Sum Scratch
Used(All)` in the closing box is scratch *memory*, and it is largest for in-core
runs). On a shared filesystem this is a hard planning constraint:

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
    (15.2 TB per node), r7id/r8id and the i-family carry instance-store NVMe
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
    reused between jobs and leftover scratch accumulates.
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

TBC — scaling and instance-comparison charts to follow.
