# AnsysMechanical shell tests

Run everything:

```bash
apps/AnsysMechanical/tests/run-tests.sh
```

No Slurm, no EC2, no licensed solver, no AWS credentials and no network access
are required — every case is driven from a checked-in log fixture.

## What is covered and why

The success/failure boundary for MAPDL benchmark runs is genuinely subtle: some
official decks stop at a fixed iteration count and exit **non-zero after a
perfectly good run**, while a truncated or killed run can exit **zero**. Both
naive readings of that produce silent, opposite-direction bugs — a valid
benchmark discarded, or a failed run recorded as a result. These tests pin the
boundary.

| Fixture | Represents |
|---|---|
| `normal-success.log` | clean completion, In-Core |
| `benign-iteration-stop.log` | the expected fixed-iteration termination, Out-of-Core |
| `genuine-error-column-zero.log` | a real error at column zero, with `RUN COMPLETED` also present |
| `genuine-error-deep-indent.log` | a real error indented far from column one |
| `benign-plus-genuine-error.log` | the benign stop *and* a real error in one log |
| `truncated-no-completion.log` | output that stops mid-run |
| `zero-elapsed.log` | `Elapsed Time (sec) = 0.000` |
| `negative-elapsed.log` | `Elapsed Time (sec) = -5.000` |

`test-mapdl-verdict.sh` asserts the verdict and the resulting job exit status for
each fixture across solver exit codes 0, 1, 2 and 42, plus stage-out behaviour
(successful copy, byte-identical copy, already-shared path, empty source, missing
source, unwritable destination).

`test-recorder.sh` exercises `dynamodb/record-benchmark.sh` in `--dry-run`:
replay discovery of `output.log`, `output-<jobid>.log` and `*.out`; rejection of
zero, negative and non-numeric timings whether explicit or derived; refusal to
derive timing from an unverified solve; explicit values winning over derived ones;
and the emitted item being valid JSON carrying the canonical attributes.

`test-sbatch-e2e.sh` runs **`AnsysMechanical.sbatch` itself**, with `scontrol`,
`srun`, `mpirun`, `module`, `curl`, `sudo` and `mapdl` replaced by stubs, so the
assembled script really executes rather than only passing `bash -n`. It asserts
the job's final exit status for each fixture (including that a fixed-iteration
deck exits 0 while a truncated `rc=0` run exits non-zero), that a failed run does
not record a benchmark row, that `-machines` is built from `SLURM_TASKS_PER_NODE`
and totals `SLURM_NPROCS`, that the recorder receives the expected metadata, and
that a missing verdict library aborts before any solver time is spent.

## Adding a case

Drop a `.log` fixture in `fixtures/` and add an assertion to the relevant
`test-*.sh`. `run-tests.sh` picks up any `test-*.sh` automatically and also runs
`bash -n` over the sbatch, the library and the recorder.
