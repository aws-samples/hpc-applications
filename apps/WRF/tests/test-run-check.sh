#!/bin/bash
# =============================================================================
# Tests for lib/wrf-run-check.sh: did a run complete and write its output?
# =============================================================================
# Needs no Slurm, no EC2, no WRF, no MPI and no AWS credentials. Every case is
# a run directory the test writes itself (synthetic times only).
#
#   ./tests/test-run-check.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib/wrf-run-check.sh"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

if [ ! -r "${LIB}" ]; then
    bad "the run-check library exists" "${LIB}" "missing"
    printf 'run-check tests: %d passed, %d failed\n' "${pass}" "${fail}"
    exit 1
fi
# shellcheck source=../lib/wrf-run-check.sh
. "${LIB}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# run <name> <event>... writes the run directory ${WORK}/<name> with an
# rsl.error.0000 of these events, and prints its path. A number is a step
# taking that many seconds; Hhh:mm a history write (domain 1) at that time of
# the synthetic day; Uhh:mm the same as WRF logs it with nocolons = .true. (an
# '_' for each ':'); G the same for domain 2; R a restart write (domain 1); Q a
# restart write of domain 2; S the closing "SUCCESS COMPLETE WRF" line.
run() {
    local d="${WORK}/$1" e n=0; shift
    mkdir -p "${d}"
    for e in "$@"; do
        case "${e}" in
            H*) echo "Timing for Writing wrfout_d01_2000-01-01_${e#H}:00 for domain        1:    3.00000 elapsed seconds" ;;
            U*) echo "Timing for Writing $(hu "${e#U}") for domain        1:    3.00000 elapsed seconds" ;;
            G*) echo "Timing for Writing wrfout_d02_2000-01-01_${e#G}:00 for domain        2:    3.00000 elapsed seconds" ;;
            R)  echo 'Timing for Writing restart for domain        1:    4.00000 elapsed seconds' ;;
            Q)  echo 'Timing for Writing restart for domain        2:    4.00000 elapsed seconds' ;;
            S)  echo 'd01 2000-01-01_06:00:00 wrf: SUCCESS COMPLETE WRF' ;;
            *)  n=$((n+1))
                printf 'Timing for main: time 2000-01-01_00:%02d:00 on domain   1: %10s elapsed seconds\n' "${n}" "${e}" ;;
        esac
    done > "${d}/rsl.error.0000"
    printf '%s\n' "${d}"
}
# namelist <dir> [lines]: a namelist.input, with those &time_control lines if given.
namelist() {
    { echo ' &time_control'; echo ' run_hours = 6,'; [ -n "${2:-}" ] && echo " $2"; echo ' /'; } > "$1/namelist.input"
}
# out <dir> <file>...: non-empty output files.
out() { local d="$1" f; shift; for f in "$@"; do echo "stub output" > "${d}/${f}"; done; }
# h <hh:mm>: the history file a write at that time names in the log; hu <hh:mm>:
# the same with an '_' for each ':', as PnetCDF, or nocolons = .true., writes it.
h() { echo "wrfout_d01_2000-01-01_$1:00"; }
hu() { local n; n="$(h "$1")"; echo "${n//:/_}"; }

# check <label> <dir> <expected status> [expected output]: the output is
# compared line for line (exactly) when given, and must be empty on a pass.
check() {
    local label="$1" d="$2" want_rc="$3" want="${4:-}" got rc
    got="$(wrf_run_check "${d}")"; rc=$?
    if [ "${rc}" -eq "${want_rc}" ] && [ "${got}" = "${want}" ]; then ok "${label}"
    else bad "${label}" "status ${want_rc}, output: ${want//$'\n'/ | }" "status ${rc}, output: ${got//$'\n'/ | }"; fi
}

echo "== a run that completed and wrote its output =="

d="$(run complete 4.0 H00:00 1.0 1.0 H01:00 1.0 R 1.0 H02:00 S)"
namelist "${d}" 'frames_per_outfile = 1,'
out "${d}" "$(h 00:00)" "$(h 01:00)" "$(h 02:00)" wrfrst_d01_2000-01-01_01:30:00
check "SUCCESS COMPLETE WRF, every history file and the restart file: passes, silently" "${d}" 0

