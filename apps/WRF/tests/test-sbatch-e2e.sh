#!/bin/bash
# =============================================================================
# End-to-end test of the WRF benchmark scripts as ASSEMBLED.
# =============================================================================
# Runs every benchmark script with stubbed Slurm, IMDS, MPI and wrf.exe
# commands, so the whole script executes: the run directory, a stubbed solve
# that leaves a fixture as rsl.error.0000, the timing extraction, the report and
# the recorder call.
#
# No Slurm, no EC2, no WRF, no MPI, no AWS credentials, no network. The stubs
# never run a command on the host: the cache drops and THP settings the scripts
# launch through srun and mpirun are swallowed, sudo does nothing, and an aws
# stub refuses every call.
#
#   ./tests/test-sbatch-e2e.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRF_APP="$(cd "${HERE}/.." && pwd)"
FIX="${HERE}/fixtures"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }

SCRIPTS=(x86/wrf-benchmark.sbatch
         x86/wrf-benchmark-intel.sbatch
         x86/wrf-benchmark-conus2.5km.sbatch
         x86/wrf-benchmark-conus2.5km-intel.sbatch
         Arm/wrf-benchmark.sbatch)

if ! (ulimit -s unlimited) 2>/dev/null; then
    skipt "every benchmark script" "this environment refuses the scripts' 'ulimit -s unlimited'"
    printf 'sbatch e2e tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
    exit 0
fi

STUBS="$(mktemp -d)"
trap 'rm -rf "${STUBS}"' EXIT

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "${STUBS}/bin" "${STUBS}/WRF/test/em_real" "${STUBS}/conus" "${STUBS}/elsewhere"

cat > "${STUBS}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS stub: token request or instance-type lookup.
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) echo "stub.48xlarge";;
  *)               echo "";;
esac
exit 0
EOF

cat > "${STUBS}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show nodes <list>: two node records, as Slurm prints them.
for n in node1 node2; do
  echo "NodeName=${n} Arch=x86_64 CoresPerSocket=2"
  echo "   NodeAddr=${n} NodeHostName=${n} Version=25.05.0"
done
EOF

cat > "${STUBS}/bin/srun" <<'EOF'
#!/bin/bash
# The scripts only srun the cache drop and THP setting: swallow them.
exit 0
EOF

cat > "${STUBS}/bin/mpirun" <<'EOF'
#!/bin/bash
# Only the solve runs: exec wrf.exe when it is among the arguments. Every other
# launch (the cache drop, THP) is swallowed.
for a in "$@"; do
  case "$a" in
    --version) echo "mpirun (Open MPI) 5.0.9"; exit 0;;
    */wrf.exe) exec "$a";;
  esac
done
exit 0
EOF

cat > "${STUBS}/bin/sudo" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "${STUBS}/bin/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "${AWS_STUB_LOG}"
echo "aws stub: refusing to call AWS from a test" >&2
exit 1
EOF

# Recorder stub: log how the script called it (arguments and key environment).
cat > "${STUBS}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
{
  echo "ARGS: $*"
  echo "BENCHMARK_CASE=${BENCHMARK_CASE:-}"
  echo "TIME_TO_SOLUTION=${TIME_TO_SOLUTION:-}"
} >> "${RECORDER_LOG}"
exit 0
EOF

