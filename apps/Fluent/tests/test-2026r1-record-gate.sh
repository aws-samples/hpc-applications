#!/bin/bash
# =============================================================================
# x86/Fluent-Benchmark.2026R1.sbatch records a run only when the harness's
# transcript of the case and core count, working/<tag>/transcript/
# <case>-<cores>.trn, gives the case's rating: a positive number on its
# "Million Cell Iteration Per Wall Second =" line. See helpers-2026r1.sh.
#   * that number reaches the recorder as MIUPS, in one call, also from a
#     transcript with CRLF line ends;
#   * nothing is recorded, a NOTE names the transcript and the existing NOTE
#     follows, when the transcript has the journal's command for that line
#     but not the line, when the rating is 0.00, nan or -1.50, and when a
#     rating is only in another case's transcript, another core count's,
#     Fluent's own transcript or a .trn staged with the dataset;
#   * the job's exit status does not change.
#
#   apps/Fluent/tests/test-2026r1-record-gate.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-2026r1.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-2026r1.sh"
echo "2026 R1 script: the rating gate (${SBATCH#"${FLUENT_APP}/"})"

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
        ok "$1 -> a NOTE names the transcript, then the existing NOTE"
    else
        bad "$1 -> a NOTE names the transcript, then the existing NOTE" "${NOTE_TRN} / ${NOTE_SKIP}" "${ERR}"
    fi
    [ "${RC}" -eq 0 ] && ok "$1 -> the job's exit status is unchanged (0)" \
        || bad "$1 -> the job's exit status is unchanged" "exit 0" "exit ${RC}"
}

# ---------------------------------------------------------------------------
# 1. The transcript gives the rating.
# ---------------------------------------------------------------------------
run_2026r1 rated
recorded "the rating in the harness's transcript"
sed 's/$/\r/' "${FIX}/steady-25-iterations.trn" > "${WORK}/crlf.trn"
run_2026r1 crlf STUB_TRANSCRIPT="${WORK}/crlf.trn"
recorded "a transcript with CRLF line ends"

# ---------------------------------------------------------------------------
# 2. The journal's command for the rating line, without the line: the run
#    stopped there.
# ---------------------------------------------------------------------------
sed '/^Million Cell Iteration Per Wall Second/,$d' "${FIX}/steady-25-iterations.trn" > "${WORK}/no-rating.trn"
if grep -q 'Million Cell Iteration Per Wall Second' "${WORK}/no-rating.trn"; then
    ok "the cut transcript still has the journal's command for the rating line"
else
    bad "the cut transcript still has the journal's command" "the command" "none"
fi
run_2026r1 no-rating STUB_TRANSCRIPT="${WORK}/no-rating.trn"
not_recorded "the journal's command for the rating, no rating"

# ---------------------------------------------------------------------------
# 3. A rating that is not a positive number.
# ---------------------------------------------------------------------------
for v in 0.00 nan -1.50; do
    sed "s/^\(Million Cell Iteration Per Wall Second =\).*/\1     ${v} MIUPS/" \
        "${FIX}/steady-25-iterations.trn" > "${WORK}/rating-${v}.trn"
    run_2026r1 "rating-${v}" STUB_TRANSCRIPT="${WORK}/rating-${v}.trn"
    not_recorded "a rating of ${v}"
done

# ---------------------------------------------------------------------------
# 4. A rating, but not in the harness's transcript of this case and core count.
# ---------------------------------------------------------------------------
run_2026r1 other-case STUB_TRANSCRIPT_NAME=aircraft_wing_14m-384.trn
not_recorded "a rating only in another case's transcript"
run_2026r1 other-cores STUB_TRANSCRIPT_NAME=sedan_4m-192.trn
not_recorded "a rating only in another core count's transcript"
run_2026r1 fluent-own STUB_TRANSCRIPT= STUB_FLUENT_TRANSCRIPT="${FIX}/steady-25-iterations.trn"
not_recorded "a rating only in Fluent's own transcript"
mkdir -p "${WORK}/dataset/sedan_4m"
cp "${FIX}/steady-25-iterations.trn" "${WORK}/dataset/sedan_4m/sedan_4m-384.trn"
tar cf "${WORK}/sedan_4m.tar" -C "${WORK}/dataset" sedan_4m
RUN_URI="${WORK}/sedan_4m.tar" run_2026r1 staged STUB_TRANSCRIPT="${WORK}/no-rating.trn"
if [ -f "${WORKDIR}/sedan_4m/sedan_4m-384.trn" ]; then
    ok "the dataset's .trn is staged in the run directory"
else
    bad "the dataset's .trn is staged in the run directory" "sedan_4m/sedan_4m-384.trn" "none"
fi
not_recorded "a rating only in a .trn staged with the dataset"

summary "2026 R1 script: the rating gate"