d="$(run no-output 4.0 1.0 1.0 S)"
check "a run that writes no output passes on its log alone, without a namelist" "${d}" 0

echo "== rsl.error.0000 =="

d="$(run no-success 4.0 H00:00 1.0 1.0)"
namelist "${d}" 'frames_per_outfile = 1,'
out "${d}" "$(h 00:00)"
check "no SUCCESS COMPLETE WRF: refused" "${d}" 1 "rsl.error.0000 does not say SUCCESS COMPLETE WRF"

mkdir -p "${WORK}/no-rsl"
check "no rsl.error.0000: refused" "${WORK}/no-rsl" 1 "no readable rsl.error.0000"
mkdir -p "${WORK}/rsl-is-a-dir/rsl.error.0000"
check "rsl.error.0000 is a directory: refused" "${WORK}/rsl-is-a-dir" 1 "no readable rsl.error.0000"
check "no such run directory: refused" "${WORK}/absent" 1 "no run directory '${WORK}/absent'"
check "no argument: refused" "" 1 "no run directory ''"
if [ "$(id -u)" -eq 0 ]; then
    printf '  \033[33mSKIP\033[0m %s (%s)\n' "an unreadable rsl.error.0000 is refused" "running as root; permissions do not apply"
else
    d="$(run unreadable 4.0 1.0 S)"; chmod 000 "${d}/rsl.error.0000"
    check "an unreadable rsl.error.0000: refused" "${d}" 1 "no readable rsl.error.0000"
    chmod 600 "${d}/rsl.error.0000"
fi

echo "== history files =="

d="$(run history-missing 4.0 H00:00 1.0 H01:00 1.0 H02:00 S)"
namelist "${d}" 'frames_per_outfile = 1,'
out "${d}" "$(h 00:00)" "$(h 02:00)"
check "a history file WRF wrote is missing: refused, naming it" "${d}" 1 "history file $(h 01:00) is missing"

d="$(run history-empty 4.0 H00:00 1.0 H01:00 S)"
namelist "${d}" 'frames_per_outfile = 1,'
out "${d}" "$(h 00:00)"; : > "${d}/$(h 01:00)"
check "an empty history file: refused, naming it" "${d}" 1 "history file $(h 01:00) is empty"

d="$(run history-dir 4.0 H00:00 S)"
namelist "${d}" 'frames_per_outfile = 1,'
mkdir -p "${d}/$(h 00:00)"
check "a directory in place of a history file: refused as missing" "${d}" 1 "history file $(h 00:00) is missing"

# frames_per_outfile writes go in each file, named after the first of them:
# 12 writes in files of 10 frames (WRF's default, when the namelist does not
# set it) are 2 files, named after the 1st and the 11th write.
writes=(); for i in 00 01 02 03 04 05 06 07 08 09 10 11; do writes+=("H${i}:00" 1.0); done
d="$(run default-frames 4.0 "${writes[@]}" S)"
namelist "${d}"
out "${d}" "$(h 00:00)" "$(h 10:00)"
check "no frames_per_outfile: 10 per file (WRF's default), so 2 files for 12 writes" "${d}" 0
rm -f "${d}/$(h 10:00)"
check "no frames_per_outfile: the 11th write's file is the second file" "${d}" 1 "history file $(h 10:00) is missing"

d="$(run three-frames 4.0 H00:00 H01:00 H02:00 H03:00 H04:00 H05:00 H06:00 S)"
namelist "${d}" 'frames_per_outfile = 3, 3, 3,'
out "${d}" "$(h 00:00)" "$(h 06:00)"
check "frames_per_outfile = 3: the 1st, 4th and 7th writes name the files" "${d}" 1 "history file $(h 03:00) is missing"
out "${d}" "$(h 03:00)"
check "frames_per_outfile = 3: with those three files, passes" "${d}" 0

