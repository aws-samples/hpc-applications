# CFX shell tests

Run everything:

```bash
apps/CFX/tests/run-tests.sh
```

`run-tests.sh` runs every `test-*.sh` in this directory, and each one describes
its cases in its header. This page describes `test-sbatch-e2e.sh`, the sbatch
example's end-to-end test.

No Slurm, no EC2, no licensed solver, no MPI, no AWS credentials and no network
access are required: every case is driven from a checked-in cfx5solve output file
in `fixtures/` or one the test writes itself. Every time and mesh count in them is
synthetic.

## What is covered and why

The sbatch example times `cfx5solve` with the wall clock and passes that time to
the recorder as `TIME_TO_SOLUTION`. It covers partitioning and cfx5solve's own
start-up and wrap-up as well as the iterations, and those do not get faster with
more cores. After the solve, the example also prints the time of the iterations
from the solver's output file (`<case>_NNN.out`): `CFD Solver wall clock seconds`,
and that time over the number of `OUTER LOOP ITERATION =` lines:

```
Iteration time: 123.45 s (CFD Solver wall clock seconds, perf_Test_R16_001.out)
Time per iteration: 12.345 s (10 outer loop iterations)
```

| Fixture | Represents | Iteration time | Time per iteration | Mesh size recorded |
|---|---|---|---|---|
| `steady-10-iterations.out` | a partitioning run and a steady-state solver run of 10 outer loop iterations, on one domain | 123.45 s | 12.345 s | 1.000000 |
| `stopped-after-3.out` | a solver run that stops after its third iteration, before it reports its time | N/A | N/A | none |
| `transient.out` | a transient run: time steps and coefficient loops, no outer loop iterations | 50.00 s | N/A (no outer loop iterations) | none |
| `steady-two-domains.out` | a partitioning run and a steady-state solver run of 2 outer loop iterations, on two domains | 20.00 s | 10.000 s | 1.500000 (global) |

`test-sbatch-e2e.sh` runs **the sbatch example itself** (`CFX.sbatch`, or
`CFX-mpirun.sbatch` where it has that name; `CFX_SBATCH` points at another copy),
with `curl`, `scontrol`, `date` and `cfx5solve` replaced by stubs. The script
installs CFX under a fixed `/fsx/ansys_inc/<version>/CFX/bin`, so the test runs a
copy in which that one line points at a temporary directory, and checks that the
copy differs from the script in that line only. The `cfx5solve` stub writes a
fixture as `<case>_001.out` in its working directory and exits with the status the
case asks for. For each case it asserts the two lines above, and what the example
does besides:

  * the run directory, the `cfx5solve` command line, the existing output lines and
    the exit status (0, 1 or 2, as the solve exits);
  * the recorder is called once, after the two lines, with `BENCHMARK_CASE`,
    `CFX_VERSION`, `RUN_DIR` and the wall clock as `TIME_TO_SOLUTION`, as before,
    and with what makes runs comparable as arguments: the iteration time
    (`--metric cfd_solver_wall_seconds=`), the number of outer loop iterations
    (`--metric num_iterations=`) and the mesh size in millions of elements
    (`--mesh-cells-million`); with this directory's recorder in `--dry-run`, the
    item it would store has the wall clock as `time_to_solution_seconds` and
    those three beside it. The mesh size is the domain's
    `Total Number of Elements`, or the `Global Number of Elements` of a case with
    several domains; there is none when the domains' counts differ and no global
    count is given, or when the count is not a number, and a `MESH_CELLS_MILLION`
    set in the environment is kept. A transient run gets the iteration time
    only. Times under 10 s and of 6 digits, CRLF line ends and a comma-decimal
    locale give plain decimals with a point;
  * a solve that exits non-zero is not recorded, with the existing NOTE.

The cases: the fixtures above; no output file at all (N/A, naming the file looked
for); two output files in the run directory (the last, `_002`, is read); a run of
one outer loop iteration (`1 outer loop iteration`); times of under 10 s, of 6
digits (printed without an exponent) and in a file with CRLF line ends; a
`CFD Solver wall clock seconds:` line with no number on it, ending after its colon
or with the asterisks Fortran prints for a field too narrow for its value (N/A,
never 0); a comma-decimal locale with `POSIXLY_CORRECT` set, under which gawk would
read `1.2345E+02` as 1 unless the script ran awk in the C locale (skipped when no
such locale is installed); and an output file the job cannot read (N/A, and the
job still exits 0, but the run is not recorded; skipped as root).

A run is recorded only when cfx5solve exits 0 and the newest output file holds a
`CFD Solver wall clock seconds` value. The last cases check that a run that exits
0 without one is not recorded, and says so in a NOTE: an output file that ends
before the solver's time, the line without a number or with asterisks, no output
file, and a newest `_002` without the value next to an `_001` with it. A transient
run, CRLF line ends and a comma-decimal locale are recorded, and a run that exits
1 gets the existing NOTE only.

## Adding a case

Drop a cfx5solve output file in `fixtures/` and add a `run_case` and its
assertions to `test-sbatch-e2e.sh`. `run-tests.sh` picks up any `test-*.sh`
automatically and also runs `bash -n` over the sbatch examples, the recorder and
the tests.
