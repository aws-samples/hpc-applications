#!/bin/bash
# =============================================================================
# End-to-end test of the CFX sbatch example as ASSEMBLED.
# =============================================================================
# Runs the real script with curl, scontrol, date and cfx5solve replaced by stubs,
# so the whole script executes: the run directory, the solve call, the
# iteration time it prints, the recorder invocation and the final exit status.
#
# The script installs CFX under a fixed /fsx/ansys_inc/<version>/CFX/bin. The
# test runs a copy in which that one line points at a temporary directory
# instead, and checks that the copy differs from the script in that line only.
#
# No Slurm, no EC2, no MPI, no licensed solver, no AWS credentials, no network.
#
#   ./tests/test-sbatch-e2e.sh
#   CFX_SBATCH=/path/to/CFX.sbatch ./tests/test-sbatch-e2e.sh   # another copy
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"

# The sbatch example: CFX.sbatch, or CFX-mpirun.sbatch where it has that name.
SBATCH="${CFX_SBATCH:-}"
if [ -z "${SBATCH}" ]; then
    for _s in "${HERE}/../CFX.sbatch" "${HERE}/../CFX-mpirun.sbatch"; do
        if [ -f "${_s}" ]; then SBATCH="${_s}"; break; fi
    done
fi

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }

if [ -z "${SBATCH}" ] || [ ! -f "${SBATCH}" ]; then
    echo "ERROR: no CFX sbatch example found next to ${HERE}" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
echo "sbatch e2e tests (${SBATCH#"${HERE}/../"})"

# ---------------------------------------------------------------------------
# The copy that runs: the CFX install root moved under ${CFX_TEST_ROOT}.
# ---------------------------------------------------------------------------
CFX_DIR_LINE='CFX_DIR="/fsx/ansys_inc/${cfxversion}/CFX/bin"'
RUNNABLE="${WORK}/cfx-e2e.sbatch"
n_lines="$(grep -cxF "${CFX_DIR_LINE}" "${SBATCH}")"
sed 's#^CFX_DIR="/fsx/ansys_inc/#CFX_DIR="${CFX_TEST_ROOT}/ansys_inc/#' "${SBATCH}" > "${RUNNABLE}"
n_diff="$(diff "${SBATCH}" "${RUNNABLE}" | grep -c '^[<>]')"
if [ "${n_lines}" = "1" ] && [ "${n_diff}" = "2" ]; then
    ok "the copy differs from the script in its CFX_DIR line only"
else
    bad "the copy differs from the script in its CFX_DIR line only" \
        "1 CFX_DIR line, 2 diff lines" "${n_lines} CFX_DIR line(s), ${n_diff} diff line(s)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS stub: token request or instance-type lookup.
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) echo "hpc8a.96xlarge";;
  *)               echo "";;