# Three writes in files of 2 frames are 2 files, named after the 1st and the
# 3rd write. With only the 1st file in place, the check names the 3rd write's
# file and nothing else: the default of 10 (a key not read) would expect the
# 1st file alone and pass, and domain 2's value of 1 would also name the 2nd.
d="$(run frames-case 4.0 H00:00 H01:00 H02:00 S)"
namelist "${d}" 'FRAMES_PER_OUTFILE= 2 ,1, ! two frames per file'
out "${d}" "$(h 00:00)"
check "FRAMES_PER_OUTFILE in capitals, a value per domain: domain 1's (2) is read, so the 3rd write's file is missing" "${d}" 1 "history file $(h 02:00) is missing"
out "${d}" "$(h 02:00)"
check "FRAMES_PER_OUTFILE in capitals: with the 1st and the 3rd write's files, passes" "${d}" 0
# In a Turkish locale awk lowercases I to a dotless ı, so the key in capitals is
# read there only because the check runs awk in the C locale.
if locale -a 2>/dev/null | grep -qiE '^tr_TR\.utf-?8$'; then
    d="$(run frames-turkish 4.0 H00:00 H01:00 H02:00 S)"
    namelist "${d}" 'FRAMES_PER_OUTFILE = 2,'
    out "${d}" "$(h 00:00)"
    got="$(export LC_ALL=tr_TR.UTF-8; wrf_run_check "${d}")"; rc=$?
    want="history file $(h 02:00) is missing"
    [ "${rc}" -eq 1 ] && [ "${got}" = "${want}" ] \
        && ok "FRAMES_PER_OUTFILE in capitals, under LC_ALL=tr_TR.UTF-8: 2 is read, so the 3rd write's file is missing" \
        || bad "FRAMES_PER_OUTFILE under LC_ALL=tr_TR.UTF-8" "status 1, output: ${want}" "status ${rc}, output: ${got//$'\n'/ | }"
else
    printf '  \033[33mSKIP\033[0m %s (%s)\n' "FRAMES_PER_OUTFILE in capitals under LC_ALL=tr_TR.UTF-8" "the locale is not installed"
fi

d="$(run frames-comment 4.0 H00:00 H01:00 H02:00 S)"
namelist "${d}" 'frames_per_outfile = 2 ! two frames per file'
out "${d}" "$(h 00:00)"
check "frames_per_outfile with a comment right after the value: 2 is read, so the 3rd write's file is missing" "${d}" 1 "history file $(h 02:00) is missing"
out "${d}" "$(h 02:00)"
check "frames_per_outfile with a comment right after the value: with the 1st and the 3rd write's files, passes" "${d}" 0

# Three writes in files of 1 frame are 3 files. With only the 1st in place, a
# check that reads 1 names the other two; one that took the key as unset would
# expect files of 10 frames, the 1st file alone, and pass.
d="$(run frames-repeat 4.0 H00:00 H01:00 H02:00 S)"
namelist "${d}" 'frames_per_outfile = 3*1,'
out "${d}" "$(h 00:00)"
check "frames_per_outfile = 3*1 (a repeat count): 1 is read, so the 2nd and the 3rd write's files are missing" "${d}" 1 "history file $(h 01:00) is missing
history file $(h 02:00) is missing"
out "${d}" "$(h 01:00)" "$(h 02:00)"
check "frames_per_outfile = 3*1: with every write's file, passes" "${d}" 0

d="$(run frames-blanks 4.0 H00:00 H01:00 H02:00 S)"
namelist "${d}" 'frames_per_outfile = 2 1'
out "${d}" "$(h 00:00)"
check "frames_per_outfile = 2 1 (values apart by a blank): domain 1's 2 is read, so the 3rd write's file is missing" "${d}" 1 "history file $(h 02:00) is missing"

d="$(run frames-commented 4.0 H00:00 H01:00 H02:00 S)"
namelist "${d}" $'! frames_per_outfile = 5,\n frames_per_outfile = 1,'
out "${d}" "$(h 00:00)"
check "a commented-out frames_per_outfile line is not read: the other line's 1 is" "${d}" 1 "history file $(h 01:00) is missing
history file $(h 02:00) is missing"

