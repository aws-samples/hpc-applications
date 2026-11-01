#!/bin/bash
# =============================================================================
# The recorder, dynamodb/record-benchmark.sh, times a run of the 2026 R1
# harness on the mesh's own cell count. The harness computes MIUPS on the
# count its transcript prints, "Cell count = N", which can differ from the
# size in the case's name: fixtures/steady-cell-count.trn is a synthetic
# transcript of sedan_4m (4 million cells by its name) whose mesh has
# 3,500,000 cells, at 14.00 MIUPS. See helpers-recorder.sh. The recorder runs
# in --dry-run, which prints the item it would store and writes nothing:
#   * the time per iteration is N / 1e6 / MIUPS, and N is recorded as
#     mesh_cells; num_cells_million stays the size in the case's name, and no
#     NOTE is printed;
#   * N is read from the transcript's file also when its path, relative, starts
#     with a name and "=" (a run directory named run=1), which awk would take
#     for an assignment if it were awk's argument, and never from the
#     recorder's standard input;
#   * only the lines that start with "Cell count =" give N, not the journal's
#     echo of that print or the partition table's row, and they must all give
#     the same positive integer, as Fluent prints one; otherwise, as with no
#     such line, there is no count, the time per iteration is
#     num_cells_million / MIUPS, and one NOTE says so;
#   * the count goes only with its transcript's own MIUPS, read from it or
#     given and equal to its line as a number (14, 14.00, 14.000): another
#     MIUPS given, another case's transcript, or a transcript with no MIUPS
#     line gives no count; MESH_CELLS in the environment is never the count;
#   * a time per iteration or to solution given by flag or environment is
#     recorded as given, next to the count;
#   * a mesh size that is not a number gives no time and no NOTE, and the
#     WARN that it is ignored;
#   * fluentbench.pl's output gives the time per iteration, the rating and the
#     speed as before, with no count and no NOTE, also when a transcript there
#     has a "Cell count =" line but no MIUPS;
#   * x86/Fluent-Benchmark.2026R1.sbatch and gpu/Fluent-Benchmark-GPU.sbatch,
#     with this recorder in --dry-run, store the count and the time on it;
#   * --help prints the header's lines, from its second line to its last, the
#     new field's lines among them, and no line of code.
#
#   apps/Fluent/tests/test-recorder-cell-count.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-recorder.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-recorder.sh"
echo "The recorder: the time per iteration on the mesh's own cell count"

# The run's other fields, so that none comes from the host: sedan_4m, 25 iterations, 2 x hpc8a.96xlarge, 384 ranks.
RUN=(--case sedan_4m --num-iterations 25 --instance-type hpc8a.96xlarge --os "Amazon Linux 2023" --num-cores 384
     --num-nodes 2 --mpi intelmpi --version v261 --source CellCountTest)

# on_nominal <description>: no count, the time on the case's name size (4 / 14.00), and one NOTE naming it
on_nominal() {
    exits0 "$1"
    is "$1" mesh_cells -
    is "$1" time_per_iteration_seconds 0.285714
    is "$1" time_to_solution_seconds 7.14285
    notes "$1" 1
    if grep -qF "on the case's nominal size (4 million cells)." <<< "${ERR}"; then ok "$1: the NOTE names the size"
    else bad "$1: the NOTE names the size" "(4 million cells)" "${ERR}"; fi
}
# on_count <description>: the count, and the time on it (3,500,000 cells at 14.00 MIUPS), with no NOTE
on_count() {
    exits0 "$1"
    is "$1" mesh_cells 3500000
    is "$1" time_per_iteration_seconds 0.25
    is "$1" time_to_solution_seconds 6.25
    notes "$1" 0
}