esac
exit 0
EOF
cat > "${WORK}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show hostname node[1-2]
echo node1
echo node2
EOF
# date +%s answers 1000 and then 1123, so the script's wall clock is 123 s;
# every other format goes to the real date.
cat > "${WORK}/bin/date" <<'EOF'
#!/bin/bash
if [ "$*" = "+%s" ]; then
    f="${STUB_STATE}/date-calls"
    n=$(( $(cat "${f}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${f}"
    if [ "${n}" -eq 1 ]; then echo 1000; else echo 1123; fi
    exit 0
fi
exec /bin/date "$@"
EOF
# Recorder stub: log how the script invoked it (arguments and the key variables).
cat > "${WORK}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
{
  echo "ARGS: $*"
  echo "BENCHMARK_CASE=${BENCHMARK_CASE:-}"
  echo "TIME_TO_SOLUTION=${TIME_TO_SOLUTION:-}"
  echo "CFX_VERSION=${CFX_VERSION:-}"
  echo "RUN_DIR=${RUN_DIR:-}"
} >> "${STUB_STATE}/recorder.log"
echo "[stub recorder] called"
exit 0
EOF
# Real-recorder wrapper: this directory's recorder in --dry-run, so the test sees
# the item it would store, and nothing is written or sent.
cat > "${WORK}/bin/real-recorder.sh" <<EOF
#!/bin/bash
"${HERE}/../dynamodb/record-benchmark.sh" --dry-run --no-put --source E2ETest "\$@" \\
    > "\${STUB_STATE}/recorder.json" 2>> "\${STUB_STATE}/recorder.err"
EOF
chmod +x "${WORK}"/bin/*

# run_case <name> <rc> <output file to write, or ""> [second output file]
# Runs the copy with cfx5solve stubbed: it records its arguments, writes the
# given file(s) as <case>_001.out (and _002.out) in its working directory, and
# exits with <rc>. Sets OUT (stdout), ERR (stderr), RC, WORKDIR and STATE.
run_case() {
    local name="$1" rc="$2" out1="$3" out2="${4:-}"
    STATE="${WORK}/${name}"
    mkdir -p "${STATE}/root/ansys_inc/v261/CFX/bin" "${STATE}/base" "${STATE}/case"
    : > "${STATE}/case/perf_Test_R16.def"
    cat > "${STATE}/root/ansys_inc/v261/CFX/bin/cfx5solve" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "${STATE}/cfx5solve.args"
echo "[stub cfx5solve] running"
[ -n "${out1}" ] && cp "${out1}" ./perf_Test_R16_001.out
[ -n "${out2}" ] && cp "${out2}" ./perf_Test_R16_002.out
[ -n "${STUB_CHMOD:-}" ] && chmod "${STUB_CHMOD:-}" ./perf_Test_R16_00*.out
exit ${rc}
EOF
    chmod +x "${STATE}/root/ansys_inc/v261/CFX/bin/cfx5solve"
    OUT="$(cd "${STATE}" && env PATH="${WORK}/bin:${PATH}" STUB_STATE="${STATE}" \
        CFX_TEST_ROOT="${STATE}/root" cfxversion=v261 basedir="${STATE}/base" \
        def_file="${STATE}/case/perf_Test_R16.def" \
        DYNAMODB_RECORDER="${RECORDER:-${WORK}/bin/recorder-stub.sh}" STUB_CHMOD="${STUB_CHMOD:-}" \
        SLURM_JOB_NAME=cfx-e2e.sbatch SLURM_JOB_ID=4242 SLURM_JOB_NUM_NODES=2 \
        SLURM_NPROCS=384 SLURM_NTASKS=384 SLURM_NODELIST='node[1-2]' SLURM_SUBMIT_DIR="${STATE}" \
        ${EXTRA_ENV:-} bash "${RUNNABLE}" 2> "${STATE}/stderr")"
    RC=$?
    ERR="$(cat "${STATE}/stderr")"
    WORKDIR="$(printf '%s\n' "${OUT}" | sed -n 's/^Execution directory is: //p')"
}

expect_line() {  # <description> <exact line> : the line is in OUT
    if grep -qxF -- "$2" <<< "${OUT}"; then ok "$1"
    else bad "$1" "$2" "$(printf '%s\n' "${OUT}" | grep -E '^(Iteration time|Time per iteration):' | tr '\n' '|')"; fi
}
expect_rc() {  # <description> <rc>
    if [ "${RC}" -eq "$2" ]; then ok "$1"; else bad "$1" "exit $2" "exit ${RC}"; fi
}
line_no() {  # the line number of the first line of OUT that starts with <prefix>
    printf '%s\n' "${OUT}" | grep -n -m1 -F -- "$1" | cut -d: -f1
}

# ---------------------------------------------------------------------------
# 1. A steady-state run: 10 outer loop iterations, 1.2345E+02 s of iterations.
# ---------------------------------------------------------------------------
run_case steady 0 "${FIX}/steady-10-iterations.out"
expect_rc "a solve that exits 0 -> the job exits 0" 0
expect_line "the iterations' time, from CFD Solver wall clock seconds" \
    "Iteration time: 123.45 s (CFD Solver wall clock seconds, perf_Test_R16_001.out)"
expect_line "the time per iteration, over the outer loop iterations" \
    "Time per iteration: 12.345 s (10 outer loop iterations)"
expect_line "the existing first line is unchanged" "Execution directory is: ${WORKDIR}"
expect_line "the existing host-file line is unchanged" "building the MPI hostfile"
want_dir="$(readlink -m "${STATE}/base/cfx-e2e")/Run/4242-2xhpc8a.96xlarge-384-"
case "${WORKDIR}" in
    "${want_dir}"*) ok "the run directory is named as before";;
    *) bad "the run directory is named as before" "${want_dir}<date>" "${WORKDIR}";;
esac
l_solve="$(line_no "[stub cfx5solve] running")"; l_iter="$(line_no "Iteration time:")"
l_per="$(line_no "Time per iteration:")"; l_rec="$(line_no "[stub recorder] called")"
if [ -n "${l_solve}" ] && [ -n "${l_rec}" ] && [ "${l_solve}" -lt "${l_iter}" ] \
        && [ "${l_iter}" -lt "${l_per}" ] && [ "${l_per}" -lt "${l_rec}" ]; then
    ok "printed after the solve and before the recorder runs"
else
    bad "printed after the solve and before the recorder runs" "solve < iteration < per iteration < recorder" \
        "${l_solve:-?} ${l_iter:-?} ${l_per:-?} ${l_rec:-?}"
fi
expected_args="$(printf '%s\n' -batch -def "${STATE}/case/perf_Test_R16.def" -parallel \
    -start-method 'Intel MPI Distributed Parallel' -par-dist "node1
node2" -part 384 -part-large)"
if [ "$(cat "${STATE}/cfx5solve.args")" = "${expected_args}" ]; then
    ok "the cfx5solve command line is unchanged"
else
    bad "the cfx5solve command line is unchanged" "${expected_args//$'\n'/ }" "$(tr '\n' ' ' < "${STATE}/cfx5solve.args")"
fi
reclog="$(cat "${STATE}/recorder.log" 2>/dev/null)"
if grep -qxF -- "ARGS: " <<< "${reclog}"; then ok "the recorder gets no arguments, as before"
else bad "the recorder gets no arguments" "ARGS: " "$(printf '%s' "${reclog}" | tr '\n' '|')"; fi
for want in "BENCHMARK_CASE=perf_Test_R16" "TIME_TO_SOLUTION=123" "CFX_VERSION=v261" "RUN_DIR=${WORKDIR}"; do
    if grep -qxF -- "${want}" <<< "${reclog}"; then ok "the recorder gets ${want%%=*} as before"
    else bad "the recorder gets ${want}" "${want}" "$(printf '%s' "${reclog}" | tr '\n' '|')"; fi
done
[ "$(grep -c '^ARGS:' "${STATE}/recorder.log" 2>/dev/null)" = "1" ] \
    && ok "the recorder runs once" || bad "the recorder runs once" "1" "$(grep -c '^ARGS:' "${STATE}/recorder.log" 2>/dev/null)"

# The item this directory's recorder would store is unchanged: the wall clock,
# and no attribute for the iteration time.
RECORDER="${WORK}/bin/real-recorder.sh" run_case steady-real 0 "${FIX}/steady-10-iterations.out"
item="$(sed -n '/^{/,$p' "${STATE}/recorder.json" 2>/dev/null)"
if grep -qF '"time_to_solution_seconds": {"N": "123"}' <<< "${item}"; then
    ok "the recorded time is the wall clock (time_to_solution_seconds 123)"
else
    bad "the recorded time is the wall clock" '"time_to_solution_seconds": {"N": "123"}' "$(printf '%s' "${item}" | tr '\n' ' ')"
fi
if grep -q '^{' <<< "${item}" && ! grep -qiE 'iteration|123\.45|12\.345' <<< "${item}"; then
    ok "the recorded item has no iteration attribute"
else
    bad "the recorded item has no iteration attribute" "an item without one" "$(printf '%s' "${item}" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 2. The solve stops before it reports its time, and exits 1.
# ---------------------------------------------------------------------------
run_case stopped 1 "${FIX}/stopped-after-3.out"
expect_rc "a solve that exits 1 -> the job exits 1" 1
expect_line "no CFD Solver wall clock seconds line -> N/A, and why" \
    "Iteration time: N/A (no CFD Solver wall clock seconds value in perf_Test_R16_001.out)"
expect_line "no iteration time -> no time per iteration" "Time per iteration: N/A"
[ ! -e "${STATE}/recorder.log" ] && ok "not recorded, as before" || bad "not recorded" "no recorder call" "$(cat "${STATE}/recorder.log")"
grep -qxF "NOTE: solver exited 1; skipping benchmark recording." <<< "${ERR}" \
    && ok "the existing NOTE for a solve that exits non-zero is unchanged" \
    || bad "the existing NOTE" "NOTE: solver exited 1; skipping benchmark recording." "${ERR}"

# ---------------------------------------------------------------------------
# 3. No output file at all (cfx5solve exits 2 before it starts).
# ---------------------------------------------------------------------------
run_case no-output 2 ""
expect_rc "a solve that exits 2 -> the job exits 2" 2
expect_line "no output file -> N/A, naming the file looked for and where" \
    "Iteration time: N/A (no perf_Test_R16_NNN.out in ${WORKDIR})"
expect_line "no output file -> no time per iteration" "Time per iteration: N/A"

# ---------------------------------------------------------------------------
# 4. Two output files in the run directory: the newest run's (_002) is read.
# ---------------------------------------------------------------------------
sed 's/^ CFD Solver wall clock seconds: .*/ CFD Solver wall clock seconds: 9.9999E+02/' \
    "${FIX}/steady-10-iterations.out" > "${WORK}/older-run.out"
run_case two-outputs 0 "${WORK}/older-run.out" "${FIX}/steady-10-iterations.out"
expect_line "two output files -> the last one, _002" \
    "Iteration time: 123.45 s (CFD Solver wall clock seconds, perf_Test_R16_002.out)"

# ---------------------------------------------------------------------------
# 5. The outer loop iterations: a transient run has none to divide by, and a
#    run of one says so in the singular.
# ---------------------------------------------------------------------------
run_case transient 0 "${FIX}/transient.out"
expect_line "a transient run: the iterations' time" \
    "Iteration time: 50.00 s (CFD Solver wall clock seconds, perf_Test_R16_001.out)"
expect_line "a transient run: no outer loop iterations -> N/A, and why" \
    "Time per iteration: N/A (no outer loop iterations in perf_Test_R16_001.out)"
grep -vE 'OUTER LOOP ITERATION = +([2-9]|10) ' "${FIX}/steady-10-iterations.out" > "${WORK}/one-iteration.out"
run_case one-iteration 0 "${WORK}/one-iteration.out"
expect_line "one outer loop iteration -> 'iteration', not 'iterations'" \
    "Time per iteration: 123.450 s (1 outer loop iteration)"

# ---------------------------------------------------------------------------
# 6. Number formats CFX prints, written by the test.
# ---------------------------------------------------------------------------
sed 's/^ CFD Solver wall clock seconds: .*/ CFD Solver wall clock seconds: 9.3270E+00/' \
    "${FIX}/steady-10-iterations.out" > "${WORK}/small.out"
run_case small 0 "${WORK}/small.out"
expect_line "a time under 10 s" "Iteration time: 9.33 s (CFD Solver wall clock seconds, perf_Test_R16_001.out)"
expect_line "a time per iteration under 1 s" "Time per iteration: 0.933 s (10 outer loop iterations)"
sed 's/^ CFD Solver wall clock seconds: .*/ CFD Solver wall clock seconds: 1.2345E+05/' \
    "${FIX}/steady-10-iterations.out" > "${WORK}/large.out"
run_case large 0 "${WORK}/large.out"
expect_line "a time of 6 digits, printed without an exponent" \
    "Iteration time: 123450.00 s (CFD Solver wall clock seconds, perf_Test_R16_001.out)"
sed 's/$/\r/' "${FIX}/steady-10-iterations.out" > "${WORK}/crlf.out"
run_case crlf 0 "${WORK}/crlf.out"
expect_line "an output file with CRLF line ends" \
    "Iteration time: 123.45 s (CFD Solver wall clock seconds, perf_Test_R16_001.out)"
expect_line "an output file with CRLF line ends: per iteration" \
    "Time per iteration: 12.345 s (10 outer loop iterations)"

# ---------------------------------------------------------------------------
# 7. A solver-time line without a number: N/A, never a made-up 0.
# ---------------------------------------------------------------------------
sed 's/^ CFD Solver wall clock seconds: .*/ CFD Solver wall clock seconds:/' \
    "${FIX}/steady-10-iterations.out" > "${WORK}/no-value.out"
run_case no-value 0 "${WORK}/no-value.out"
expect_line "a line that ends after its colon -> N/A, and why" \
    "Iteration time: N/A (no CFD Solver wall clock seconds value in perf_Test_R16_001.out)"
expect_line "a line that ends after its colon -> no time per iteration" "Time per iteration: N/A"
sed 's/^ CFD Solver wall clock seconds: .*/ CFD Solver wall clock seconds: **********/' \
    "${FIX}/steady-10-iterations.out" > "${WORK}/overflow.out"
run_case overflow 0 "${WORK}/overflow.out"
expect_line "asterisks for a field too narrow for its value -> N/A, and why" \
    "Iteration time: N/A (no CFD Solver wall clock seconds value in perf_Test_R16_001.out)"
expect_line "asterisks for a field too narrow for its value -> no time per iteration" "Time per iteration: N/A"

# ---------------------------------------------------------------------------
# 8. A comma-decimal locale (with POSIXLY_CORRECT, gawk reads numbers in it).
# ---------------------------------------------------------------------------
comma_locale="$(locale -a 2>/dev/null | grep -m1 -iE '^(de_DE|fr_FR|it_IT|es_ES)\.utf-?8$')"
if [ -n "${comma_locale}" ]; then
    EXTRA_ENV="LC_ALL=${comma_locale} POSIXLY_CORRECT=1" run_case locale 0 "${FIX}/steady-10-iterations.out"
    expect_line "a comma-decimal locale reads and prints with a point" \
        "Iteration time: 123.45 s (CFD Solver wall clock seconds, perf_Test_R16_001.out)"
else
    skipt "a comma-decimal locale reads and prints with a point" "no such locale installed"
fi

# ---------------------------------------------------------------------------
# 9. An output file the job cannot read.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    STUB_CHMOD=000 run_case unreadable 0 "${FIX}/steady-10-iterations.out"
    expect_rc "an unreadable output file -> the job still exits 0" 0
    expect_line "an unreadable output file -> N/A, and why" "Iteration time: N/A (cannot read perf_Test_R16_001.out)"
    expect_line "an unreadable output file -> no time per iteration" "Time per iteration: N/A"
    [ -s "${STATE}/recorder.log" ] && ok "an unreadable output file -> still recorded" \
        || bad "an unreadable output file -> still recorded" "one recorder call" "none"
else
    skipt "an unreadable output file" "running as root"
fi

echo
printf 'sbatch e2e tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ]
