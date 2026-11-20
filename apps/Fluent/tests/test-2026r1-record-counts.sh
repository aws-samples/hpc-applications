#!/bin/bash
# =============================================================================
# x86/Fluent-Benchmark.2026R1.sbatch gives the recorder the run's length. See
# helpers-2026r1.sh.
#   * --char warmup_iterations=<WARMUP_ITERATIONS, or 10> and
#     --char timed_iterations=<the "Number of Iterations" of the harness's
#     transcript>, with NUM_ITERATIONS=<ITERATIONS, or 25>;
#   * for a transient case, whose 25 timed time steps the harness counts as
#     250 iterations, timed_iterations is 250 and NUM_ITERATIONS stays 25;
#   * no timed_iterations when the transcript has only the journal's command
#     for that line;
#   * this directory's recorder in --dry-run would store both counts, next to
#     the case, its size, the timed count asked for and the rating.
#
#   apps/Fluent/tests/test-2026r1-record-counts.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-2026r1.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-2026r1.sh"
echo "2026 R1 script: the run's length in the record (${SBATCH#"${FLUENT_APP}/"})"

args_are() {  # <description> <argument>...: the recorder got exactly these arguments, once
    local desc="$1"; shift
    local want got
    want="$(printf 'ARG %s\n' "$@")"
    got="$(grep '^ARG ' "${STATE}/recorder.log" 2>/dev/null)"
    if [ "$(recorder_calls)" = "1" ] && [ "${got}" = "${want}" ]; then ok "${desc}"
    else bad "${desc}" "${want//$'\n'/ | }" "$(recorder_calls) call(s): ${got//$'\n'/ | }"; fi
}
iterations_are() {  # <description> <N>: the recorder got NUM_ITERATIONS=<N>
    recorder_has "NUM_ITERATIONS=$2" && ok "$1" \
        || bad "$1" "NUM_ITERATIONS=$2" "$(grep '^NUM_ITERATIONS=' "${STATE}/recorder.log" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 1. A steady case, ITERATIONS=25 and WARMUP_ITERATIONS=10.
# ---------------------------------------------------------------------------
run_2026r1 steady
args_are "steady: warm-up 10 and 25 timed iterations" \
    --char warmup_iterations=10 --char timed_iterations=25
iterations_are "steady: NUM_ITERATIONS=25, as before" 25

# ---------------------------------------------------------------------------
# 2. A transient case: 25 time steps, 250 iterations.
# ---------------------------------------------------------------------------
run_2026r1 transient BENCHMARK_NAME=landing_gear_15m STUB_TRANSCRIPT="${FIX}/transient-25-time-steps.trn"
args_are "transient: warm-up 10, and the 250 iterations of the 25 timed time steps" \
    --char warmup_iterations=10 --char timed_iterations=250
iterations_are "transient: NUM_ITERATIONS=25, the time steps asked for, as before" 25

# ---------------------------------------------------------------------------
# 3. ITERATIONS and WARMUP_ITERATIONS not set: the script's defaults, the
#    published protocol of 25 timed and 10 warm-up iterations.
# ---------------------------------------------------------------------------
run_2026r1 defaults ITERATIONS= WARMUP_ITERATIONS=
args_are "defaults: warm-up 10, and the 25 iterations the harness timed" \
    --char warmup_iterations=10 --char timed_iterations=25
iterations_are "defaults: NUM_ITERATIONS=25" 25

# ---------------------------------------------------------------------------
# 4. Only the journal's command for the "Number of Iterations" line.
# ---------------------------------------------------------------------------
sed '/^Number of Iterations/d' "${FIX}/steady-25-iterations.trn" > "${WORK}/no-count.trn"
run_2026r1 no-count STUB_TRANSCRIPT="${WORK}/no-count.trn"
args_are "no \"Number of Iterations\" line: the warm-up count only" --char warmup_iterations=10

# ---------------------------------------------------------------------------
# 5. This directory's recorder, in --dry-run, on the transient case.
# ---------------------------------------------------------------------------
run_2026r1 real-recorder BENCHMARK_NAME=landing_gear_15m STUB_TRANSCRIPT="${FIX}/transient-25-time-steps.trn" \
    DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
item="$(sed -n '/^{/,$p' "${STATE}/recorder.json" 2>/dev/null)"
for want in '"warmup_iterations": {"S": "10"}' '"timed_iterations": {"S": "250"}' '"num_iterations": {"N": "25"}' \
            '"benchmark_case": {"S": "landing_gear_15m"}' '"num_cells_million": {"N": "15"}' \
            '"miups": {"N": "23.45"}'; do
    grep -qF -- "${want}" <<< "${item}" && ok "the item would store ${want}" \
        || bad "the item would store ${want}" "${want}" "$(printf '%s' "${item}" | tr '\n' ' ')"
done
if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${item}" | python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null \
        && ok "the item is valid JSON" || bad "the item is valid JSON" "valid JSON" "$(printf '%s' "${item}" | tr '\n' ' ')"
else
    skipt "the item is valid JSON" "no python3"
fi

summary "2026 R1 script: the run's length in the record"
