#!/bin/bash
# =============================================================================
# Shared by the tests of the recorder, dynamodb/record-benchmark.sh: source it.
# =============================================================================
# It sources helpers-launchers.sh, for the PASS/FAIL counters, the stubs and
# run_2026r1 and run_launcher, and defines:
#   trn       copies a transcript into a case's run directory
#   record    runs the recorder in --dry-run on a case's run directory, with
#             RUN (an array the test file sets: the run's other fields, so
#             that none comes from the host), in an empty environment (env -i)
#             whose PATH starts with the stubs; --dry-run prints the item it
#             would store and writes nothing
#   launcher_item
#             the item of the last run_2026r1 or run_launcher whose recorder
#             was this directory's, in --dry-run (real-recorder)
#   field, is, notes, exits0
#             what the item stores, and what the run printed
# No Slurm, no EC2, no Fluent, no MPI, no AWS credentials, no network, and
# every value in the fixtures is synthetic.
# =============================================================================
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"

RECORDER="${FLUENT_APP}/dynamodb/record-benchmark.sh"
# A synthetic transcript of sedan_4m (4 million cells by its name) whose mesh has 3,500,000 cells, at 14.00 MIUPS.
# shellcheck disable=SC2034  # the test files read it
CELLS_TRN="${FIX}/steady-cell-count.trn"
# The NOTE the recorder prints when the time per iteration is on the case's nominal size.
NOMINAL_NOTE="NOTE: no transcript gives the mesh's own cell count"

# trn <name> <file> [<path>]: copies <file> into the run directory of case <name>, as <path> in it (default
# working/<tag>/transcript/sedan_4m-384.trn, where the 2026 R1 harness writes its transcript of the case and
# core count)
trn() {
    local dest="${WORK}/$1/run/${3:-working/10-26-2026=12-00-00/transcript/sedan_4m-384.trn}"
    mkdir -p "$(dirname "${dest}")" && cp "$2" "${dest}"
}
# record <name> [VAR=value ...] [-- <argument> ...]: runs the recorder in --dry-run on the run directory of case
# <name>, ${WORK}/<name>/run, with RUN and the arguments after --, plus each VAR=value in its environment. Sets
# STATE (the case's directory), ITEM (the item it would store), ERR (its error stream) and RC (its exit status).
# shellcheck disable=SC2034  # the test files read RC and ERR
record() {
    local name="$1"; shift
    local -a vars=() args=()
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then shift; args=("$@"); break; fi
        vars+=("$1"); shift
    done
    STATE="${WORK}/${name}"
    mkdir -p "${STATE}/run" "${STATE}/home"
    (cd "${STATE}" && env -i PATH="${WORK}/bin:/usr/bin:/bin" HOME="${STATE}/home" LANG=C STUB_STATE="${STATE}" \
        "${vars[@]}" bash "${RECORDER}" --dry-run --no-put --run-dir "${STATE}/run" "${RUN[@]}" "${args[@]}" \
        > "${STATE}/stdout" 2> "${STATE}/stderr")
    RC=$?
    ITEM="$(sed -n '/^{/,$p' "${STATE}/stdout")"
    ERR="$(cat "${STATE}/stderr")"
}
# launcher_item: ITEM and ERR from the last launcher run, whose recorder was this one in --dry-run (real-recorder)
launcher_item() {
    ITEM="$(sed -n '/^{/,$p' "${STATE}/recorder.json" 2>/dev/null)"
    ERR="$(cat "${STATE}/recorder.err" 2>/dev/null)"
}
# field <name>: the item's value for that field, as stored, or nothing
field() { sed -n "s/^ *\"$1\": {\"[SN]\": \"\(.*\)\"},\{0,1\}\$/\1/p" <<< "${ITEM}"; }
# is <description> <field> <value>: the item stores the field with that value; with the value -, no such field
is() {
    local got; got="$(field "$2")"
    if [ "$3" = - ]; then
        if [ -z "${got}" ]; then ok "$1: no $2"; else bad "$1: no $2" "no $2" "$2 ${got}"; fi
    elif [ "${got}" = "$3" ] && grep -q "\"$2\": " <<< "${ITEM}"; then
        ok "$1: $2 $3"
    else
        bad "$1: $2 $3" "$3" "${got:-no $2}"
    fi
}
# notes <description> <n>: the run printed <n> NOTE(s) that the time per iteration is on the nominal size
notes() {
    local n; n="$(grep -c "^${NOMINAL_NOTE}" <<< "${ERR}")"
    if [ "${n}" = "$2" ]; then ok "$1: ${n} NOTE on the nominal size"
    else bad "$1: $2 NOTE on the nominal size" "$2" "${n}: ${ERR}"; fi
}
# exits0 <description>: the last record exited 0
exits0() { if [ "${RC}" -eq 0 ]; then ok "$1: exit 0"; else bad "$1: exit 0" "exit 0" "exit ${RC}: ${ERR}"; fi; }
