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

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

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
printf 'sbatch e2e tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
