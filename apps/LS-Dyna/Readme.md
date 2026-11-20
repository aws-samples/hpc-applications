# Ansys LS-DYNA

Ansys [LS-DYNA](https://www.ansys.com/products/structures/ansys-ls-dyna) is a multi-physics solver using the finite-element method (FEM). It is commonly used in many different areas in computer aided engineering (CAE), especially the explicit solver for crash simulations.

This page runs LS-DYNA MPP (distributed memory) on [AWS ParallelCluster](https://aws.amazon.com/hpc/parallelcluster/) with the cluster's Intel MPI 2021 over EFA, one MPI rank per core. One script, [`LS-Dyna.sbatch`](LS-Dyna.sbatch), runs every version below, from R13.1 to R17.0.1.

## Versions and builds

The script was run with these MPP single-precision builds, on Amazon Linux 2023 with the cluster's Intel MPI 2021.18 (`module load intelmpi`). All of them are linked against Intel MPI's `libmpi.so.12`, which Intel MPI 2021 provides.

| LS-DYNA | Build | Executable | Instruction set |
|---|---|---|---|
| R13.1 | LSTC | `ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018` | AVX2 |
| R14.1.1 | Ansys 2025 R2 | `ansys_inc/v252/ansys/bin/linx64/lsdyna_sp_mpp.e` | SSE2 |
| R15.0.2 | LSTC | `ls-dyna_mpp_s_R15_0_2_x64_centos79_aocc400_avx2_intelmpi-2018` | AVX2 |
| R16.1.1 | Ansys 2026 R1 | `ansys_inc/v261/ansys/bin/linx64/lsdyna_sp_mpp.e` | SSE2 |
| R16.2.1 | LSTC | `ls-dyna_mpp_s_R16_2_1_x64_centos79_aocc420_avx512_intelmpi-2018` | AVX-512 |
| R17.0.1 | LSTC | `ls-dyna_mpp_s_R17_0_1_x64_rhel810_aocc500_avx512_intelmpi-2021` | AVX-512 |

- **Ansys releases.** Every Ansys release from 2021 R1 installs LS-DYNA with the `-lsdyna` option of its silent install: R11.2.0 (2021 R1), R11.2.2 (2021 R2), R12.1 (2022 R1), R13.1.0 (2022 R2), R13.1.1 (2023 R1 and R2), R14.1.0 (2024 R1), R14.1.1 (2024 R2 to 2025 R2) and R16.1.1 (2026 R1); none ships R15. Ansys ships SSE2 builds only (`lsdyna_sp_mpp.e`, `lsdyna_dp_mpp.e`). The LS-DYNA manuals install with Mechanical APDL's `data` component, not with `-lsdyna`.
- **Ansys's LS-DYNA download portal** ([download.ansys.com/ls-dyna](https://download.ansys.com/ls-dyna), sign-in required) offers each release's MPP builds by instruction set (SSE2, AVX2, AVX-512), compiler (Intel ifort or ifx, AMD AOCC), MPI (Intel MPI, Open MPI, Platform MPI) and precision: the builds this page calls LSTC's. Each comes as a self-extracting `.tgz_extractor.sh`; the executable is named like its directory.
- **On AMD instances, use an AVX2 or an AOCC AVX-512 build.** On one `hpc8a.96xlarge`, R13.1's AVX2 build ran car2car 1.17× as fast as its SSE2 build (the first 15,000 cycles, one run each), and the AOCC AVX-512 builds of R16.2.1 and R17.0.1 ran 2–5% faster than their AOCC AVX2 builds (one run each). The AOCC AVX-512 builds of R16.2.1 and R17.0.1, and R17.0.1's ifx AVX-512 build, run on `hpc8a` and `hpc7a`; R13.1's AVX-512 builds, compiled with Intel ifort, are for Intel processors (the compiler adds a processor check). `hpc6a.48xlarge` (AMD EPYC 7R13) has no AVX-512: use an AVX2 build there.
- **AOCC builds' runtime.** The AOCC MPP single-precision builds above need no AOCC library. The portal's AOCC double-precision and hybrid builds need AOCC's `libomp.so` (and, for AOCC 4.0, `libflang.so`), which neither the download nor the cluster's nodes provide.

## Running LS-DYNA

```bash
cd apps/LS-Dyna
export ANSYSLMD_LICENSE_FILE=1055@<license-server>     # Ansys licensing, for Ansys's builds and LSTC's
sbatch --nodes=2 --ntasks-per-node=192 LS-Dyna.sbatch <solver executable> <input deck> [pfile]
```

The shape is sbatch's own: `--nodes`, `--ntasks-per-node`, `--constraint` and `--partition` on the command line override the script's defaults (one `hpc8a.96xlarge` node, 192 ranks). Submit from `apps/LS-Dyna` (or the repository root), so the job finds [`lib/lsdyna-run.sh`](lib/lsdyna-run.sh). The script:

1. Checks the shape (one rank count on every node) and the pinning before anything starts (see [Pinning on Hpc8a and Hpc7a](#pinning-on-hpc8a-and-hpc7a)).
2. Makes a run directory under `${BASE_DIR:-/fsx}`, links every file of the deck's directory into it (so the deck finds its `*INCLUDE` files), and writes the run's pfile: the given one without its directory section, plus `dir { global <run dir> local <run dir>/local }`. Keep each model's input files in a directory of their own: the script refuses a directory that holds an earlier run's output (`d3hsp`, `messag`, ...), because LS-DYNA would write through the links.
3. Drops the page cache and sets transparent huge pages to `always` on every node.
4. Runs `mpirun -np <ranks> -ppn <ranks per node> <solver> i=<deck> p=run.pfile [memory=...] [memory2=...]`.
5. Decides the outcome from LS-DYNA's own termination line, not from the exit status, and records the benchmark (see [Contribute your results](#contribute-your-results)) only after a normal termination.

| Variable | Effect |
|---|---|
| `ANSYSLMD_LICENSE_FILE` | `<port>@<server>` of an Ansys licence server: `LSTC_LICENSE=ansys`, for Ansys's builds and LSTC's alike |
| `LSTC_LICENSE_SERVER` | An LSTC network licence server: `LSTC_LICENSE=network`. One of the two is required; `LSTC_LICENSE` overrides the choice |
| `MEMORY`, `MEMORY2` | `memory=` and `memory2=` for the solver, in words (see [Memory](#memory)) |
| `PFILE_LSTC_REDUCE=1` | Adds `lstc_reduce` to the pfile's general section (see [Reproducible energies](#reproducible-energies-lstc_reduce)) |
| `LSTC_RSH` | The remote shell LS-DYNA's MPP ranks use to signal the root rank; default `ssh -x -o BatchMode=yes -o ConnectTimeout=10` (see [The MPP remote shell](#the-mpp-remote-shell)) |
| `ENDTIME` | `endtime=`: ends the run before the deck's termination time, for a quick check (such a run is not recorded) |
| `BASE_DIR`, `LOCAL_DIR` | Where the run directory goes (default `/fsx`), and the pfile's local directory (default `<run dir>/local`, made on every node) |
| `BENCHMARK_CASE` | The case name a recorded run gets; default the deck's file name without its extension (the CCSA vehicles' main deck is `combine.key` for each of them) |

For example, car2car-ver10 on R13.1, two nodes at 144 ranks per node:

```bash
export ANSYSLMD_LICENSE_FILE=1055@<license-server> MEMORY=900m MEMORY2=90m
sbatch --nodes=2 --ntasks-per-node=144 LS-Dyna.sbatch \
    /fsx/ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018/ls-dyna_mpp_s_R13_1_0_x64_centos78_ifort190_avx2_intelmpi-2018 \
    /fsx/models/car2car/Caravan-V03c-2400k-main-shell16-120ms.k /fsx/models/car2car/Caravan-V03c_2400k.pfile
```

### Licence

Both Ansys's builds and LSTC's run on an Ansys licence server (`LSTC_LICENSE=ansys` and `ANSYSLMD_LICENSE_FILE`). An MPP run checks out one `dyna` feature and one `FEAT_DYSMP` feature per rank beyond the first, so its licence cost follows ranks × time. LSTC's builds carry their own licensing client in their directory, which the script puts first on `LD_LIBRARY_PATH`. Ansys's builds find theirs in their install tree; an Ansys build copied out of its install finds it through `ANSYSCL_DIR` and `ANSYSCL<release>_DIR` (for example `ANSYSCL252_DIR` for 2025 R2).

Ansys's own MPP launcher (`lsdyna -dis`, which calls `ansys261 -lsdynampp`) runs the MPP executable with the Intel MPI 2018 Update 3 libraries Ansys bundles. On Amazon Linux 2023 that runtime needs the `libstrtok.so` library Ansys ships beside it, preloaded before the launcher starts (`export LD_PRELOAD=/ansys_inc/v261/tp/MPI/Intel/2018.3.222/linx64/lib/libstrtok.so`); Ansys's scripts set it for `-mpi intelmpi2018` only. With that preload, `ansys261 -dis -np <ranks> -mpi intelmpi -lsdynampp i=<deck> p=<pfile>` matched a direct `mpirun` of the same build cycle for cycle on one node (call `ansys261` itself: `lsdyna` rewrites `-mpi intelmpi2018`); Ansys's launcher was not checked on more than one node. Read the solve's outcome from LS-DYNA's termination line in the output (`N o r m a l    t e r m i n a t i o n`), as this page's script does, rather than from the launcher's exit status. The script on this page launches every build the same way instead, with the cluster's Intel MPI 2021 over EFA.

### Memory

Ansys's builds size their memory themselves (`LSTC_MEMORY=auto`, which the script sets for every build). LSTC's builds take `memory=` and `memory2=` (in words) on the command line: `MEMORY=900m MEMORY2=90m` ran car2car, 3cars, neon, the Camry and the Yaris below on 1 to 8 nodes, and `MEMORY=1400m MEMORY2=300m` ran ODB-10M on 4 nodes.

## Best practices

### MPI over EFA

The script loads the cluster's Intel MPI and runs it over EFA with `I_MPI_OFI_LIBRARY_INTERNAL=0`, `I_MPI_FABRICS=shm:ofi`, `I_MPI_OFI_PROVIDER=efa`, `I_MPI_MULTIRAIL=1`, `FI_EFA_FORK_SAFE=1` and the `libfabric-aws` module, as the other apps here do. `I_MPI_DEBUG=5` prints the core every rank runs on, so the job log shows the placement.

### The MPP remote shell

LS-DYNA's MPP ranks signal the root rank through a remote shell, for example to stop the run before its termination time: LS-DYNA writes the command to the run directory's `bg_switch` file as `<shell> <root host> kill -INT <pid>`, taking the shell from `LSTC_RSH`. R13.1's default is `rsh`, which ParallelCluster nodes do not have, while ssh between the compute nodes works: the script sets `LSTC_RSH="ssh -x -o BatchMode=yes -o ConnectTimeout=10"`, and Intel MPI passes it to every rank (Open MPI needs `-x LSTC_RSH`). Each of the six builds above wrote that shell into `bg_switch`.

Each MPP rank writes its own message file (`local/mesNNNN`), and rank 0's output does not repeat them all: read every rank's file for LS-DYNA's numbered messages. Give each job a Slurm time limit (`-t`) that fits its model.

### Node preparation

Before the solve, the script drops the page cache and sets transparent huge pages to `always` on every node, as the other apps' scripts here do, so every run starts from the same memory state.

### Pinning on Hpc8a and Hpc7a

`hpc8a.96xlarge` and `hpc7a.96xlarge` have 24 CCDs of 8 cores (one L3 each). With fewer than 192 ranks per node, the script pins the ranks with the official list from [Utils/flexible-cores](../../Utils/flexible-cores), which puts the same number of ranks on every CCD, and refuses any count that list does not cover (24, 48, 72, 96, 120, 144, 168 or 192 per node) before the solve starts. A full node runs one rank per core in order (`I_MPI_PIN_ORDER=compact`); other instance types below their core count use Intel MPI's own placement. With fewer ranks than cores and no instance type from the instance metadata (no answer within a few seconds, an error, or an answer that is not an instance type name), a node that `lscpu` shows with 192 AMD cores could be an `hpc8a.96xlarge` or an `hpc7a.96xlarge`, so it gets the same list or refusal, and any other node runs with Intel MPI's own placement and a one-line NOTE on stderr that the check is skipped.

On car2car with R13.1 on `hpc8a.96xlarge`, 3 runs each:

- **At 144 ranks per node the list matters.** Intel MPI's own placement gives 48 ranks two cores and 96 ranks one, which leaves 4, 6 or 8 ranks on each CCD in turn, and the run took 4.3% longer than on the list, which puts 6 on every CCD.
- **At 96 ranks per node it does not.** Intel MPI's own placement already puts 4 ranks on each CCD (two nodes), and the two agree within 0.2%.
- **144 ranks per node on the list ran 1.02× as fast as the full node (192 ranks),** on 25% fewer ranks, so 25% fewer licence features.

### Decomposition: the deck's own, or LS-DYNA's default

A model decomposes the way its deck or pfile asks: car2car's deck has `*CONTROL_MPP_DECOMPOSITION_TRANSFORMATION` (`SY 1000`), 3cars' and neon's pfiles a `decomp` section. Without one, LS-DYNA uses recursive coordinate bisection (RCB) with no transformation. On car2car (R13.1, `hpc8a.96xlarge`, 3 runs each), RCB ran 1.23× as fast as the deck's own decomposition on one node and 1.14× on two, with the same cycle count. On four nodes (768 ranks), RCB's solution diverges after about 96 ms (its total energy ratio rises from 1.09 to 537), reproducibly, while the deck's own decomposition runs to 120 ms there. On ODB-10M (R16.2.1, 768 ranks on 4 `hpc8a.96xlarge` nodes), whose deck's `*CONTROL_MPP_DECOMPOSITION_TRANSFORMATION` is `SY 10000000`, RCB ran the full 120 ms 1.76× as fast as the deck's own decomposition (medians of 3 runs each), in the same number of cycles, and at every 10 ms each of its `glstat` energies differed from the deck decomposition's by less than 1.3% of the initial energy. So RCB is worth trying, not a default: try it at the core counts you will run, and check its energies (`glstat`) against the deck's own decomposition. To try it, remove the deck's `*CONTROL_MPP_DECOMPOSITION_TRANSFORMATION` card, or the pfile's `decomp` section.

### Reproducible energies: lstc_reduce

None of the decks below asks for LS-DYNA's consistent reductions except ODB-10M's. Without them, the order in which the ranks' contributions at shared nodes are summed follows the MPI library's algorithm, and the keyword manual (`*CONTROL_MPP_IO_LSTC_REDUCE`) warns that this numerical noise can make an explicit run with many cycles bifurcate. Repeats of one shape keep the same cycle count, but their energies can part after the impact: car2car's total energy ratio at 120 ms ranged from 1.08 to 1.43 over all its runs, and from 1.19 to 1.43 over the three runs on one `hpc8a.96xlarge`. Where they part, the run time can follow the solution: car2car's repeats on 4 × 96 ranks ran within 3% of each other to 70 ms, then up to 1.48× slower per 10 ms on a higher-energy solution. ODB-10M's deck asks for it (`*** LSTC_REDUCE is ON` in `d3hsp`), and its repeats on 4 `hpc8a.96xlarge` nodes had the same energy history to the last state.

So for runs whose results you compare (versions, decompositions, repeats), set `PFILE_LSTC_REDUCE=1`: the script adds `lstc_reduce` to the pfile's general section (the pfile form of `*CONTROL_MPP_IO_LSTC_REDUCE`), and `d3hsp` confirms it (`*** LSTC_REDUCE is selected` on R13.1, `*** LSTC_REDUCE is ON` on R17.0.1). The manual says it gives identical results for the same decomposition and core count. Its cost on these models was not measured: the runs this page quotes did not add it.

### R17's input mesh check

R17.0 adds an input check for overlapping solid elements (Errors 21535 and 21536) that cannot be turned off. Two of the models below hold such solids: the CCSA Camry v5a (three of the rear seat foam) and ODB-10M (562). For the Camry, `model-fixes.sh camry-meshfix` removes the overlap: it deletes wedge 2028692 and keeps hex 2033993's part beyond its common face with hex 2033910, as a wedge (about 9 cm³ of foam that the mesh models twice). R17.0.1 then runs it to 120 ms. On R16.2.1, which accepts both meshes, the fixed and the shipped Camry run alike to 30 ms (3 runs each): the same 42,845 cycles and the same first element deletion, times within 0.6% and total energy ratios within 0.02%. Run ODB-10M on R16.2.1 (see [Model compatibility](#model-compatibility)).

## Model compatibility

Public benchmark models and the LS-DYNA versions they ran on, to their end time unless noted. A documented change is an edited copy of one input file, made with [`model-fixes.sh`](model-fixes.sh).

| Model | Size | Runs on | Documented change |
|---|---|---|---|
| car2car-ver10 (TopCrunch): two Dodge Caravans, frontal offset | 2.45M elements, 120 ms | R12.2.2 (to 8 ms), R13.1, R14.1.1, R15.0.2 | none |
| 3cars (TopCrunch): three-vehicle collision | 0.79M elements, 150 ms | R13.1, R14.1.1, R16.1.1, R16.2.1, R17.0.1 | `pfile-region`, `3cars-joint27` |
| neon_refined_revised (TopCrunch) | 0.54M elements, 30 ms | R13.1, R14.1.1, R16.1.1, R16.2.1, R17.0.1 | `pfile-region` |
| [2012 Toyota Camry detailed v5a](https://www.ccsa.gmu.edu/models/2012-toyota-camry/) (CCSA): frontal impact into a rigid wall | 2.26M elements, 120 ms | R13.1, R14.1.1, R16.1.1, R16.2.1, R17.0.1 | `camry-meshfix`, needed on R17.0.1 (as shipped, the Camry runs on R13.1, R14.1.1, R16.1.1 and R16.2.1, checked to 30 ms) |
| [2010 Toyota Yaris detailed v2j](https://www.ccsa.gmu.edu/models/2010-toyota-yaris/) (CCSA): frontal impact into a rigid wall | 1.52M elements, 200 ms | R16.1.1 and R16.2.1 (to 30 ms), R17.0.1 | none |
| ODB-10M (TopCrunch): offset deformable barrier | about 10M elements, 120 ms | R14.1.1 and R16.1.1 (to 5 ms), R16.2.1 | none |

- **Compare versions on the Camry or 3cars:** both run on R13.1 and R14.1.1, and from R16.1.1 to R17.0.1. car2car-ver10 runs on R12.2.2, R13.1, R14.1.1 and R15.0.2, of the versions checked.
- **The Camry** runs with `camry-meshfix` on R17.0.1 (see [R17's input mesh check](#r17s-input-mesh-check)), and the fixed mesh runs on all five of its versions, so use it for every version you compare.
- **3cars and neon:** their pfiles ship `decomp { silist ... }`; R12.2.2, R13.1, R14.1.1 and R16.1.1 read a `silist` only inside a region (Error 50192), so `pfile-region` writes `decomp { region { silist ... } ... }`. 3cars' revolute joint 27 joins coincident nodes, which R13.1, R14.1.1 and R16.1.1 check for (Error 21424); `3cars-joint27` makes it the spherical joint it amounts to.
- **Shapes on R17.0.1** (`hpc8a.96xlarge` and `hpc7a.96xlarge`): the Camry was measured on 192 ranks (1 × 192, 2 × 96, 4 × 48) and on 384 (2 × 192, 4 × 96, 8 × 48), the Yaris on 192 ranks and on 2 × 192, and 3cars on 192 ranks.

### Preparing the models

A fixed model is a directory of its own: links to the shipped files, and the edited copy in place of the file it replaces. For the Camry:

```bash
mkdir -p /fsx/models/camry-fixed
ln -s /fsx/models/camry/combine.key /fsx/models/camry/set-camry-detailed-v5a.key /fsx/models/camry/wall.key /fsx/models/camry-fixed/
./model-fixes.sh camry-meshfix /fsx/models/camry/camry-detailed-v5a.key /fsx/models/camry-fixed/camry-detailed-v5a.key
BENCHMARK_CASE=2012-toyota-camry-detailed-v5a-meshfix sbatch LS-Dyna.sbatch <R17.0.1 solver> /fsx/models/camry-fixed/combine.key
```

and the same way for the others:

```bash
./model-fixes.sh pfile-region  /fsx/models/3cars/pfile_32+            /fsx/models/3cars-fixed/pfile_32+
./model-fixes.sh 3cars-joint27 /fsx/models/3cars/3cars_shell2_150ms.k /fsx/models/3cars-fixed/3cars_shell2_150ms.k
./model-fixes.sh pfile-region  /fsx/models/neon/neon.refined.pfile     /fsx/models/neon-fixed/neon.refined.pfile
```

Each fix refuses a file that does not hold exactly the text it edits, refuses to write over its input (or a link to it), and prints the change. 3cars ships one pfile per rank count (`pfile_2` to `pfile_32+`); pass the one for your run's ranks as the script's third argument.

## Benchmarking Summary

AWS ran LS-DYNA with this page's script in October 2026, on [hpc8a](https://aws.amazon.com/ec2/instance-types/hpc8a/), [hpc7a](https://aws.amazon.com/ec2/instance-types/hpc7a/) and [hpc6a](https://aws.amazon.com/ec2/instance-types/hpc6a/) instances: MPP single precision with the cluster's Intel MPI 2021.18 over EFA, one rank per core, the flexible-cores lists on under-populated `hpc8a` and `hpc7a` nodes, and the page cache dropped and THP set to `always` before each run. The decks ran as shipped (without `lstc_reduce`), with the documented changes of [Model compatibility](#model-compatibility). Performance is LS-DYNA's own elapsed time to the deck's termination time, and every value below is a ratio of medians of 3 runs, except where marked ¹ (a single run). The runs of 48 of the 50 repeated points agree within 5% (median spread 1.0%); the other two are car2car-ver10 on 4 × 96 ranks (see [The same ranks on more nodes](#the-same-ranks-on-more-nodes)). neon's 30 ms is too short a run to compare, and ODB-10M was run on one shape only, so neither is in the tables below.

The results in brief:

- **hpc8a.96xlarge is 1.41–1.57× hpc7a.96xlarge** node for node, on one node and on two.
- **The same ranks run faster on two nodes:** 192 ranks on 2 × 96 ran 1.09–1.49× as fast as on one full node. LS-DYNA checks out its licence features per rank, so the licence cost per run fell to 0.67–0.91×, for 1.35–1.83× the EC2 cost per run.
- **car2car-ver10 stops scaling past two full nodes** of `hpc8a` or `hpc7a`: four ran it slower than two.
- **On one hpc8a.96xlarge, R16.2.1's and R17.0.1's AOCC AVX-512 builds** ran the Camry 1.04× and 3cars 1.13–1.27× as fast as R13.1's AVX2 build, and Ansys's SSE2 builds of R14.1.1 and R16.1.1 0.82–1.05×.

### Scaling on hpc8a, hpc7a and hpc6a

Every node is fully populated: 192 ranks per node on `hpc8a.96xlarge` and `hpc7a.96xlarge`, 96 on `hpc6a.48xlarge`. Performance is relative to one `hpc7a.96xlarge` node running the same model and version = 1.00×; higher is faster. The chart shows car2car-ver10, the Camry and the Yaris, and labels each line's last point with its parallel efficiency against the same instance type's first point; the table adds 3cars on one node.

![LS-DYNA scaling of car2car-ver10, the Camry and the Yaris on hpc8a, hpc7a and hpc6a](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/LS-Dyna/LSDYNA-Scaling.png?raw=true)

| Model | Instance type | 1 node | 2 nodes | 4 nodes |
|---|---|--:|--:|--:|
| car2car-ver10, R13.1 | hpc8a.96xlarge | 1.41× | 2.30× | 1.94×¹ |
| | hpc7a.96xlarge | 1.00× | 1.52× | 1.43×¹ |
| | hpc6a.48xlarge | 0.48× | 0.78× | 0.96×¹ |
| Camry v5a, R17.0.1 | hpc8a.96xlarge | 1.41× | 2.51× | — |
| | hpc7a.96xlarge | 1.00× | 1.75× | — |
| Yaris v2j, R17.0.1 | hpc8a.96xlarge | 1.52× | 2.46× | — |
| | hpc7a.96xlarge | 1.00× | 1.57× | — |
| 3cars, R17.0.1 | hpc8a.96xlarge | 1.52× | — | — |
| | hpc7a.96xlarge | 1.00× | — | — |

¹ A single run: car2car-ver10 had stopped scaling by 4 nodes, so the point was not repeated.

- `hpc8a.96xlarge` runs these models 1.41–1.57× as fast as `hpc7a.96xlarge`, node for node.
- On two nodes, parallel efficiency against one node of the same type is 76–89%. car2car-ver10 runs at 34% and 36% efficiency on 4 `hpc8a` and `hpc7a` nodes, slower than on 2; on 4 `hpc6a.48xlarge` nodes, with half the ranks per node, at 51%.
- One `hpc6a.48xlarge` node (96 cores) delivers 0.48× of one `hpc7a.96xlarge` node (192 cores) on car2car-ver10.
- 3cars on R17.0.1 was measured on 192 ranks: on one full node here, and on 2 × 96 and 4 × 48 in the next table.

### The same ranks on more nodes

These runs spread a fixed number of ranks over more nodes, at the flexible-cores counts per node (see [Pinning on Hpc8a and Hpc7a](#pinning-on-hpc8a-and-hpc7a)). Values are relative to the fully populated shape of the same total = 1.00× (1 × 192 for 192 ranks, 2 × 192 for 384):

| Model | Instance type | Ranks | Nodes × ranks per node | Speed | EC2 cost per run |
|---|---|--:|---|--:|--:|
| car2car-ver10, R13.1 | hpc8a.96xlarge | 192 | 2 × 96 | 1.49× | 1.35× |
| | | | 4 × 48 | 1.49× | 2.68× |
| | hpc8a.96xlarge | 384 | 4 × 96 | 0.93× | 2.16× |
| | | | 8 × 48 | 1.07× | 3.73× |
| | hpc7a.96xlarge | 192 | 2 × 96 | 1.45× | 1.38× |
| | | | 4 × 48 | 1.48× | 2.70× |
| | hpc7a.96xlarge | 384 | 4 × 96 | 1.06× | 1.88× |
| | | | 8 × 48 | 1.19× | 3.35× |
| Camry v5a, R17.0.1 | hpc8a.96xlarge | 192 | 2 × 96 | 1.39× | 1.44× |
| | | | 4 × 48 | 1.54× | 2.60× |
| | hpc8a.96xlarge | 384 | 4 × 96 | 1.29× | 1.55× |
| | | | 8 × 48 | 1.33× | 3.00× |
| | hpc7a.96xlarge | 192 | 2 × 96 | 1.36× | 1.47× |
| | | | 4 × 48 | 1.45× | 2.76× |
| | hpc7a.96xlarge | 384 | 4 × 96 | 1.27× | 1.57× |
| | | | 8 × 48 | 1.28× | 3.14× |
| Yaris v2j, R17.0.1 | hpc8a.96xlarge | 192 | 2 × 96 | 1.33× | 1.50× |
| | | | 4 × 48 | 1.37× | 2.91× |
| | hpc7a.96xlarge | 192 | 2 × 96 | 1.32× | 1.52× |
| | | | 4 × 48 | 1.31× | 3.05× |
| 3cars, R17.0.1 | hpc8a.96xlarge | 192 | 2 × 96 | 1.21× | 1.65× |
| | | | 4 × 48 | 1.05× | 3.79× |
| | hpc7a.96xlarge | 192 | 2 × 96 | 1.09× | 1.83× |
| | | | 4 × 48 | 0.88× | 4.56× |

Speed is the reference's time over the shape's time (higher is faster). With the same ranks, the licence cost per run follows the run time, so a speed of 1.49× is 0.67× the licence cost per run. The EC2 cost per run is nodes × time on the same instance type.

![LS-DYNA: the same ranks spread over more nodes](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/LS-Dyna/LSDYNA-FlexibleCores.png?raw=true)

- **192 ranks on 2 × 96** ran 1.09–1.49× as fast as on one full node, for 1.35–1.83× the EC2 cost per run. On 4 × 48 they ran 0.88–1.54× as fast, for 2.60–4.56× the EC2 cost per run: at most 1.11× faster than on 2 × 96 (the Camry on `hpc8a`), and slower for 3cars and for the Yaris on `hpc7a`.
- **384 ranks:** the Camry ran 1.27–1.29× as fast on 4 × 96 as on 2 × 192, for 1.55–1.57× the EC2 cost per run. car2car-ver10 ran 0.93× (`hpc8a`) and 1.06× (`hpc7a`) on 4 × 96, and 1.07× and 1.19× on 8 × 48.
- **car2car-ver10 on 4 × 96** is the one shape whose runs spread more than 5%: 11.7% on `hpc8a` and 7.1% on `hpc7a`. They ran within 3% of each other to 70 ms, and after that each at the pace of the solution it reached (see [Reproducible energies](#reproducible-energies-lstc_reduce)), so their median is a median over different solutions.

### Versions on one hpc8a.96xlarge

Each model on one `hpc8a.96xlarge` at 192 ranks, relative to the same model on R13.1 = 1.00×; higher is faster. Each version ran the build named in its column (see [Versions and builds](#versions-and-builds)), so a ratio holds the build's compiler and instruction set as well as the version.

| Model | R13.1 (LSTC AVX2) | R14.1.1 (Ansys SSE2) | R15.0.2 (LSTC AOCC AVX2) | R16.1.1 (Ansys SSE2) | R16.2.1 (LSTC AOCC AVX-512) | R17.0.1 (LSTC AOCC AVX-512) |
|---|--:|--:|--:|--:|--:|--:|
| car2car-ver10 | 1.00× | 0.87× | 1.00× | — | — | — |
| Camry v5a | 1.00× | 0.82× | — | 0.94× | 1.04× | 1.04× |
| 3cars | 1.00× | 0.94× | — | 1.05× | 1.13× | 1.27× |

A dash: not run on that version. Of these versions, car2car-ver10 runs on R13.1, R14.1.1 and R15.0.2 (see [Model compatibility](#model-compatibility)), and the Camry and 3cars ran on R13.1, R14.1.1, R16.1.1, R16.2.1 and R17.0.1.

![LS-DYNA versions on one hpc8a.96xlarge, each model against its R13.1 run](https://github.com/aws-samples/hpc-applications/blob/main/Doc/img/LS-Dyna/LSDYNA-Versions.png?raw=true)

- R16.2.1 and R17.0.1, LSTC's AOCC AVX-512 builds, ran the Camry 1.04× as fast as R13.1, and 3cars 1.13× and 1.27×.
- Ansys's SSE2 builds ran 0.82–0.94× as fast as R13.1 on R14.1.1, and 0.94–1.05× on R16.1.1.
- car2car-ver10 ran as fast on R15.0.2 as on R13.1 (1.00×), both on AVX2 builds.

## Files

| File | |
|---|---|
| [`LS-Dyna.sbatch`](LS-Dyna.sbatch) | One LS-DYNA MPP run with Intel MPI 2021 over EFA |
| [`lib/lsdyna-run.sh`](lib/lsdyna-run.sh) | The script's checks and helpers: pinning, licence, pfile, termination |
| [`model-fixes.sh`](model-fixes.sh) | The documented input changes for current releases |
| [`tests/`](tests/) | `tests/run-tests.sh`: the script, its helpers and the fixes, with stubbed Slurm, MPI and solver |
| [`dynamodb/`](dynamodb/) | The benchmark recorder |

## Contribute your results

The benchmark script in this folder calls [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every run that ends in LS-DYNA's normal termination, with LS-DYNA's own elapsed time and version. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs and `BENCHMARK_CASE=<model>` when the deck's file name does not name the model (the CCSA vehicles' `combine.key` does not). See [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
