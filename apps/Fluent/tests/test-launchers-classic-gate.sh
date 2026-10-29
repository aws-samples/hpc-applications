#!/bin/bash
# =============================================================================
# The classic benchmark scripts (x86/Fluent-Benchmark.IMPI.sbatch,
# x86/Fluent-Benchmark.OMPI.sbatch, Arm/Fluent-benchmark.sbatch) record a run
# only when fluentbench.pl's output of the case and core count,
# <case>-<cores>.out in the run directory, gives the case's rating: a positive
# number on its "Solver rating =" line. See helpers-launchers.sh. For each:
#   * that number reaches the recorder as SOLVER_RATING, in one call, with
#     that file's time per iteration and solver speed as TIME_PER_ITERATION
#     and SOLVER_SPEED, also from an output file with CRLF line ends, and this
#     directory's recorder in --dry-run would store the three;
#   * the three are that file's also when the dataset ships another output
#     file, linked into the run directory, with other values, which the
#     recorder would read first;
#   * nothing is recorded, a NOTE names the file and a second NOTE says the
#     recording is skipped, when the output file has no rating line, a rating
#     line with no number, a rating of 0.00, nan or -1.50, or is missing, and
#     when a rating is only in another case's output file, another core
#     count's, the job's own output (output.<job>.out, where the script tees
#     it) or a file shipped with the dataset and linked into the run
#     directory;
#   * the job's exit status does not change.
# x86/Fluent-Benchmark.OMPI.sbatch names the case BENCHMARK_NAME, and also
# takes a directory that holds the case's files. With such a directory named
# otherwise than the case, the run is recorded from the case's output file,
# and a rating only in an output file named after the directory does not
# count.
#
#   apps/Fluent/tests/test-launchers-classic-gate.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"
echo "The classic benchmark scripts: the rating gate"

NOTE_OUT="NOTE: sedan_4m-384.out, fluentbench.pl's output of this case and core count, gives no positive rating on a \"Solver rating =\" line."
NOTE_SKIP="NOTE: no solver rating found in the benchmark output; skipping benchmark recording."

VALUES=(SOLVER_RATING=3456.0 TIME_PER_ITERATION=1.000 SOLVER_SPEED=86400.0)   # fluentbench-rated.out's

recorded() {  # <description>: the last run was recorded once, with the values of fluentbench-rated.out
    local v all=1
    for v in "${VALUES[@]}"; do recorder_has "${v}" || all=""; done
    if [ "$(recorder_calls)" = "1" ] && [ -n "${all}" ]; then
        ok "$1 -> recorded once, with ${VALUES[*]}"
    else
        bad "$1 -> recorded once, with ${VALUES[*]}" "1 call, ${VALUES[*]}" \
            "$(recorder_calls) call(s), $(grep -E '^(SOLVER_RATING|TIME_PER_ITERATION|SOLVER_SPEED)=' \
                                          "${STATE}/recorder.log" 2>/dev/null | tr '\n' ' ')"
    fi
    if has_line "${ERR}" "${NOTE_OUT}" || has_line "${ERR}" "${NOTE_SKIP}"; then
        bad "$1 -> no NOTE about the rating" "no NOTE" "${ERR}"
    else
        ok "$1 -> no NOTE about the rating"
    fi
}
not_recorded() {  # <description>: the last run was not recorded, both NOTEs say why, the job exits 0
    [ "$(recorder_calls)" = "0" ] && ok "$1 -> not recorded" \
        || bad "$1 -> not recorded" "no recorder call" "$(recorder_calls) call(s)"
    if has_line "${ERR}" "${NOTE_OUT}" && has_line "${ERR}" "${NOTE_SKIP}"; then
        ok "$1 -> a NOTE names the output file, then the NOTE that skips the recording"
    else
        bad "$1 -> a NOTE names the output file, then the NOTE that skips the recording" \
            "${NOTE_OUT} / ${NOTE_SKIP}" "${ERR}"
    fi
    [ "${RC}" -eq 0 ] && ok "$1 -> the job's exit status is unchanged (0)" \
        || bad "$1 -> the job's exit status is unchanged" "exit 0" "exit ${RC}"
}

