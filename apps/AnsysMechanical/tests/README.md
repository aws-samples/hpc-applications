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
| `normal-success.log` | clean completion, `Memory Option: In-Core`, with the out-of-core memory requirement every sparse-direct run also prints |
| `benign-iteration-stop.log` | the expected fixed-iteration termination, `Memory Option: Optimal Out-of-Core` |
| `iterative-pcg.log` | an iterative (PCG) completion, which prints no `Memory Option:` line |
| `disk-full-abort.log` | an I/O error on a full disk, followed by `RUN COMPLETED` and a positive elapsed time, in MAPDL 2026 R1's format (path replaced) |
| `genuine-error-column-zero.log` | a real error at column zero, with `RUN COMPLETED` also present |
| `genuine-error-deep-indent.log` | a real error indented far from column one |
| `benign-plus-genuine-error.log` | the benign stop *and* a real error in one log |
| `truncated-no-completion.log` | output that stops mid-run |
| `zero-elapsed.log` | `Elapsed Time (sec) = 0.000` |
| `negative-elapsed.log` | `Elapsed Time (sec) = -5.000` |
| `benign-block-with-extra-failure.log` | the expected termination text **plus** a second genuine failure in the *same* block |
| `benign-block-observed-wording-with-extra-failure.log` | the same trap using the wording our own runs produce |
| `benign-malformed-possessive.log` | `userXs request` — catches a `user.?s` pattern treating `.?` as any character |
| `scratch-hpc6id-findmnt.txt`, `scratch-hpc6id-lsblk.txt`, `scratch-hpc6id-df.txt` | what a real hpc6id.32xlarge answered for `/scratch` to the NVMe scratch check's three queries (`findmnt -n -o SOURCE --mountpoint`, `lsblk -n -s -P -o TYPE,MODEL`, `df -Pk`): an LVM volume over four instance-store drives |

One more case is **generated at run time** rather than committed: a genuine benign
block carrying the trailing padding MAPDL really emits. `fixture-helpers.sh`
(`write_padded_benign_log`) builds it, because a committed file whose whole purpose
is trailing whitespace would be reported by `git diff --check` and silently gutted
by any editor or hook that trims it — leaving the test green but meaningless. The
generator asserts the padding survived.

`test-mapdl-verdict.sh` asserts the verdict and the resulting job exit status. Not
every fixture is run against every status — the cases are chosen per boundary:

  * the benign fixture across `{0, 1, 255}` (accepted) and `{2, 42, 137}`
    (rejected, status preserved), which pins normalisation to the statuses the
    fixed-iteration stop actually produces;
  * genuine-error fixtures at `2` and at `0`, covering both a preserved status and
    a synthesised one;
  * the clean fixture at `42`, covering an unrelated failure that must not be
    masked;
  * an invariant check that sweeps **eight selected fixtures** across
    `{0, 1, 2, 42, 255}`: `solve_ok=1` must never coexist with a non-zero final
    status, since that pairing is what would let a failed job record a benchmark
    row.

It also covers stage-out (successful copy, byte-identical copy, already-shared
path, empty source, missing source, unwritable destination), and a
**cross-classifier consistency check**: MAPDL error blocks are classified by two
production implementations — the authoritative `lib/mapdl-verdict.sh` and the
compact copy inside `dynamodb/record-benchmark.sh`, which stays self-contained by
design. The test extracts the recorder's real function and asserts both report the
same unexpected-block count for **every** fixture, so the two cannot drift into
accepting a run live that replay rejects.

`test-recorder.sh` exercises `dynamodb/record-benchmark.sh` in `--dry-run`:
replay discovery of `output.log`, `output-<jobid>.log` and `*.out`; rejection of
zero, negative and non-numeric timings whether explicit or derived; refusal to
derive timing from an unverified solve; explicit values winning over derived ones;
the emitted item being valid JSON carrying the canonical attributes; and the
**no-derive contract for `cores_per_node`** — it is omitted when `task_placement`
is supplied and when the core count is not an exact multiple of the node count,
derived only for a genuinely uniform layout, and never overridden when passed
explicitly.

