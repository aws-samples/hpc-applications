#!/bin/bash
# =============================================================================
# WRF run check: did the run complete and write its output?
# =============================================================================
# Sourced by the WRF benchmark scripts (x86/wrf-benchmark*.sbatch and
# Arm/wrf-benchmark.sbatch), which record a run (dynamodb/record-benchmark.sh)
# only when it passes, and exercised directly by tests/test-run-check.sh (needs
# neither Slurm nor WRF).
#
#   wrf_run_check <run dir>
#
# A run passes when, in <run dir>:
#   * rsl.error.0000, rank 0's log, says "SUCCESS COMPLETE WRF";
#   * every history file of domain 1 that WRF wrote is there and not empty;
#   * there are at least as many restart files of domain 1 (wrfrst_d01_*) as
#     WRF made restart writes, and none of them is empty.
#
# Which files WRF wrote comes from its own log. rank 0 prints a
#   Timing for Writing wrfout_d01_<date> for domain        1: ...
# line for every history write, and a
#   Timing for Writing restart for domain        1: ...
# line for every restart write, whether or not the write succeeded: so the lines
# say which files should exist, and the files whether the writes happened.
# WRF names the history line after the time of the write, but it puts
# frames_per_outfile writes (namelist.input, &time_control; WRF's default is 10)
# in each history file, named after the first of them: the history files are
# the ones the 1st, (frames_per_outfile + 1)th, ... of those lines name, so a
# run that writes history needs namelist.input in <run dir> (the scripts copy
# it there). A run that writes no output passes on its log alone.
#
# frames_per_outfile is read from the line that sets it, which must start
# with it,
#   frames_per_outfile = <n>[, <domain 2>, ...]
# in any case, <n> a positive whole number (a repeat count, <r>*<n>, reads as
# <n>). WRF's default of 10 is used only when no line names the key: a namelist
# that names it in any other form (after another setting on the same line, with
# a subscript, with its value on the next line) or on more than one line is
# refused, so the check never guesses which history files WRF wrote.
#
# The rule assumes WRF's default file names (history_outname, rst_outname),
# in the run directory, and every write in a single file (io_form 2 or 11),
# not in a file per rank (io_form 102); it reads domain 1 only.
#
# It prints one line per problem found, and returns 0 when there is none and 1
# otherwise. Call it in an `if` or with `||`: then it never stops a caller
# running under `set -euo pipefail`. Sourcing it defines wrf_run_check and
# changes no shell option.
# =============================================================================

# wrf_run_check <run dir>
wrf_run_check() {
    local d="${1:-}" rsl nl fpo f p problems="" restart_lines restart_files=0
    if [ -z "${d}" ] || [ ! -d "${d}" ]; then
        printf '%s\n' "no run directory '${d}'"
        return 1
    fi
    rsl="${d}/rsl.error.0000"
    if [ ! -f "${rsl}" ] || [ ! -r "${rsl}" ]; then
        printf '%s\n' "no readable rsl.error.0000"
        return 1
    fi
    grep -q 'SUCCESS COMPLETE WRF' "${rsl}" \
        || problems+="rsl.error.0000 does not say SUCCESS COMPLETE WRF"$'\n'

    # History: the files the 1st, (frames_per_outfile + 1)th, ... write lines name.
    if grep -q '^Timing for Writing wrfout_d01_' "${rsl}"; then
        nl="${d}/namelist.input"
        fpo=""
        if [ -f "${nl}" ] && [ -r "${nl}" ]; then
            # Domain 1's frames_per_outfile, comments removed: "unset" when no
            # line names it; "ok <n>" when the one line that does reads
            # "frames_per_outfile = <n>[, ...]" in any case, <n> a positive whole
            # number (a repeat count, <r>*<n>, reads as <n>); otherwise
            # "bad <that line>", or "lines <count>" when several lines name it.
            fpo="$(LC_ALL=C awk '
                { line = $0; sub(/!.*/, "", line); low = tolower(line)
                  if (low !~ /(^|[^a-z0-9_])frames_per_outfile([^a-z0-9_]|$)/) next
                  if (++n > 1) next
                  text = line; gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
                  if (match(low, /^[[:space:]]*frames_per_outfile[[:space:]]*=[[:space:]]*/)) {
                      rest = substr(line, RLENGTH + 1)
                      if (rest ~ /^[0-9]+\*[0-9]/) rest = substr(rest, index(rest, "*") + 1)
                      if (rest ~ /^[0-9]+([[:space:],\/]|$)/) {
                          v = rest; sub(/[^0-9].*$/, "", v); sub(/^0+/, "", v) }
                  } }
                END { if (n == 0) print "unset"; else if (n > 1) print "lines " n
                      else if (v != "") print "ok " v; else print "bad " text }' \
                   "${nl}" 2>/dev/null)" || fpo=""
            case "${fpo}" in
                unset)    fpo=10 ;;
                "ok "*)   fpo="${fpo#ok }" ;;
                "lines "*)
                    problems+="cannot read frames_per_outfile from namelist.input (set on ${fpo#lines } lines)"$'\n'
                    fpo="" ;;
                "bad "*)
                    problems+="cannot read frames_per_outfile from namelist.input ('${fpo#bad }')"$'\n'
                    fpo="" ;;
                *)  problems+="cannot read frames_per_outfile from namelist.input"$'\n'
                    fpo="" ;;
            esac
        else
            problems+="no namelist.input to tell which history files WRF wrote"$'\n'
        fi
        if [ -n "${fpo}" ]; then
            while IFS= read -r f; do
                p="${d}/${f}"
                if [ ! -f "${p}" ]; then
                    problems+="history file ${f} is missing"$'\n'
                elif [ ! -s "${p}" ]; then
                    problems+="history file ${f} is empty"$'\n'
                fi
            done < <(LC_ALL=C awk -v fpo="${fpo}" '
                         /^Timing for Writing wrfout_d01_/ { if (n++ % fpo == 0) print $4 }' \
                         "${rsl}" 2>/dev/null)
        fi
    fi

    # Restart: as many non-empty wrfrst_d01_* files as restart writes, at least.
    restart_lines="$(LC_ALL=C awk '/^Timing for Writing restart for domain +1:/ { n++ }
                                   END { print n + 0 }' "${rsl}" 2>/dev/null)" || restart_lines=0
    for p in "${d}"/wrfrst_d01_*; do
        [ -f "${p}" ] || continue
        restart_files=$((restart_files + 1))
        [ -s "${p}" ] || problems+="restart file ${p##*/} is empty"$'\n'
    done
    if [ "${restart_files}" -lt "${restart_lines:-0}" ]; then
        problems+="${restart_lines} restart write(s) in rsl.error.0000 but ${restart_files} wrfrst_d01_* file(s)"$'\n'
    fi

    if [ -n "${problems}" ]; then
        printf '%s' "${problems}"
        return 1
    fi
    return 0
}
