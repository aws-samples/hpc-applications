#!/bin/bash
# =============================================================================
# Fixture-driven tests for dynamodb/record-benchmark.sh
# =============================================================================
# Uses --dry-run throughout: no AWS calls, no credentials, no files written,
# no Slurm and no licensed solver.
#
#   ./tests/test-recorder.sh
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
# shellcheck source=fixture-helpers.sh
. "${HERE}/fixture-helpers.sh"

REC="${HERE}/../dynamodb/record-benchmark.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

# Minimal valid identity so the required-field checks pass off-cluster.
base_args=( --instance-type hpc6id.32xlarge --os "Amazon Linux 2023"
            --num-cores 64 --num-nodes 1 --mpi intelmpi --version v261
            --case V26direct-5 --source TestSuite --dry-run )

# run_rec <run_dir> [extra args...] -> JSON on stdout, notes on stderr (captured)
run_rec() {
    local rd="$1"; shift
    RUN_DIR="$rd" "${REC}" "${base_args[@]}" --run-dir "$rd" "$@" 2>/tmp/rec-stderr.$$
}
# Extract a numeric attribute from the emitted DynamoDB item JSON.
attr_n() { grep -A1 "\"$2\"" <<<"$1" | grep -oE '"N": "[^"]*"' | head -1 | sed -E 's/.*"N": "([^"]*)".*/\1/'; }
has_attr() { grep -q "\"$2\"" <<<"$1"; }

echo "== replay discovery: the launcher writes output-<jobid>.log, not output.log =="

tmp="$(mktemp -d)"
cp "${FIX}/normal-success.log" "${tmp}/output-90210.log"
out="$(run_rec "${tmp}")"
got="$(attr_n "${out}" time_to_solution_seconds)"
if [ "${got}" = "845.000" ]; then
    ok "output-<jobid>.log is discovered and 845.000 s recovered"
else
    bad "output-<jobid>.log discovery" "845.000" "${got:-<absent>}"
fi
rm -rf "${tmp}"

tmp="$(mktemp -d)"
cp "${FIX}/normal-success.log" "${tmp}/output.log"
out="$(run_rec "${tmp}")"
got="$(attr_n "${out}" time_to_solution_seconds)"
[ "${got}" = "845.000" ] && ok "plain output.log still works (unchanged behaviour)" \
    || bad "output.log discovery" "845.000" "${got:-<absent>}"
rm -rf "${tmp}"

tmp="$(mktemp -d)"
cp "${FIX}/normal-success.log" "${tmp}/solve.out"
out="$(run_rec "${tmp}")"
got="$(attr_n "${out}" time_to_solution_seconds)"
[ "${got}" = "845.000" ] && ok "*.out still works (unchanged behaviour)" \
    || bad "*.out discovery" "845.000" "${got:-<absent>}"
rm -rf "${tmp}"

echo "== a valid fixed-iteration benchmark is still recorded =="

tmp="$(mktemp -d)"
cp "${FIX}/benign-iteration-stop.log" "${tmp}/output-90211.log"
out="$(run_rec "${tmp}")"
got="$(attr_n "${out}" time_to_solution_seconds)"
[ "${got}" = "1244.974" ] && ok "benign iteration stop: timing derived (1244.974)" \
    || bad "benign iteration stop timing" "1244.974" "${got:-<absent>}"
rm -rf "${tmp}"

tmp="$(mktemp -d)"
cp "${FIX}/iterative-pcg.log" "${tmp}/output-90222.log"
out="$(run_rec "${tmp}")"
got="$(attr_n "${out}" time_to_solution_seconds)"
[ "${got}" = "928.538" ] && ok "iterative (PCG) run: timing derived (928.538)" \
    || bad "iterative run timing" "928.538" "${got:-<absent>}"
rm -rf "${tmp}"

echo "== derived timing requires a VERIFIED solve =="

tmp="$(mktemp -d)"
cp "${FIX}/truncated-no-completion.log" "${tmp}/output-90212.log"
out="$(run_rec "${tmp}")"
if has_attr "${out}" time_to_solution_seconds; then
    bad "truncated output derives no timing" "attribute absent" "$(attr_n "${out}" time_to_solution_seconds)"
else
    ok "truncated output (no RUN COMPLETED) derives no timing"