`test-sbatch-e2e.sh` runs **`AnsysMechanical.sbatch` itself**, with `scontrol`,
`srun`, `mpirun`, `module`, `curl`, `sudo`, `mapdl` and the scratch check's
`findmnt`, `lsblk`, `df` and `hostname` replaced by stubs, so the assembled script
really executes rather than only passing `bash -n`. It asserts:

  * the job's final exit status per fixture (a fixed-iteration deck exits 0; a
    truncated `rc=0` run exits non-zero; a disk-full abort keeps its 255);
  * the memory mode handed to the recorder is the one on MAPDL's `Memory Option:`
    line;
  * **recorder eligibility** — a run that exits non-zero writes no benchmark row,
    including the subtle `clean output + rc=42` and `benign block + rc=42` cases;
  * `-machines` is built from `SLURM_TASKS_PER_NODE` and totals `SLURM_NPROCS`;
  * a placement Slurm cannot describe (unset or unparseable `SLURM_TASKS_PER_NODE`)
    aborts rather than being invented;
  * a heterogeneous `43,42` allocation records `task_placement`, not a uniform
    `cores_per_node` — asserted twice: once on the launcher's arguments via the
    recorder stub, and once on the **production recorder's emitted JSON** (via a
    wrapper that runs the real script in `--dry-run`), because the recorder derives
    fields of its own and arguments alone do not prove what would be stored;
  * **NVMe stage-out failure at the integration boundary** — with the shared
    filesystem made read-only mid-solve, the job fails, the reclaim step does not
    run, the retained scratch path is printed, the log survives on scratch, and no
    row is recorded; a healthy control run reclaims scratch and does record;
  * a missing verdict library aborts before any solver time is spent.

The NVMe cases use `SCRATCH_ROOT` to point at a temporary directory, which stubbed
`findmnt`, `lsblk` and `df` describe as the hpc6id fixtures' `/scratch`, so it passes
the scratch check. They skip when running as root (the failure is simulated with
directory permissions).

`test-nvme-scratch.sh` runs the assembled sbatch on emulated nodes to pin the **NVMe
scratch check**: `srun` runs each per-node step once per node, and `hostname`,
`findmnt`, `lsblk` and `df` answer from that node's fixture, in the formats
util-linux 2.37 and GNU coreutils 8.32 print on Amazon Linux 2023. It asserts:

  * NVMe is used only when every node passes: the hpc6id fixtures pass, on one node
    and on four, and the job records `scratch_mode=nvme`;
  * any one failing node sends the job to the shared filesystem, with that node's
    reason in the log and `scratch_mode=shared` recorded: a plain directory on the
    root volume, an EBS volume, a volume over an instance-store drive and an EBS
    volume, tmpfs, NFS, too little space (299 GiB free against 300), a `df` that
    fails or answers a number the shell cannot hold, a `SCRATCH_ROOT` that does not
    exist or that the job user cannot write;
  * a node that does not answer, and a second answer from one host name, cannot
    stand in for a node;
  * with two mounts at `SCRATCH_ROOT`, the one on top decides;
  * `SCRATCH_MIN_FREE_GIB` is honoured from 1 to 9999999, defaults to 300 when unset
    or empty, and anything else (0 in any spelling, 8 digits or more, a unit, a sign,
    a fraction, a space) ends the job before any node work, in `shared` mode too;
    the probe itself answers no to a minimum it cannot compare;
  * `SCRATCH_MODE=nvme` falls back with the same warning as before, `auto` falls back
    without one, and `shared` never checks.

## Adding a case

Drop a `.log` fixture in `fixtures/` and add an assertion to the relevant
`test-*.sh`. `run-tests.sh` picks up any `test-*.sh` automatically and also runs
`bash -n` over the sbatch, the library and the recorder.
