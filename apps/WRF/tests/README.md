# WRF shell tests

Run everything:

```bash
apps/WRF/tests/run-tests.sh
```

No Slurm, no EC2, no WRF, no MPI, no AWS credentials and no network access
are required: every case is driven from a checked-in `rsl.error.0000` fixture
or one the test writes itself. Every time in them is synthetic.

## What is covered and why

The benchmark scripts report `AVG_STEP`, the mean of every `Timing for main`
line of `rsl.error.0000`, each step's time being the number before
`elapsed seconds` on its line. WRF counts each history or restart write, and
each lateral-boundary read, in the `Timing for main` line of the step that
makes it, so the average includes I/O that does not get faster in proportion to
the node count.
`lib/wrf-step-timing.sh` computes two values that leave it out: the median of
every step, and the steady step, the mean of every step but the first and
those that follow a `Timing for Writing` line (history, restart) or a
`Timing for processing` line (lateral boundaries, wrfinput). The rule assumes
a single domain, and WRF prints no timing line for auxiliary input streams
(`auxinput*`, such as SST updates), so steps that read them are not left out.

| Fixture | Represents | Median | Steady |
|---|---|---|---|
| `hourly-history.rsl` | 12 steps, a history write before the first step of every synthetic hour and one after the last step | 1.15000 | 1.11111 |
| `restart-write.rsl` | a restart write alone, then a history and a restart write before the same step (8 steps: an even count) | 2.10000 | 2.00000 |
| `lateral-boundary.rsl` | a lateral-boundary read in the middle of the run | 3.05000 | 3.00000 |
| `adaptive-dt.rsl` | 8 steps labelled `main (dt= ...)`, as with an adaptive time step (one of them `(dt=100.00)`), and a history write in the middle; average 2.10 | 1.20000 | 1.13333 |
| `no-steps.rsl` | a run that stopped before its first step | N/A | N/A |

`test-step-timing.sh` asserts those values, with the arithmetic in its
comments, and that a missing file gives N/A. It also writes small cases of its
own: one step (a median, no steady step), every step after the first following
I/O, steps that sort differently as text and as numbers, an adaptive-time-step
run (`main (dt= 15.00): ...`, where the time is not the 9th field), an empty
file, no argument, a directory, an unreadable file (skipped as root), and a
comma-decimal locale with `POSIXLY_CORRECT` set, which makes gawk read
`1.15000` as 1 unless the helper runs awk in the C locale (skipped when no such
locale is installed). Finally it pins the contract the scripts rely on: under
`set -euo pipefail` both functions print one value and never stop the caller,
and sourcing the library defines its two functions and changes no shell option.

`tests/test_wrf_step_timing.py`, at the repository root (`pytest tests`), adds
property tests with Hypothesis: the helper against a reference on generated
logs, and every benchmark script's own `AVG_STEP` pipeline on generated steps
with a fixed and an adaptive time step. It also runs this suite.

