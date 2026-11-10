#!/bin/bash
# =============================================================================
# The recorder, dynamodb/record-benchmark.sh, reads the 2026 R1 harness's
# fields (MIUPS, the mesh's cell count, the case and data read times, the case
# and the method) only from the harness's transcript of the case and core
# count. A run directory can hold other transcripts: Fluent's own session
# transcript, fluent-<date>-<time>-<pid>.trn (for a case such as sedan_4m, the
# run directory's first .trn), fluentbench.pl's <case>-<cores>.trn, or a link
# to a dataset's file. Here Fluent's own transcript carries other values than
# the harness's (fixtures/steady-cell-count.trn), so the item shows which one
# the recorder read. See helpers-recorder.sh. In --dry-run:
#   * TRANSCRIPT, or --transcript, names the transcript: every such field comes
#     from it, the case from its name when none is given, and none from the
#     run directory's transcripts; a TRANSCRIPT that is not a readable file is
#     ignored, with a WARN, and then no transcript is read, not even the
#     harness's in the run directory;
#   * without it, the recorder reads the last <case>-<cores>.trn, of the case
#     and core count given, when they are, at the run directory's top level (as
#     with --run-dir at a working/<tag>/transcript/) or under its
#     working/<tag>/transcript/, that is a file, not a link, and prints the
#     harness's MIUPS line: with two working/<tag>/ whose transcripts both do,
#     the later, whose MIUPS, given as an older 2026 R1 script passes it, keeps
#     the count; never Fluent's own transcript (also when its process id is the
#     run's core count), fluentbench.pl's, a link, another case's or core
#     count's, another name (also when the core count is not a number), or a
#     .trn elsewhere in the run directory; with no such file, no field of the
#     harness's is recorded;
#   * the count goes with a TRANSCRIPT only with its own MIUPS: one that prints
#     no MIUPS gives no count, with a MIUPS given or none, and nor does one
#     whose MIUPS is not the one given; with a MIUPS given, the time is then on
#     the case's nominal size, with the NOTE;
#   * the solver mode is detected as before, when the run directory holds a
#     .trn;
#   * x86/Fluent-Benchmark.2026R1.sbatch and gpu/Fluent-Benchmark-GPU.sbatch
#     pass the transcript their check read as TRANSCRIPT (with two
#     working/<tag>/, the last one with the rating line, whose timed
#     iterations the CPU script passes too), and the item has its values, not
#     those of Fluent's own transcript;
#   * the classic benchmark scripts' items take no read time, MIUPS or count
#     from Fluent's own transcript, and the journal scripts' no field of the
#     harness's: their case is the case file's name.
#
#   apps/Fluent/tests/test-recorder-transcript.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-recorder.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-recorder.sh"
echo "The recorder: the harness's transcript, and no other"

# The run's other fields, but for its case, which each case gives or not: 25 iterations, 2 x hpc8a.96xlarge,
# 384 ranks.
RUN=(--num-iterations 25 --instance-type hpc8a.96xlarge --os "Amazon Linux 2023" --num-cores 384 --num-nodes 2
     --mpi intelmpi --version v261 --source TranscriptTest)
SESSION=fluent-20261026-120000-1000.trn   # the name the stubs give Fluent's own session transcript
TAG=working/10-26-2026=12-00-00           # the harness's working/<tag>/ in the stubs
LATER=working/10-26-2026=12-30-00         # a second working/<tag>/, which sorts after it (STUB_LATER_TRANSCRIPT's)
# Fluent's own session transcript of a 2026 R1 run, with other values than the harness's transcript, so that the
# item shows which one was read: 3,600,000 cells, 15.00 MIUPS, read times 9.999 and 8.888.
sed 's/^Cell count = 3500000$/Cell count = 3600000/; s/14\.00 MIUPS$/15.00 MIUPS/; s/2\.468 sec$/9.999 sec/
     s/1\.357 sec$/8.888 sec/' "${CELLS_TRN}" > "${WORK}/session-2026r1.trn"
# ... and of a classic run: no MIUPS, and the timer report that fluentbench.pl's journal ends with, at 0.000.
{
    sed '/Million Cell Iteration Per/d' "${WORK}/session-2026r1.trn"
    printf '%s\n' "Case File Timer for 0 input and 0 output on 384 compute nodes" \
        "  Average wall-clock time per case input:       0.000 sec" \
        "Data File Timer for 0 input and 0 output on 384 compute nodes" \
        "  Average wall-clock time per data input:       0.000 sec"
} > "${WORK}/session-classic.trn"

