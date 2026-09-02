#!/bin/bash
# =============================================================================
# End-to-end test of AnsysMechanical.sbatch as ASSEMBLED.
# =============================================================================
# Runs the real launcher with stubbed scheduler/solver/MPI commands, so the whole
# script executes: task-placement derivation, the solve call, the verdict, the
# stage-out gate, the recorder invocation and the final exit status.
#
# No Slurm, no EC2, no MPI, no licensed solver, no AWS credentials, no network.
#
#   ./tests/test-sbatch-e2e.sh
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
SBATCH="${HERE}/../AnsysMechanical.sbatch"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }

STUBS="$(mktemp -d)"
trap 'rm -rf "${STUBS}"' EXIT

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "${STUBS}/bin"

cat > "${STUBS}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show hostnames=node[1-2]
for a in "$@"; do
  case "$a" in hostnames=*) echo "${a#hostnames=}" | tr ',' '\n';; esac
done
EOF

cat > "${STUBS}/bin/srun" <<'EOF'
#!/bin/bash
# Drop srun's own flags and run the remaining command locally, once.
while [ $# -gt 0 ]; do
  case "$1" in --ntasks=*|--ntasks-per-node=*|-n|-N) shift;; *) break;; esac
done
exec "$@"
EOF

cat > "${STUBS}/bin/mpirun" <<'EOF'
#!/bin/bash
echo "[stub mpirun] $*" >&2
exit 0
EOF

cat > "${STUBS}/bin/module" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "${STUBS}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS stub: token request or instance-type lookup.
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) echo "hpc6id.32xlarge";;
  *)               echo "";;
esac
exit 0
EOF

cat > "${STUBS}/bin/sudo" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "${STUBS}/bin/tee" <<'EOF'
#!/bin/bash
cat > /dev/null
EOF

# Recorder stub: log how the launcher invoked it (args + key env).
cat > "${STUBS}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
{
  echo "ARGS: $*"
  echo "BENCHMARK_CASE=${BENCHMARK_CASE:-}"
  echo "TIME_TO_SOLUTION=${TIME_TO_SOLUTION:-}"
  echo "MECHANICAL_VERSION=${MECHANICAL_VERSION:-}"
  echo "RUN_DIR=${RUN_DIR:-}"
} >> "${RECORDER_LOG}"
exit 0
EOF

# Real-recorder wrapper: runs the PRODUCTION recorder in dry-run and captures the
# item JSON it would store. Asserting launcher ARGUMENTS is not enough - the
# recorder derives fields of its own, so only the final JSON proves what would
# actually land in the dataset.
cat > "${STUBS}/bin/real-recorder.sh" <<EOF
#!/bin/bash
"${HERE}/../dynamodb/record-benchmark.sh" --dry-run --no-put --source E2ETest "\$@" \\
    > "\${RECORDER_JSON}" 2>> "\${RECORDER_LOG}"