# ---------------------------------------------------------------------------
# 1. The harness's transcript: the count, the time on it, the case's size kept.
# ---------------------------------------------------------------------------
trn count "${CELLS_TRN}"
record count
on_count "the harness's transcript"
is "the harness's transcript" miups 14.00
is "the harness's transcript" num_cells_million 4
is "the harness's transcript" case_read_seconds 2.468
# A relative run directory named run=1, and on the recorder's standard input a line that would give another count.
mkdir -p "${WORK}/run-equals/run=1/working/10-26-2026=12-00-00/transcript"
cp "${CELLS_TRN}" "${WORK}/run-equals/run=1/working/10-26-2026=12-00-00/transcript/sedan_4m-384.trn"
printf '%s\n' "Cell count = 999" > "${WORK}/stdin-count.txt"
record run-equals -- --run-dir run=1 < "${WORK}/stdin-count.txt"
on_count "--run-dir run=1, relative, with \"Cell count = 999\" on standard input"

# ---------------------------------------------------------------------------
# 2. Every "Cell count =" line must give the same number.
# ---------------------------------------------------------------------------
sed 's/^\(Cell count = 3500000\)$/\1\n\1  /' "${CELLS_TRN}" > "${WORK}/agree.trn"
trn agree "${WORK}/agree.trn"
record agree
on_count "two lines that agree, one with trailing spaces"
sed 's/^\(Cell count = 3500000\)$/\1\nCell count = 3500001/' "${CELLS_TRN}" > "${WORK}/disagree.trn"
trn disagree "${WORK}/disagree.trn"
record disagree
on_nominal "two lines that disagree"

# ---------------------------------------------------------------------------
# 3. No "Cell count =" line: the journal's echo of the print and the partition
#    table's row are left, and give no count.
# ---------------------------------------------------------------------------
sed '/^Cell count = /d' "${CELLS_TRN}" > "${WORK}/no-count.trn"
if grep -qF '(format #t "~%Cell count = ~a" number-of-cells)' "${WORK}/no-count.trn" \
        && grep -q '^   Cell count  .* 3500000$' "${WORK}/no-count.trn"; then
    ok "the cut transcript keeps the journal's echo and the partition table's row"
else
    bad "the cut transcript keeps the journal's echo and the partition table's row" "both" "$(grep 'Cell count' "${WORK}/no-count.trn")"
fi
trn no-count "${WORK}/no-count.trn"
record no-count
on_nominal "no \"Cell count =\" line"

# ---------------------------------------------------------------------------
# 4. A count that is not a positive integer, as Fluent prints one.
# ---------------------------------------------------------------------------
i=0
for v in 0 -3500000 3500000.0 3.5e6 3,500,000 03500000 "3500000 cells" ""; do
    i=$((i + 1))
    sed "s/^Cell count = 3500000\$/Cell count = ${v}/" "${CELLS_TRN}" > "${WORK}/count-${i}.trn"
    trn "count-${i}" "${WORK}/count-${i}.trn"
    record "count-${i}"
    on_nominal "\"Cell count = ${v}\""
done
sed 's/^\(Cell count = 3500000\)$/\1\nCell count = n\/a/' "${CELLS_TRN}" > "${WORK}/count-na.trn"
trn count-na "${WORK}/count-na.trn"
record count-na
on_nominal "a count, then \"Cell count = n/a\""

# ---------------------------------------------------------------------------
# 5. A time given by flag or environment is recorded as given, next to the count.
# ---------------------------------------------------------------------------
for c in "time-flag -- --time-per-iteration 0.9" "time-env TIME_PER_ITERATION=0.9"; do
    read -r name rest <<< "${c}"
    trn "${name}" "${CELLS_TRN}"
    # shellcheck disable=SC2086  # the words of the case's settings
    record "${name}" ${rest}
    exits0 "${name}"
    is "${name}" time_per_iteration_seconds 0.9
    is "${name}" time_to_solution_seconds 22.5
    is "${name}" mesh_cells 3500000
    notes "${name}" 0