# Output files that give no rating, cut or edited from the rated one.
sed '/^Solver rating/,$d' "${FIX}/fluentbench-rated.out" > "${WORK}/no-rating.out"
sed 's/^\(Solver rating[[:space:]]*=\).*/\1/' "${FIX}/fluentbench-rated.out" > "${WORK}/rating-empty.out"
sed 's/$/\r/' "${FIX}/fluentbench-rated.out" > "${WORK}/crlf.out"
for v in 0.00 nan -1.50; do
    sed "s/^\(Solver rating[[:space:]]*=\).*/\1 ${v}/" "${FIX}/fluentbench-rated.out" > "${WORK}/rating-${v}.out"
done
# The case's archive, with a rated output file in the files that are linked into the run directory.
mkdir -p "${WORK}/s3-shipped" "${WORK}/dataset-shipped"
cp -r "${WORK}/dataset/bench" "${WORK}/dataset-shipped/"
cp "${FIX}/fluentbench-rated.out" "${WORK}/dataset-shipped/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m-384.out"
tar cf "${WORK}/s3-shipped/sedan_4m.tar" -C "${WORK}/dataset-shipped" bench
# The case's archive, with another output file of other values in the files that are linked into the run
# directory: sedan_4m-1.out, which comes before sedan_4m-384.out in the recorder's own search (each value from
# the first *.out file that has its line).
mkdir -p "${WORK}/s3-other" "${WORK}/dataset-other"
cp -r "${WORK}/dataset/bench" "${WORK}/dataset-other/"
sed -e 's/^\(Solver wall time per iteration[[:space:]]*=\)[[:space:]]*[0-9.]*/\1 9.999/' \
    -e 's/^\(Solver speed[[:space:]]*=\)[[:space:]]*[0-9.]*/\1 8640.0/' \
    -e 's/^\(Solver rating[[:space:]]*=\).*/\1 111.1/' \
    "${FIX}/fluentbench-rated.out" > "${WORK}/dataset-other/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m-1.out"
tar cf "${WORK}/s3-other/sedan_4m.tar" -C "${WORK}/dataset-other" bench

# item_stores <description> <attribute>...: the item this directory's recorder would store in the last run
# has each attribute
item_stores() {
    local what="$1" item want
    shift
    item="$(sed -n '/^{/,$p' "${STATE}/recorder.json" 2>/dev/null)"
    for want in "$@"; do
        grep -qF -- "${want}" <<< "${item}" && ok "${what}: the item would store ${want}" \
            || bad "${what}: the item would store ${want}" "${want}" "$(printf '%s' "${item}" | tr '\n' ' ')"
    done
}

