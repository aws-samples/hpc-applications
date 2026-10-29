#!/bin/bash
# =============================================================================
# gpu/Fluent-Benchmark-GPU.sbatch records a run only when the 2026 R1
# harness's transcript of the case and core count, working/<tag>/transcript/
# <case>-<cores>.trn, gives the case's rating: a positive number on its
# "Million Cell Iteration Per Wall Second =" line, as
# x86/Fluent-Benchmark.2026R1.sbatch does (test-2026r1-record-gate.sh). See
# helpers-launchers.sh.
#   * that number reaches the recorder as MIUPS, in one call, with the case,
#     the method and the GPU solver mode, also from a transcript with CRLF line
#     ends, and this directory's recorder in --dry-run would store it;
#   * nothing is recorded, a NOTE names the transcript and a second NOTE says
#     the recording is skipped, when the transcript has the journal's command
#     for that line but not the line, when the rating is 0.00, nan or -1.50,
#     when the harness writes no transcript, and when a rating is only in
#     another case's transcript, another core count's, Fluent's own transcript
#     or a .trn shipped with the dataset;
#   * the job's exit status does not change.
#
#   apps/Fluent/tests/test-launchers-gpu-gate.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"
S="${GPU_BENCHMARK_SCRIPT}"
echo "The GPU benchmark script: the rating gate (${S})"

NOTE_TRN="NOTE: working/*/transcript/sedan_4m-384.trn, the harness's transcript of this case and core count, gives no positive MIUPS on a \"Million Cell Iteration Per Wall Second =\" line."
NOTE_SKIP="NOTE: no MIUPS result found in transcripts; skipping benchmark recording."

recorded() {  # <description>: the last run was recorded once, with MIUPS=12.34
    if [ "$(recorder_calls)" = "1" ] && recorder_has "MIUPS=12.34"; then
        ok "$1 -> recorded once, with MIUPS=12.34"
    else
        bad "$1 -> recorded once, with MIUPS=12.34" "1 call, MIUPS=12.34" \
            "$(recorder_calls) call(s), $(grep '^MIUPS=' "${STATE}/recorder.log" 2>/dev/null | tr '\n' ' ')"
    fi
    if has_line "${ERR}" "${NOTE_TRN}" || has_line "${ERR}" "${NOTE_SKIP}"; then
        bad "$1 -> no NOTE about the rating" "no NOTE" "${ERR}"
    else
        ok "$1 -> no NOTE about the rating"
    fi
}
not_recorded() {  # <description>: the last run was not recorded, both NOTEs say why, the job exits 0
    [ "$(recorder_calls)" = "0" ] && ok "$1 -> not recorded" \
        || bad "$1 -> not recorded" "no recorder call" "$(recorder_calls) call(s)"
    if has_line "${ERR}" "${NOTE_TRN}" && has_line "${ERR}" "${NOTE_SKIP}"; then
        ok "$1 -> a NOTE names the transcript, then the NOTE that skips the recording"
    else
        bad "$1 -> a NOTE names the transcript, then the NOTE that skips the recording" \
            "${NOTE_TRN} / ${NOTE_SKIP}" "${ERR}"
    fi
    [ "${RC}" -eq 0 ] && ok "$1 -> the job's exit status is unchanged (0)" \
        || bad "$1 -> the job's exit status is unchanged" "exit 0" "exit ${RC}"
}

# ---------------------------------------------------------------------------
# 1. The transcript gives the rating.
# ---------------------------------------------------------------------------
run_launcher "${S}" rated
recorded "the rating in the harness's transcript"
for want in "BENCHMARK_CASE=sedan_4m" "BENCHMARK_METHOD=fluent_benchmark_harness" "SOLVER_MODE=gpu"; do
    recorder_has "${want}" && ok "the recorder gets ${want}" \
        || bad "the recorder gets ${want%%=*}" "${want}" "$(tr '\n' '|' < "${STATE}/recorder.log" 2>/dev/null)"