`test-sbatch-e2e.sh` runs **every benchmark script itself**
(`x86/wrf-benchmark*.sbatch` and `Arm/wrf-benchmark.sbatch`), with `curl`,
`scontrol`, `srun`, `mpirun`, `sudo`, `aws` and `wrf.exe` replaced by stubs, so
the assembled script really executes. The stubs touch nothing on the host: the
cache drops and THP settings are swallowed, and the `aws` stub refuses every
call. The `wrf.exe` stub leaves a fixture as `rsl.error.0000`, and the output
files its log says WRF wrote (or none, empty ones, or no restart file, as a
case asks). For each script it asserts:

  * the average step is unchanged, and the report gives `Median timestep:` and
    `Steady timestep:` right after `Avg timestep:` (the x86 scripts also print
    both next to their average in the checking section);
  * with an adaptive time step (`adaptive-dt.rsl`), the average reads each
    step's time before `elapsed seconds`, which is not the 9th field there, in
    the report, the x86 checking section and the recorder's arguments;
  * the recorder gets `median_timestep_seconds` and `steady_timestep_seconds`
    next to `avg_timestep_seconds`, and this repository's recorder, run in
    `--dry-run`, would store them as two new numeric attributes of a valid
    item; an N/A value is skipped with a warning, as the average already is;
  * the library is found when the job is submitted from the script's
    directory, from `apps/WRF` or from the repository root, and through
    `WRF_STEP_TIMING_LIB` from anywhere else; the variable takes precedence
    over a copy in the submit directory;
  * the CONUS 2.5km scripts give WRF `CONUS_DIR`'s `namelist.input` with
    `io_form_history` and `io_form_restart` changed from 2 to 11 and nothing
    else, and leave `CONUS_DIR` as it is, or the namelist as it is with
    `WRF_OUTPUT_FORMAT=namelist`; a namelist that does not take exactly that
    change (no `io_form` lines, both at 11 already, `io_form_history` alone at
    2, `io_form_restart` at 102, or `io_form_history` set twice) stops the job
    before `wrf.exe`, an unknown value of the variable stops it before the run
    directory, and neither is recorded; the other scripts give WRF the namelist
    as it is;
  * without the library the job still completes, prints a NOTE saying how to
    point at it, and gives N/A for both;
  * without `rsl.error.0000` all three values are N/A and the job completes,
    as before, but the run is not recorded and a NOTE says why;
  * with no step line the job stops where it did before (the existing
    `grep "Timing for main" | tail -5` under `pipefail`), with no report and
    no benchmark row;
  * a run is recorded only when the run check passes: without
    `SUCCESS COMPLETE WRF` (`no-success.rsl`, a run that stopped before the end
    of its forecast), with a history file missing or empty, or with fewer
    restart files than restart writes, the job completes as before, prints a
    NOTE that names the problem and records nothing; with two problems, one
    NOTE names both, joined with `; `. The check is found like the step-timing
    library (a run submitted from the script's directory, from `apps/WRF` or
    from the repository root is recorded), `WRF_RUN_CHECK_LIB` takes
    precedence, and without it nothing is recorded and a NOTE says how to point
    at it.

`test-run-check.sh` tests `lib/wrf-run-check.sh`, the check the benchmark
scripts run before they record a run, on run directories it writes itself. A
complete run passes, silently, and so does a run that writes no output. It is
refused when `rsl.error.0000` is missing, unreadable or does not say
`SUCCESS COMPLETE WRF`; when a history file WRF wrote is missing, empty or a
directory; when there are fewer restart files than restart writes, or an empty
one; when history was written but there is no `namelist.input`, or its
`frames_per_outfile` cannot be read: not a positive number, set on two lines,
or named in a form the check does not read (after another setting on its line,
with a subscript, with its value on the next line, or a null value for domain 1,
`3* 1`), none of which is taken for WRF's default. The tests check which files
`frames_per_outfile` puts the writes in (WRF's default of 10 only when no line
names the key; the domain-1 value when the key is in capitals and the line has
a value per domain, also in a Turkish locale, `tr_TR.UTF-8`, where awk
lowercases `I` to a dotless `ı` outside the C locale (skipped when that locale
is not installed), when a comment follows the value with no comma, when a
blank separates the values, and in a repeat count, `3*1`; a commented-out line
is not read), that domain 2 is ignored, that every problem is listed, one per
line, and the contract the scripts rely on: called in an `if` under
`set -euo pipefail` it never stops the caller, and sourcing it defines one
function, changes no shell option and leaves no variable behind.
`tests/test_wrf_run_check.py` (`pytest tests`) checks it against a reference on
run directories generated by Hypothesis, with `frames_per_outfile` in forms it
reads and forms it refuses.

## Adding a case

Drop an `.rsl` fixture in `fixtures/` and add an assertion to the relevant
`test-*.sh`. `run-tests.sh` picks up any `test-*.sh` automatically and also runs
`bash -n` over the WRF scripts, the libraries, the recorder and the tests.
