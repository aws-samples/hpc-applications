#!/bin/bash
# =============================================================================
# The journal scripts (x86/Fluent.IMPI.sbatch, x86/Fluent.OMPI.sbatch,
# Arm/Fluent.sbatch, gpu/Fluent-GPU.sbatch, gpu/Fluent-GPU.OMPI.sbatch) record
# a run only when Fluent exits with status 0: Fluent's own status, which the
# scripts read past the tee that keeps its output. See helpers-launchers.sh.
# For each:
#   * a run that Fluent ends with status 0 is recorded once, with no NOTE about
#     the solver's status;
#   * a run that Fluent ends with status 2, or 137 (killed), is not recorded,
#     and the NOTE "solver exited <status>; skipping benchmark recording." says
#     so, instead of the NOTE about a missing recorder when none is found;
#   * either way the job exits 0, as before, and output.<job>.out keeps
#     Fluent's output;
#   * with no recorder to be found, a run that Fluent ends with status 0 gets
#     the NOTE that says how to point at one.
#
#   apps/Fluent/tests/test-launchers-journal-gate.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"
echo "The journal scripts: Fluent's exit status"

NOTE_NOT_FOUND="NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record."

exits_0_with_output() {  # <description>: the job exits 0, and output.<job>.out holds Fluent's line
    [ "${RC}" -eq 0 ] && ok "$1 -> the job exits 0" || bad "$1 -> the job exits 0" "exit 0" "exit ${RC}"
    grep -q '^\[stub fluent\] ' "${WORKDIR}/output.4242.out" 2>/dev/null \
        && ok "$1 -> output.<job>.out keeps Fluent's output" \
        || bad "$1 -> output.<job>.out keeps Fluent's output" "the stub's line" \
               "$(cat "${WORKDIR}/output.4242.out" 2>/dev/null)"
}

for s in "${JOURNAL_SCRIPTS[@]}"; do
    echo "== ${s}"
    n="${s//\//-}"
    run_launcher "${s}" "${n}-rc0"
    if [ "$(recorder_calls)" = "1" ] && ! grep -q '^NOTE: solver exited' <<< "${ERR}"; then
        ok "${s}: Fluent exits 0 -> recorded once, no NOTE about its status"
    else
        bad "${s}: Fluent exits 0 -> recorded once, no NOTE about its status" "1 call, no NOTE" \
            "$(recorder_calls) call(s); ${ERR}"
    fi
    exits_0_with_output "${s}: Fluent exits 0"
    for rc in 2 137; do
        run_launcher "${s}" "${n}-rc${rc}" STUB_FLUENT_RC="${rc}"
        [ "$(recorder_calls)" = "0" ] && ok "${s}: Fluent exits ${rc} -> not recorded" \
            || bad "${s}: Fluent exits ${rc} -> not recorded" "no recorder call" "$(recorder_calls) call(s)"
        has_line "${ERR}" "NOTE: solver exited ${rc}; skipping benchmark recording." \
            && ok "${s}: Fluent exits ${rc} -> a NOTE gives its status" \
            || bad "${s}: Fluent exits ${rc} -> a NOTE gives its status" \
                   "NOTE: solver exited ${rc}; skipping benchmark recording." "${ERR}"
        exits_0_with_output "${s}: Fluent exits ${rc}"
    done
    run_launcher "${s}" "${n}-no-recorder" DYNAMODB_RECORDER=
    has_line "${ERR}" "${NOTE_NOT_FOUND}" && ok "${s}: no recorder -> a NOTE says how to point at it" \
        || bad "${s}: no recorder -> a NOTE says how to point at it" "${NOTE_NOT_FOUND}" "${ERR}"
    run_launcher "${s}" "${n}-rc2-no-recorder" DYNAMODB_RECORDER= STUB_FLUENT_RC=2
    if has_line "${ERR}" "NOTE: solver exited 2; skipping benchmark recording." \
            && ! has_line "${ERR}" "${NOTE_NOT_FOUND}"; then
        ok "${s}: Fluent exits 2, no recorder -> the NOTE gives its status, not the missing recorder"
    else
        bad "${s}: Fluent exits 2, no recorder -> the NOTE gives its status, not the missing recorder" \
            "NOTE: solver exited 2; skipping benchmark recording." "${ERR}"
    fi
done

summary "The journal scripts: Fluent's exit status"