done
trn total-flag "${CELLS_TRN}"
record total-flag -- --time-to-solution 30
exits0 "total-flag"
is "--time-to-solution 30" time_to_solution_seconds 30
is "--time-to-solution 30" time_per_iteration_seconds 0.25
is "--time-to-solution 30" mesh_cells 3500000

# ---------------------------------------------------------------------------
# 6. The count goes only with its transcript's own MIUPS.
# ---------------------------------------------------------------------------
# 6a. A replay with its MIUPS given, from a directory that holds another case's
#     transcript, at another MIUPS: that transcript's count is not the run's.
sed 's/^\(Million Cell Iteration Per Wall Second =\).*/\1    30.00 MIUPS/; s/= 3500000$/= 14400000/' \
    "${CELLS_TRN}" > "${WORK}/other-case.trn"
for c in "other-case-flag -- --miups 20" "other-case-env MIUPS=20"; do
    read -r name rest <<< "${c}"
    trn "${name}" "${WORK}/other-case.trn" working/10-26-2026=12-00-00/transcript/aircraft_wing_14m-384.trn
    # shellcheck disable=SC2086  # the words of the case's settings
    record "${name}" ${rest}
    exits0 "${name}"
    is "another case's transcript (${rest})" mesh_cells -
    is "another case's transcript (${rest})" miups 20
    is "another case's transcript (${rest})" time_per_iteration_seconds 0.2
    notes "another case's transcript (${rest})" 1
done
# 6b. The transcript's own MIUPS given, also written with other digits.
for c in "own-14.00 -- --miups 14.00" "own-14 -- --miups 14" "own-14.000 -- --miups 14.000" "own-env MIUPS=14.00"; do
    read -r name rest <<< "${c}"
    trn "${name}" "${CELLS_TRN}"
    # shellcheck disable=SC2086  # the words of the case's settings
    record "${name}" ${rest}
    on_count "the transcript's own MIUPS given (${rest})"
done
# 6c. Another MIUPS given, with the run's transcript.
trn own-other "${CELLS_TRN}"
record own-other -- --miups 14.01
exits0 "own-other"
is "MIUPS 14.01 given, the transcript printing 14.00" mesh_cells -
is "MIUPS 14.01 given, the transcript printing 14.00" time_per_iteration_seconds 0.28551
notes "MIUPS 14.01 given, the transcript printing 14.00" 1
# 6d. A transcript with no MIUPS line (not even the journal's command for it).
sed '/Million Cell Iteration Per Wall Second/d' "${CELLS_TRN}" > "${WORK}/no-miups.trn"
trn no-miups-given "${WORK}/no-miups.trn"
record no-miups-given -- --miups 14.00
on_nominal "no MIUPS line, MIUPS 14.00 given"
trn no-miups "${WORK}/no-miups.trn"
record no-miups
exits0 "no-miups"
is "no MIUPS line, none given" mesh_cells -
is "no MIUPS line, none given" time_per_iteration_seconds -
notes "no MIUPS line, none given" 0
# 6e. MESH_CELLS in the environment.
record stray-none MESH_CELLS=99999999 -- --miups 14.00
on_nominal "MESH_CELLS=99999999, no transcript"
trn stray-own "${CELLS_TRN}"
record stray-own MESH_CELLS=99999999
on_count "MESH_CELLS=99999999, the run's transcript"

# ---------------------------------------------------------------------------
# 7. A mesh size that is not a number, and no transcript: no time, no NOTE.
# ---------------------------------------------------------------------------
record size-abc -- --miups 17.41 --num-cells-million abc
exits0 "size-abc"
is "--num-cells-million abc" time_per_iteration_seconds -
is "--num-cells-million abc" num_cells_million -
notes "--num-cells-million abc" 0
has_line "${ERR}" "WARN: ignoring non-numeric value for 'num_cells_million': 'abc'" \
    && ok "--num-cells-million abc: the WARN that it is ignored" \
    || bad "--num-cells-million abc: the WARN that it is ignored" "the WARN" "${ERR}"

