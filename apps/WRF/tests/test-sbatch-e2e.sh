#!/bin/bash
# =============================================================================
# End-to-end test of the WRF benchmark scripts as ASSEMBLED.
# =============================================================================
# Runs every benchmark script with stubbed Slurm, IMDS, lscpu, MPI and wrf.exe
# commands, so the whole script executes: the run directory, a stubbed solve
# that leaves a fixture as rsl.error.0000 and the output files it names, the
# timing extraction, the report, the run check and the recorder call.
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
# IMDS stub: token request or instance-type lookup (IMDS_INSTANCE_TYPE, set
# even to nothing, replaces the default type). Each call's arguments go to
# CURL_LOG, one line per call, when it is set. IMDS_MODE=down answers nothing
# (exit 28, as curl does at its time limit); IMDS_MODE=http-error answers an
# HTTP 401, which curl -f (--fail, or f among short options) turns into exit 22
# and no output, and plain curl prints, with exit 0; IMDS_MODE=cut-off answers
# the instance-type lookup with the type's first characters (the type less its
# last five), then exit 28, as curl ends a transfer at its time limit.
[ -n "${CURL_LOG:-}" ] && printf '%s\n' "$*" >> "${CURL_LOG}"
case "${IMDS_MODE:-}" in
  down) exit 28 ;;
  http-error)
    for a in "$@"; do
      case "${a}" in --fail) exit 22 ;; --*) ;; -*f*) exit 22 ;; esac
    done
    echo "<html><head><title>401 - Unauthorized</title></head></html>"
    exit 0 ;;
  cut-off)
    case "$*" in
      *instance-type*) t="${IMDS_INSTANCE_TYPE-stub.48xlarge}"; printf '%s' "${t%?????}"; exit 28 ;;
    esac ;;
esac
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) echo "${IMDS_INSTANCE_TYPE-stub.48xlarge}";;
  *)               echo "";;
esac
exit 0
EOF

cat > "${STUBS}/bin/lscpu" <<'EOF'
#!/bin/bash
# lscpu stub: the node STUB_LSCPU names, <vendor>-<sockets>x<cores per
# socket>[-smt] (amd-2x96 is an hpc8a.96xlarge or an hpc7a.96xlarge; -smt
# gives 2 threads per core), or none, an lscpu that fails. Like lscpu, it
# answers in the language of LC_ALL, else LC_MESSAGES, else LANG: English in
# C, C.UTF-8, POSIX and en_*, German in any other locale. Each call's LC_ALL
# goes to LSCPU_LOG, when it is set.
[ -n "${LSCPU_LOG:-}" ] && echo "LC_ALL=${LC_ALL-unset}" >> "${LSCPU_LOG}"
case "${STUB_LSCPU:-}" in
  amd-2x96)     set -- AuthenticAMD 2 96 1 ;;
  amd-1x192)    set -- AuthenticAMD 1 192 1 ;;
  amd-2x48-smt) set -- AuthenticAMD 2 48 2 ;;
  amd-1x96)     set -- AuthenticAMD 1 96 1 ;;
  amd-2x128)    set -- AuthenticAMD 2 128 1 ;;
  intel-2x96)   set -- GenuineIntel 2 96 1 ;;
  *)            echo "lscpu: cannot read the CPUs" >&2; exit 1 ;;
esac
lang="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
case "${lang}" in
  C|C.*|POSIX|en_*)
    printf '%-33s %s\n' "Architecture:" x86_64 "CPU(s):" "$(( $2 * $3 * $4 ))" "Vendor ID:" "$1" \
        "  Model name:" "Stub CPU" "    Thread(s) per core:" "$4" "    Core(s) per socket:" "$3" \
        "    Socket(s):" "$2" ;;
  *)
    printf '%-33s %s\n' "Architektur:" x86_64 "CPU(s):" "$(( $2 * $3 * $4 ))" "Anbieterkennung:" "$1" \
        "  Modellname:" "Stub CPU" "    Thread(s) pro Kern:" "$4" "    Kern(e) pro Sockel:" "$3" \
        "    Sockel:" "$2" ;;
esac
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

# Recorder stub: log how the script called it: its --metric arguments, in
# order (ARGS), its other arguments, which describe the run (RUN), and key
# environment.
cat > "${STUBS}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
metrics=() others=()
while [ $# -gt 0 ]; do
  case "$1" in
    --metric) metrics+=("$1" "${2:-}"); shift; [ $# -gt 0 ] && shift ;;
    *)        others+=("$1"); shift ;;
  esac
done
{
  echo "ARGS: ${metrics[*]}"
  echo "RUN: ${others[*]}"
  echo "BENCHMARK_CASE=${BENCHMARK_CASE:-}"
  echo "TIME_TO_SOLUTION=${TIME_TO_SOLUTION:-}"
} >> "${RECORDER_LOG}"
exit 0
EOF

# Real-recorder wrapper: runs this repository's recorder in --dry-run, which
# prints the item it would store and touches neither disk nor AWS. Checking the
# script's arguments is not enough: only the item shows what would be stored.
cat > "${STUBS}/bin/real-recorder.sh" <<EOF
#!/bin/bash
"${WRF_APP}/dynamodb/record-benchmark.sh" --dry-run --source E2ETest "\$@" \\
    > "\${RECORDER_JSON}" 2>> "\${RECORDER_LOG}"
EOF

# Stub solve: leave the chosen fixture as rsl.error.0000 in the run directory
# (none when WRF_FIXTURE is empty), and the output files its log says WRF
# wrote: a file for every history write it names, and one for every restart
# write. WRF_OUTPUT=none writes none of them, =empty writes them all empty, and
# =no-restart writes the history files only. As WRF does, it writes each
# history file under the name the log gives it, with an '_' for each ':' when
# the run directory's namelist.input sets io_form_history = 11 (PnetCDF).
cat > "${STUBS}/WRF/test/em_real/wrf.exe" <<'EOF'
#!/bin/bash
echo " starting wrf task 0 of 8"
[ -n "${WRF_FIXTURE:-}" ] || exit 0
cp "${WRF_FIXTURE}" rsl.error.0000
mode="${WRF_OUTPUT:-all}"
[ "${mode}" = none ] && exit 0
pnetcdf=0
grep -qE '^[[:space:]]*io_form_history[[:space:]]*=[[:space:]]*11([^0-9]|$)' namelist.input 2>/dev/null && pnetcdf=1
n=0
while read -r w1 w2 w3 name _; do
  [ "${w1} ${w2} ${w3}" = "Timing for Writing" ] || continue
  if [ "${name}" = restart ]; then
    [ "${mode}" = no-restart ] && continue
    n=$((n + 1)); name="wrfrst_d01_restart-${n}"
  elif [ "${pnetcdf}" = 1 ]; then
    name="${name//:/_}"
  fi
  if [ "${mode}" = empty ]; then : > "${name}"; else echo "stub output" > "${name}"; fi