# A line that names the key in any other form is refused, never read as unset.
d="$(run frames-forms 4.0 H00:00 H01:00 H02:00 S)"
out "${d}" "$(h 00:00)"
for form in 'history_interval = 60, frames_per_outfile = 1,' 'frames_per_outfile(1) = 1,' 'frames_per_outfile = 3* 1,'; do
    namelist "${d}" "${form}"
    check "'${form}': refused, not read with WRF's default" "${d}" 1 "cannot read frames_per_outfile from namelist.input ('${form}')"
done
namelist "${d}" $'frames_per_outfile =\n 1,'
check "frames_per_outfile with its value on the next line: refused, not read with WRF's default" "${d}" 1 "cannot read frames_per_outfile from namelist.input ('frames_per_outfile =')"
namelist "${d}" $'frames_per_outfile = 1,\n frames_per_outfile = 2,'
check "frames_per_outfile on two lines: refused" "${d}" 1 "cannot read frames_per_outfile from namelist.input (set on 2 lines)"

d="$(run frames-bad 4.0 H00:00 S)"
namelist "${d}" 'frames_per_outfile = 0,'
out "${d}" "$(h 00:00)"
check "frames_per_outfile = 0: refused" "${d}" 1 "cannot read frames_per_outfile from namelist.input ('frames_per_outfile = 0,')"
namelist "${d}" "frames_per_outfile = two,"
check "frames_per_outfile not a number: refused" "${d}" 1 "cannot read frames_per_outfile from namelist.input ('frames_per_outfile = two,')"

d="$(run no-namelist 4.0 H00:00 1.0 S)"
out "${d}" "$(h 00:00)"
check "history writes but no namelist.input: refused" "${d}" 1 "no namelist.input to tell which history files WRF wrote"

d="$(run domain-2 4.0 H00:00 G00:00 1.0 S)"
namelist "${d}" 'frames_per_outfile = 1,'
out "${d}" "$(h 00:00)"
check "domain 2's history writes are not checked" "${d}" 0

echo "== history file names: io_form_history and nocolons =="

# The log names each history file as WRF made the name. Serial netCDF
# (io_form_history = 2, WRF's default) writes it under that name, PnetCDF (11)
# with an '_' for each ':' in it; with nocolons = .true. the name has an '_'
# for each ':' already, in the log too.
d="$(run pnetcdf 4.0 H00:00 1.0 H01:00 1.0 R 1.0 H02:00 S)"
namelist "${d}" $'frames_per_outfile = 1,\n io_form_history = 11,'
out "${d}" "$(hu 00:00)" "$(hu 01:00)" "$(hu 02:00)" wrfrst_d01_2000-01-01_01_30_00
check "PnetCDF (io_form_history = 11): the log's names with an '_' for each ':' are the files: passes" "${d}" 0
rm -f "${d}/$(hu 01:00)"; out "${d}" "$(h 01:00)"
check "PnetCDF: a file under the log's name, colons kept, counts as missing" "${d}" 1 "history file $(hu 01:00) is missing"
: > "${d}/$(hu 01:00)"
check "PnetCDF: an empty file under the PnetCDF name: refused, naming it" "${d}" 1 "history file $(hu 01:00) is empty"

d="$(run pnetcdf-colons 4.0 H00:00 1.0 H01:00 S)"
namelist "${d}" $'frames_per_outfile = 1,\n io_form_history = 11,'
out "${d}" "$(h 00:00)" "$(h 01:00)"
check "PnetCDF, every file under the log's names, colons kept: refused, naming the PnetCDF names" "${d}" 1 \
    "history file $(hu 00:00) is missing
history file $(hu 01:00) is missing"

d="$(run pnetcdf-frames 4.0 H00:00 H01:00 H02:00 S)"
namelist "${d}" $'frames_per_outfile = 2,\n io_form_history = 11,'
out "${d}" "$(hu 00:00)"
check "PnetCDF, 2 frames per file: the 3rd write's file, under its PnetCDF name, is missing" "${d}" 1 "history file $(hu 02:00) is missing"
out "${d}" "$(hu 02:00)"
check "PnetCDF, 2 frames per file: with the 1st and the 3rd write's files, passes" "${d}" 0