# harness <description>: the item has the values of the harness's transcript (3,500,000 cells, 14.00 MIUPS, read
# times 2.468 and 1.357), the 2026 R1 harness's method, and the case sedan_4m
harness() {
    exits0 "$1"
    is "$1" miups 14.00
    is "$1" mesh_cells 3500000
    is "$1" time_per_iteration_seconds 0.25
    is "$1" case_read_seconds 2.468
    is "$1" data_read_seconds 1.357
    is "$1" benchmark_method fluent_benchmark_harness
    is "$1" benchmark_case sedan_4m
}
# later <description>: the item has the values of the later of the harness's two transcripts (3,500,000 cells, 16.00
# MIUPS, read times 4.444 and 3.333), the count with them, and no NOTE
later() {
    exits0 "$1"
    is "$1" miups 16.00
    is "$1" mesh_cells 3500000
    is "$1" time_per_iteration_seconds 0.21875
    is "$1" case_read_seconds 4.444
    is "$1" data_read_seconds 3.333
    is "$1" benchmark_case sedan_4m
    notes "$1" 0
}
# no_harness <description>: the item has none of the fields that only the harness's transcript gives here
no_harness() {
    local f
    exits0 "$1"
    for f in miups mesh_cells case_read_seconds data_read_seconds time_per_iteration_seconds; do is "$1" "${f}" -; done
}
# fluent_own <name>: Fluent's own session transcript of a 2026 R1 run, in the run directory of case <name>, where
# the classic scripts' Fluent writes it (its top level, where it sorts before sedan_4m-384.trn) and where the 2026 R1
# harness's does
fluent_own() {
    trn "$1" "${WORK}/session-2026r1.trn" "${SESSION}"
    trn "$1" "${WORK}/session-2026r1.trn" "${TAG}/sedan_4m/${SESSION}"
}

# ---------------------------------------------------------------------------
# 1. TRANSCRIPT, or --transcript, names the transcript.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/given"
cp "${CELLS_TRN}" "${WORK}/given/sedan_4m-384.trn"
for name in given-env given-flag given-miups missing not-a-file; do fluent_own "${name}"; done
# The harness's transcript in the run directory too, which a TRANSCRIPT that names no readable file does not
# fall back to.
for name in missing not-a-file; do trn "${name}" "${CELLS_TRN}"; done
record given-env TRANSCRIPT="${WORK}/given/sedan_4m-384.trn"
harness "TRANSCRIPT, no case given"
record given-flag -- --transcript "${WORK}/given/sedan_4m-384.trn"
harness "--transcript, no case given"
record given-miups TRANSCRIPT="${WORK}/given/sedan_4m-384.trn" -- --case sedan_4m --miups 14.00
harness "TRANSCRIPT, the case and its MIUPS given, as the 2026 R1 scripts pass them"
# not_readable <name> <description> <path>: TRANSCRIPT=<path>, with Fluent's own transcript and the harness's in
# the run directory: neither is read
not_readable() {
    record "$1" TRANSCRIPT="$3" -- --case sedan_4m
    no_harness "$2"
    is "$2" benchmark_method -
    has_line "${ERR}" "WARN: ignoring TRANSCRIPT '$3': not a readable file, so no transcript is read." \
        && ok "$2: the WARN" || bad "$2: the WARN" "the WARN" "${ERR}"
}
not_readable missing "a TRANSCRIPT that does not exist" "${WORK}/given/no-such.trn"
not_readable not-a-file "a TRANSCRIPT that is a directory" "${WORK}/given"

# ---------------------------------------------------------------------------
# 2. Without it: the harness's transcript, not Fluent's own, which sorts first
#    here; with two working/<tag>/, the later; at the top level.
# ---------------------------------------------------------------------------
for name in fallback fallback-no-case; do
    fluent_own "${name}"
    trn "${name}" "${CELLS_TRN}"
done
record fallback -- --case sedan_4m
harness "the harness's transcript, and Fluent's own at the top level"
record fallback-no-case
harness "the same, no case given: the case from the harness's transcript's name"
# The harness run twice in one run directory: its transcript in two working/<tag>/, both rated, the later at 16.00
# MIUPS with read times 4.444 and 3.333. The 2026 R1 scripts check the later, and an older one passes its MIUPS: the
# recorder reads the later too, so that MIUPS goes with its count.
sed 's/^\(Million Cell Iteration Per Wall Second =\).*/\1    16.00 MIUPS/; s/2\.468 sec$/4.444 sec/
     s/1\.357 sec$/3.333 sec/' "${CELLS_TRN}" > "${WORK}/later-16.trn"