# ---------------------------------------------------------------------------
# 8. fluentbench.pl's output: as before.
# ---------------------------------------------------------------------------
for name in classic classic-trn; do
    mkdir -p "${WORK}/${name}/run"
    cp "${FIX}/fluentbench-rated.out" "${WORK}/${name}/run/sedan_4m-384.out"
done
# A transcript as fluentbench.pl writes one, <case>-<cores>.trn, with a "Cell count =" line and no MIUPS.
sed '/Million Cell Iteration Per/d' "${CELLS_TRN}" > "${WORK}/classic.trn"
trn classic-trn "${WORK}/classic.trn" sedan_4m-384.trn
for name in classic classic-trn; do
    record "${name}" BENCHMARK_METHOD=fluentbench
    exits0 "${name}"
    is "${name}" time_per_iteration_seconds 1.000
    is "${name}" time_to_solution_seconds 25
    is "${name}" solver_rating 3456.0
    is "${name}" solver_speed 86400.0
    is "${name}" benchmark_method fluentbench
    is "${name}" mesh_cells -
    is "${name}" miups -
    notes "${name}" 0
done

# ---------------------------------------------------------------------------
# 9. The 2026 R1 launch scripts, with this recorder in --dry-run.
# ---------------------------------------------------------------------------
run_2026r1 launcher-cpu STUB_TRANSCRIPT="${CELLS_TRN}" DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
launcher_item
is "x86/Fluent-Benchmark.2026R1.sbatch" mesh_cells 3500000
is "x86/Fluent-Benchmark.2026R1.sbatch" miups 14.00
is "x86/Fluent-Benchmark.2026R1.sbatch" time_per_iteration_seconds 0.25
is "x86/Fluent-Benchmark.2026R1.sbatch" time_to_solution_seconds 6.25
is "x86/Fluent-Benchmark.2026R1.sbatch" num_cells_million 4
notes "x86/Fluent-Benchmark.2026R1.sbatch" 0
run_launcher "${GPU_BENCHMARK_SCRIPT}" launcher-gpu STUB_TRANSCRIPT="${CELLS_TRN}" \
    DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
launcher_item
is "${GPU_BENCHMARK_SCRIPT}" mesh_cells 3500000
is "${GPU_BENCHMARK_SCRIPT}" miups 14.00
is "${GPU_BENCHMARK_SCRIPT}" time_per_iteration_seconds 0.25
notes "${GPU_BENCHMARK_SCRIPT}" 0

# ---------------------------------------------------------------------------
# 10. --help: the whole header, the new field's lines among them, and no code.
# ---------------------------------------------------------------------------
help="$(env -i PATH=/usr/bin:/bin bash "${RECORDER}" --help)"
header="$(awk 'NR > 1 && !/^#/ { exit } NR > 1' "${RECORDER}" | sed 's/^# \{0,1\}//')"
n="$(printf '%s\n' "${header}" | wc -l)"
if [ "$(printf '%s\n' "${help}" | head -n "${n}")" = "${header}" ] \
        && [ "$(printf '%s\n' "${help}" | sed -n "$((n + 1)),$((n + 2))p")" = "$(printf '\nOPTIONS')" ]; then
    ok "--help prints the header's ${n} lines, from its second line to its last, then the options"
else
    bad "--help prints the header's lines, then the options" "the ${n} lines of the header, then OPTIONS" \
        "$(printf '%s\n' "${help}" | sed -n "$((n - 1)),$((n + 2))p" | tr '\n' '|')"
fi
grep -qF "mesh_cells                the mesh's own cell count, from the 2026R1 harness's transcript" <<< "${help}" \
    && ok "--help names mesh_cells" || bad "--help names mesh_cells" "the mesh_cells lines" "none"
grep -q 'set -uo pipefail' <<< "${help}" && bad "--help prints no code" "no code" "set -uo pipefail" \
    || ok "--help prints no code"

summary "The recorder: the time per iteration on the mesh's own cell count"
