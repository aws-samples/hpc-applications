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
# shellcheck source=fixture-helpers.sh
. "${HERE}/fixture-helpers.sh"

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

verdict_is iterative-pcg.log 0 1 0 \
    "iterative (PCG) completion, rc=0 -> success"

echo "== genuine errors must be caught at ANY indentation =="

verdict_is genuine-error-column-zero.log 2 0 2 \
    "column-zero '*** ERROR ***' with RUN COMPLETED present -> failure, rc preserved"

verdict_is genuine-error-deep-indent.log 2 0 2 \
    "deeply indented '*** ERROR ***' -> failure, rc preserved"

verdict_is genuine-error-column-zero.log 0 0 3 \
    "genuine error but MAPDL returned 0 -> failure is SYNTHESISED (never reports success)"

verdict_is benign-plus-genuine-error.log 1 0 1 \
    "benign stop in a SEPARATE block from a real error -> failure"

echo "== the benign whitelist matches a COMPLETE block, not a substring =="

# A single block carrying the expected termination text *plus* another genuine
# failure must not be absolved. Both observed wording variants are covered.
verdict_is benign-block-with-extra-failure.log 0 0 3 \
    "benign phrases + extra failure text in ONE block -> failure (anchored match)"

verdict_is benign-block-with-extra-failure.log 1 0 1 \
    "same augmented block with rc=1 -> failure, rc preserved"

verdict_is benign-block-observed-wording-with-extra-failure.log 0 0 3 \
    "observed wording + extra failure text in ONE block -> failure"

for fx in benign-block-with-extra-failure benign-block-observed-wording-with-extra-failure; do
    got="$(mapdl_count_error_blocks "${FIX}/${fx}.log")"
    [ "${got}" = "1 0 1" ] && ok "${fx}: block classified unexpected, not benign" \
        || bad "${fx} block counts" "1 0 1" "${got}"
done

echo "== the possessive is a literal apostrophe, not 'any character' =="

# `user.?s` would accept malformed text like `userXs`, because in ERE `.?` is any
# single character. The wording must match literally.
verdict_is benign-malformed-possessive.log 0 0 3 \
    "'userXs request' is NOT the benign message -> failure"

got="$(mapdl_count_error_blocks "${FIX}/benign-malformed-possessive.log")"
[ "${got}" = "1 0 1" ] && ok "malformed possessive classified unexpected" \
    || bad "malformed possessive block counts" "1 0 1" "${got}"

echo "== MAPDL pads its lines: trailing whitespace must not reject a good run =="

padded="$(mktemp)"
if write_padded_benign_log "${padded}"; then
    mapdl_solve_verdict "${padded}" 1
    if [ "${MAPDL_SOLVE_OK}" = "1" ] && [ "${MAPDL_FINAL_RC}" = "0" ]; then
        ok "benign block with trailing padding + rc=1 -> accepted (trimmed both ends)"
    else
        bad "padded benign block accepted" "solve_ok=1 final_rc=0" "$(mapdl_verdict_summary)"
    fi
    blk="$(mapdl_error_blocks "${padded}")"
    case "${blk}" in
        *" ") bad "block body is trimmed at both ends" "no trailing space" "<${blk}>" ;;
        *)    ok "block body is trimmed at both ends" ;;
    esac
else
    bad "generate the padded fixture" "trailing whitespace present" "generation failed"
fi
rm -f "${padded}"

echo "== normalisation is limited to the benign exit-status set =="

# Grounded in the recorded campaign: the fixed-iteration stop exited 1 and 255;
# runs that reached their own end exited 0. Anything else is an unrelated failure
# and must NOT be masked just because a benign block is present.
for rc in 0 1 255; do
    verdict_is benign-iteration-stop.log "${rc}" 1 0 \
        "benign stop + rc=${rc} -> accepted (rc is in the benign status set)"
done
for rc in 2 42 137; do
    verdict_is benign-iteration-stop.log "${rc}" 0 "${rc}" \
        "benign stop + rc=${rc} -> FAILURE, rc preserved (not in the benign status set)"
done

echo "== unverified output must never report scheduler success =="

verdict_is truncated-no-completion.log 0 0 3 \
    "truncated output, rc=0 -> failure synthesised (rc=3)"

verdict_is truncated-no-completion.log 1 0 1 \
    "truncated output, rc=1 -> failure, solver rc preserved"

verdict_is missing-file-does-not-exist.log 0 0 3 \
    "output file absent, rc=0 -> failure synthesised"

echo "== an unrelated non-zero status must NOT be normalised away =="