fi
grep -q "no 'RUN COMPLETED'" /tmp/rec-stderr.$$ \
    && ok "truncated output explains itself on stderr" \
    || bad "truncated output note" "mentions RUN COMPLETED" "$(head -2 /tmp/rec-stderr.$$)"
rm -rf "${tmp}"

tmp="$(mktemp -d)"
cp "${FIX}/genuine-error-column-zero.log" "${tmp}/output-90213.log"
out="$(run_rec "${tmp}")"
if has_attr "${out}" time_to_solution_seconds; then
    bad "genuine error derives no timing" "attribute absent" "$(attr_n "${out}" time_to_solution_seconds)"
else
    ok "column-zero genuine error derives no timing (even with RUN COMPLETED present)"
fi
rm -rf "${tmp}"

# A disk-full abort carries RUN COMPLETED and a positive Elapsed Time; only its
# error block says the solve never finished.
tmp="$(mktemp -d)"
cp "${FIX}/disk-full-abort.log" "${tmp}/output-90221.log"
out="$(run_rec "${tmp}")"
if has_attr "${out}" time_to_solution_seconds; then
    bad "disk-full abort derives no timing" "attribute absent" "$(attr_n "${out}" time_to_solution_seconds)"
else
    ok "disk-full abort derives no timing (RUN COMPLETED and Elapsed Time present)"
fi
rm -rf "${tmp}"

# The recorder carries its own copy of the block classifier, so the anchored
# benign match must hold here too: expected termination text PLUS another failure
# in the same block is NOT benign and must not yield a recorded solve time.
for fx in benign-block-with-extra-failure benign-block-observed-wording-with-extra-failure; do
    tmp="$(mktemp -d)"
    cp "${FIX}/${fx}.log" "${tmp}/output-90218.log"
    out="$(run_rec "${tmp}")"
    if has_attr "${out}" time_to_solution_seconds; then
        bad "${fx}: derives no timing" "attribute absent" \
            "$(attr_n "${out}" time_to_solution_seconds)"
    else
        ok "${fx}: augmented benign block derives no timing"
    fi
    rm -rf "${tmp}"
done

tmp="$(mktemp -d)"
cp "${FIX}/zero-elapsed.log" "${tmp}/output-90214.log"
out="$(run_rec "${tmp}")"
if has_attr "${out}" time_to_solution_seconds; then
    bad "zero elapsed derives no timing" "attribute absent" "$(attr_n "${out}" time_to_solution_seconds)"
else
    ok "Elapsed Time = 0.000 derives no timing"
fi
rm -rf "${tmp}"

tmp="$(mktemp -d)"
cp "${FIX}/negative-elapsed.log" "${tmp}/output-90215.log"
out="$(run_rec "${tmp}")"
if has_attr "${out}" time_to_solution_seconds; then
    bad "negative elapsed derives no timing" "attribute absent" "$(attr_n "${out}" time_to_solution_seconds)"
else
    ok "Elapsed Time = -5.000 derives no timing"
fi
rm -rf "${tmp}"

tmp="$(mktemp -d)"
cp "${FIX}/benign-malformed-possessive.log" "${tmp}/output-90219.log"
out="$(run_rec "${tmp}")"
if has_attr "${out}" time_to_solution_seconds; then
    bad "malformed possessive derives no timing" "attribute absent" \
        "$(attr_n "${out}" time_to_solution_seconds)"
else
    ok "'userXs request' is not benign here either -> derives no timing"
fi
rm -rf "${tmp}"

# MAPDL pads its output lines. A genuine benign block with trailing padding must be
# ACCEPTED, and by both classifiers identically.
tmp="$(mktemp -d)"
if write_padded_benign_log "${tmp}/output-90220.log"; then
    out="$(run_rec "${tmp}")"
    got="$(attr_n "${out}" time_to_solution_seconds)"
    [ "${got}" = "456.000" ] && ok "benign block with trailing padding still derives timing (456.000)" \
        || bad "trailing-padding benign timing" "456.000" "${got:-<absent>}"
else
    bad "generate the padded fixture" "trailing whitespace present" "generation failed"
fi
rm -rf "${tmp}"

echo "== cores_per_node is never invented for a non-uniform layout =="

