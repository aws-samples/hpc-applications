#!/bin/bash
# =============================================================================
# The CPU launchers' success gate: the contribution recorder is called only when
# md.log gives a positive ns/day. A run whose md.log has no Performance line, or
# a rate of 0, still completes with its results block, but is not recorded.
#
#   ./tests/test-mdlog-gate.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

recorder_calls() { grep -c 'BENCHMARK_CASE=' "${RECLOG}"; }

for arch in x86 Arm; do
    echo "== ${arch}/gromacs-benchmark.sbatch =="

    run_launcher "${arch}"
    [ "${RC}" -eq 0 ] && [ "$(recorder_calls)" -eq 1 ] && ok "a positive ns/day: the run is recorded once" \
        || bad "a positive ns/day: recorded once" "exit 0, 1 recorder call" "exit ${RC}, $(recorder_calls) call(s)"

    run_launcher "${arch}" STUB_NS_PER_DAY=
    [ "${RC}" -eq 0 ] && [ "$(mdrun_count)" -eq 1 ] && ok "no Performance line: the job still completes" \
        || bad "no Performance line: completes" "exit 0, 1 mdrun" "exit ${RC}, $(mdrun_count) mdrun"
    grep -qx 'ns/day:           n/a' <<<"${OUT}" && ok "no Performance line: the results block says n/a" \
        || bad "results block" "ns/day:           n/a" "$(grep 'ns/day' <<<"${OUT}" | head -2 | tr '\n' '|')"
    [ "$(recorder_calls)" -eq 0 ] && ok "no Performance line: the recorder is not called" \
        || bad "no Performance line: not recorded" "no recorder call" "$(head -1 "${RECLOG}")"
    grep -qx 'NOTE: md.log gives no positive ns/day, so this run is not recorded.' <<<"${OUT}" \
        && ok "no Performance line: the job log says why" \
        || bad "the gate's note" "NOTE: md.log gives no positive ns/day, so this run is not recorded." \
               "$(grep 'NOTE' <<<"${OUT}" | tr '\n' '|')"

    run_launcher "${arch}" STUB_NS_PER_DAY=0.000
    [ "$(recorder_calls)" -eq 0 ] && ok "ns/day 0.000: the recorder is not called" \
        || bad "ns/day 0.000: not recorded" "no recorder call" "$(head -1 "${RECLOG}")"

    run_launcher "${arch}" SLURM_JOB_NUM_NODES=2 STUB_NS_PER_DAY=
    [ "${RC}" -eq 0 ] && [ "$(mdrun_bin)" = gmx_mpi ] && [ "$(recorder_calls)" -eq 0 ] \
        && ok "two nodes, no Performance line: completes, not recorded" \
        || bad "two nodes, no Performance line" "exit 0, gmx_mpi, no recorder call" \
               "exit ${RC}, $(mdrun_bin), $(recorder_calls) call(s)"
done

summary "md.log gate tests"
