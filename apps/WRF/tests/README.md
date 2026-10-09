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
line of `rsl.error.0000`. WRF counts each history or restart write, and each
lateral-boundary read, in the `Timing for main` line of the step that makes it,
so the average includes I/O that does not get faster with more nodes.
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

## Adding a case

Drop an `.rsl` fixture in `fixtures/` and add an assertion to the relevant
`test-*.sh`. `run-tests.sh` picks up any `test-*.sh` automatically and also runs
`bash -n` over the WRF scripts, the library, the recorder and the tests.
