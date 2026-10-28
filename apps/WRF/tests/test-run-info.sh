#!/bin/bash
# =============================================================================
# Tests for lib/wrf-run-info.sh: what the record says about a run
# =============================================================================
# Needs no Slurm, no EC2, no WRF, no MPI and no AWS credentials. Every case is
# a run directory the test writes itself (synthetic times only).
#
#   ./tests/test-run-info.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib/wrf-run-info.sh"
FIX="${HERE}/fixtures"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

if [ ! -r "${LIB}" ]; then
    bad "the run-info library exists" "${LIB}" "missing"
    printf 'run-info tests: %d passed, %d failed\n' "${pass}" "${fail}"
    exit 1
fi
# shellcheck source=../lib/wrf-run-info.sh
. "${LIB}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# dir <name> [rsl fixture]: a run directory ${WORK}/<name>, with that fixture as
# its rsl.error.0000 when given; prints its path.
dir() {
    local d="${WORK}/$1"
    mkdir -p "${d}"
    if [ -n "${2:-}" ]; then cp "${2}" "${d}/rsl.error.0000"; fi
    printf '%s\n' "${d}"
}
# nl <dir> <line>...: its namelist.input, a &time_control and a &domains group
# around the lines given (one argument per line, written with a leading blank).
nl() {
    local d="$1" l; shift
    { echo ' &time_control'; for l in "$@"; do echo " ${l}"; done; echo ' /'; } > "${d}/namelist.input"
}
# check <label> <dir> <expected output>: wrf_run_info's output, line for line,
# and its status, always 0.
check() {
    local label="$1" d="$2" want="$3" got rc
    got="$(wrf_run_info "${d}")"; rc=$?
    if [ "${rc}" -eq 0 ] && [ "${got}" = "${want}" ]; then ok "${label}"
    else bad "${label}" "status 0, output: ${want//$'\n'/ | }" "status ${rc}, output: ${got//$'\n'/ | }"; fi
}

# The CONUS 2.5km case, in the namelist's own layout.
CONUS25=('run_days                            = 0,' 'run_hours                           = 6,'
         'run_minutes                         = 0,' 'run_seconds                         = 0, '
         'start_year                          = 2019,' 'start_month                         = 11,'
         'start_day                           = 26,' 'start_hour                          = 18,'
         'start_minute                        = 00,' 'start_second                        = 00,'
         'end_year                            = 2019,' 'end_month                           = 11,'
         'end_day                             = 27,' 'end_hour                            = 00,'
         'end_minute                          = 00,' 'end_second                          = 00,'
         'history_interval_m                  = 60' 'frames_per_outfile                  = 1,'
         'io_form_history                     = 2,' 'io_form_restart                     = 2,'
         'time_step                           = 15,' 'max_dom                             = 1,'
         's_we                                = 1,' 'e_we                                = 1501,'
         'e_sn                                = 1201,' 'e_vert                              = 50,'
         'dx                                  = 2500,')

echo "== a complete run directory =="

d="$(dir conus25 "${FIX}/hourly-history.rsl")"
nl "${d}" "${CONUS25[@]}"
check "CONUS 2.5km: 1501 x 1201 x 50 cells, 6 hours, the fixture's 12 steps, serial output" "${d}" \
"num_cells_million=90.135
simulated_minutes=360
io_form=2
num_timesteps=12"

d="$(dir pnetcdf)"
nl "${d}" "${CONUS25[@]}"
sed -i 's/^\( io_form_history *= *\)2,$/\111,/' "${d}/namelist.input"
{ echo 'Timing for main: time 2000-01-01_00:00:15 on domain   1:    6.40000 elapsed seconds'
  echo 'Timing for main (dt= 20.50): time 2000-01-01_00:00:35 on domain   1:    1.20000 elapsed seconds'
  echo 'Timing for main (dt=100.00): time 2000-01-01_00:02:15 on domain   1:    1.40000 elapsed seconds'
  echo 'Timing for Writing wrfout_d01_2000-01-01_00:02:15 for domain        1:    3.00000 elapsed seconds'
  echo 'Timing for main (dt=  9.75): time 2000-01-01_00:02:25 on domain   1:    1.00000 elapsed seconds'
} > "${d}/rsl.error.0000"
check "PnetCDF output: io_form 11; steps with an adaptive time step count too (4)" "${d}" \
"num_cells_million=90.135
simulated_minutes=360
io_form=11
num_timesteps=4"

d="$(dir conus12 "${FIX}/lateral-boundary.rsl")"
nl "${d}" 'run_hours = 12,' 'io_form_history = 2,' 'e_we = 425,' 'e_sn = 300,' 'e_vert = 50,'
check "a 425 x 300 x 50 grid is 6.375 million cells; 12 hours are 720 minutes" "${d}" \
"num_cells_million=6.375
simulated_minutes=720
io_form=2
num_timesteps=6"

echo "== the run length =="

