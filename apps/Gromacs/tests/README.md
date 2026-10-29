# GROMACS shell tests

Run everything:

```bash
apps/Gromacs/tests/run-tests.sh
```

No Slurm, no EC2, no GROMACS, no MPI, no AWS credentials and no network access are
required. `pytest tests` runs the same suite (`tests/test_gromacs_launchers.py`).

## What is covered and why

The suite runs **the launch scripts themselves**, `x86/gromacs-benchmark.sbatch` and
`Arm/gromacs-benchmark.sbatch`, with `curl` (IMDS), `lscpu`, `scontrol`, `srun`,
`sudo`, `fi_info`, `mpirun`, `ldd`, `aws`, `gmx` and `gmx_mpi` replaced by the stubs of
`harness.sh`, so the assembled script executes from its checks to its results block.
`test-imds-reads.sh` also runs `GPU/gromacs-benchmark.sbatch` that way, with an
`nvidia-smi` stub and a stub GPU build of its own.
The `curl` stub answers IMDS as `STUB_IMDS` says (an instance type by default; no
answer, an answer cut off at the time limit, an HTTP error, or a page that is not
an instance type name), and the `lscpu`
stub describes the CPU `STUB_LSCPU` names and logs each call, so the test host's CPU
never decides a case.
The stubs touch nothing on the host: the cache drop and the THP setting are
swallowed, a download is refused (and its URL logged), and the `aws` stub refuses
every call. The `gmx` and `gmx_mpi` stubs log each `mdrun` command line with its
OpenMP environment and write an `md.log` with synthetic timings; the `mpirun` stub
logs its command line and runs the `gmx_mpi` stub.

`test-launchers.sh` checks, for both launchers:

- one node runs Thread_MPI `gmx` once, with no `mpirun`, as
  `-ntmpi <cores> -ntomp 1 -pin on -pinoffset 0 -pinstride 1`, and
  `THREADS_PER_RANK=4` gives `-ntmpi 48 -ntomp 4` on 192 tasks per node;
- more nodes run `gmx_mpi` under `mpirun -np <ranks> --hostfile hostfile --bind-to core`,
  `--map-by slot` with one thread per rank, `--map-by ppr:<ranks>:node:PE=<threads>`
  with more, OpenMPI over EFA (`pml cm`, `mtl ofi`), and `OMP_NUM_THREADS` set;
- every run gets the model's `.tpr` and default `nsteps` and
  `-resethway -noconfout -nstlist 100 -deffnm md`;
- the results block gives `md.log`'s ns/day, and the contribution recorder is called;
- `THREADS_PER_RANK=0` and an unknown `MODEL` are refused before any `mdrun`.

`run-tests.sh` runs every `test-*.sh` here and `bash -n` over every GROMACS script.
To test another revision's scripts, point `GROMACS_APP` at its `apps/Gromacs`
directory.

Every other `test-*.sh` covers one behaviour of the launchers, and its header says
what it checks and why.
