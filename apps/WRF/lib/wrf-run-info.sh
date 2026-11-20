#!/bin/bash
# =============================================================================
# WRF run description: what makes two runs comparable
# =============================================================================
# Sourced by the WRF benchmark scripts (x86/wrf-benchmark*.sbatch and
# Arm/wrf-benchmark.sbatch), which pass what it prints to the recorder
# (dynamodb/record-benchmark.sh), and exercised directly by
# tests/test-run-info.sh (needs neither Slurm nor WRF).
#
#   wrf_run_info <run dir>
#
# prints, one per line as <name>=<value>, what it can read from the run's
# namelist.input and rsl.error.0000:
#   num_cells_million  domain 1's grid, e_we x e_sn x e_vert / 10^6, with 3
#                      decimals (CONUS 2.5km: 1501 x 1201 x 50 = 90.135)
#   simulated_minutes  the forecast's length as wrf.exe takes it: run_days,
#                      run_hours, run_minutes and run_seconds when one of them
#                      is above 0, else domain 1's end_* date minus its start_*
#                      date; a whole number, or 3 decimals
#   io_form            io_form_history: 2 is serial netCDF, 11 PnetCDF
#   num_timesteps      the "Timing for main" lines of domain 1 in rsl.error.0000
#
# A value it cannot read is left out, never guessed. A namelist key is read
# only from a line that starts with it, "<key> = <value>[, <domain 2>, ...]" in
# any case, <value> a whole number (a repeat count, <r>*<value>, reads as
# <value>), and only when one line names the key. A key named anywhere else on
# a line, or on more than one line, is not read, and neither is one the
# namelist leaves to WRF's default, except run_days, run_hours, run_minutes and
# run_seconds, which count as 0 there, as in WRF.
#
# It always returns 0. Sourcing it defines wrf_run_info and changes no shell
# option.
# =============================================================================

# wrf_run_info <run dir>
wrf_run_info() {
    local d="${1:-}"
    if [ -z "${d}" ] || [ ! -d "${d}" ]; then return 0; fi
    if [ -f "${d}/namelist.input" ] && [ -r "${d}/namelist.input" ]; then
        LC_ALL=C awk '
            # Days from 1970-01-01 to a date of the Gregorian calendar.
            function days(y, m, dd,    era, yoe, doy) {
                y -= (m <= 2)
                era = int((y >= 0 ? y : y - 399) / 400)
                yoe = y - era * 400
                doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + dd - 1
                return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468
            }
            # A key read: named on one line only, as "<key> = <whole number>".
            function ok(k) { return (k in seen) && seen[k] == 1 && val[k] != "" }
            # Seconds from 1970 to the date <p>_year ... <p>_second give for domain 1, or -1.
            function stamp(p,    y, mo, dd, h, mi, s) {
                if (!(ok(p "_year") && ok(p "_month") && ok(p "_day") && ok(p "_hour") \
                      && ok(p "_minute") && ok(p "_second"))) return -1
                y = val[p "_year"]; mo = val[p "_month"]; dd = val[p "_day"]
                h = val[p "_hour"]; mi = val[p "_minute"]; s = val[p "_second"]
                if (mo < 1 || mo > 12 || dd < 1 || dd > 31 || h > 23 || mi > 59 || s > 59) return -1
                return days(y, mo, dd) * 86400 + h * 3600 + mi * 60 + s
            }
            BEGIN {
                nk = split("e_we e_sn e_vert run_days run_hours run_minutes run_seconds " \
                           "start_year start_month start_day start_hour start_minute start_second " \
                           "end_year end_month end_day end_hour end_minute end_second " \
                           "io_form_history", key, " ")
            }
            { line = tolower($0); sub(/!.*/, "", line)
              for (i = 1; i <= nk; i++) {
                  k = key[i]
                  if (line !~ ("(^|[^a-z0-9_])" k "([^a-z0-9_]|$)")) continue
                  seen[k]++; val[k] = ""
                  if (match(line, "^[[:space:]]*" k "[[:space:]]*=[[:space:]]*")) {
                      rest = substr(line, RLENGTH + 1)
                      if (rest ~ /^[0-9]+\*[0-9]/) rest = substr(rest, index(rest, "*") + 1)
                      if (rest ~ /^[0-9]+([[:space:],\/]|$)/) {
                          v = rest; sub(/[^0-9].*$/, "", v); val[k] = v + 0 }
                  } } }
            END {
                if (ok("e_we") && ok("e_sn") && ok("e_vert") \
                    && val["e_we"] > 0 && val["e_sn"] > 0 && val["e_vert"] > 0)
                    printf "num_cells_million=%.3f\n", val["e_we"] * val["e_sn"] * val["e_vert"] / 1e6
                # run_* when one of them is above 0 (unset counts as 0), else end - start.
                good = 1; secs = 0
                split("run_days 86400 run_hours 3600 run_minutes 60 run_seconds 1", r, " ")
                for (i = 1; i <= 8; i += 2) {
                    if (!(r[i] in seen)) continue
                    if (!ok(r[i])) { good = 0; break }
                    secs += val[r[i]] * r[i + 1]
                }
                if (good && secs == 0) {
                    a = stamp("start"); b = stamp("end")
                    if (a >= 0 && b > a) secs = b - a
                }
                if (good && secs > 0) {
                    if (secs % 60 == 0) printf "simulated_minutes=%d\n", secs / 60
                    else printf "simulated_minutes=%.3f\n", secs / 60
                }
                if (ok("io_form_history")) printf "io_form=%d\n", val["io_form_history"]
            }' "${d}/namelist.input" 2>/dev/null || true
    fi
    if [ -f "${d}/rsl.error.0000" ] && [ -r "${d}/rsl.error.0000" ]; then
        LC_ALL=C awk '/^Timing for main/ && /on domain +1:/ { n++ }
                      END { if (n > 0) printf "num_timesteps=%d\n", n }' \
            "${d}/rsl.error.0000" 2>/dev/null || true
    fi
    return 0
}