# Stub solve: leave the chosen fixture as rsl.error.0000 in the run directory
# (none when WRF_FIXTURE is empty).
cat > "${STUBS}/WRF/test/em_real/wrf.exe" <<'EOF'
#!/bin/bash
echo " starting wrf task 0 of 8"
if [ -n "${WRF_FIXTURE:-}" ]; then cp "${WRF_FIXTURE}" rsl.error.0000; fi
exit 0
EOF
chmod +x "${STUBS}"/bin/* "${STUBS}/WRF/test/em_real/wrf.exe"

cat > "${STUBS}/wrf-env.sh" <<EOF
export WRF_DIR="${STUBS}/WRF"
EOF

# A stand-in for lib/wrf-step-timing.sh whose two functions print sentinel
# values: a report that shows them loaded this file, not the repository's.
mkdir -p "${STUBS}/stub-lib"
cat > "${STUBS}/stub-lib/wrf-step-timing.sh" <<'EOF'
wrf_median_step() { echo "7.77777"; }
wrf_steady_step() { echo "8.88888"; }
EOF

: > "${STUBS}/conus/wrfinput_d01"
: > "${STUBS}/conus/wrfbdy_d01"
printf ' &time_control\n run_hours = 3,\n /\n' > "${STUBS}/conus/namelist.input"
: > "${STUBS}/aws-calls.log"

# run_script <script> <fixture or ""> [NAME=value...]
# Runs one benchmark script in a clean environment; extra NAME=value pairs
# override the defaults. Sets OUT (stdout and stderr), RC and RECLOG.
run_script() {
    local script="$1" fixture="$2"; shift 2
    local base; base="$(mktemp -d "${STUBS}/case.XXXXXX")"
    RECLOG="${base}/recorder.log"; : > "${RECLOG}"
    OUT="$(cd "${base}" && env -i \
        PATH="${STUBS}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${base}" LANG=C \
        WRF_ENV="${STUBS}/wrf-env.sh" CONUS_DIR="${STUBS}/conus" BASE_DIR="${base}" \
        WRF_FIXTURE="${fixture}" RECORDER_LOG="${RECLOG}" AWS_STUB_LOG="${STUBS}/aws-calls.log" \
        DYNAMODB_RECORDER="${STUBS}/bin/recorder-stub.sh" \
        SLURM_JOB_ID=4242 SLURM_JOB_NAME="$(basename "${script}")" SLURM_CLUSTER_NAME=test \
        SLURM_JOB_NUM_NODES=2 SLURM_NTASKS_PER_NODE=4 SLURM_NTASKS=8 SLURM_NODELIST="node[1-2]" \
        SLURM_SUBMIT_DIR="${WRF_APP}/$(dirname "${script}")" \
        "$@" \
        bash "${WRF_APP}/${script}" 2>&1)"
    RC=$?
}

# has <label> <exact line>: the output holds that line
has() {
    if grep -qxF -- "$2" <<<"${OUT}"; then ok "$1"
    else bad "$1" "$2" "$(grep -E 'timestep|NOTE' <<<"${OUT}" | head -8 | tr '\n' '|')"; fi
}

for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    x86=0; case "${s}" in x86/*) x86=1;; esac

    run_script "${s}" "${FIX}/hourly-history.rsl"
    [ "${RC}" -eq 0 ] && ok "completes (exit 0)" || bad "completes" "exit 0" "exit ${RC}"
    has "the average is unchanged" "Avg timestep:     2.25s"
    has "the report gives the median step" "Median timestep:  1.15000s"
    has "the report gives the steady step" "Steady timestep:  1.11111s"
    got="$(grep -A2 -xF 'Avg timestep:     2.25s' <<<"${OUT}" | tr '\n' '|')"
    [ "${got}" = "Avg timestep:     2.25s|Median timestep:  1.15000s|Steady timestep:  1.11111s|" ] \
        && ok "the two report lines follow the average, once each" \
        || bad "report lines in order" "Avg|Median|Steady" "${got}"
    if [ "${x86}" -eq 1 ]; then
        has "the checking section keeps its average" "Average time per timestep: 2.25s"
        has "the checking section gives the median step" "Median time per timestep: 1.15000s"
        has "the checking section gives the steady step" "Steady time per timestep: 1.11111s"
    fi
    if grep -qxF 'Median timestep:  1.15000s' <<<"${OUT}" \
        && ! grep -q 'NOTE: lib/wrf-step-timing.sh not found' <<<"${OUT}"; then
        ok "the library is found from the submit directory"
    else
        bad "the library is found from the submit directory" "Median timestep:  1.15000s, and no NOTE" \
            "$(grep -E 'timestep|NOTE' <<<"${OUT}" | head -8 | tr '\n' '|')"
    fi
    grep -q -- '--metric avg_timestep_seconds=2.25' "${RECLOG}" \
        && ok "the recorder still gets the average" \
        || bad "the recorder gets the average" "--metric avg_timestep_seconds=2.25" "$(head -1 "${RECLOG}")"

    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="${WRF_APP}"
    has "submitted from apps/WRF: the library is found" "Median timestep:  1.15000s"
    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="$(cd "${WRF_APP}/../.." && pwd)"
    has "submitted from the repository root: the library is found" "Median timestep:  1.15000s"

    run_script "${s}" ""
    [ "${RC}" -eq 0 ] && ok "no rsl.error.0000: completes (exit 0), as before" \
        || bad "no rsl.error.0000 completes" "exit 0" "exit ${RC}"
    has "no rsl.error.0000: the average is N/A, as before" "Avg timestep:     N/As"
    has "no rsl.error.0000: the median step is N/A" "Median timestep:  N/As"
    has "no rsl.error.0000: the steady step is N/A" "Steady timestep:  N/As"

    # The existing "grep 'Timing for main' | tail -5" stops the script under
    # pipefail when no step was timed, before the report and the recorder.
    run_script "${s}" "${FIX}/no-steps.rsl"
    [ "${RC}" -ne 0 ] && ok "no step lines: the job fails (exit ${RC}), as before" \
        || bad "no step lines fails the job" "non-zero" "exit 0"
    grep -q 'Benchmark Results' <<<"${OUT}" \
        && bad "no step lines: no report" "no report" "report printed" \
        || ok "no step lines: no report, as before"
    [ -s "${RECLOG}" ] && bad "no step lines: nothing recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "no step lines: nothing recorded, as before"

    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="${STUBS}/elsewhere"
    [ "${RC}" -eq 0 ] && ok "library not found: still completes (exit 0)" \
        || bad "library not found completes" "exit 0" "exit ${RC}"
    grep -q 'NOTE: lib/wrf-step-timing.sh not found.*WRF_STEP_TIMING_LIB=' <<<"${OUT}" \
        && ok "library not found: a NOTE says how to point at it" \
        || bad "library not found NOTE" "NOTE ... WRF_STEP_TIMING_LIB=" "absent"
    has "library not found: the average is unchanged" "Avg timestep:     2.25s"
    has "library not found: the median step is N/A" "Median timestep:  N/As"
    has "library not found: the steady step is N/A" "Steady timestep:  N/As"

    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="${STUBS}/elsewhere" \
        WRF_STEP_TIMING_LIB="${WRF_APP}/lib/wrf-step-timing.sh"
    has "WRF_STEP_TIMING_LIB points at the library" "Steady timestep:  1.11111s"

    # Submitted from the script's directory, where lib/ holds the repository's
    # copy: the variable still comes first.
    run_script "${s}" "${FIX}/hourly-history.rsl" WRF_STEP_TIMING_LIB="${STUBS}/stub-lib/wrf-step-timing.sh"
    got="$(grep -A2 -xF 'Avg timestep:     2.25s' <<<"${OUT}" | tr '\n' '|')"
    [ "${got}" = "Avg timestep:     2.25s|Median timestep:  7.77777s|Steady timestep:  8.88888s|" ] \
        && ok "WRF_STEP_TIMING_LIB takes precedence over a submit-directory copy" \
        || bad "WRF_STEP_TIMING_LIB takes precedence over a submit-directory copy" \
               "Avg timestep:     2.25s|Median timestep:  7.77777s|Steady timestep:  8.88888s|" "${got}"
done

echo "== the stubs kept AWS out of it =="
[ -s "${STUBS}/aws-calls.log" ] && bad "no AWS call" "none" "$(head -1 "${STUBS}/aws-calls.log")" \
    || ok "no test called AWS"

echo
printf 'sbatch e2e tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ] || exit 1
