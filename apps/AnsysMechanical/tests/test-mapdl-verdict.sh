#!/bin/bash
# =============================================================================
# Fixture-driven tests for lib/mapdl-verdict.sh
# =============================================================================
# Needs no Slurm, no EC2, no licensed solver and no AWS credentials.
#
#   ./tests/test-mapdl-verdict.sh          # run everything
#
# Every case below encodes a boundary where an earlier revision of this launcher
# got the verdict WRONG (accepting a real failure, or rejecting a valid
# fixed-iteration benchmark). Keep them passing.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
LIB="${HERE}/../lib/mapdl-verdict.sh"

# shellcheck source=../lib/mapdl-verdict.sh
. "${LIB}"

pass=0; fail=0; skip=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }

# verdict_is <fixture> <rc> <expected solve_ok> <expected final_rc> <label>
verdict_is() {
    local fx="$1" rc="$2" want_ok="$3" want_rc="$4" label="$5"
    # Called directly (NOT in a subshell) so the verdict globals reach us.
    mapdl_solve_verdict "${FIX}/${fx}" "${rc}"
    if [ "${MAPDL_SOLVE_OK}" = "${want_ok}" ] && [ "${MAPDL_FINAL_RC}" = "${want_rc}" ]; then
        ok "${label}"
    else
        bad "${label}" "solve_ok=${want_ok} final_rc=${want_rc}" "$(mapdl_verdict_summary)"
    fi
}

echo "== solve verdict: the run is judged by its OUTPUT, not its exit code =="

verdict_is normal-success.log 0 1 0 \
    "normal completion, rc=0 -> success"

verdict_is benign-iteration-stop.log 1 1 0 \
    "expected fixed-iteration stop, rc=1 -> success (non-zero explained by the benign block)"

verdict_is benign-iteration-stop.log 0 1 0 \
    "expected fixed-iteration stop, rc=0 -> success"

echo "== genuine errors must be caught at ANY indentation =="

verdict_is genuine-error-column-zero.log 2 0 2 \
    "column-zero '*** ERROR ***' with RUN COMPLETED present -> failure, rc preserved"

verdict_is genuine-error-deep-indent.log 2 0 2 \
    "deeply indented '*** ERROR ***' -> failure, rc preserved"

verdict_is genuine-error-column-zero.log 0 0 3 \
    "genuine error but MAPDL returned 0 -> failure is SYNTHESISED (never reports success)"

verdict_is benign-plus-genuine-error.log 1 0 1 \
    "benign stop alongside a real error -> failure (the benign whitelist does not absolve the rest)"

echo "== unverified output must never report scheduler success =="

verdict_is truncated-no-completion.log 0 0 3 \
    "truncated output, rc=0 -> failure synthesised (rc=3)"

verdict_is truncated-no-completion.log 1 0 1 \
    "truncated output, rc=1 -> failure, solver rc preserved"

verdict_is missing-file-does-not-exist.log 0 0 3 \
    "output file absent, rc=0 -> failure synthesised"

echo "== an unrelated non-zero status must NOT be normalised away =="

verdict_is normal-success.log 42 1 42 \
    "clean output but rc=42 with no benign block -> rc=42 preserved"

echo "== elapsed time must be finite and strictly positive =="

verdict_is zero-elapsed.log 0 0 3 \
    "Elapsed Time (sec) = 0.000 -> failure"

verdict_is negative-elapsed.log 0 0 3 \
    "Elapsed Time (sec) = -5.000 -> failure"

got="$(mapdl_elapsed_seconds "${FIX}/normal-success.log")"
if [ "${got}" = "845.000" ]; then
    ok "elapsed parses the value after '=' (845.000), not the trailing Date year"
else
    bad "elapsed parses the value after '=' not the Date year" "845.000" "${got:-<empty>}"
fi

for f in zero-elapsed negative-elapsed; do
    got="$(mapdl_elapsed_seconds "${FIX}/${f}.log")"
    if [ -z "${got}" ]; then ok "${f}: non-positive elapsed yields no value"
    else bad "${f}: non-positive elapsed yields no value" "<empty>" "${got}"; fi
done

echo "== error-block classification =="