EOF
chmod +x "${STUBS}"/bin/*

# run_case <fixture> <mapdl_rc> -> sets OUT / RC / RECLOG
run_case() {
    local fixture="$1" mapdl_rc="$2"
    local base; base="$(mktemp -d)"
    local vdir="${base}/ansys_inc/v261/ansys/bin"
    mkdir -p "${vdir}" "${base}/inputs"

    # mapdl stub: emit the chosen fixture to the -o target, exit with the chosen rc.
    cat > "${vdir}/mapdl" <<EOF
#!/bin/bash
outfile=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && outfile="\$a"
  prev="\$a"
done
echo "[stub mapdl] args: \$*" >&2
[ -n "\${outfile}" ] && cp "${fixture}" "\${outfile}"
exit ${mapdl_rc}
EOF
    chmod +x "${vdir}/mapdl"

    : > "${base}/inputs/V26direct-5.dat"
    : > "${base}/inputs/V26direct-5geom.db"

    RECLOG="${base}/recorder.log"; : > "${RECLOG}"

    OUT="$(
      PATH="${STUBS}/bin:${PATH}" \
      RECORDER_LOG="${RECLOG}" \
      DYNAMODB_RECORDER="${STUBS}/bin/recorder-stub.sh" \
      MAPDL_VERDICT_LIB="${HERE}/../lib/mapdl-verdict.sh" \
      BASE_DIR="${base}" \
      SCRATCH_MODE="shared" \
      SLURM_JOB_ID=90000 \
      SLURM_JOB_NAME="AnsysMechanical.sbatch" \
      SLURM_JOB_NUM_NODES=2 \
      SLURM_NPROCS=128 \
      SLURM_NTASKS=128 \
      SLURM_JOB_NODELIST="node1,node2" \
      SLURM_TASKS_PER_NODE="64(x2)" \
      SLURM_SUBMIT_DIR="${HERE}/.." \
      bash "${SBATCH}" v261 "${base}/inputs/V26direct-5.dat" 2>&1
    )"
    RC=$?
    BASEDIR="${base}"
}

echo "== the assembled launcher runs, and the verdict drives its exit status =="

run_case "${FIX}/normal-success.log" 0
[ "${RC}" -eq 0 ] && ok "clean solve, mapdl rc=0 -> job exits 0" \
    || bad "clean solve exit status" "0" "${RC}"
grep -q 'solve_ok=1' <<<"${OUT}" && ok "clean solve reports solve_ok=1" \
    || bad "clean solve verdict line" "solve_ok=1" "$(grep -o 'solve_ok=[0-9]' <<<"${OUT}" | head -1)"

run_case "${FIX}/benign-iteration-stop.log" 1
[ "${RC}" -eq 0 ] && ok "fixed-iteration deck, mapdl rc=1 -> job exits 0 (valid benchmark kept)" \
    || bad "benign stop exit status" "0" "${RC}"
grep -q 'TIME_TO_SOLUTION=' "${RECLOG}" && ok "benign stop still invokes the recorder" \
    || bad "benign stop recorder invoked" "recorder called" "not called"

run_case "${FIX}/genuine-error-column-zero.log" 2
[ "${RC}" -eq 2 ] && ok "column-zero real error, rc=2 -> job exits 2" \
    || bad "genuine error exit status" "2" "${RC}"
if [ -s "${RECLOG}" ]; then
    bad "genuine error skips recording" "recorder not called" "recorder called"
else
    ok "genuine error does NOT record a benchmark row"
fi
grep -q 'Unexpected MAPDL error block' <<<"${OUT}" \
    && ok "the offending error block is printed for the operator" \
    || bad "error block echoed" "printed" "absent"

run_case "${FIX}/truncated-no-completion.log" 0
[ "${RC}" -eq 3 ] && ok "truncated output with mapdl rc=0 -> job exits 3 (synthesised failure)" \
    || bad "truncated rc=0 exit status" "3" "${RC}"
if [ -s "${RECLOG}" ]; then
    bad "truncated run skips recording" "recorder not called" "recorder called"
else
    ok "truncated run does NOT record a benchmark row"
fi

run_case "${FIX}/normal-success.log" 42
[ "${RC}" -eq 42 ] && ok "unrelated rc=42 on clean output -> job exits 42 (not masked)" \
    || bad "unrelated nonzero exit status" "42" "${RC}"
# The integrity case: the scheduler sees failure 42, so no benchmark row may be
# written. Gating on output completeness alone used to let this through.
if [ -s "${RECLOG}" ]; then
    bad "rc=42 writes NO benchmark row" "recorder not called" "recorder called: $(head -1 "${RECLOG}")"
else
    ok "clean output + rc=42 records NOTHING (a failed job is not benchmark data)"
fi

run_case "${FIX}/benign-block-with-extra-failure.log" 0
[ "${RC}" -eq 3 ] && ok "augmented benign block, rc=0 -> job exits 3" \
    || bad "augmented benign block exit status" "3" "${RC}"
if [ -s "${RECLOG}" ]; then
    bad "augmented benign block records nothing" "recorder not called" "recorder called"
else
    ok "augmented benign block records NOTHING"
fi

run_case "${FIX}/benign-iteration-stop.log" 42
[ "${RC}" -eq 42 ] && ok "benign block + unrelated rc=42 -> job exits 42 (not masked by the block)" \
    || bad "benign block + rc=42 exit status" "42" "${RC}"
if [ -s "${RECLOG}" ]; then
    bad "benign block + rc=42 records nothing" "recorder not called" "recorder called"
else
    ok "benign block + rc=42 records NOTHING"
fi

run_case "${FIX}/benign-iteration-stop.log" 255
[ "${RC}" -eq 0 ] && ok "benign block + rc=255 -> job exits 0 (255 is an observed benign status)" \
    || bad "benign block + rc=255 exit status" "0" "${RC}"
grep -q 'TIME_TO_SOLUTION=' "${RECLOG}" && ok "benign block + rc=255 DOES record a row" \
    || bad "benign block + rc=255 records" "recorder called" "not called"

run_case "${FIX}/zero-elapsed.log" 0
[ "${RC}" -eq 3 ] && ok "zero elapsed time -> job exits 3" \
    || bad "zero elapsed exit status" "3" "${RC}"

echo "== task placement comes from Slurm =="

run_case "${FIX}/normal-success.log" 0
if grep -q 'node1:64:node2:64' <<<"${OUT}"; then
    ok "-machines built from SLURM_TASKS_PER_NODE (node1:64:node2:64)"
else
    bad "-machines list" "node1:64:node2:64" "$(grep -o 'Task placement: [^ ]*' <<<"${OUT}")"
fi
grep -q 'total 128 cores over 2 node' <<<"${OUT}" \
    && ok "placement total matches SLURM_NPROCS" \
    || bad "placement total" "128 cores over 2 nodes" "$(grep -o 'total .* node(s)' <<<"${OUT}")"

echo "== recorder receives the right metadata =="

run_case "${FIX}/normal-success.log" 0
grep -q 'BENCHMARK_CASE=V26direct-5'    "${RECLOG}" && ok "case name passed to the recorder" \
    || bad "case name" "V26direct-5" "$(grep BENCHMARK_CASE "${RECLOG}")"
grep -q 'MECHANICAL_VERSION=v261'       "${RECLOG}" && ok "version passed to the recorder" \
    || bad "version" "v261" "$(grep MECHANICAL_VERSION "${RECLOG}")"
grep -q 'mapdl_elapsed_seconds=845.000' "${RECLOG}" && ok "MAPDL elapsed passed as a metric" \
    || bad "mapdl_elapsed metric" "845.000" "$(grep ARGS "${RECLOG}")"
grep -q 'cores-per-node 64'             "${RECLOG}" && ok "cores-per-node passed from real placement" \
    || bad "cores-per-node" "64" "$(grep ARGS "${RECLOG}")"

echo "== NVMe mode: a failed stage-out must retain scratch and fail the job =="

# Runs the real launcher in nvme mode against a fake instance-store root, and makes
# the shared filesystem go read-only DURING the solve (the mapdl stub flips it) so
# the stage-out copy fails. This is the integration boundary the helper's unit test
# cannot cover: cleanup suppression, the recovery message, and the job status.
nvme_case() {   # <fixture> <mapdl_rc> <break_shared: 0|1>
    local fixture="$1" mapdl_rc="$2" break_shared="$3"
    local base; base="$(mktemp -d)"
    local vdir="${base}/ansys_inc/v261/ansys/bin"
    mkdir -p "${vdir}" "${base}/inputs" "${base}/fake-scratch"

    cat > "${vdir}/mapdl" <<EOF
#!/bin/bash
outfile=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && outfile="\$a"; prev="\$a"; done
[ -n "\${outfile}" ] && cp "${fixture}" "\${outfile}"
# Simulate the shared filesystem becoming unwritable while the solver ran.
if [ "${break_shared}" = "1" ]; then
    for d in "${base}"/*/Run/*; do [ -d "\$d" ] && chmod 500 "\$d"; done
fi
exit ${mapdl_rc}
EOF
    chmod +x "${vdir}/mapdl"
    : > "${base}/inputs/V26direct-5.dat"
    RECLOG="${base}/recorder.log"; : > "${RECLOG}"

    OUT="$(
      PATH="${STUBS}/bin:${PATH}" RECORDER_LOG="${RECLOG}" \
      DYNAMODB_RECORDER="${STUBS}/bin/recorder-stub.sh" \
      MAPDL_VERDICT_LIB="${HERE}/../lib/mapdl-verdict.sh" \
      BASE_DIR="${base}" SCRATCH_MODE="nvme" SCRATCH_ROOT="${base}/fake-scratch" \
      SLURM_JOB_ID=91000 SLURM_JOB_NAME="AnsysMechanical.sbatch" \
      SLURM_JOB_NUM_NODES=1 SLURM_NPROCS=64 SLURM_NTASKS=64 \
      SLURM_JOB_NODELIST="node1" SLURM_TASKS_PER_NODE="64" \
      SLURM_SUBMIT_DIR="${HERE}/.." \
      bash "${SBATCH}" v261 "${base}/inputs/V26direct-5.dat" 2>&1
    )"
    RC=$?
    BASEDIR="${base}"
    # Restore permissions so mktemp dirs can be cleaned up.
    for d in "${base}"/*/Run/*; do [ -d "$d" ] && chmod 700 "$d"; done 2>/dev/null
}

if [ "$(id -u)" -eq 0 ]; then
    skipt "NVMe stage-out failure retains scratch" "running as root; permissions do not apply"
    skipt "NVMe stage-out success reclaims scratch" "paired with the above"
else
    nvme_case "${FIX}/normal-success.log" 0 1
    grep -q 'Using node-local NVMe scratch' <<<"${OUT}" \
        && ok "nvme mode engaged against the fake instance-store root" \
        || bad "nvme mode engaged" "NVMe scratch message" "$(grep -o 'scratch: [a-z]*' <<<"${OUT}" | head -1)"
    [ "${RC}" -ne 0 ] && ok "failed stage-out fails the job (rc=${RC})" \
        || bad "failed stage-out fails the job" "non-zero" "0"
    grep -q 'NOT reclaiming node-local scratch' <<<"${OUT}" \
        && ok "failed stage-out explicitly suppresses cleanup" \
        || bad "cleanup suppressed" "'NOT reclaiming' message" "absent"
    grep -q 'local scratch reclaimed' <<<"${OUT}" \
        && bad "cleanup did not run" "no reclaim message" "scratch WAS reclaimed" \
        || ok "the reclaim step really did not execute"
    grep -qE 'ERROR: +'"${BASEDIR}"'/fake-scratch/mapdl-' <<<"${OUT}" \
        && ok "recovery message names the retained scratch path" \
        || bad "recovery path printed" "fake-scratch/mapdl-... path" "$(grep -c ERROR <<<"${OUT}") ERROR lines"
    if [ -s "${BASEDIR}/fake-scratch/mapdl-"*"/output-91000.log" ] 2>/dev/null; then
        ok "the solver log survives on scratch (recoverable)"
    else
        bad "log retained on scratch" "output-91000.log present" "missing"
    fi
    [ -s "${RECLOG}" ] && bad "failed stage-out records nothing" "recorder not called" "recorder called" \
        || ok "failed stage-out records NO benchmark row"
    rm -rf "${BASEDIR}"

    # Control: same path, working shared filesystem -> success and cleanup runs.
    nvme_case "${FIX}/normal-success.log" 0 0
    [ "${RC}" -eq 0 ] && ok "control: healthy nvme run exits 0" \
        || bad "control nvme exit" "0" "${RC}"
    grep -q 'local scratch reclaimed' <<<"${OUT}" \
        && ok "control: scratch IS reclaimed after a verified stage-out" \
        || bad "control reclaim" "reclaim message" "absent"
    grep -q 'TIME_TO_SOLUTION=' "${RECLOG}" \
        && ok "control: healthy nvme run records a row" \
        || bad "control records" "recorder called" "not called"
    rm -rf "${BASEDIR}"
fi

echo "== placement that Slurm cannot describe must fail closed, not be invented =="

run_case_env() {   # <SLURM_TASKS_PER_NODE> <nodelist> <nprocs> <nodes>
    local base; base="$(mktemp -d)"
    local vdir="${base}/ansys_inc/v261/ansys/bin"
    mkdir -p "${vdir}" "${base}/inputs"
    printf '#!/bin/bash\nexit 0\n' > "${vdir}/mapdl"; chmod +x "${vdir}/mapdl"
    : > "${base}/inputs/V26direct-5.dat"
    OUT="$(
      PATH="${STUBS}/bin:${PATH}" MAPDL_VERDICT_LIB="${HERE}/../lib/mapdl-verdict.sh" \
      BASE_DIR="${base}" SCRATCH_MODE="shared" \
      SLURM_JOB_ID=92000 SLURM_JOB_NAME="AnsysMechanical.sbatch" \
      SLURM_JOB_NUM_NODES="$4" SLURM_NPROCS="$3" SLURM_NTASKS="$3" \
      SLURM_JOB_NODELIST="$2" SLURM_TASKS_PER_NODE="$1" \
      SLURM_SUBMIT_DIR="${HERE}/.." \
      bash "${SBATCH}" v261 "${base}/inputs/V26direct-5.dat" 2>&1
    )"
    RC=$?
    rm -rf "${base}"
}

run_case_env "" "node1,node2" 128 2
if [ "${RC}" -ne 0 ] && grep -q 'cannot determine the per-host task placement' <<<"${OUT}"; then
    ok "unset SLURM_TASKS_PER_NODE aborts instead of inventing a placement"
else
    bad "unset TASKS_PER_NODE fails closed" "non-zero + explanation" "rc=${RC}"
fi

run_case_env "garbage" "node1,node2" 128 2
if [ "${RC}" -ne 0 ] && grep -q 'cannot determine the per-host task placement' <<<"${OUT}"; then
    ok "unparseable SLURM_TASKS_PER_NODE aborts instead of inventing a placement"
else
    bad "unparseable TASKS_PER_NODE fails closed" "non-zero + explanation" "rc=${RC}"
fi

echo "== heterogeneous placement is not recorded as a uniform cores_per_node =="

run_case_het() {   # <recorder path>
    local recorder="$1"
    local base; base="$(mktemp -d)"
    local vdir="${base}/ansys_inc/v261/ansys/bin"
    mkdir -p "${vdir}" "${base}/inputs"
    cat > "${vdir}/mapdl" <<EOF
#!/bin/bash
outfile=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && outfile="\$a"; prev="\$a"; done
[ -n "\${outfile}" ] && cp "${FIX}/normal-success.log" "\${outfile}"
exit 0
EOF
    chmod +x "${vdir}/mapdl"
    : > "${base}/inputs/V26direct-5.dat"
    RECLOG="${base}/recorder.log"; : > "${RECLOG}"
    RECJSON="${base}/recorder-item.json"; : > "${RECJSON}"
    OUT="$(
      PATH="${STUBS}/bin:${PATH}" RECORDER_LOG="${RECLOG}" RECORDER_JSON="${RECJSON}" \
      DYNAMODB_RECORDER="${recorder}" \
      MAPDL_VERDICT_LIB="${HERE}/../lib/mapdl-verdict.sh" \
      BASE_DIR="${base}" SCRATCH_MODE="shared" \
      SLURM_JOB_ID=93000 SLURM_JOB_NAME="AnsysMechanical.sbatch" \
      SLURM_JOB_NUM_NODES=2 SLURM_NPROCS=85 SLURM_NTASKS=85 \
      SLURM_JOB_NODELIST="node1,node2" SLURM_TASKS_PER_NODE="43,42" \
      SLURM_SUBMIT_DIR="${HERE}/.." \
      bash "${SBATCH}" v261 "${base}/inputs/V26direct-5.dat" 2>&1
    )"
    RC=$?
    BASEDIR="${base}"
}

run_case_het "${STUBS}/bin/recorder-stub.sh"
[ "${RC}" -eq 0 ] && ok "heterogeneous 43,42 placement runs (total 85 == SLURM_NPROCS)" \
    || bad "heterogeneous run" "0" "${RC}"
grep -q 'node1:43:node2:42' <<<"${OUT}" \
    && ok "-machines reflects the real uneven layout" \
    || bad "-machines uneven layout" "node1:43:node2:42" "$(grep -o 'Task placement:.*' <<<"${OUT}")"
if grep -q 'cores-per-node' "${RECLOG}"; then
    bad "no uniform cores_per_node recorded" "absent" "$(grep -o 'cores-per-node [0-9]*' "${RECLOG}")"
else
    ok "heterogeneous run does NOT record a uniform cores_per_node"
fi
grep -q 'task_placement=node1:43:node2:42' "${RECLOG}" \
    && ok "the full layout is recorded as task_placement instead" \
    || bad "task_placement recorded" "task_placement=node1:43:node2:42" "$(grep -o 'ARGS.*' "${RECLOG}")"
rm -rf "${BASEDIR}"

echo "== the PRODUCTION recorder's final JSON, not just the launcher's arguments =="

# Checking launcher arguments is not sufficient: the recorder derives fields of its
# own, and previously re-derived a bogus uniform cores_per_node = ceil(85/2) = 43
# even though the launcher deliberately omitted it. Only the emitted item proves
# what would actually be stored.
run_case_het "${STUBS}/bin/real-recorder.sh"
[ "${RC}" -eq 0 ] && ok "heterogeneous run with the real recorder exits 0" \
    || bad "real-recorder het run" "0" "${RC}"

if [ ! -s "${RECJSON}" ]; then
    bad "the real recorder emitted an item" "JSON present" "empty (see ${RECLOG})"
else
    if grep -q '"cores_per_node"' "${RECJSON}"; then
        bad "no uniform cores_per_node in the stored item" "absent" \
            "$(grep -o '"cores_per_node": {[^}]*}' "${RECJSON}")"
    else
        ok "stored item has NO cores_per_node for the 43,42 layout"
    fi
    grep -q '"task_placement": {"S": "node1:43:node2:42"}' "${RECJSON}" \
        && ok "stored item carries the real task_placement" \
        || bad "task_placement in stored item" 'node1:43:node2:42' "$(grep -o '"task_placement".*' "${RECJSON}")"
    grep -q '"num_cores": {"N": "85"}' "${RECJSON}" \
        && ok "stored item keeps the true total core count (85)" \
        || bad "num_cores in stored item" "85" "$(grep -o '"num_cores".*' "${RECJSON}")"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${RECJSON}" 2>/dev/null \
            && ok "the stored item is valid JSON" \
            || bad "stored item is valid JSON" "parses" "invalid"
    fi
fi
rm -rf "${BASEDIR}"

echo "== refuses to run without the verdict library =="

out="$(PATH="${STUBS}/bin:${PATH}" MAPDL_VERDICT_LIB=/nonexistent/nope.sh \
       SLURM_SUBMIT_DIR=/nonexistent SLURM_JOB_ID=1 SLURM_JOB_NUM_NODES=1 \
       SLURM_NPROCS=1 SLURM_JOB_NODELIST=node1 SLURM_JOB_NAME=x \
       bash <(sed 's#"${_self_dir}/lib/mapdl-verdict.sh"#"/nonexistent/lib.sh"#' "${SBATCH}") 2>&1)"
rc=$?
if [ "${rc}" -ne 0 ] && grep -q 'cannot find lib/mapdl-verdict.sh' <<<"${out}"; then
    ok "a missing verdict library aborts before the solve, with an actionable message"
else
    bad "missing library aborts" "non-zero + actionable message" "rc=${rc}"
fi

echo
printf 'sbatch e2e tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ] || exit 1