# run_* take precedence over the dates in wrf.exe: here they give 90 minutes,
# the dates 6 hours.
d="$(dir run-first)"
nl "${d}" 'run_hours = 1,' 'run_minutes = 30,' 'start_year = 2019,' 'start_month = 11,' 'start_day = 26,' \
    'start_hour = 18,' 'start_minute = 0,' 'start_second = 0,' 'end_year = 2019,' 'end_month = 11,' \
    'end_day = 27,' 'end_hour = 0,' 'end_minute = 0,' 'end_second = 0,'
check "run_* set: they give the length, not the dates" "${d}" "simulated_minutes=90"

d="$(dir days)"
nl "${d}" 'run_days = 1,' 'run_hours = 12,' 'run_seconds = 90,'
check "run_days, run_hours and run_seconds add up; 90 s more is 1.5 minutes" "${d}" "simulated_minutes=2161.500"

# With every run_* at 0 or unset, wrf.exe runs from the start date to the end
# date of domain 1.
dates() {  # dates <dir> <start Y M D h m s> <end Y M D h m s> [other lines]
    local d="$1"; shift
    local s=("$1" "$2" "$3" "$4" "$5" "$6") e=("$7" "$8" "$9" "${10}" "${11}" "${12}"); shift 12
    nl "${d}" "start_year = ${s[0]}, ${s[0]}," "start_month = ${s[1]}," "start_day = ${s[2]}," \
        "start_hour = ${s[3]}," "start_minute = ${s[4]}," "start_second = ${s[5]}," \
        "end_year = ${e[0]}, ${e[0]}," "end_month = ${e[1]}," "end_day = ${e[2]}," \
        "end_hour = ${e[3]}," "end_minute = ${e[4]}," "end_second = ${e[5]}," "$@"
}
d="$(dir dates)"; dates "${d}" 2019 11 26 18 00 00  2019 11 27 00 00 00 'run_hours = 0,'
check "run_* at 0: the length is the end date minus the start date" "${d}" "simulated_minutes=360"
d="$(dir dates-unset)"; dates "${d}" 2019 12 31 18 00 00  2020 01 01 06 00 00
check "run_* unset: the dates, across a new year" "${d}" "simulated_minutes=720"
d="$(dir dates-leap)"; dates "${d}" 2020 02 28 00 00 00  2020 03 01 00 00 30
check "the dates, across a leap day, with seconds" "${d}" "simulated_minutes=2880.500"
d="$(dir dates-century)"; dates "${d}" 2100 02 28 00 00 00  2100 03 01 00 00 00
check "the dates, across the end of February of 2100 (no leap day)" "${d}" "simulated_minutes=1440"
d="$(dir dates-back)"; dates "${d}" 2019 11 27 00 00 00  2019 11 26 18 00 00
check "an end date before the start date: no length" "${d}" ""
d="$(dir dates-bad)"; dates "${d}" 2019 13 26 18 00 00  2019 11 27 00 00 00
check "a month that does not exist: no length" "${d}" ""
d="$(dir dates-short)"
nl "${d}" 'start_year = 2019,' 'start_month = 11,' 'start_day = 26,' 'start_hour = 18,' \
    'end_year = 2019,' 'end_month = 11,' 'end_day = 27,' 'end_hour = 0,' 'end_minute = 0,' 'end_second = 0,'
check "a date with keys unset (WRF's defaults are not guessed): no length" "${d}" ""

d="$(dir run-bad)"
nl "${d}" 'run_days = 0,' 'run_hours = six,'
check "run_hours not a number: no length, not the dates either" "${d}" ""
d="$(dir run-two)"
nl "${d}" 'run_hours = 6,' 'run_hours = 12,'
check "run_hours on two lines: no length" "${d}" ""

echo "== how the namelist is read =="

d="$(dir forms)"
nl "${d}" 'E_WE = 2*1501,' 'e_sn = 1201 1201' 'e_vert = 50, ! levels' 'RUN_HOURS=6' 'io_form_history = 11/'
check "capitals, a repeat count, values apart by a blank, a comment, no blanks, a slash" "${d}" \
"num_cells_million=90.135
simulated_minutes=360
io_form=11"
# In a Turkish locale awk lowercases I to a dotless ı, so RUN_MINUTES and
# IO_FORM_HISTORY in capitals are read there only because the library runs awk
# in the C locale.
if locale -a 2>/dev/null | grep -qiE '^tr_TR\.utf-?8$'; then
    d="$(dir turkish)"
    nl "${d}" 'E_WE = 1501,' 'E_SN = 1201,' 'E_VERT = 50,' 'RUN_MINUTES = 90,' 'IO_FORM_HISTORY = 11,'
    got="$(export LC_ALL=tr_TR.UTF-8; wrf_run_info "${d}")"; rc=$?
    want=$'num_cells_million=90.135\nsimulated_minutes=90\nio_form=11'
    [ "${rc}" -eq 0 ] && [ "${got}" = "${want}" ] \
        && ok "keys in capitals, under LC_ALL=tr_TR.UTF-8: RUN_MINUTES and IO_FORM_HISTORY are read" \
        || bad "keys in capitals under LC_ALL=tr_TR.UTF-8" "status 0, output: ${want//$'\n'/ | }" "status ${rc}, output: ${got//$'\n'/ | }"