tmp="$(mktemp -d)"
# 85 cores over 2 nodes: ceil() would have produced a bogus uniform 43.
out="$(run_rec "${tmp}" --num-cores 85 --num-nodes 2 --time-to-solution 100 \
        --char task_placement=node1:43:node2:42)"
if has_attr "${out}" cores_per_node; then
    bad "task_placement suppresses cores_per_node" "absent" "$(attr_n "${out}" cores_per_node)"
else
    ok "task_placement supplied -> cores_per_node is NOT derived"
fi
has_attr "${out}" task_placement && ok "the real layout is recorded as task_placement" \
    || bad "task_placement recorded" "present" "absent"

out="$(run_rec "${tmp}" --num-cores 85 --num-nodes 2 --time-to-solution 100)"
if has_attr "${out}" cores_per_node; then
    bad "non-divisible layout suppresses cores_per_node" "absent" "$(attr_n "${out}" cores_per_node)"
else
    ok "non-divisible 85/2 -> cores_per_node is NOT derived even without task_placement"
fi

out="$(run_rec "${tmp}" --num-cores 384 --num-nodes 2 --time-to-solution 100)"
got="$(attr_n "${out}" cores_per_node)"
[ "${got}" = "192" ] && ok "uniform 384/2 -> cores_per_node=192 (exact division, no ceil)" \
    || bad "uniform derivation" "192" "${got:-<absent>}"

out="$(run_rec "${tmp}" --num-cores 85 --num-nodes 2 --cores-per-node 43 --time-to-solution 100 \
        --char task_placement=node1:43:node2:42)"
got="$(attr_n "${out}" cores_per_node)"
[ "${got}" = "43" ] && ok "an EXPLICIT --cores-per-node is still honoured" \
    || bad "explicit cores-per-node honoured" "43" "${got:-<absent>}"
rm -rf "${tmp}"

echo "== explicit timing must also be finite and positive =="

tmp="$(mktemp -d)"
for badval in 0 -5 0.0 abc; do
    out="$(run_rec "${tmp}" --time-to-solution "${badval}")"
    if has_attr "${out}" time_to_solution_seconds; then
        bad "explicit --time-to-solution ${badval} rejected" "attribute absent" \
            "$(attr_n "${out}" time_to_solution_seconds)"
    else
        ok "explicit --time-to-solution ${badval} is rejected"
    fi
done

out="$(run_rec "${tmp}" --time-to-solution 612)"
got="$(attr_n "${out}" time_to_solution_seconds)"
[ "${got}" = "612" ] && ok "explicit valid --time-to-solution 612 is recorded" \
    || bad "explicit valid timing" "612" "${got:-<absent>}"
rm -rf "${tmp}"

echo "== explicit values stay authoritative over derived ones =="

tmp="$(mktemp -d)"
cp "${FIX}/normal-success.log" "${tmp}/output-90216.log"   # would derive 845.000
out="$(run_rec "${tmp}" --time-to-solution 999)"
got="$(attr_n "${out}" time_to_solution_seconds)"
[ "${got}" = "999" ] && ok "explicit 999 wins over the derivable 845.000" \
    || bad "explicit wins over derived" "999" "${got:-<absent>}"
rm -rf "${tmp}"

echo "== schema sanity =="

tmp="$(mktemp -d)"
cp "${FIX}/normal-success.log" "${tmp}/output-90217.log"
out="$(run_rec "${tmp}" --mdofs 12.5 --analysis-type static \
        --metric mapdl_elapsed_seconds=845.0 --char memory_mode=InCore --char scratch_mode=nvme)"
allgood=1
for a in record_id application benchmark_case instance_type operating_system \
         num_cores num_instances libraries time_to_solution_seconds \
         mapdl_elapsed_seconds memory_mode scratch_mode provenance_origin; do
    has_attr "${out}" "$a" || { bad "required attribute '$a' present" "present" "absent"; allgood=0; }
done
[ "${allgood}" -eq 1 ] && ok "all canonical attributes emitted (incl. extra metrics/chars)"
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "${out}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        ok "emitted item is valid JSON"
    else
        bad "emitted item is valid JSON" "parses" "invalid"
    fi
fi
rm -rf "${tmp}"

rm -f /tmp/rec-stderr.$$
echo
printf 'recorder tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
