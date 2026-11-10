#!/bin/bash
# =============================================================================
# The classic benchmark scripts (x86/Fluent-Benchmark.IMPI.sbatch,
# x86/Fluent-Benchmark.OMPI.sbatch, Arm/Fluent-benchmark.sbatch) give the
# recorder the case that their rating gate checked, as BENCHMARK_CASE, and the
# method, as BENCHMARK_METHOD=fluentbench. On a node, the run directory also
# holds Fluent's own session transcript, fluent-<date>-<time>-<pid>.trn, and an
# older recorder not given the case and the method takes both from the run
# directory's first .trn (Fluent's own session transcript for a case such as
# sedan_4m, fluentbench.pl's <case>-<cores>.trn for others): the transcript's
# name, and the 2026 R1 harness's method. See helpers-launchers.sh. For each:
#   * with a synthetic session transcript in the run directory, the recorder
#     gets BENCHMARK_CASE=sedan_4m and BENCHMARK_METHOD=fluentbench, in one
#     call, and this directory's recorder, in --dry-run, would store
#     "benchmark_case" sedan_4m and "benchmark_method" fluentbench;
#   * without it, the recorder gets the same two;
# x86/Fluent-Benchmark.OMPI.sbatch names the case BENCHMARK_NAME, and also
# takes a directory that holds the case's files: from such a directory named
# otherwise than the case, the recorder gets the case.
#
#   apps/Fluent/tests/test-launchers-classic-case.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"
echo "The classic benchmark scripts: the case and the method the recorder gets"

SESSION_TRN_NAME=fluent-20261026-120000-1000.trn   # the name the fluentbench.pl stub gives STUB_SESSION_TRN
# A synthetic session transcript, as Fluent writes one in the run directory of a classic run.
cat > "${WORK}/session.trn" <<'EOF'
Synthetic session transcript for the tests: it holds no value of a real run.
> /file/read-case sedan_4m.cas.gz
Done.
> /solve/iterate 25
> /exit yes
EOF

# gets <description>: the last run called the recorder once, with BENCHMARK_CASE=sedan_4m and
# BENCHMARK_METHOD=fluentbench
gets() {
    if [ "$(recorder_calls)" = "1" ] && recorder_has "BENCHMARK_CASE=sedan_4m" \
            && recorder_has "BENCHMARK_METHOD=fluentbench"; then
        ok "$1 -> the recorder gets BENCHMARK_CASE=sedan_4m and BENCHMARK_METHOD=fluentbench, once"
    else
        bad "$1 -> the recorder gets BENCHMARK_CASE=sedan_4m and BENCHMARK_METHOD=fluentbench, once" \
            "1 call, BENCHMARK_CASE=sedan_4m, BENCHMARK_METHOD=fluentbench" \
            "$(recorder_calls) call(s), $(grep -E '^BENCHMARK_(CASE|METHOD)=' "${STATE}/recorder.log" 2>/dev/null | tr '\n' ' ')"
    fi
}
# stores <description>: the item this directory's recorder would store in the last run names the case and
# the method, not the session transcript's name
stores() {
    local item want
    item="$(sed -n '/^{/,$p' "${STATE}/recorder.json" 2>/dev/null)"
    for want in '"benchmark_case": {"S": "sedan_4m"}' '"benchmark_method": {"S": "fluentbench"}'; do
        grep -qF -- "${want}" <<< "${item}" && ok "$1 -> the item would store ${want}" \
            || bad "$1 -> the item would store ${want}" "${want}" \
                   "$(grep -E '"benchmark_(case|method)"' <<< "${item}" | tr -s ' ' | tr '\n' ' ')"
    done
}

for s in "${BENCHMARK_SCRIPTS[@]}"; do
    echo "== ${s}"
    n="${s//\//-}"
    run_launcher "${s}" "${n}-session" STUB_SESSION_TRN="${WORK}/session.trn"
    if [ -f "${WORKDIR}/${SESSION_TRN_NAME}" ]; then
        ok "${s}: the session transcript ${SESSION_TRN_NAME} is in the run directory"
    else
        bad "${s}: the session transcript ${SESSION_TRN_NAME} is in the run directory" "the file" "none"
    fi
    gets "${s}: a session transcript in the run directory"
    run_launcher "${s}" "${n}-session-real" STUB_SESSION_TRN="${WORK}/session.trn" \
        DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
    stores "${s}: a session transcript in the run directory"
    run_launcher "${s}" "${n}-no-session"
    gets "${s}: no session transcript"
done

s=x86/Fluent-Benchmark.OMPI.sbatch
echo "== ${s}, with its input in a directory named otherwise than the case"
mkdir -p "${WORK}/inputs"
cp "${WORK}/dataset/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m.cas.gz" \
   "${WORK}/dataset/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m.dat.gz" "${WORK}/inputs/"
RUN_URI="${WORK}/inputs" run_launcher "${s}" ompi-dir-session STUB_SESSION_TRN="${WORK}/session.trn"
gets "${s}: the input directory inputs/, a session transcript in the run directory"

summary "The classic benchmark scripts: the case and the method the recorder gets"
