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
`Arm/lammps-benchmark.sbatch`), with `curl`, `scontrol`, `srun`, `sudo`, `fi_info`, `mpirun` and `lmp` replaced by
stubs, so the assembled script really executes. The stub `lmp` runs as many steps as the deck's run line asks for, with
`${name}` taken from `-var name`, as LAMMPS does. For each script it asserts:

- for each model (`lj`, `rhodo`, `rhodo_scaled`, `eam`), with no override: `lmp` gets the model's default `SCALE` and
  `-var nsteps` with its default run length, and no `-var t`; the run directory's deck differs from the cached one in
  its run line only, and the cached deck is unchanged; the results block gives the run length, the atom count and the
  scale; the job log says how the run length is set; the recorder gets the model, its scale and the run length;
  nothing is downloaded;
- `TIMESTEPS` and `SCALE` override the defaults, alone and together (the recorder gets the `TIMESTEPS` run), and
  `MODEL=rhodo` keeps its 32,000 atoms whatever `SCALE` is (`in.rhodo` has no `replicate` command);
- a `TIMESTEPS` that is not a whole number from 1 to 10,000,000 (`0`, `-5`, `abc`, `1e4`, `10.5`, `1 000`, `007`,
  `10000001`, a 20-digit number) stops the job with an `ERROR:` line before any launch, and `10000000` runs;
- a cached deck without exactly one plain `run <steps>` line (none, two, `run 100 post no`, `run ${t}`,
  `run ${nsteps}`) stops the job before any launch, with an `ERROR:` line that gives the number of run lines or the one
  run line, and is left as it was;
- a plain run line with another step count and tabs (`run 250`) is replaced, its whitespace kept.

The property tests in [`tests/test_lammps_properties.py`](../../../tests/test_lammps_properties.py) (run with
`pytest tests`) also run the scripts' own `set_run_length` on generated decks.

## Adding a case

Add an assertion to `test-sbatch-e2e.sh`, or a new `test-*.sh`: `run-tests.sh` picks up any `test-*.sh` and also runs
`bash -n` over the LAMMPS scripts, the recorders and the tests.