for name in two-tags two-tags-miups; do
    fluent_own "${name}"
    trn "${name}" "${CELLS_TRN}"
    trn "${name}" "${WORK}/later-16.trn" "${LATER}/transcript/sedan_4m-384.trn"
done
record two-tags -- --case sedan_4m
later "two working/<tag>/, both rated"
record two-tags-miups MIUPS=16.00 -- --case sedan_4m
later "two working/<tag>/, both rated, MIUPS 16.00 given (an older 2026 R1 script's)"
# --run-dir at working/<tag>/transcript/: the harness's transcript at the run directory's top level.
trn top-level "${CELLS_TRN}"
record top-level -- --case sedan_4m --run-dir "${WORK}/top-level/run/${TAG}/transcript"
harness "--run-dir at working/<tag>/transcript/: the transcript at its top level"

# ---------------------------------------------------------------------------
# 3. Only Fluent's own transcript, which has the harness's lines, as a 2026 R1
#    session's does: no field of the harness's.
# ---------------------------------------------------------------------------
fluent_own fluent-own-only
record fluent-own-only
no_harness "only Fluent's own transcript"
is "only Fluent's own transcript" benchmark_method -
is "only Fluent's own transcript" benchmark_case -
is "only Fluent's own transcript" solver_mode cpu

# ---------------------------------------------------------------------------
# 4. A classic run's directory: fluentbench.pl's output and transcript, and
#    Fluent's own transcript, with the case and the method the classic scripts
#    pass.
# ---------------------------------------------------------------------------
trn classic "${WORK}/session-classic.trn" "${SESSION}"
trn classic "${WORK}/session-classic.trn" sedan_4m-384.trn
cp "${FIX}/fluentbench-rated.out" "${WORK}/classic/run/sedan_4m-384.out"
record classic BENCHMARK_CASE=sedan_4m BENCHMARK_METHOD=fluentbench
exits0 "a classic run"
for f in miups mesh_cells case_read_seconds data_read_seconds; do is "a classic run" "${f}" -; done
is "a classic run" time_per_iteration_seconds 1.000
is "a classic run" solver_rating 3456.0
is "a classic run" benchmark_case sedan_4m
is "a classic run" benchmark_method fluentbench
is "a classic run" solver_mode cpu

# ---------------------------------------------------------------------------
# 5. Not the harness's transcript of the case and core count.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/dataset-trn" "${WORK}/link/run"
cp "${CELLS_TRN}" "${WORK}/dataset-trn/sedan_4m-384.trn"
ln -s "${WORK}/dataset-trn/sedan_4m-384.trn" "${WORK}/link/run/sedan_4m-384.trn"
record link -- --case sedan_4m
no_harness "a link at the top level, as the GPU script links a dataset's files"
trn other-cores "${CELLS_TRN}" "${TAG}/transcript/sedan_4m-192.trn"
record other-cores -- --case sedan_4m
no_harness "another core count's transcript"
trn other-case "${CELLS_TRN}" "${TAG}/transcript/aircraft_wing_14m-384.trn"
record other-case -- --case sedan_4m
no_harness "another case's transcript"
trn other-name "${CELLS_TRN}" "${TAG}/transcript/sedan_4m.trn"
record other-name
no_harness "a transcript named otherwise than <case>-<cores>.trn"
trn elsewhere "${CELLS_TRN}" "${TAG}/sedan_4m/sedan_4m-384.trn"
trn elsewhere "${CELLS_TRN}" bench/fluent/v6/sedan_4m/sedan_4m-384.trn
record elsewhere -- --case sedan_4m
no_harness "the harness's copy in working/<tag>/<case>/, and a dataset's .trn"
# Fluent's own transcript, named after a process id that is the run's core count, and no case given: its name
# alone keeps it out.
trn pid-384 "${WORK}/session-2026r1.trn" fluent-20261026-120000-384.trn
record pid-384
no_harness "Fluent's own transcript of process 384, at 384 cores, no case given"
# A core count that is not a number: any <case>-<N>.trn of the case, but no other name.
trn cores-text-other-name "${CELLS_TRN}" "${TAG}/transcript/sedan_4m.trn"
record cores-text-other-name -- --num-cores 384x
no_harness "--num-cores 384x, a transcript named otherwise than <case>-<cores>.trn"
trn cores-text "${CELLS_TRN}"
record cores-text -- --num-cores 384x
is "--num-cores 384x, the harness's transcript" miups 14.00
is "--num-cores 384x, the harness's transcript" mesh_cells 3500000
# TRANSCRIPT naming a transcript that prints no MIUPS (fluentbench.pl's, say), none given: no count goes with it.
sed '/Million Cell Iteration Per/d' "${CELLS_TRN}" > "${WORK}/given/no-miups-384.trn"
record given-no-miups TRANSCRIPT="${WORK}/given/no-miups-384.trn" -- --case sedan_4m
exits0 "TRANSCRIPT with no MIUPS line"
is "TRANSCRIPT with no MIUPS line" miups -
is "TRANSCRIPT with no MIUPS line" mesh_cells -
is "TRANSCRIPT with no MIUPS line" time_per_iteration_seconds -
# given_other <name> <transcript> <MIUPS given> <time> <description>: TRANSCRIPT and a MIUPS given that is not the
# transcript's own: no count goes with it, and the time is on the case's nominal size, with the NOTE
given_other() {
    record "$1" TRANSCRIPT="$2" -- --case sedan_4m --miups "$3"
    exits0 "$5"
    is "$5" mesh_cells -
    is "$5" time_per_iteration_seconds "$4"
    notes "$5" 1
}
given_other given-no-miups-given "${WORK}/given/no-miups-384.trn" 14.00 0.285714 \
    "TRANSCRIPT with no MIUPS line, MIUPS 14.00 given"