done
sed 's/$/\r/' "${FIX}/steady-25-iterations.trn" > "${WORK}/crlf.trn"
run_launcher "${S}" crlf STUB_TRANSCRIPT="${WORK}/crlf.trn"
recorded "a transcript with CRLF line ends"

# ---------------------------------------------------------------------------
# 2. The journal's command for the rating line, without the line, a rating
#    that is not a positive number, and no transcript at all.
# ---------------------------------------------------------------------------
sed '/^Million Cell Iteration Per Wall Second/,$d' "${FIX}/steady-25-iterations.trn" > "${WORK}/no-rating.trn"
run_launcher "${S}" no-rating STUB_TRANSCRIPT="${WORK}/no-rating.trn"
not_recorded "the journal's command for the rating, no rating"
for v in 0.00 nan -1.50; do
    sed "s/^\(Million Cell Iteration Per Wall Second =\).*/\1     ${v} MIUPS/" \
        "${FIX}/steady-25-iterations.trn" > "${WORK}/rating-${v}.trn"
    run_launcher "${S}" "rating-${v}" STUB_TRANSCRIPT="${WORK}/rating-${v}.trn"
    not_recorded "a rating of ${v}"
done
run_launcher "${S}" no-transcript STUB_TRANSCRIPT= STUB_HARNESS_RC=1
not_recorded "no transcript"

# ---------------------------------------------------------------------------
# 3. A rating, but not in the harness's transcript of this case and core count.
# ---------------------------------------------------------------------------
run_launcher "${S}" other-case STUB_TRANSCRIPT_NAME=aircraft_wing_14m-384.trn
not_recorded "a rating only in another case's transcript"
run_launcher "${S}" other-cores STUB_TRANSCRIPT_NAME=sedan_4m-192.trn
not_recorded "a rating only in another core count's transcript"
run_launcher "${S}" fluent-own STUB_TRANSCRIPT= STUB_FLUENT_TRANSCRIPT="${FIX}/steady-25-iterations.trn"
not_recorded "a rating only in Fluent's own transcript"
mkdir -p "${WORK}/s3-shipped" "${WORK}/dataset-shipped"
cp -r "${WORK}/dataset/bench" "${WORK}/dataset-shipped/"
cp "${FIX}/steady-25-iterations.trn" "${WORK}/dataset-shipped/bench/fluent/v6/sedan_4m/sedan_4m-384.trn"
tar cf "${WORK}/s3-shipped/sedan_4m.tar" -C "${WORK}/dataset-shipped" bench
run_launcher "${S}" shipped STUB_TRANSCRIPT="${WORK}/no-rating.trn" STUB_S3_DIR="${WORK}/s3-shipped"
if [ -f "${WORKDIR}/bench/fluent/v6/sedan_4m/sedan_4m-384.trn" ]; then
    ok "the dataset's .trn is staged in the run directory"
else
    bad "the dataset's .trn is staged in the run directory" "bench/fluent/v6/sedan_4m/sedan_4m-384.trn" "none"
fi
not_recorded "a rating only in a .trn shipped with the dataset"

# ---------------------------------------------------------------------------
# 4. This directory's recorder, in --dry-run: the item it would store.
# ---------------------------------------------------------------------------
run_launcher "${S}" real-recorder DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
item="$(sed -n '/^{/,$p' "${STATE}/recorder.json" 2>/dev/null)"
for want in '"miups": {"N": "12.34"}' '"benchmark_case": {"S": "sedan_4m"}' \
            '"benchmark_method": {"S": "fluent_benchmark_harness"}' '"solver_mode": {"S": "gpu"}'; do
    grep -qF -- "${want}" <<< "${item}" && ok "the item would store ${want}" \
        || bad "the item would store ${want}" "${want}" "$(printf '%s' "${item}" | tr '\n' ' ')"
done

summary "The GPU benchmark script: the rating gate"
