# LAMMPS shell tests

Run everything:

```bash
apps/LAMMPS/tests/run-tests.sh
```

No Slurm, no EC2, no LAMMPS, no MPI, no AWS credentials and no network access are required. The decks the tests stage
are synthetic, written by the test itself in the shape of LAMMPS's `bench/` decks, and every time in the stub's log is
synthetic.

## What is covered and why

LAMMPS's `bench/` decks end with `run 100` and read no step-count variable, so a `-var` on the command line alone
cannot change how many steps they run. The benchmark scripts copy the deck into the run directory with that line made
`run ${nsteps}`, and pass `-var nsteps` with the run length: a default per model, or `TIMESTEPS`.

`test-sbatch-e2e.sh` runs **both benchmark scripts themselves** (`x86/lammps-benchmark.sbatch` and
`Arm/lammps-benchmark.sbatch`), with `curl`, `scontrol`, `srun`, `sudo`, `fi_info`, `lscpu`, `mpirun` and `lmp`
replaced by stubs, so the assembled script really executes. The stub `lmp` runs as many steps as the deck's run line
asks for, with `${name}` taken from `-var name`, as LAMMPS does. For each script it asserts:

- for each model (`lj`, `rhodo`, `rhodo_scaled`, `eam`), with no override: `lmp` gets the model's default `SCALE` and
  `-var nsteps` with its default run length, and no `-var t`; the run directory's deck differs from the cached one in
  its run line only, and the cached deck is unchanged; the results block gives the run length, the atom count and the
  scale; the job log says how the run length is set; the recorder gets the model, its scale and the run length;
  nothing is downloaded;
- a run whose `log.lammps` has no `Loop time` line, reports fewer timesteps than asked for, or has no closing
  `Total wall time` line (the stub `lmp`'s `STUB_LMP_LOG`) is not recorded: the recorder is not called, and a
  `NOTE: not recorded:` line says why, while the job still ends with exit 0 and its results block;
- with the optional DynamoDB block uncommented as `dynamodb/README.md` says (in a copy of the script that differs in
  that block alone, and a stub in place of `record_to_dynamodb.sh`), a run that ends as asked is recorded once by
  each recorder, and none of those three runs by either;
- `TIMESTEPS` and `SCALE` override the defaults, alone and together (the recorder gets the `TIMESTEPS` run), and
  `MODEL=rhodo` keeps its 32,000 atoms whatever `SCALE` is (`in.rhodo` has no `replicate` command): with `SCALE=4`
  its results, its record, its run directory's name and `lmp`'s `-var x`, `y` and `z` give scale 1, and a `NOTE:` on
  stderr says so, which neither its default nor `SCALE=1` prints;
- a `TIMESTEPS` that is not a whole number from 1 to 10,000,000 (`0`, `-5`, `abc`, `1e4`, `10.5`, `1 000`, `007`,
  `10000001`, a 20-digit number) stops the job with an `ERROR:` line before any launch, and `10000000` runs;
- a cached deck without exactly one plain `run <steps>` line (none, two, `run 100 post no`, `run ${t}`,
  `run ${nsteps}`) stops the job before any launch, with an `ERROR:` line that gives the number of run lines or the one
  run line, and is left as it was;
- a plain run line with another step count and tabs (`run 250`) is replaced, its whitespace kept.

For the x86 script it also checks the rank placement, with the stub IMDS answering the instance type the test sets:

- on `hpc8a.96xlarge` and `hpc7a.96xlarge`, 48 and 96 ranks per node get the flexible-cores lists, and a full node and
  a hybrid layout (48 ranks x 2 threads) their usual mapping;
- there, 16, 32, 64, 128 or 384 cores per node, pure MPI or hybrid, stop the job before the run directory is made,
  with an `ERROR:` line that names the supported counts;
- other instance types and sizes (`hpc6a.48xlarge`, `hpc7a.48xlarge`, `c7a.48xlarge`) get no list at any count, so 48
  ranks on a 96-core node name no core above 95;
- when the stub IMDS gives no instance type (no answer, as a call past its timeout; an HTTP error; an answer that is
  not an instance type name, also one that holds a type name inside other text, or one in capitals), a stub `lscpu`
  describes the node. On a 192-core AMD node, 64 cores per node stop the job before the run directory is made, with an
  `ERROR:` line on stderr that names the supported counts, and 96 get the flexible-cores list. On any other node (a
  192-core Intel node, a 96-core AMD node with or without SMT, so with 96 or 192 CPUs, one with 96 cores on one
  socket, one with 2 x 128 cores, or one where `lscpu` fails) the job runs, mapped by slot. Either way a `NOTE:` line
  on stderr says which, and both layouts of `lscpu`'s output (flat, and indented as newer util-linux prints it) are
  read. A full node, and a hybrid layout at a supported count, run as on any type, with no `lscpu` call and no
  `NOTE:`;
- every IMDS call has a connect timeout and a total timeout of a few seconds, and when IMDS gives the instance type
  (`hpc8a.96xlarge`, `c7a.48xlarge` on a 192-core AMD CPU, or `c8i.96xlarge` in a Turkish locale, where `[a-z]`
  leaves out `i`), no `NOTE:` is printed and `lscpu` is not run.

The property tests in [`tests/test_lammps_properties.py`](../../../tests/test_lammps_properties.py) (run with
`pytest tests`) also run the scripts' own `set_run_length` on generated decks.

## Adding a case

Add an assertion to `test-sbatch-e2e.sh`, or a new `test-*.sh`: `run-tests.sh` picks up any `test-*.sh` and also runs
`bash -n` over the LAMMPS scripts, the recorders and the tests.