given_other given-other-miups "${WORK}/given/sedan_4m-384.trn" 14.01 0.28551 \
    "TRANSCRIPT printing 14.00, MIUPS 14.01 given"

# ---------------------------------------------------------------------------
# 6. The solver mode, as before.
# ---------------------------------------------------------------------------
fluent_own gpu-mode
touch "${WORK}/gpu-mode/run/${TAG}/sedan_4m/sedan_4m.gpu"
record gpu-mode
is "a .gpu file, and a .trn in the run directory" solver_mode gpu
record no-trn
is "no .trn in the run directory" solver_mode -

# ---------------------------------------------------------------------------
# 7. The 2026 R1 scripts pass the transcript their check read as TRANSCRIPT.
# ---------------------------------------------------------------------------
run_2026r1 cpu-stub
recorder_has "TRANSCRIPT=${WORKDIR}/${TAG}/transcript/sedan_4m-384.trn" \
    && ok "x86/Fluent-Benchmark.2026R1.sbatch: the recorder gets TRANSCRIPT, the transcript checked" \
    || bad "x86/Fluent-Benchmark.2026R1.sbatch: the recorder gets TRANSCRIPT, the transcript checked" \
           "TRANSCRIPT=${WORKDIR}/${TAG}/transcript/sedan_4m-384.trn" "$(grep TRANSCRIPT "${STATE}/recorder.log")"
run_2026r1 cpu-real STUB_TRANSCRIPT="${CELLS_TRN}" STUB_FLUENT_TRANSCRIPT="${WORK}/session-2026r1.trn" \
    DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
launcher_item
harness "x86/Fluent-Benchmark.2026R1.sbatch, Fluent's own transcript beside the harness's"
# Two working/<tag>/ (the harness run twice in one run directory): the transcript checked, and passed, is the last
# one with the rating line, whose rating and timed iterations the recorder gets. The unrated one timed 30.
sed '/^Million Cell Iteration Per Wall Second/,$d; s/=       25 iter$/=       30 iter/' "${CELLS_TRN}" \
    > "${WORK}/unrated.trn"