else
    printf '  \033[33mSKIP\033[0m %s (%s)\n' "keys in capitals under LC_ALL=tr_TR.UTF-8" "the locale is not installed"
fi

d="$(dir unread)"
nl "${d}" 'e_we = 1501, e_sn = 1201,' 'e_vert(1) = 50,' 'run_hours =' ' 6,' 'io_form_history = 3* 11,'
check "a key after another on a line, a subscript, a value on the next line, a null value: none read" "${d}" ""

d="$(dir after-another)"
nl "${d}" 'e_we = 1501,' 'e_vert = 50,' 'run_hours = 1, e_sn = 1201,'
check "the key that starts a line is read (run_hours), not one after it (e_sn): no cell count" "${d}" "simulated_minutes=60"

d="$(dir twice)"
nl "${d}" 'e_we = 1501,' 'e_sn = 1201,' 'e_vert = 50,' 'e_vert = 35,' 'io_form_history = 2,'
check "e_vert on two lines: no cell count; the rest is read" "${d}" "io_form=2"

d="$(dir commented)"
nl "${d}" '! e_vert = 35,' 'e_we = 1501,' 'e_sn = 1201,' 'e_vert = 50,'
check "a commented-out line is not read" "${d}" "num_cells_million=90.135"

d="$(dir zero)"
nl "${d}" 'e_we = 1501,' 'e_sn = 0,' 'e_vert = 50,'
check "a grid with a 0 dimension: no cell count" "${d}" ""

d="$(dir lookalike)"
nl "${d}" 's_we = 1,' 'e_we_x = 1501,' 'max_e_vert = 50,' 'io_form_history_x = 11,'
check "keys whose names only contain the ones read: nothing read" "${d}" ""

echo "== the steps =="

d="$(dir domains)"
{ cat "${FIX}/hourly-history.rsl"
  echo 'Timing for main: time 2000-01-01_00:05:00 on domain   2:    0.50000 elapsed seconds'; } > "${d}/rsl.error.0000"
check "steps of domain 2 are not counted" "${d}" "num_timesteps=12"

d="$(dir no-steps "${FIX}/no-steps.rsl")"
check "a log with no step: no step count" "${d}" ""

echo "== missing files, and the caller's contract =="

d="$(dir only-rsl "${FIX}/restart-write.rsl")"
check "no namelist.input: the step count only" "${d}" "num_timesteps=8"
d="$(dir only-nl)"; nl "${d}" 'run_hours = 6,'
check "no rsl.error.0000: the namelist's values only" "${d}" "simulated_minutes=360"
check "no such run directory: nothing, status 0" "${WORK}/absent" ""
check "no argument: nothing, status 0" "" ""
if [ "$(id -u)" -eq 0 ]; then
    printf '  \033[33mSKIP\033[0m %s (%s)\n' "an unreadable namelist.input gives nothing" "running as root; permissions do not apply"
else
    d="$(dir unreadable)"; nl "${d}" 'run_hours = 6,'; chmod 000 "${d}/namelist.input"
    check "an unreadable namelist.input: nothing read from it" "${d}" ""
    chmod 600 "${d}/namelist.input"
fi

got="$(bash -c 'set -euo pipefail; . "$1"; wrf_run_info "$2"; wrf_run_info "$3"; echo reached-the-end' \
    _ "${LIB}" "${WORK}/only-nl" "${WORK}/absent" 2>&1)"; rc=$?
want="simulated_minutes=360
reached-the-end"
[ "${rc}" -eq 0 ] && [ "${got}" = "${want}" ] \
    && ok "under set -euo pipefail it prints what it read and the caller carries on" \
    || bad "set -euo pipefail caller carries on" "rc=0 and: ${want//$'\n'/ | }" "rc=${rc} and: ${got//$'\n'/ | }"

before="$(bash -c 'set -euo pipefail; set -o; shopt' 2>&1)"
after="$(bash -c 'set -euo pipefail; . "$1"; set -o; shopt' _ "${LIB}" 2>&1)"
[ "${before}" = "${after}" ] && ok "sourcing the library changes no shell option" \
    || bad "sourcing the library changes no shell option" "same set -o / shopt" "$(diff <(echo "${before}") <(echo "${after}") | head -3)"
defined="$(bash -c 'before=$(declare -F); . "$1"; diff <(echo "$before") <(declare -F) | sed -n "s/^> declare -f //p" | tr "\n" " "' _ "${LIB}")"
[ "${defined}" = "wrf_run_info " ] && ok "sourcing the library defines wrf_run_info and nothing else" \
    || bad "the library defines only wrf_run_info" "wrf_run_info" "${defined}"
leaked="$(bash -c 'before=$(compgen -v | sort); . "$1"; wrf_run_info "$2" > /dev/null; comm -13 <(echo "$before") <(compgen -v | sort) | grep -E "^[a-z][a-z0-9_]*$" | grep -vx "before" | tr "\n" " "' _ "${LIB}" "${WORK}/conus25")"
[ -z "${leaked}" ] && ok "a call leaves no variable behind" || bad "a call leaves no variable behind" "none" "${leaked}"

echo
printf 'run-info tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