d="$(run serial 4.0 H00:00 1.0 H01:00 S)"
namelist "${d}" $'frames_per_outfile = 1,\n io_form_history = 2,'
out "${d}" "$(h 00:00)" "$(h 01:00)"
check "serial netCDF (io_form_history = 2): the log's names, colons kept, are the files: passes" "${d}" 0
rm -f "${d}/$(h 01:00)"; out "${d}" "$(hu 01:00)"
check "serial netCDF: a file with an '_' for each ':' counts as missing" "${d}" 1 "history file $(h 01:00) is missing"
namelist "${d}" 'frames_per_outfile = 1,'
check "io_form_history unset (WRF's default, serial netCDF): the same" "${d}" 1 "history file $(h 01:00) is missing"

for io in 2 11; do
    d="$(run "nocolons-${io}" 4.0 U00:00 1.0 U01:00 S)"
    namelist "${d}" $'frames_per_outfile = 1,\n io_form_history = '"${io}"$',\n nocolons = .true.,'
    out "${d}" "$(hu 00:00)" "$(hu 01:00)"
    check "nocolons = .true., io_form_history = ${io}: the log's names already have an '_' for each ':', and so do the files: passes" "${d}" 0
done
# nocolons is not read: the log gives the name WRF made, which it reflects. A
# log that gives colons under nocolons = .true. is not one WRF run's, and its
# names are looked for as it gives them.
d="$(run nocolons-colons 4.0 H00:00 S)"
namelist "${d}" $'frames_per_outfile = 1,\n nocolons = .true.,'
out "${d}" "$(hu 00:00)"
check "nocolons = .true. but a log that gives colons, serial netCDF: the log's name is looked for, and is missing" "${d}" 1 \
    "history file $(h 00:00) is missing"

# io_form_history is read as frames_per_outfile is: from the one line that
# starts with it, in any case; any other form is refused, never taken for WRF's
# default.
d="$(run io-forms 4.0 H00:00 S)"
out "${d}" "$(hu 00:00)"
for form in 'IO_FORM_HISTORY = 11' 'io_form_history = 11 ! PnetCDF' 'io_form_history=011,'; do
    namelist "${d}" $'frames_per_outfile = 1,\n '"${form}"
    check "'${form}': 11 is read, so the file has an '_' for each ':': passes" "${d}" 0
done
for form in 'io_form_restart = 11, io_form_history = 11,' 'io_form_history(1) = 11,' 'io_form_history = 0,' \
            'io_form_history = pnetcdf,'; do
    namelist "${d}" $'frames_per_outfile = 1,\n '"${form}"
    check "'${form}': refused, not read with WRF's default" "${d}" 1 "cannot read io_form_history from namelist.input ('${form}')"
done
namelist "${d}" $'frames_per_outfile = 1,\n io_form_history =\n 11,'
check "io_form_history with its value on the next line: refused" "${d}" 1 "cannot read io_form_history from namelist.input ('io_form_history =')"
namelist "${d}" $'frames_per_outfile = 1,\n io_form_history = 11,\n io_form_history = 2,'
check "io_form_history on two lines: refused" "${d}" 1 "cannot read io_form_history from namelist.input (set on 2 lines)"
namelist "${d}" $'frames_per_outfile = 0,\n io_form_history = pnetcdf,'
check "neither key readable: both named, frames_per_outfile first" "${d}" 1 \
    "cannot read frames_per_outfile from namelist.input ('frames_per_outfile = 0,')
cannot read io_form_history from namelist.input ('io_form_history = pnetcdf,')"
if locale -a 2>/dev/null | grep -qiE '^tr_TR\.utf-?8$'; then
    namelist "${d}" $'frames_per_outfile = 1,\n IO_FORM_HISTORY = 11,'
    got="$(LC_ALL=tr_TR.UTF-8 wrf_run_check "${d}")"; rc=$?
    if [ "${rc}" -eq 0 ] && [ -z "${got}" ]; then
        ok "IO_FORM_HISTORY in capitals, under LC_ALL=tr_TR.UTF-8: 11 is read, so the file has an '_' for each ':'"
    else
        bad "IO_FORM_HISTORY under LC_ALL=tr_TR.UTF-8" "status 0, no output" "status ${rc}, output: ${got//$'\n'/ | }"
    fi
