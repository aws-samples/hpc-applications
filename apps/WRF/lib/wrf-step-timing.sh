#!/bin/bash
# =============================================================================
# WRF step-timing helpers
# =============================================================================
# Sourced by the WRF benchmark scripts (x86/wrf-benchmark*.sbatch and
# Arm/wrf-benchmark.sbatch) and exercised directly by tests/test-step-timing.sh
# (needs neither Slurm nor WRF).
#
# Why this exists: the scripts report AVG_STEP, the mean of every
# "Timing for main" line of rsl.error.0000. WRF times each step from the top of
# its integration loop (frame/module_integrate.F), and the history and restart
# writes and the lateral-boundary reads happen inside that loop, in
# med_before_solve_io (share/mediation_integrate.F). So a step that writes
# output or reads boundaries carries that I/O in its own "Timing for main"
# line, which rsl.error.0000 prints right after the I/O's own
# "Timing for Writing ..." or "Timing for processing ..." line. The I/O does
# not get faster with more nodes: with hourly history output the average folds
# in a share of I/O that grows with the node count, so node counts compared on
# it understate scaling. The two values below leave that I/O out:
#
#   wrf_median_step <rsl file>  the median of every "Timing for main" step.
#   wrf_steady_step <rsl file>  the mean of every step but the first and those
#                               that follow a "Timing for Writing" line (any
#                               output: history, restart) or a "Timing for
#                               processing" line (any input: the lateral
#                               boundaries, wrfinput).
#
# The rule assumes a single domain, and WRF prints no timing line for
# auxiliary input streams (auxinput*, such as SST updates), so steps that read
# them are not left out.
#
# Like AVG_STEP they read every "Timing for main" line, of every domain. A
# step's time is the number before "elapsed seconds" on its line (the field
# AVG_STEP reads as $9 on a fixed-time-step run). Both print seconds with 5
# decimals, the precision WRF prints its timings with, or N/A when nothing can
# be computed: no file, no step line, or no step left once the exclusions
# apply. Both always return 0, so a caller running under `set -euo pipefail`
# is never stopped by them.
# =============================================================================

# wrf_median_step <rsl file>
# For an even number of steps, the mean of the two middle ones. The values are
# sorted as numbers in the C locale, whatever the caller's locale.
wrf_median_step() {
    local f="${1:-}" v=""
    if [ -n "$f" ] && [ -r "$f" ]; then
        v="$(LC_ALL=C awk '/Timing for main/ { print $(NF-2) }' "$f" 2>/dev/null \
             | LC_ALL=C sort -n \
             | LC_ALL=C awk '{ v[++n] = $1 }
                 END { if (n > 0) printf "%.5f\n", (n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2) }')" \
            || v=""
    fi
    printf '%s\n' "${v:-N/A}"
}

# wrf_steady_step <rsl file>
# Several I/O lines before one step (a history and a restart write at the same
# time) exclude that one step; the step after it counts again.
wrf_steady_step() {
    local f="${1:-}" v=""
    if [ -n "$f" ] && [ -r "$f" ]; then
        v="$(LC_ALL=C awk '
                /Timing for Writing/ || /Timing for processing/ { after_io = 1; next }
                /Timing for main/ {
                    if (++n > 1 && !after_io) { s += $(NF-2); k++ }
                    after_io = 0
                }
                END { if (k > 0) printf "%.5f\n", s / k }' "$f" 2>/dev/null)" \
            || v=""
    fi
    printf '%s\n' "${v:-N/A}"
}
