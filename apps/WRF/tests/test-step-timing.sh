#!/bin/bash
# =============================================================================
# Fixture-driven tests for lib/wrf-step-timing.sh
# =============================================================================
# Needs no Slurm, no EC2, no WRF, no MPI and no AWS credentials.
#
#   ./tests/test-step-timing.sh
#
# Every time in the fixtures is synthetic. The expected values are worked out
# by hand in the comments, so a change of rule shows up as a changed number.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
LIB="${HERE}/../lib/wrf-step-timing.sh"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }

if [ ! -r "${LIB}" ]; then
    bad "the helper library exists" "${LIB}" "missing"
    printf 'step-timing tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
    exit 1
fi
# shellcheck source=../lib/wrf-step-timing.sh
. "${LIB}"

WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

# is <label> <expected> <command...>
is() {
    local label="$1" want="$2" got; shift 2
    got="$("$@")"
    if [ "${got}" = "${want}" ]; then ok "${label}"; else bad "${label}" "${want}" "${got}"; fi
}

# rsl <event>... prints a synthetic rsl.error.0000. A number is a
# "Timing for main" step taking that many seconds (5 decimals, as WRF prints
# them), and A<number> the same step as WRF prints it with an adaptive time
# step ("main (dt= 15.00): ..."); H is a history write, R a restart write, B a
# lateral-boundary read.
rsl() {
    local e n=0
    for e in "$@"; do
        case "${e}" in
            H) echo 'Timing for Writing wrfout_d01_2000-01-01_00:00:00 for domain        1:    3.00000 elapsed seconds' ;;
            R) echo 'Timing for Writing restart for domain        1:    4.00000 elapsed seconds' ;;
            B) echo 'Timing for processing lateral boundary for domain        1:    0.50000 elapsed seconds' ;;
            A*) n=$((n+1))
                printf 'Timing for main (dt= 15.00): time 2000-01-01_00:%02d:00 on domain   1: %10s elapsed seconds\n' "${n}" "${e#A}" ;;
            *) n=$((n+1))
               printf 'Timing for main: time 2000-01-01_00:%02d:00 on domain   1: %10s elapsed seconds\n' "${n}" "${e}" ;;
        esac
    done
}

echo "== the four fixtures =="

# Steps 8.7 1.0 1.2 1.1 | 4.1 1.0 1.3 1.1 | 4.2 1.1 1.2 1.0, a history write
# before the first step of every hour and one after the last step.
#   median: the 6th and 7th of the 12 sorted steps, (1.1 + 1.2) / 2
#   steady: without step 1 (8.7) and the two after an hourly write (4.1, 4.2),
#           10.0 / 9; the write after the last step changes nothing
is "hourly history: median of all 12 steps" "1.15000" \
    wrf_median_step "${FIX}/hourly-history.rsl"
is "hourly history: steady step leaves out step 1 and the steps after a write" "1.11111" \
    wrf_steady_step "${FIX}/hourly-history.rsl"

# Steps 7.0 2.0 | R | 6.0 2.2 | H R | 9.0 1.8 2.0 2.0
#   median: 8 steps, (2.0 + 2.2) / 2
#   steady: without 7.0 (step 1), 6.0 (after a restart write alone) and 9.0
#           (after a history and a restart write): 10.0 / 5. Two writes before
#           one step leave out that step only, so 1.8 counts.
is "restart write: median of an even number of steps" "2.10000" \
    wrf_median_step "${FIX}/restart-write.rsl"
is "restart write: a restart alone, or with a history write, leaves out one step" "2.00000" \
    wrf_steady_step "${FIX}/restart-write.rsl"

# Steps 5.0 3.0 3.1 | B | 3.9 2.9 3.0
#   median: (3.0 + 3.1) / 2;  steady: without 5.0 and 3.9, 12.0 / 4
is "lateral boundary: median" "3.05000" \
    wrf_median_step "${FIX}/lateral-boundary.rsl"
is "lateral boundary: the step after a lateral-boundary read is left out" "3.00000" \
    wrf_steady_step "${FIX}/lateral-boundary.rsl"

is "missing file: median is N/A" "N/A" wrf_median_step "${WORK}/rsl.error.0000"
is "missing file: steady step is N/A" "N/A" wrf_steady_step "${WORK}/rsl.error.0000"
is "no step lines: median is N/A" "N/A" wrf_median_step "${FIX}/no-steps.rsl"
is "no step lines: steady step is N/A" "N/A" wrf_steady_step "${FIX}/no-steps.rsl"

echo "== edge cases =="

rsl 4.00000 > "${WORK}/one-step"
is "one step: the median is that step" "4.00000" wrf_median_step "${WORK}/one-step"
is "one step: no steady step is left" "N/A" wrf_steady_step "${WORK}/one-step"

rsl 9.00000 H 4.00000 R 5.00000 B 6.00000 > "${WORK}/all-io"
is "every step after the first follows I/O: no steady step" "N/A" wrf_steady_step "${WORK}/all-io"
is "every step after the first follows I/O: the median still counts them" "5.50000" \
    wrf_median_step "${WORK}/all-io"