else
    printf '  \033[33mSKIP\033[0m %s (%s)\n' "IO_FORM_HISTORY in capitals under LC_ALL=tr_TR.UTF-8" "the locale is not installed"
fi

echo "== restart files =="

d="$(run restart-missing 4.0 R 1.0 R 1.0 S)"
out "${d}" wrfrst_d01_2000-01-01_01:00:00
check "2 restart writes, 1 restart file: refused" "${d}" 1 "2 restart write(s) in rsl.error.0000 but 1 wrfrst_d01_* file(s)"
out "${d}" wrfrst_d01_2000-01-01_02:00:00
check "2 restart writes, 2 restart files: passes" "${d}" 0
out "${d}" wrfrst_d01_2000-01-01_00:00:00
check "an extra restart file (a run's input restart, say) changes nothing" "${d}" 0
: > "${d}/wrfrst_d01_2000-01-01_02:00:00"
check "an empty restart file: refused, naming it" "${d}" 1 "restart file wrfrst_d01_2000-01-01_02:00:00 is empty"

d="$(run restart-domain-2 4.0 Q 1.0 S)"
check "domain 2's restart writes are not counted" "${d}" 0

echo "== several problems, and the caller's contract =="

d="$(run several 4.0 H00:00 R 1.0)"
namelist "${d}" 'frames_per_outfile = 1,'
check "every problem is listed, one per line" "${d}" 1 "rsl.error.0000 does not say SUCCESS COMPLETE WRF
history file $(h 00:00) is missing
1 restart write(s) in rsl.error.0000 but 0 wrfrst_d01_* file(s)"

got="$(bash -c 'set -euo pipefail; . "$1"
    for d in "$2" "$3"; do if out=$(wrf_run_check "$d"); then echo "pass"; else echo "refused: $out"; fi; done
    echo reached-the-end' _ "${LIB}" "${WORK}/complete" "${WORK}/no-success" 2>&1)"; rc=$?
want="pass
refused: rsl.error.0000 does not say SUCCESS COMPLETE WRF
reached-the-end"
[ "${rc}" -eq 0 ] && [ "${got}" = "${want}" ] \
    && ok "under set -euo pipefail, called in an if: one verdict each, and the caller carries on" \
    || bad "set -euo pipefail caller carries on" "rc=0 and: ${want//$'\n'/ | }" "rc=${rc} and: ${got//$'\n'/ | }"

before="$(bash -c 'set -euo pipefail; set -o; shopt' 2>&1)"
after="$(bash -c 'set -euo pipefail; . "$1"; set -o; shopt' _ "${LIB}" 2>&1)"
[ "${before}" = "${after}" ] && ok "sourcing the library changes no shell option" \
    || bad "sourcing the library changes no shell option" "same set -o / shopt" "$(diff <(echo "${before}") <(echo "${after}") | head -3)"
defined="$(bash -c 'before=$(declare -F); . "$1"; diff <(echo "$before") <(declare -F) | sed -n "s/^> declare -f //p" | tr "\n" " "' _ "${LIB}")"
[ "${defined}" = "wrf_run_check " ] && ok "sourcing the library defines wrf_run_check and nothing else" \
    || bad "the library defines only wrf_run_check" "wrf_run_check" "${defined}"
# (bash's own variables, PIPESTATUS for one, are in capitals; the function's are not)
leaked="$(bash -c 'before=$(compgen -v | sort); . "$1"; wrf_run_check "$2" > /dev/null; comm -13 <(echo "$before") <(compgen -v | sort) | grep -E "^[a-z][a-z0-9_]*$" | grep -vx "before" | tr "\n" " "' _ "${LIB}" "${WORK}/complete")"
[ -z "${leaked}" ] && ok "a call leaves no variable behind" || bad "a call leaves no variable behind" "none" "${leaked}"

echo
printf 'run-check tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
