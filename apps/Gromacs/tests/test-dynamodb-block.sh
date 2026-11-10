#!/bin/bash
# =============================================================================
# The optional DynamoDB block of the three launchers (x86/, Arm/ and
# GPU/gromacs-benchmark.sbatch), uncommented as dynamodb/README.md says, takes
# the launchers' success gate (test-mdlog-gate.sh, test-gpu-gate.sh): it calls
# record_to_dynamodb.sh for a run whose md.log gives a positive ns/day, as the
# contribution recorder records it, and for no other run (no Performance line,
# or a rate of 0), where the gate's NOTE says why and the job still exits 0.
# Each launcher runs from a copy that differs from it in that block alone
# (checked here), with a stub in place of record_to_dynamodb.sh. As shipped,
# with the block commented out, the stub is never called.
#
# Runs the launchers with the stubs of harness.sh, the GPU launcher with its GPU
# stubs (gpu_stubs) and the stub L40S build's env script.
#
#   ./tests/test-dynamodb-block.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
gpu_stubs
recorder_calls() { grep -c 'BENCHMARK_CASE=' "${RECLOG}"; }

UPLOADER_LOG="${STUBS}/uploader.log"
cat > "${STUBS}/bin/uploader-stub.sh" <<'EOF'
#!/bin/bash
# Stands in for dynamodb/record_to_dynamodb.sh: logs values the launcher exports to it.
echo "MODEL=${MODEL:-} NS_PER_DAY=${NS_PER_DAY:-} GPU_COUNT=${GPU_COUNT:-}" >> "${UPLOADER_LOG}"
exit 0
EOF
chmod +x "${STUBS}/bin/uploader-stub.sh"
uploader_calls() { grep -c . "${UPLOADER_LOG}"; }

# uncomment_uploader <script> <copy>: writes to <copy> the script with its
# optional DynamoDB block uncommented as dynamodb/README.md says, the leading
# '# ' stripped from each line, from the one after the block's header to the
# blank line that ends it. Prints the first and last line it changed; fails if
# there is no such block, or a line of it does not start with '# '.
uncomment_uploader() {
    awk -v out="$2" '
      state == 2 && /^$/ { state = 3; last = NR - 1 }
      state == 2 { if (substr($0, 1, 2) != "# ") bad = 1; $0 = substr($0, 3); if (!first) first = NR }
      { print > out }
      state == 1 && /^# -+$/ { state = 2 }
      state == 0 && $0 == "# Optional: record the result to DynamoDB." { state = 1 }
      END { if (state != 3 || bad) exit 1; print first, last }
    ' "$1"
}

# The copies, in a tree laid out as apps/Gromacs: run_launcher runs them when
# GROMACS_APP names it.
SHIPPED_APP="${GROMACS_APP}"
COPY_APP="${STUBS}/uncommented"

# launch <x86|Arm|GPU> <shipped|uncommented> [NAME=value...]: run_launcher on
# one node, with the stub in place of record_to_dynamodb.sh, the GPU launcher
# with the stub GPU build
launch() {
    local arch="$1" tree="$2"; shift 2
    : > "${UPLOADER_LOG}"
    [ "${tree}" = uncommented ] && GROMACS_APP="${COPY_APP}"
    if [ "${arch}" = GPU ]; then set -- GROMACS_ENV="${GPU_TMPI_ENV}" "$@"; fi
    run_launcher "${arch}" DYNAMODB_RECORDER="${STUBS}/bin/uploader-stub.sh" UPLOADER_LOG="${UPLOADER_LOG}" "$@"
    GROMACS_APP="${SHIPPED_APP}"
}