done < rsl.error.0000
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
# A stand-in for lib/wrf-run-check.sh that refuses every run, with a sentinel
# reason: a NOTE that gives it shows the script loaded this file.
cat > "${STUBS}/stub-lib/wrf-run-check.sh" <<'EOF'
wrf_run_check() { echo "stub check refused"; return 1; }
EOF

: > "${STUBS}/conus/wrfinput_d01"
: > "${STUBS}/conus/wrfbdy_d01"
printf ' &time_control\n run_hours = 3,\n io_form_history = 2,\n io_form_restart = 2,\n /\n' > "${STUBS}/conus/namelist.input"
# The CONUS 2.5km scripts write the history and restart files through PnetCDF
# by default: WRF gets CONUS_DIR's namelist.input with io_form_history and
# io_form_restart 11 instead of 2, and nothing else changed, in the run
# directory; WRF_OUTPUT_FORMAT=namelist gives it the namelist as it is. A
# namelist that does not take the change stops the job before wrf.exe, and an
# unknown value of the variable stops it before the run directory. The other
# scripts give WRF the namelist as it is. The change must set exactly the two
# lines: a namelist with only io_form_history at 2, with io_form_restart at
# 102, or with io_form_history set twice takes part of it, or more, and stops
# the job too.
NL_STOPS=(conus-no-io-form conus-pnetcdf conus-history-only conus-restart-102 conus-history-twice)
for c in "${NL_STOPS[@]}"; do mkdir -p "${STUBS}/${c}"; : > "${STUBS}/${c}/wrfinput_d01"; : > "${STUBS}/${c}/wrfbdy_d01"; done
printf ' &time_control\n run_hours = 3,\n /\n' > "${STUBS}/conus-no-io-form/namelist.input"
printf ' &time_control\n run_hours = 3,\n io_form_history = 11,\n io_form_restart = 11,\n /\n' \
    > "${STUBS}/conus-pnetcdf/namelist.input"
printf ' &time_control\n run_hours = 3,\n io_form_history = 2,\n /\n' > "${STUBS}/conus-history-only/namelist.input"
printf ' &time_control\n run_hours = 3,\n io_form_history = 2,\n io_form_restart = 102,\n /\n' \
    > "${STUBS}/conus-restart-102/namelist.input"
printf ' &time_control\n run_hours = 3,\n io_form_history = 2,\n io_form_history = 2,\n io_form_restart = 2,\n /\n' \
    > "${STUBS}/conus-history-twice/namelist.input"
SHIPPED_NL="$(cat "${STUBS}/conus/namelist.input")"
PNETCDF_NL=$' &time_control\n run_hours = 3,\n io_form_history = 11,\n io_form_restart = 11,\n /'
# run_nl: the namelist.input in the run directory of the last run_script, or nothing
run_nl() { local f; f="$(find "$(dirname "${RECLOG}")/Run" -name namelist.input 2>/dev/null | head -1)"; [ -n "${f}" ] && cat "${f}"; }
# stopped <label>: the job failed before wrf.exe started, and recorded nothing
stopped() {
    if [ "${RC}" -ne 0 ] && ! grep -q 'starting wrf task' <<<"${OUT}" && [ ! -s "${RECLOG}" ]; then ok "$1"
    else bad "$1" "a failed job, no wrf.exe, nothing recorded" \
             "exit ${RC}; $(grep -c 'starting wrf task' <<<"${OUT}") wrf.exe start(s); recorder log $(wc -l < "${RECLOG}") line(s)"; fi
}
: > "${STUBS}/aws-calls.log"
# A stand-in for lib/wrf-run-info.sh that prints a sentinel value: a recorder
# call that carries it shows the script loaded this file.
cat > "${STUBS}/stub-lib/wrf-run-info.sh" <<'EOF'
wrf_run_info() { echo "num_timesteps=7777"; }
EOF
# A case whose namelist gives the grid and the run length (the CONUS 2.5km
# grid, a 6-hour forecast), for the run description the record carries.
mkdir -p "${STUBS}/conus-sized"
: > "${STUBS}/conus-sized/wrfinput_d01"; : > "${STUBS}/conus-sized/wrfbdy_d01"
cat > "${STUBS}/conus-sized/namelist.input" <<'EOF'
 &time_control
 run_days                            = 0,
 run_hours                           = 6,
 run_minutes                         = 0,
 run_seconds                         = 0,
 io_form_history                     = 2,
 io_form_restart                     = 2,
 /
 &domains
 time_step                           = 15,
 e_we                                = 1501,
 e_sn                                = 1201,
 e_vert                              = 50,
 /
EOF