got="$(mapdl_count_error_blocks "${FIX}/benign-iteration-stop.log")"
[ "${got}" = "1 1 0" ] && ok "benign fixture: 1 block, 1 benign, 0 unexpected" \
    || bad "benign fixture block counts" "1 1 0" "${got}"

got="$(mapdl_count_error_blocks "${FIX}/benign-plus-genuine-error.log")"
[ "${got}" = "2 1 1" ] && ok "mixed fixture: 2 blocks, 1 benign, 1 unexpected" \
    || bad "mixed fixture block counts" "2 1 1" "${got}"

got="$(mapdl_count_error_blocks "${FIX}/normal-success.log")"
[ "${got}" = "0 0 0" ] && ok "clean fixture: no error blocks (NOTE/WARNING blocks are not errors)" \
    || bad "clean fixture block counts" "0 0 0" "${got}"

# An error block with no body must still count: unclassifiable is a failure.
empty_body="$(mktemp)"; printf ' *** ERROR ***    CP = 1.0\n\n' > "${empty_body}"
got="$(mapdl_count_error_blocks "${empty_body}")"
[ "${got}" = "1 0 1" ] && ok "error block with an empty body still counts as unexpected" \
    || bad "empty-body error block counts" "1 0 1" "${got}"
rm -f "${empty_body}"

echo "== memory mode =="
got="$(mapdl_memory_mode "${FIX}/normal-success.log")"
[ "${got}" = "InCore" ] && ok "In-Core detected" || bad "In-Core detected" "InCore" "${got}"
got="$(mapdl_memory_mode "${FIX}/benign-iteration-stop.log")"
[ "${got}" = "OutOfCore" ] && ok "Out-of-Core detected" || bad "Out-of-Core detected" "OutOfCore" "${got}"

echo "== stage-out: cleanup must never run on a failed copy =="

tmp="$(mktemp -d)"
src="${tmp}/output-4242.log"; cp "${FIX}/normal-success.log" "${src}"

if mapdl_stage_out "${src}" "${tmp}/shared" 2>/dev/null; then
    if [ -s "${tmp}/shared/output-4242.log" ]; then
        ok "successful stage-out returns 0 and the destination is intact"
    else bad "successful stage-out leaves the file" "non-empty dest" "missing/empty"; fi
else
    bad "successful stage-out returns 0" "rc=0" "rc!=0"
fi

if mapdl_stage_out "${src}" "${tmp}/shared" >/dev/null 2>&1 \
   && cmp -s "${src}" "${tmp}/shared/output-4242.log"; then
    ok "staged copy is byte-identical to the source"
else
    bad "staged copy is byte-identical" "identical" "differs"
fi

# Same path in and out (SCRATCH_MODE=shared): nothing to copy, still a success.
if mapdl_stage_out "${tmp}/shared/output-4242.log" "${tmp}/shared" >/dev/null 2>&1; then
    ok "already-shared output stages successfully without copying onto itself"
else
    bad "already-shared output stage-out" "rc=0" "rc!=0"
fi

# Empty output must not be accepted as a durable copy.
: > "${tmp}/empty.log"
if mapdl_stage_out "${tmp}/empty.log" "${tmp}/shared" >/dev/null 2>&1; then
    bad "empty source rejected" "rc!=0" "rc=0"
else
    ok "empty solver output is not accepted as a successful stage-out"
fi

# Missing source.
if mapdl_stage_out "${tmp}/nope.log" "${tmp}/shared" >/dev/null 2>&1; then
    bad "missing source rejected" "rc!=0" "rc=0"
else
    ok "missing source is rejected"
fi

# Unwritable destination = the failure mode that used to delete the only log.
if [ "$(id -u)" -eq 0 ]; then
    skipt "unwritable destination is rejected" "running as root; permissions do not apply"
else
    ro="${tmp}/readonly"; mkdir -p "${ro}"; chmod 500 "${ro}"
    if mapdl_stage_out "${src}" "${ro}" >/dev/null 2>&1; then
        bad "unwritable destination rejected" "rc!=0" "rc=0"
    else
        ok "unwritable destination is rejected (so scratch is retained, not reclaimed)"
    fi
    chmod 700 "${ro}"
fi
rm -rf "${tmp}"

echo
printf 'verdict tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ] || exit 1