for arch in x86 Arm GPU; do
    echo "== ${arch}/gromacs-benchmark.sbatch =="
    gpu_count=""; [ "${arch}" = GPU ] && gpu_count=1

    launch "${arch}" shipped
    if [ "${RC}" -eq 0 ] && [ "$(uploader_calls)" -eq 0 ] && [ "$(recorder_calls)" -eq 1 ]; then
        ok "as shipped, the block commented out: record_to_dynamodb.sh is not called, the contribution recorder is"
    else
        bad "as shipped: record_to_dynamodb.sh is not called" "exit 0, no DynamoDB call, 1 contribution recorder call" \
            "exit ${RC}, $(uploader_calls) DynamoDB call(s), $(recorder_calls) contribution recorder call(s)"
    fi

    mkdir -p "${COPY_APP}/${arch}"
    script="${SHIPPED_APP}/${arch}/gromacs-benchmark.sbatch" copy="${COPY_APP}/${arch}/gromacs-benchmark.sbatch"
    if span="$(uncomment_uploader "${script}" "${copy}")" && bash -n "${copy}" \
            && [ "$(diff "${script}" "${copy}" | grep -E '^[0-9]')" = "${span/ /,}c${span/ /,}" ]; then
        ok "the DynamoDB block uncommented: the copy differs from the script in that block alone (lines ${span/ /-})"
    else
        bad "the DynamoDB block uncommented: the copy differs from the script in that block alone" \
            "the block's lines, each without its leading '# ', and nothing else" \
            "lines ${span:-none}; $(diff "${script}" "${copy}" 2>&1 | grep -E '^[0-9]' | tr '\n' '|')"
    fi

    launch "${arch}" uncommented
    want="MODEL=benchMEM NS_PER_DAY=100.000 GPU_COUNT=${gpu_count}"
    if [ "${RC}" -eq 0 ] && [ "$(uploader_calls)" -eq 1 ] && grep -qxF "${want}" "${UPLOADER_LOG}" \
            && [ "$(recorder_calls)" -eq 1 ]; then
        ok "uncommented, a positive ns/day: recorded once by each recorder (${want})"
    else
        bad "uncommented, a positive ns/day: recorded once by each recorder" \
            "exit 0; one DynamoDB call, ${want}; one contribution recorder call" \
            "exit ${RC}; $(tr '\n' '|' < "${UPLOADER_LOG}"); $(recorder_calls) contribution recorder call(s)"
    fi

    for case_ in "no Performance line|STUB_NS_PER_DAY=" "ns/day 0.000|STUB_NS_PER_DAY=0.000"; do
        label="${case_%%|*}"
        launch "${arch}" uncommented "${case_#*|}"
        if [ "${RC}" -eq 0 ] && [ "$(uploader_calls)" -eq 0 ] && [ "$(recorder_calls)" -eq 0 ] \
                && grep -qx 'NOTE: md.log gives no positive ns/day, so this run is not recorded.' <<<"${ERR}" \
                && ! grep -q 'DynamoDB recorder not found' <<<"${OUT}"; then
            ok "uncommented, ${label}: neither recorder is called, the gate's NOTE says why, and the job exits 0"
        else
            bad "uncommented, ${label}: neither recorder is called" \
                "exit 0; no DynamoDB call; no contribution recorder call; the gate's NOTE" \
                "exit ${RC}; $(uploader_calls) DynamoDB call(s): $(tr '\n' '|' < "${UPLOADER_LOG}"); $(recorder_calls) contribution recorder call(s); $(grep -E '^NOTE|DynamoDB' <<<"${OUT}" | head -2 | tr '\n' '|')"
        fi
    done

    launch "${arch}" uncommented DYNAMODB_RECORDER="${STUBS}/no-such-recorder.sh"
    if [ "${RC}" -eq 0 ] && grep -qxF "DynamoDB recorder not found at ${STUBS}/no-such-recorder.sh — skipping result persistence" \
            <<<"${OUT}" && [ "$(recorder_calls)" -eq 1 ]; then
        ok "uncommented, no record_to_dynamodb.sh at DYNAMODB_RECORDER: a line says so, the contribution recorder still records"
    else
        bad "uncommented, no record_to_dynamodb.sh at DYNAMODB_RECORDER" \
            "exit 0; the not-found line; one contribution recorder call" \
            "exit ${RC}; $(grep 'DynamoDB' <<<"${OUT}" | head -1); $(recorder_calls) contribution recorder call(s)"
    fi
done

summary "optional DynamoDB block tests"