rsl 10.00000 9.00000 2.00000 > "${WORK}/numeric"
is "steps are sorted as numbers (a text sort would pick 2.00000)" "9.00000" \
    wrf_median_step "${WORK}/numeric"

# With an adaptive time step WRF labels each step "main (dt= 15.00)", which
# moves its time from the 9th field (where AVG_STEP reads it) to the 11th; it
# is still the number before "elapsed seconds". Steps 8.0 2.0 4.0:
#   median: 4.0;  steady: without step 1 (8.0), (2.0 + 4.0) / 2
rsl A8.00000 A2.00000 A4.00000 > "${WORK}/adaptive-dt"
is "adaptive time step: the median takes the time before 'elapsed seconds', not field 9" "4.00000" \
    wrf_median_step "${WORK}/adaptive-dt"
is "adaptive time step: the steady step takes the time before 'elapsed seconds', not field 9" "3.00000" \
    wrf_steady_step "${WORK}/adaptive-dt"

: > "${WORK}/empty"
is "empty file: median is N/A" "N/A" wrf_median_step "${WORK}/empty"
is "empty file: steady step is N/A" "N/A" wrf_steady_step "${WORK}/empty"
is "no argument: median is N/A" "N/A" wrf_median_step
is "no argument: steady step is N/A" "N/A" wrf_steady_step
mkdir -p "${WORK}/a-directory"
is "a directory: median is N/A" "N/A" wrf_median_step "${WORK}/a-directory"
is "a directory: steady step is N/A" "N/A" wrf_steady_step "${WORK}/a-directory"

if [ "$(id -u)" -eq 0 ]; then
    skipt "unreadable file gives N/A" "running as root; permissions do not apply"
else
    cp "${FIX}/hourly-history.rsl" "${WORK}/unreadable"; chmod 000 "${WORK}/unreadable"
    is "unreadable file: median is N/A" "N/A" wrf_median_step "${WORK}/unreadable"
    is "unreadable file: steady step is N/A" "N/A" wrf_steady_step "${WORK}/unreadable"
fi

# A locale whose decimal separator is a comma must not change the numbers.
# POSIXLY_CORRECT makes gawk read and print numbers in that locale, which
# turns 1.15000 into 1,00000 unless the helper runs awk in the C locale.
comma_locale=""
for l in de_DE.UTF-8 de_DE.utf8 fr_FR.UTF-8 fr_FR.utf8 it_IT.UTF-8 it_IT.utf8; do
    if [ "$(LC_ALL="${l}" locale decimal_point 2>/dev/null)" = "," ]; then comma_locale="${l}"; break; fi
done
if [ -z "${comma_locale}" ]; then
    skipt "a comma-decimal locale changes nothing" "no such locale installed"
else
    got="$(LC_ALL="${comma_locale}" POSIXLY_CORRECT=1 bash -c '. "$1"; wrf_median_step "$2"; wrf_steady_step "$2"' \
           _ "${LIB}" "${FIX}/hourly-history.rsl" | tr '\n' ' ')"
    [ "${got}" = "1.15000 1.11111 " ] && ok "${comma_locale} with POSIXLY_CORRECT: same median and steady step" \
        || bad "${comma_locale} with POSIXLY_CORRECT: same median and steady step" "1.15000 1.11111" "${got}"
fi

echo "== a caller under set -euo pipefail is never stopped =="

out="$(bash -c 'set -euo pipefail; . "$1"
    for f in "$2" "$3" "$4"; do m=$(wrf_median_step "$f"); s=$(wrf_steady_step "$f"); echo "$m $s"; done
    echo reached-the-end' _ "${LIB}" "${WORK}/missing" "${FIX}/no-steps.rsl" "${FIX}/hourly-history.rsl" 2>&1)"
rc=$?
want="N/A N/A
N/A N/A
1.15000 1.11111
reached-the-end"
if [ "${rc}" -eq 0 ] && [ "${out}" = "${want}" ]; then
    ok "missing file, no step lines and a good file: one value each, and the caller carries on"
else
    bad "set -euo pipefail caller carries on" "rc=0 and: ${want//$'\n'/ | }" "rc=${rc} and: ${out//$'\n'/ | }"
fi

before="$(bash -c 'set -euo pipefail; set -o; shopt' 2>&1)"
after="$(bash -c 'set -euo pipefail; . "$1"; set -o; shopt' _ "${LIB}" 2>&1)"
[ "${before}" = "${after}" ] && ok "sourcing the library changes no shell option" \
    || bad "sourcing the library changes no shell option" "same set -o / shopt" "$(diff <(echo "${before}") <(echo "${after}") | head -3)"
defined="$(bash -c 'before=$(declare -F); . "$1"; diff <(echo "$before") <(declare -F) | sed -n "s/^> declare -f //p" | tr "\n" " "' _ "${LIB}")"
[ "${defined}" = "wrf_median_step wrf_steady_step " ] && ok "sourcing the library defines its two functions and nothing else" \
    || bad "the library defines only its two functions" "wrf_median_step wrf_steady_step" "${defined}"

echo
printf 'step-timing tests: %d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" -eq 0 ] || exit 1