for s in "${BENCHMARK_SCRIPTS[@]}"; do
    echo "== ${s}"
    n="${s//\//-}"
    # -----------------------------------------------------------------------
    # 1. The output file gives the rating.
    # -----------------------------------------------------------------------
    run_launcher "${s}" "${n}-rated"
    recorded "${s}: the rating in fluentbench.pl's output file"
    run_launcher "${s}" "${n}-crlf" STUB_OUT="${WORK}/crlf.out"
    recorded "${s}: an output file with CRLF line ends"
    # -----------------------------------------------------------------------
    # 2. The output file gives no rating.
    # -----------------------------------------------------------------------
    run_launcher "${s}" "${n}-no-rating" STUB_OUT="${WORK}/no-rating.out"
    not_recorded "${s}: an output file with no rating line"
    run_launcher "${s}" "${n}-rating-empty" STUB_OUT="${WORK}/rating-empty.out"
    not_recorded "${s}: a rating line with no number"
    for v in 0.00 nan -1.50; do
        run_launcher "${s}" "${n}-rating-${v}" STUB_OUT="${WORK}/rating-${v}.out"
        not_recorded "${s}: a rating of ${v}"
    done
    run_launcher "${s}" "${n}-no-out" STUB_OUT= STUB_RC=1
    not_recorded "${s}: no output file"
    # -----------------------------------------------------------------------
    # 3. A rating, but not in fluentbench.pl's output of this case and core count.
    # -----------------------------------------------------------------------
    run_launcher "${s}" "${n}-other-case" STUB_OUT_NAME=aircraft_wing_14m-384.out
    not_recorded "${s}: a rating only in another case's output file"
    run_launcher "${s}" "${n}-other-cores" STUB_OUT_NAME=sedan_4m-192.out
    not_recorded "${s}: a rating only in another core count's output file"
    run_launcher "${s}" "${n}-stdout" STUB_OUT= STUB_STDOUT="${FIX}/fluentbench-rated.out"
    not_recorded "${s}: a rating only in the job's own output"
    run_launcher "${s}" "${n}-shipped" STUB_OUT= STUB_S3_DIR="${WORK}/s3-shipped"
    if [ -L "${WORKDIR}/sedan_4m-384.out" ]; then
        ok "${s}: the file shipped with the dataset is linked into the run directory"
    else
        bad "${s}: the file shipped with the dataset is linked into the run directory" "a link sedan_4m-384.out" "none"
    fi
    not_recorded "${s}: a rating only in a file shipped with the dataset"
    # -----------------------------------------------------------------------
    # 4. Another output file of the dataset, with other values, in the run
    #    directory: the values recorded are still the case's own file's.
    # -----------------------------------------------------------------------
    run_launcher "${s}" "${n}-other-values" STUB_S3_DIR="${WORK}/s3-other"
    if [ -L "${WORKDIR}/sedan_4m-1.out" ]; then
        ok "${s}: the dataset's other output file is linked into the run directory"
    else
        bad "${s}: the dataset's other output file is linked into the run directory" "a link sedan_4m-1.out" "none"
    fi
    recorded "${s}: another output file, with other values, in the run directory"
    # -----------------------------------------------------------------------
    # 5. This directory's recorder, in --dry-run: the item it would store.
    # -----------------------------------------------------------------------
    run_launcher "${s}" "${n}-real-recorder" DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
    item_stores "${s}" '"solver_rating": {"N": "3456.0"}' '"time_per_iteration_seconds": {"N": "1.000"}' \
        '"solver_speed": {"N": "86400.0"}' '"benchmark_case": {"S": "sedan_4m"}' '"num_cores": {"N": "384"}' \
        '"num_instances": {"N": "2"}'
    run_launcher "${s}" "${n}-real-recorder-other" STUB_S3_DIR="${WORK}/s3-other" \
        DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
    item_stores "${s}: another output file, with other values, in the run directory" \
        '"solver_rating": {"N": "3456.0"}' '"time_per_iteration_seconds": {"N": "1.000"}' \
        '"solver_speed": {"N": "86400.0"}'
done

# ---------------------------------------------------------------------------
# 6. x86/Fluent-Benchmark.OMPI.sbatch: the case BENCHMARK_NAME names, from an
#    input directory named otherwise.
# ---------------------------------------------------------------------------
s=x86/Fluent-Benchmark.OMPI.sbatch
echo "== ${s}, with its input in a directory named otherwise than the case"
mkdir -p "${WORK}/cases"
cp "${WORK}/dataset/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m.cas.gz" \
   "${WORK}/dataset/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m.dat.gz" "${WORK}/cases/"
RUN_URI="${WORK}/cases" run_launcher "${s}" ompi-dir
[ "$(sed -n 2p "${STATE}/solver.args" 2>/dev/null)" = sedan_4m ] \
    && ok "${s}: the input directory cases/ -> fluentbench.pl runs the case sedan_4m" \
    || bad "${s}: the input directory cases/ -> fluentbench.pl runs the case sedan_4m" "sedan_4m" \
           "$(sed -n 2p "${STATE}/solver.args" 2>/dev/null)"
recorded "${s}: the input directory cases/, the case's output file sedan_4m-384.out"
RUN_URI="${WORK}/cases" run_launcher "${s}" ompi-dir-other-name STUB_OUT_NAME=cases-384.out
not_recorded "${s}: the input directory cases/, a rating only in cases-384.out"

summary "The classic benchmark scripts: the rating gate"