verdict_is normal-success.log 42 0 42 \
    "clean output but rc=42 with no benign block -> rc=42 preserved AND not accepted"

echo "== 'accepted' means verified output AND a zero final status =="

# solve_ok is what the launcher gates benchmark recording on, so it must never be
# true for a job the scheduler reports as failed - otherwise a failed run becomes
# training data. This is the invariant, asserted over the whole matrix below.
for fx in normal-success benign-iteration-stop genuine-error-column-zero \
          truncated-no-completion zero-elapsed negative-elapsed \
          benign-plus-genuine-error benign-block-with-extra-failure; do
    for rc in 0 1 2 42 255; do
        mapdl_solve_verdict "${FIX}/${fx}.log" "${rc}"
        if [ "${MAPDL_SOLVE_OK}" -eq 1 ] && [ "${MAPDL_FINAL_RC}" -ne 0 ]; then
            bad "${fx} + rc=${rc}: accepted implies final_rc=0" \
                "solve_ok=1 => final_rc=0" "$(mapdl_verdict_summary)"
        fi
    done
done
ok "across 8 fixtures x rc {0,1,2,42,255}: solve_ok=1 never coexists with a non-zero final_rc"

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

echo "== memory mode comes from MAPDL's 'Memory Option:' line =="

# Every sparse-direct run prints "Equation solver memory required for
# out-of-core mode" in its memory summary, in-core runs included, so a search of
# the whole output for "out-of-core" labels every in-core run out-of-core.
if grep -qi 'out-of-core' "${FIX}/normal-success.log"; then
    ok "the in-core fixture mentions out-of-core outside its Memory Option line"
else
    bad "in-core fixture mentions out-of-core" "present (or the next test is vacuous)" "absent"
fi
got="$(mapdl_memory_mode "${FIX}/normal-success.log")"
[ "${got}" = "InCore" ] && ok "Memory Option: In-Core -> InCore, despite the out-of-core requirement line" \
    || bad "In-Core detected" "InCore" "${got}"
got="$(mapdl_memory_mode "${FIX}/benign-iteration-stop.log")"
[ "${got}" = "OutOfCore" ] && ok "Memory Option: Optimal Out-of-Core -> OutOfCore" \
    || bad "Out-of-Core detected" "OutOfCore" "${got}"
got="$(mapdl_memory_mode "${FIX}/iterative-pcg.log")"
[ "${got}" = "unknown" ] && ok "iterative (PCG) run prints no Memory Option line -> unknown" \
    || bad "iterative run memory mode" "unknown" "${got}"
got="$(mapdl_memory_mode "${FIX}/truncated-no-completion.log")"
[ "${got}" = "unknown" ] && ok "run that stopped before its statistics -> unknown" \
    || bad "truncated run memory mode" "unknown" "${got}"

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

echo "== the live and replay classifiers must agree on EVERY fixture =="

# Two production implementations classify MAPDL error blocks: the authoritative
# library, and the compact copy inside dynamodb/record-benchmark.sh (which stays
# self-contained by design). If they diverge, the same solver output is accepted
# live and rejected on replay, or the reverse. Extract the recorder's real function
# and run both over every fixture.
REC="${HERE}/../dynamodb/record-benchmark.sh"
rec_fn="$(mktemp)"
sed -n '/^mapdl_unexpected_error_blocks()/,/^}/p' "${REC}" > "${rec_fn}"
if [ ! -s "${rec_fn}" ]; then
    bad "extract the recorder's classifier" "function found" "not found in ${REC}"
else
    # Include the GENERATED padded log: trailing whitespace is precisely where the
    # two implementations used to disagree, so it must be in this sweep.
    padded_cmp="$(mktemp)"; write_padded_benign_log "${padded_cmp}"
    agree=1; checked=0
    for fx in "${FIX}"/*.log "${padded_cmp}"; do
        mapdl_solve_verdict "${fx}" 0
        live="${MAPDL_UNEXPECTED}"
        replay="$(bash -c ". '${rec_fn}'; mapdl_unexpected_error_blocks '${fx}'" 2>/dev/null)"
        # The library reports a count of unexpected blocks; so does the recorder.
        if [ "${live}" != "${replay}" ]; then
            bad "live/replay agree on $(basename "${fx}")" \
                "both report the same unexpected count" "live=${live} replay=${replay}"
            agree=0
        fi
        checked=$((checked+1))
    done
    rm -f "${padded_cmp}"
    [ "${agree}" -eq 1 ] && ok "live and replay classifiers agree on all ${checked} fixtures (incl. the padded one)"
fi
rm -f "${rec_fn}"

echo
printf 'verdict tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ] || exit 1