sed 's/^\(Million Cell Iteration Per Wall Second =\).*/\1    15.00 MIUPS/' "${CELLS_TRN}" > "${WORK}/rated-15.trn"
for c in "rated-unrated|${CELLS_TRN}|${WORK}/unrated.trn|${TAG}|14.00" \
         "unrated-rated|${WORK}/unrated.trn|${CELLS_TRN}|${LATER}|14.00" \
         "rated-rated|${CELLS_TRN}|${WORK}/rated-15.trn|${LATER}|15.00"; do
    IFS='|' read -r name first later where miups <<< "${c}"
    run_2026r1 "tags-${name}" STUB_TRANSCRIPT="${first}" STUB_LATER_TRANSCRIPT="${later}"
    if [ "$(recorder_calls)" = 1 ] && recorder_has "TRANSCRIPT=${WORKDIR}/${where}/transcript/sedan_4m-384.trn" \
            && recorder_has "MIUPS=${miups}" && recorder_has "ARG timed_iterations=25"; then
        ok "two working/<tag>/, ${name}: TRANSCRIPT the last one rated, ${where#working/}, MIUPS=${miups}, 25 timed"
    else
        bad "two working/<tag>/, ${name}: TRANSCRIPT the last one rated, its MIUPS and timed iterations" \
            "TRANSCRIPT=${WORKDIR}/${where}/transcript/sedan_4m-384.trn MIUPS=${miups} timed_iterations=25" \
            "$(recorder_calls) call(s): $(grep -E '^(TRANSCRIPT=|MIUPS=|ARG timed)' "${STATE}/recorder.log" 2>/dev/null | tr '\n' ' ')"
    fi
done
run_launcher "${GPU_BENCHMARK_SCRIPT}" gpu-stub
recorder_has "TRANSCRIPT=${WORKDIR}/${TAG}/transcript/sedan_4m-384.trn" \
    && ok "${GPU_BENCHMARK_SCRIPT}: the recorder gets TRANSCRIPT, the transcript checked" \
    || bad "${GPU_BENCHMARK_SCRIPT}: the recorder gets TRANSCRIPT, the transcript checked" \
           "TRANSCRIPT=${WORKDIR}/${TAG}/transcript/sedan_4m-384.trn" "$(grep TRANSCRIPT "${STATE}/recorder.log")"
run_launcher "${GPU_BENCHMARK_SCRIPT}" gpu-tags STUB_TRANSCRIPT="${WORK}/unrated.trn" STUB_LATER_TRANSCRIPT="${CELLS_TRN}"
if [ "$(recorder_calls)" = 1 ] && recorder_has "TRANSCRIPT=${WORKDIR}/${LATER}/transcript/sedan_4m-384.trn" \
        && recorder_has "MIUPS=14.00"; then
    ok "${GPU_BENCHMARK_SCRIPT}, two working/<tag>/, the later rated: TRANSCRIPT the later, and its MIUPS"
else
    bad "${GPU_BENCHMARK_SCRIPT}, two working/<tag>/, the later rated: TRANSCRIPT the later, and its MIUPS" \
        "TRANSCRIPT=${WORKDIR}/${LATER}/transcript/sedan_4m-384.trn MIUPS=14.00" \
        "$(recorder_calls) call(s): $(grep -E '^(TRANSCRIPT|MIUPS)=' "${STATE}/recorder.log" 2>/dev/null | tr '\n' ' ')"
fi
run_launcher "${GPU_BENCHMARK_SCRIPT}" gpu-real STUB_TRANSCRIPT="${CELLS_TRN}" \
    STUB_FLUENT_TRANSCRIPT="${WORK}/session-2026r1.trn" DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
launcher_item
harness "${GPU_BENCHMARK_SCRIPT}, Fluent's own transcript beside the harness's"

# ---------------------------------------------------------------------------
# 8. The classic benchmark scripts and the journal scripts, Fluent's own
#    transcript in their run directory.
# ---------------------------------------------------------------------------
for s in "${BENCHMARK_SCRIPTS[@]}"; do
    run_launcher "${s}" "classic-${s//\//-}" STUB_SESSION_TRN="${WORK}/session-classic.trn" \
        DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
    launcher_item
    for f in miups mesh_cells case_read_seconds data_read_seconds; do is "${s}" "${f}" -; done
    is "${s}" benchmark_case sedan_4m
    is "${s}" benchmark_method fluentbench
done
for s in "${JOURNAL_SCRIPTS[@]}"; do
    run_launcher "${s}" "journal-${s//\//-}" STUB_SESSION_TRN="${WORK}/session-2026r1.trn" \
        DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
    if [ -f "${WORKDIR}/${SESSION}" ]; then ok "${s}: Fluent's own transcript is in the run directory"
    else bad "${s}: Fluent's own transcript is in the run directory" "${SESSION}" "none"; fi
    launcher_item
    for f in miups mesh_cells case_read_seconds data_read_seconds benchmark_method; do is "${s}" "${f}" -; done
    is "${s}" benchmark_case model
done

summary "The recorder: the harness's transcript, and no other"