# run_script <script> <fixture or ""> [NAME=value...]
# Runs one benchmark script in a clean environment; extra NAME=value pairs
# override the defaults. Sets OUT (stdout and stderr), RC, RECLOG and RECJSON
# (the item the real recorder would store, when it is the one called).
run_script() {
    local script="$1" fixture="$2"; shift 2
    local base; base="$(mktemp -d "${STUBS}/case.XXXXXX")"
    RECLOG="${base}/recorder.log"; : > "${RECLOG}"
    RECJSON="${base}/recorder-item.json"; : > "${RECJSON}"
    OUT="$(cd "${base}" && env -i \
        PATH="${STUBS}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${base}" LANG=C \
        WRF_ENV="${STUBS}/wrf-env.sh" CONUS_DIR="${STUBS}/conus" BASE_DIR="${base}" \
        WRF_FIXTURE="${fixture}" RECORDER_LOG="${RECLOG}" RECORDER_JSON="${RECJSON}" \
        AWS_STUB_LOG="${STUBS}/aws-calls.log" \
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

# recorded <label>: the run passed the run check, so the recorder was called
recorded() {
    if grep -q -- '--metric avg_timestep_seconds=' "${RECLOG}" \
            && ! grep -q 'NOTE: not recording this run' <<<"${OUT}"; then ok "$1"
    else bad "$1" "the recorder called, and no 'NOTE: not recording'" \
             "$(grep NOTE <<<"${OUT}" | head -3 | tr '\n' '|')$(head -1 "${RECLOG}")"; fi
}
# hist <name>: the history file <name> (as the log gives it) under the name WRF
# writes in the last run_script's run directory: with an '_' for each ':' when
# its namelist.input sets io_form_history = 11 (PnetCDF)
hist() {
    local f
    f="$(find "$(dirname "${RECLOG}")/Run" -name namelist.input 2>/dev/null | head -1)"
    if [ -n "${f}" ] && grep -qE '^[[:space:]]*io_form_history[[:space:]]*=[[:space:]]*11([^0-9]|$)' "${f}"; then
        echo "${1//:/_}"
    else
        echo "$1"
    fi
}

for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    x86=0; case "${s}" in x86/*) x86=1;; esac
    # The record carries what makes runs comparable, which lib/wrf-run-info.sh
    # reads from the run directory: the grid size (--num-cells-million), and the
    # simulated minutes, the number of time steps and the history output's
    # io_form (--char). The case's namelist gives a 1501 x 1201 x 50 grid and 6
    # hours, the fixture has 12 steps, and io_form is the one WRF ran with, in
    # the run directory's namelist.input.
    run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/conus-sized"
    rnl="$(find "$(dirname "${RECLOG}")/Run" -name namelist.input 2>/dev/null | head -1)"
    io="$(sed -n -E 's/^[[:space:]]*io_form_history[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${rnl:-/dev/null}")"
    want="RUN: --num-cells-million 90.135 --char simulated_minutes=360 --char io_form=${io} --char num_timesteps=12"
    [ -n "${io}" ] && grep -qxF -- "${want}" "${RECLOG}" \
        && ok "the recorder gets the grid size, the simulated minutes, the steps and io_form ${io}" \
        || bad "the recorder gets the run description" "${want}" "$(grep '^RUN:' "${RECLOG}")"
    run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/conus-sized" \
        DYNAMODB_RECORDER="${STUBS}/bin/real-recorder.sh" OPERATING_SYSTEM="Test OS"
    item="$(sed -n '/^{/,$p' "${RECJSON}")"
    for attr in '"num_cells_million": {"N": "90.135"}' '"simulated_minutes": {"S": "360"}' \
                '"num_timesteps": {"S": "12"}' "\"io_form\": {\"S\": \"${io}\"}"; do
        grep -qF -- "${attr}" <<<"${item}" && ok "the stored item holds ${attr}" \
            || bad "the stored item holds ${attr}" "${attr}" \
                   "$(grep -E 'cells|minutes|timesteps"|io_form' <<<"${item}" | tr '\n' '|')"
    done
    # Without lib/wrf-run-info.sh (submitted from elsewhere, the other two
    # libraries pointed at), the run is recorded without the description, and a
    # NOTE says how to point at the library. WRF_RUN_INFO_LIB comes first.
    run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/conus-sized" \
        SLURM_SUBMIT_DIR="${STUBS}/elsewhere" WRF_STEP_TIMING_LIB="${WRF_APP}/lib/wrf-step-timing.sh" \
        WRF_RUN_CHECK_LIB="${WRF_APP}/lib/wrf-run-check.sh"
    has "lib/wrf-run-info.sh not found: a NOTE says how to point at it" \
        "NOTE: lib/wrf-run-info.sh not found, so the record has no grid size, run length or io_form; set WRF_RUN_INFO_LIB=/path/to/apps/WRF/lib/wrf-run-info.sh."
    grep -qxF 'RUN: ' "${RECLOG}" && grep -q -- '--metric avg_timestep_seconds=2.25' "${RECLOG}" \
        && ok "lib/wrf-run-info.sh not found: the run is recorded without the description" \
        || bad "lib/wrf-run-info.sh not found: recorded without it" "RUN: (nothing), and the metrics" \
               "$(head -2 "${RECLOG}" | tr '\n' '|')"
    run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/conus-sized" \
        WRF_RUN_INFO_LIB="${STUBS}/stub-lib/wrf-run-info.sh"
    grep -qxF 'RUN: --char num_timesteps=7777' "${RECLOG}" \
        && ok "WRF_RUN_INFO_LIB takes precedence over a submit-directory copy" \
        || bad "WRF_RUN_INFO_LIB takes precedence" "RUN: --char num_timesteps=7777" "$(grep '^RUN:' "${RECLOG}")"

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
    want='ARGS: --metric avg_timestep_seconds=2.25 --metric median_timestep_seconds=1.15000 --metric steady_timestep_seconds=1.11111'
    grep -qxF -- "${want}" "${RECLOG}" \
        && ok "the recorder also gets the median and the steady step" \
        || bad "the recorder gets the median and the steady step" "${want}" "$(head -1 "${RECLOG}")"

    # With an adaptive time step WRF labels each step "main (dt= ...)", which
    # moves its time off the 9th field: the average reads the number before
    # "elapsed seconds", as the median and the steady step do. Steps 6.4 1.2 1.0
    # 1.4 | 3.6 1.0 1.2 1.0: average 16.8 / 8; median (1.2 + 1.2) / 2; steady
    # without step 1 and the step after the history write, 6.8 / 6.
    run_script "${s}" "${FIX}/adaptive-dt.rsl"
    has "adaptive time step: the average reads each step's time" "Avg timestep:     2.10s"
    has "adaptive time step: the median step" "Median timestep:  1.20000s"
    has "adaptive time step: the steady step" "Steady timestep:  1.13333s"
    if [ "${x86}" -eq 1 ]; then
        has "adaptive time step: the checking section's average" "Average time per timestep: 2.10s"
    fi
    want='ARGS: --metric avg_timestep_seconds=2.10 --metric median_timestep_seconds=1.20000 --metric steady_timestep_seconds=1.13333'
    grep -qxF -- "${want}" "${RECLOG}" \
        && ok "adaptive time step: the recorder gets that average" \
        || bad "adaptive time step: the recorder gets that average" "${want}" "$(head -1 "${RECLOG}")"

    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="${WRF_APP}"
    has "submitted from apps/WRF: the library is found" "Median timestep:  1.15000s"
    recorded "submitted from apps/WRF: the run check is found and the run is recorded"
    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="$(cd "${WRF_APP}/../.." && pwd)"
    has "submitted from the repository root: the library is found" "Median timestep:  1.15000s"
    recorded "submitted from the repository root: the run check is found and the run is recorded"

    run_script "${s}" ""
    [ "${RC}" -eq 0 ] && ok "no rsl.error.0000: completes (exit 0), as before" \
        || bad "no rsl.error.0000 completes" "exit 0" "exit ${RC}"
    has "no rsl.error.0000: the average is N/A, as before" "Avg timestep:     N/As"
    has "no rsl.error.0000: the median step is N/A" "Median timestep:  N/As"
    has "no rsl.error.0000: the steady step is N/A" "Steady timestep:  N/As"
    has "no rsl.error.0000: a NOTE says why the run is not recorded" \
        "NOTE: not recording this run: no readable rsl.error.0000"
    [ -s "${RECLOG}" ] && bad "no rsl.error.0000: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "no rsl.error.0000: the run is not recorded"

    # This repository's recorder, in --dry-run: the item it would store.
    run_script "${s}" "${FIX}/hourly-history.rsl" \
        DYNAMODB_RECORDER="${STUBS}/bin/real-recorder.sh" OPERATING_SYSTEM="Test OS"
    item="$(sed -n '/^{/,$p' "${RECJSON}")"
    for attr in '"avg_timestep_seconds": {"N": "2.25"}' \
                '"median_timestep_seconds": {"N": "1.15000"}' \
                '"steady_timestep_seconds": {"N": "1.11111"}'; do
        grep -qF -- "${attr}" <<<"${item}" && ok "the stored item holds ${attr}" \
            || bad "the stored item holds ${attr}" "${attr}" "$(grep timestep <<<"${item}" | tr '\n' '|')"
    done
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys; json.loads(sys.stdin.read())' <<<"${item}" 2>/dev/null \
            && ok "the stored item is valid JSON" || bad "the stored item is valid JSON" "parses" "${item:0:200}"
    else
        skipt "the stored item is valid JSON" "no python3"
    fi
    # Without lib/wrf-step-timing.sh (submitted from elsewhere, with the run
    # check pointed at through its variable) the median and the steady step are
    # N/A: the recorder skips them with a warning, as it skips any N/A value.
    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="${STUBS}/elsewhere" \
        WRF_RUN_CHECK_LIB="${WRF_APP}/lib/wrf-run-check.sh" \
        DYNAMODB_RECORDER="${STUBS}/bin/real-recorder.sh" OPERATING_SYSTEM="Test OS"
    item="$(sed -n '/^{/,$p' "${RECJSON}")"
    if grep -qF '"avg_timestep_seconds": {"N": "2.25"}' <<<"${item}" \
            && ! grep -qE '(median|steady)_timestep_seconds' <<<"${item}"; then
        ok "N/A median and steady step: the stored item keeps the average and has neither"
    else
        bad "N/A median and steady step: skipped" "the average only" "$(grep timestep <<<"${item:-<no item>}" | tr '\n' '|')"
    fi
    grep -q "WARN: ignoring non-numeric value for 'steady_timestep_seconds': 'N/A'" "${RECLOG}" \
        && ok "N/A median and steady step: the recorder says it skipped them" \
        || bad "N/A median and steady step: recorder WARN" "WARN ... 'N/A'" "$(grep WARN "${RECLOG}" | head -3 | tr '\n' '|')"

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

    # The output format: PnetCDF by default in the CONUS 2.5km scripts, the
    # namelist as it is in the others.
    case "${s}" in
        x86/wrf-benchmark-conus2.5km*)
            run_script "${s}" "${FIX}/hourly-history.rsl"
            [ "${RC}" -eq 0 ] && [ "$(run_nl)" = "${PNETCDF_NL}" ] \
                && ok "${s}: WRF gets io_form_history and io_form_restart 11, and nothing else changed" \
                || bad "${s}: the run's namelist" "${PNETCDF_NL//$'\n'/|}" "exit ${RC}: $(run_nl | tr '\n' '|')"
            [ "$(cat "${STUBS}/conus/namelist.input")" = "${SHIPPED_NL}" ] \
                && ok "${s}: CONUS_DIR's namelist.input is left as it is" \
                || bad "${s}: CONUS_DIR's namelist.input" "unchanged" "$(tr '\n' '|' < "${STUBS}/conus/namelist.input")"
            has "${s}: the job says which output it writes" \
                "Output: PnetCDF (io_form_history = io_form_restart = 11 in this run's namelist.input)"
            run_script "${s}" "${FIX}/hourly-history.rsl" WRF_OUTPUT_FORMAT=namelist
            [ "${RC}" -eq 0 ] && [ "$(run_nl)" = "${SHIPPED_NL}" ] \
                && ok "${s}: WRF_OUTPUT_FORMAT=namelist gives WRF the namelist as it is" \
                || bad "${s}: WRF_OUTPUT_FORMAT=namelist" "${SHIPPED_NL//$'\n'/|}" "exit ${RC}: $(run_nl | tr '\n' '|')"
            run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/conus-no-io-form"
            stopped "${s}: a namelist with no io_form lines stops the job before wrf.exe"
            grep -q '^ERROR: setting io_form_history and io_form_restart from 2 to 11' <<<"${OUT}" \
                && grep -q 'Set WRF_OUTPUT_FORMAT=namelist' <<<"${OUT}" \
                && ok "${s}: the ERROR says what failed and how to run the namelist as it is" \
                || bad "${s}: the ERROR" "the change, and WRF_OUTPUT_FORMAT=namelist" "$(grep ERROR <<<"${OUT}" | head -1)"
            run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/conus-pnetcdf"
            stopped "${s}: a namelist already at 11 does not take the change either: the job stops"
            for c in "conus-history-only:only io_form_history at 2" "conus-restart-102:io_form_restart at 102" \
                     "conus-history-twice:io_form_history set twice"; do
                run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/${c%%:*}"
                stopped "${s}: a namelist with ${c#*:} stops the job before wrf.exe"
                grep -q '^ERROR: setting io_form_history and io_form_restart from 2 to 11' <<<"${OUT}" \
                    && ok "${s}: ${c#*:}: the ERROR says the change did not set exactly the two lines" \
                    || bad "${s}: ${c#*:}: the ERROR" "the change's ERROR" "$(grep ERROR <<<"${OUT}" | head -1)"
            done
            run_script "${s}" "${FIX}/hourly-history.rsl" CONUS_DIR="${STUBS}/conus-pnetcdf" WRF_OUTPUT_FORMAT=namelist
            [ "${RC}" -eq 0 ] && [ "$(run_nl)" = "${PNETCDF_NL}" ] \
                && ok "${s}: with WRF_OUTPUT_FORMAT=namelist that namelist runs as it is" \
                || bad "${s}: WRF_OUTPUT_FORMAT=namelist on a namelist at 11" "${PNETCDF_NL//$'\n'/|}" "exit ${RC}: $(run_nl | tr '\n' '|')"
            run_script "${s}" "${FIX}/hourly-history.rsl" WRF_OUTPUT_FORMAT=serial
            stopped "${s}: an unknown WRF_OUTPUT_FORMAT stops the job"
            [ ! -e "$(dirname "${RECLOG}")/Run" ] && ok "${s}: ... before the run directory is made" \
                || bad "${s}: an unknown WRF_OUTPUT_FORMAT, before the run directory" "no Run directory" \
                       "$(ls "$(dirname "${RECLOG}")" | tr '\n' ' ')"
            has "${s}: the ERROR names the two values" "ERROR: WRF_OUTPUT_FORMAT must be pnetcdf or namelist (got: serial)"
            ;;
        *)
            run_script "${s}" "${FIX}/hourly-history.rsl" BENCHMARK=2.5km
            [ "${RC}" -eq 0 ] && [ "$(run_nl)" = "${SHIPPED_NL}" ] \
                && ok "${s}: WRF gets the namelist as it is" \
                || bad "${s}: the run's namelist" "${SHIPPED_NL//$'\n'/|}" "exit ${RC}: $(run_nl | tr '\n' '|')"
            ;;
    esac

    run_script "${s}" "${FIX}/hourly-history.rsl" SLURM_SUBMIT_DIR="${STUBS}/elsewhere"
    [ "${RC}" -eq 0 ] && ok "library not found: still completes (exit 0)" \
        || bad "library not found completes" "exit 0" "exit ${RC}"
    grep -q 'NOTE: lib/wrf-step-timing.sh not found.*WRF_STEP_TIMING_LIB=' <<<"${OUT}" \
        && ok "library not found: a NOTE says how to point at it" \
        || bad "library not found NOTE" "NOTE ... WRF_STEP_TIMING_LIB=" "absent"
    has "library not found: the average is unchanged" "Avg timestep:     2.25s"
    has "library not found: the median step is N/A" "Median timestep:  N/As"
    has "library not found: the steady step is N/A" "Steady timestep:  N/As"
    has "the run check not found either: a NOTE says how to point at it" \
        "NOTE: not recording this run: lib/wrf-run-check.sh not found; set WRF_RUN_CHECK_LIB=/path/to/apps/WRF/lib/wrf-run-check.sh"
    [ -s "${RECLOG}" ] && bad "the run check not found: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "the run check not found: the run is not recorded"

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

    # The run check (lib/wrf-run-check.sh) comes before the recorder: a run is
    # recorded only when WRF completed and every output file it wrote is there.
    # The job's exit status does not change.
    run_script "${s}" "${FIX}/no-success.rsl"
    [ "${RC}" -eq 0 ] && ok "no SUCCESS COMPLETE WRF: the job completes (exit 0)" \
        || bad "no SUCCESS COMPLETE WRF: the job completes" "exit 0" "exit ${RC}"
    has "no SUCCESS COMPLETE WRF: a NOTE says why the run is not recorded" \
        "NOTE: not recording this run: rsl.error.0000 does not say SUCCESS COMPLETE WRF"
    [ -s "${RECLOG}" ] && bad "no SUCCESS COMPLETE WRF: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "no SUCCESS COMPLETE WRF: the run is not recorded"

    # Two problems at once: one NOTE names both, joined with "; ". A history
    # file is named as WRF writes it in this run (hist).
    run_script "${s}" "${FIX}/no-success.rsl" WRF_OUTPUT=none
    has "two problems: the NOTE names both" \
        "NOTE: not recording this run: rsl.error.0000 does not say SUCCESS COMPLETE WRF; history file $(hist wrfout_d01_2000-01-01_00:00:00) is missing"
    [ -s "${RECLOG}" ] && bad "two problems: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "two problems: the run is not recorded"

    run_script "${s}" "${FIX}/hourly-history.rsl" WRF_OUTPUT=none
    has "a history file missing: a NOTE names it" \
        "NOTE: not recording this run: history file $(hist wrfout_d01_2000-01-01_00:00:00) is missing"
    [ -s "${RECLOG}" ] && bad "a history file missing: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "a history file missing: the run is not recorded"

    run_script "${s}" "${FIX}/hourly-history.rsl" WRF_OUTPUT=empty
    has "an empty history file: a NOTE names it" \
        "NOTE: not recording this run: history file $(hist wrfout_d01_2000-01-01_00:00:00) is empty"
    [ -s "${RECLOG}" ] && bad "an empty history file: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "an empty history file: the run is not recorded"

    run_script "${s}" "${FIX}/restart-write.rsl" WRF_OUTPUT=no-restart
    has "restart files missing: a NOTE says so" \
        "NOTE: not recording this run: 2 restart write(s) in rsl.error.0000 but 0 wrfrst_d01_* file(s)"
    [ -s "${RECLOG}" ] && bad "restart files missing: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "restart files missing: the run is not recorded"
    run_script "${s}" "${FIX}/restart-write.rsl"
    grep -q -- '--metric avg_timestep_seconds=' "${RECLOG}" \
        && ok "history and restart files all in place: the run is recorded" \
        || bad "history and restart files all in place: recorded" "the recorder called" "not called"

    run_script "${s}" "${FIX}/hourly-history.rsl" WRF_RUN_CHECK_LIB="${STUBS}/stub-lib/wrf-run-check.sh"
    has "WRF_RUN_CHECK_LIB takes precedence over a submit-directory copy" \
        "NOTE: not recording this run: stub check refused"
    [ -s "${RECLOG}" ] && bad "WRF_RUN_CHECK_LIB's refusal: not recorded" "recorder not called" "$(head -1 "${RECLOG}")" \
        || ok "WRF_RUN_CHECK_LIB's refusal: the run is not recorded"
done

# On hpc8a.96xlarge and hpc7a.96xlarge the x86 scripts run only the counts per
# node that put the same number of ranks on each of the 24 CCDs (24, 48, ...,
# 192) and stop any other before the run directory and mpirun. Other types and
# sizes, named by the instance metadata, are not checked and lscpu is not asked.
# When the instance metadata gives no instance type (no answer, an HTTP error,
# or an answer that is not a type name), such a count stops them on a node
# whose lscpu shows 192 AMD cores (sockets x cores per socket), which could be
# either type, and runs, with a NOTE on stderr, on any other node.
# refused_early <label>: the job failed before the run directory and wrf.exe,
# and recorded nothing
refused_early() {
    if [ "${RC}" -ne 0 ] && [ ! -e "$(dirname "${RECLOG}")/Run" ] && ! grep -q 'starting wrf task' <<<"${OUT}" \
            && [ ! -s "${RECLOG}" ]; then ok "$1"
    else bad "$1" "a failed job, no run directory, no wrf.exe, nothing recorded" \
             "exit ${RC}; $(grep -c 'starting wrf task' <<<"${OUT}") wrf.exe start(s); recorder log $(wc -l < "${RECLOG}") line(s)"; fi
}
# ran <label>: the job completed and started wrf.exe
ran() {
    if [ "${RC}" -eq 0 ] && grep -q 'starting wrf task' <<<"${OUT}"; then ok "$1"
    else bad "$1" "exit 0 and wrf.exe started" "exit ${RC}: $(grep ERROR <<<"${OUT}" | head -1)"; fi
}
# says <label> <exact line>: the output holds that line
says() {
    if grep -qxF -- "$2" <<<"${OUT}"; then ok "$1"
    else bad "$1" "$2" "$(grep -E '^(ERROR|NOTE)' <<<"${OUT}" | head -3 | tr '\n' '|')"; fi
}
# lacks <label> <ERE>: no line of the output matches it
lacks() {
    if ! grep -qE -- "$2" <<<"${OUT}"; then ok "$1"
    else bad "$1" "no line matching '$2'" "$(grep -E -- "$2" <<<"${OUT}" | head -1)"; fi
}
COUNTS="run 24, 48, 72, 96, 120, 144, 168 or 192 ranks per node there (Utils/flexible-cores), and below 192 also replace this script's pinning with that count's list (README, Fewer ranks per node). Not starting WRF."
type_error() { echo "ERROR: $1 ranks per node load the 24 CCDs of $2 unevenly; ${COUNTS}"; }
amd_error() {
    echo "ERROR: $1 ranks per node load the 24 CCDs of hpc8a.96xlarge and hpc7a.96xlarge unevenly, and this node could be either (the instance metadata gave no instance type, and lscpu shows 192 AMD cores); ${COUNTS}"
}
skip_note() {
    echo "NOTE: the instance metadata gave no instance type, and lscpu does not show the 192 AMD cores of hpc8a.96xlarge and hpc7a.96xlarge, so the ranks-per-node check (Utils/flexible-cores) is skipped: running $1 ranks per node."
}
SKIPPED='^NOTE: the instance metadata gave no instance type'
# per_node <script> <ranks per node> [NAME=value...]: run_script on 2 nodes at
# that count, with fresh logs of the curl and lscpu calls (CURLLOG, LSCPULOG)
ncase=0
per_node() {
    local s="$1" c="$2"; shift 2
    ncase=$((ncase + 1)); CURLLOG="${STUBS}/curl-${ncase}.log"; LSCPULOG="${STUBS}/lscpu-${ncase}.log"
    : > "${CURLLOG}"; : > "${LSCPULOG}"
    run_script "${s}" "${FIX}/hourly-history.rsl" CURL_LOG="${CURLLOG}" LSCPU_LOG="${LSCPULOG}" \
        SLURM_NTASKS_PER_NODE="${c}" SLURM_NTASKS=$(( 2 * c )) "$@"
}
# lscpu_asked <label> yes|no: lscpu was asked, in the C locale, or not at all
lscpu_asked() {
    local got="not asked" want="not asked"
    [ -s "${LSCPULOG}" ] && got="$(sort -u "${LSCPULOG}" | tr '\n' ' ')"
    [ "$2" = yes ] && want="LC_ALL=C "
    if [ "${got}" = "${want}" ]; then ok "$1"; else bad "$1" "lscpu: ${want}" "lscpu: ${got}"; fi
}
# imds_calls <label>: two instance-metadata requests, the token's and the
# instance type's, each with -f and a time limit of 5 seconds, 2 to connect
imds_calls() {
    local tok='^-fs --connect-timeout 2 --max-time 5 -X PUT http://169\.254\.169\.254/latest/api/token -H X-aws-ec2-metadata-token-ttl-seconds: 21600$'
    local typ='^-fs --connect-timeout 2 --max-time 5 -H X-aws-ec2-metadata-token: .* http://169\.254\.169\.254/latest/meta-data/instance-type$'
    if [ "$(wc -l < "${CURLLOG}")" -eq 2 ] && sed -n 1p "${CURLLOG}" | grep -qE -- "${tok}" \
            && sed -n 2p "${CURLLOG}" | grep -qE -- "${typ}"; then ok "$1"
    else bad "$1" "2 calls, each -fs --connect-timeout 2 --max-time 5 ..." "$(tr '\n' '|' < "${CURLLOG}")"; fi
}
# BASH_ENV file that discards a benchmark script's stdout, and not its
# children's: what is left of the output is its stderr.
printf 'case "$0" in */x86/wrf-benchmark*.sbatch) exec > /dev/null ;; esac\n' > "${STUBS}/stdout-off.sh"
echo "== ranks per node on hpc8a.96xlarge and hpc7a.96xlarge (the x86 scripts) =="
for s in "${SCRIPTS[@]}"; do
    case "${s}" in x86/*) ;; *) continue ;; esac
    for t in hpc8a.96xlarge hpc7a.96xlarge; do
        for c in 24 48 72 96 120 144 168 192; do
            per_node "${s}" "${c}" IMDS_INSTANCE_TYPE="${t}"
            ran "${s}: ${c} ranks per node on ${t} run"
        done
        imds_calls "${s}: both instance-metadata requests carry -f and give up after 5 seconds, 2 to connect"
        for c in 25 32 64 100 191; do
            per_node "${s}" "${c}" IMDS_INSTANCE_TYPE="${t}" STUB_LSCPU=amd-2x96
            refused_early "${s}: ${c} ranks per node on ${t} stop the job before the run directory and mpirun"
            says "${s}: ${c} ranks per node on ${t}: the ERROR names the supported counts" "$(type_error "${c}" "${t}")"
        done
        lscpu_asked "${s}: ${t} named by the instance metadata: lscpu is not asked" no
    done
    # Other types and sizes named by the instance metadata run any count, with no
    # NOTE and no lscpu, also those with 192 AMD cores (c7a, m8a.48xlarge) and,
    # in a Turkish locale, those with an i in their name.
    for c in hpc7a.48xlarge c8i.96xlarge c7a.48xlarge m8a.48xlarge "hpc6id.32xlarge LANG=tr_TR.UTF-8" \
             "c8i.96xlarge LANG=tr_TR.UTF-8"; do
        read -r t loc <<<"${c}"
        per_node "${s}" 64 IMDS_INSTANCE_TYPE="${t}" STUB_LSCPU=amd-2x96 ${loc:+"${loc}"}
        ran "${s}: 64 ranks per node on ${t}${loc:+ (${loc})} run"
        lacks "${s}: ${t}${loc:+ (${loc})}: no NOTE" "${SKIPPED}"
        lscpu_asked "${s}: ${t}${loc:+ (${loc})}: lscpu is not asked" no
    done
    # No instance type from the instance metadata on a node whose lscpu shows
    # 2 x 96 AMD cores: no answer, an HTTP error, an empty answer, and answers
    # that are not a type name (an error page, a proxy's page that names a host,
    # a type after other text, a type and a second line, a type in capitals).
    for k in IMDS_MODE=down IMDS_MODE=http-error IMDS_INSTANCE_TYPE= \
             "IMDS_INSTANCE_TYPE=<html><body>401 Unauthorized</body></html>" \
             "IMDS_INSTANCE_TYPE=Access denied by proxy.example.com" \
             "IMDS_INSTANCE_TYPE=Not found: hpc8a.96xlarge" \
             "IMDS_INSTANCE_TYPE=hpc8a.96xlarge"$'\n'"<html>" \
             IMDS_INSTANCE_TYPE=HPC8A.96XLARGE; do
        l="${k//$'\n'/\\n}"
        per_node "${s}" 64 "${k}" STUB_LSCPU=amd-2x96
        refused_early "${s}: ${l}, lscpu 2 x 96 AMD cores: 64 ranks per node stop the job"
        says "${s}: ${l}: the ERROR names both types, why, and the supported counts" "$(amd_error 64)"
        lacks "${s}: ${l}: no NOTE that the check is skipped" "${SKIPPED}"
        lscpu_asked "${s}: ${l}: lscpu is asked, in the C locale" yes
    done
    for c in 192 24; do
        per_node "${s}" "${c}" IMDS_MODE=down STUB_LSCPU=amd-2x96
        ran "${s}: no answer, 2 x 96 AMD cores: ${c} ranks per node run"
        lacks "${s}: no answer, ${c} ranks per node: no NOTE" "${SKIPPED}"
    done
    # With -f, an HTTP error leaves no instance type, so the error page does not
    # name the run directory.
    per_node "${s}" 192 IMDS_MODE=http-error STUB_LSCPU=amd-2x96
    ran "${s}: an HTTP error, 192 ranks per node: the job runs"
    w="$(find "$(dirname "${RECLOG}")/Run" -mindepth 3 -maxdepth 3 2>/dev/null)"
    [[ "${w##*/}" =~ ^4242-2x-384-[0-9-]+$ && "$(wc -l <<<"${w}")" -eq 1 ]] \
        && ok "${s}: an HTTP error: the run directory's name has no instance type, and no error page" \
        || bad "${s}: an HTTP error: the run directory's name" "4242-2x-384-<date>" "${w//$'\n'/|}"
    # An answer that is not a type name counts as none too: a proxy's page does
    # not name the run directory either.
    per_node "${s}" 192 "IMDS_INSTANCE_TYPE=Access denied by proxy.example.com" STUB_LSCPU=amd-2x96
    ran "${s}: a proxy's page, 192 ranks per node: the job runs"
    w="$(find "$(dirname "${RECLOG}")/Run" -mindepth 3 -maxdepth 3 2>/dev/null)"
    [[ "${w##*/}" =~ ^4242-2x-384-[0-9-]+$ && "$(wc -l <<<"${w}")" -eq 1 ]] \
        && ok "${s}: a proxy's page: the run directory's name has no instance type, and none of the page" \
        || bad "${s}: a proxy's page: the run directory's name" "4242-2x-384-<date>" "${w//$'\n'/|}"
    # No answer: lscpu decides. 192 AMD cores in one socket stop 64 ranks per
    # node too; 96 AMD cores with 2 threads each (192 CPUs), 96 or 256 AMD
    # cores, 192 Intel cores, or an lscpu that fails run them, with the NOTE.
    per_node "${s}" 64 IMDS_MODE=down STUB_LSCPU=amd-1x192
    refused_early "${s}: no answer, lscpu 1 x 192 AMD cores: 64 ranks per node stop the job"
    says "${s}: no answer, lscpu 1 x 192 AMD cores: the ERROR names both types" "$(amd_error 64)"
    for shape in amd-2x48-smt amd-1x96 amd-2x128 intel-2x96 none; do
        per_node "${s}" 64 IMDS_MODE=down STUB_LSCPU="${shape}"
        ran "${s}: no answer, lscpu ${shape}: 64 ranks per node run"
        says "${s}: no answer, lscpu ${shape}: the NOTE says the check is skipped" "$(skip_note 64)"
    done
    # An HTTP error, or an error page, on an Intel node and on a 96-core AMD node.
    for k in IMDS_MODE=http-error "IMDS_INSTANCE_TYPE=<html><body>401 Unauthorized</body></html>"; do
        for shape in intel-2x96 amd-1x96; do
            per_node "${s}" 64 "${k}" STUB_LSCPU="${shape}"
            ran "${s}: ${k}, lscpu ${shape}: 64 ranks per node run"
            says "${s}: ${k}, lscpu ${shape}: the NOTE says the check is skipped" "$(skip_note 64)"
        done
    done
    # lscpu is read in the C locale: in German, its keys are translated.
    per_node "${s}" 64 IMDS_MODE=down STUB_LSCPU=amd-2x96 LC_ALL=de_DE.UTF-8
    refused_early "${s}: no answer, 2 x 96 AMD cores, LC_ALL=de_DE.UTF-8: 64 ranks per node stop the job"
    says "${s}: LC_ALL=de_DE.UTF-8: the ERROR names both types" "$(amd_error 64)"
    lscpu_asked "${s}: LC_ALL=de_DE.UTF-8: lscpu is asked in the C locale" yes
    # The two ERROR lines and the NOTE go to stderr: with the script's stdout
    # discarded, the output still holds them.
    per_node "${s}" 64 IMDS_INSTANCE_TYPE=hpc8a.96xlarge BASH_ENV="${STUBS}/stdout-off.sh"
    says "${s}: the ERROR for hpc8a.96xlarge goes to stderr" "$(type_error 64 hpc8a.96xlarge)"
    per_node "${s}" 64 IMDS_MODE=down STUB_LSCPU=amd-2x96 BASH_ENV="${STUBS}/stdout-off.sh"
    says "${s}: the ERROR for a 192-core AMD node goes to stderr" "$(amd_error 64)"
    per_node "${s}" 64 IMDS_MODE=down STUB_LSCPU=intel-2x96 BASH_ENV="${STUBS}/stdout-off.sh"
    says "${s}: the NOTE goes to stderr" "$(skip_note 64)"
    lacks "${s}: (the script's stdout was discarded)" '^=== WRF'
done

# The Arm script reads the instance type for its run directory's name and its
# job log only, as it has no ranks-per-node check. Both instance-metadata
# requests carry -f and give up after 5 seconds, 2 to connect, and with no
# answer, an answer cut off at that limit, an HTTP error, or an answer that is
# not a type name, the job runs and is recorded, its run directory's name and
# its job log hold no instance type and nothing of the answer, lscpu is not
# asked, and no NOTE is printed. A type name with an i reads as one in a
# Turkish locale too.
echo "== the instance metadata (the Arm script) =="
ARM=Arm/wrf-benchmark.sbatch
# arm_dir <label> <type>: the job ran, and its only run directory is named 4242-2x<type>-8-<date>
arm_dir() {
    local w
    w="$(find "$(dirname "${RECLOG}")/Run" -mindepth 3 -maxdepth 3 2>/dev/null)"
    if [ "${RC}" -eq 0 ] && grep -q 'starting wrf task' <<<"${OUT}" \
            && [[ "${w##*/}" =~ ^4242-2x"$2"-8-[0-9-]+$ && "$(wc -l <<<"${w}")" -eq 1 ]]; then ok "$1"
    else bad "$1" "exit 0, wrf.exe started, the run directory 4242-2x$2-8-<date>" "exit ${RC}; ${w//$'\n'/|}"; fi
}
per_node "${ARM}" 4 IMDS_INSTANCE_TYPE=m8g.48xlarge
arm_dir "${ARM}: m8g.48xlarge from the instance metadata names the run directory" m8g.48xlarge
says "${ARM}: m8g.48xlarge: and the job log" "Instance: m8g.48xlarge"
imds_calls "${ARM}: both instance-metadata requests carry -f and give up after 5 seconds, 2 to connect"
lscpu_asked "${ARM}: m8g.48xlarge: lscpu is not asked" no
for k in IMDS_MODE=down IMDS_MODE=cut-off IMDS_MODE=http-error IMDS_INSTANCE_TYPE= \
         "IMDS_INSTANCE_TYPE=<html><body>401 Unauthorized</body></html>" \
         "IMDS_INSTANCE_TYPE=Access denied by proxy.example.com" \
         "IMDS_INSTANCE_TYPE=Not found: m8g.48xlarge" \
         "IMDS_INSTANCE_TYPE=m8g.48xlarge"$'\n'"<html>" \
         IMDS_INSTANCE_TYPE=M8G.48XLARGE; do
    l="${k//$'\n'/\\n}"
    per_node "${ARM}" 4 "${k}"
    arm_dir "${ARM}: ${l}: the job runs, and its run directory's name has no instance type" ""
    says "${ARM}: ${l}: the job log names none" "Instance: "
    recorded "${ARM}: ${l}: the run is recorded"
    lacks "${ARM}: ${l}: no NOTE" '^NOTE'
    lscpu_asked "${ARM}: ${l}: lscpu is not asked" no
done
per_node "${ARM}" 4 IMDS_MODE=down
imds_calls "${ARM}: no answer: both requests carry -f and give up after 5 seconds, 2 to connect"
per_node "${ARM}" 4 IMDS_INSTANCE_TYPE=im4gn.16xlarge LANG=tr_TR.UTF-8
arm_dir "${ARM}: im4gn.16xlarge in a Turkish locale names the run directory" im4gn.16xlarge

echo "== the stubs kept AWS out of it =="
[ -s "${STUBS}/aws-calls.log" ] && bad "no AWS call" "none" "$(head -1 "${STUBS}/aws-calls.log")" \
    || ok "no test called AWS"

echo
printf 'sbatch e2e tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ] || exit 1
