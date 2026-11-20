#!/bin/bash
# =============================================================================
# PME tuning in the CPU launchers: benchPEP-h runs with -notunepme by default
# (its tuning can outlast the -resethway midpoint), on one node and on more; the
# other models keep tuning on, also when the submitting shell sets
# DEFAULT_TUNEPME; TUNEPME=on|off overrides the default for any model, and any
# other value is refused before mdrun.
#
#   ./tests/test-pme-tuning.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

for arch in x86 Arm; do
    echo "== ${arch}/gromacs-benchmark.sbatch =="

    run_launcher "${arch}" MODEL=benchPEP-h
    [ "${RC}" -eq 0 ] && ok "benchPEP-h: completes (exit 0)" || bad "benchPEP-h completes" "exit 0" "exit ${RC}"
    has_words "benchPEP-h, one node: mdrun gets -notunepme" "$(mdrun_args)" "-deffnm md -notunepme"
    grep -qx 'PME tuning:    off' <<<"${OUT}" && ok "benchPEP-h: the job log says PME tuning is off" \
        || bad "PME tuning line" "PME tuning:    off" "$(grep 'PME tuning' <<<"${OUT}")"

    run_launcher "${arch}" MODEL=benchPEP-h SLURM_JOB_NUM_NODES=2
    [ "$(mdrun_bin)" = gmx_mpi ] && has_words "benchPEP-h, two nodes: gmx_mpi gets -notunepme" "$(mdrun_args)" "-notunepme" \
        || bad "two nodes: gmx_mpi" "gmx_mpi with -notunepme" "$(mdrun_bin): $(mdrun_args)"

    run_launcher "${arch}" MODEL=benchMEM
    [ "${RC}" -eq 0 ] && [ "$(mdrun_count)" -eq 1 ] && ok "benchMEM: completes with one mdrun" \
        || bad "benchMEM: one mdrun" "exit 0, 1 mdrun" "exit ${RC}, $(mdrun_count) mdrun"
    lacks_word "benchMEM: tuning stays on (no -notunepme)" "$(mdrun_args)" "-notunepme"
    grep -qx 'PME tuning:    on' <<<"${OUT}" && ok "benchMEM: the job log says PME tuning is on" \
        || bad "PME tuning line" "PME tuning:    on" "$(grep 'PME tuning' <<<"${OUT}")"

    # The model's default comes from the launcher alone: a DEFAULT_TUNEPME in the
    # submitting shell (sbatch --export=ALL passes it on) changes nothing.
    run_launcher "${arch}" MODEL=benchMEM DEFAULT_TUNEPME=off
    [ "${RC}" -eq 0 ] && [ "$(mdrun_count)" -eq 1 ] && ok "benchMEM, DEFAULT_TUNEPME=off set: completes with one mdrun" \
        || bad "benchMEM, DEFAULT_TUNEPME=off set: one mdrun" "exit 0, 1 mdrun" "exit ${RC}, $(mdrun_count) mdrun"
    lacks_word "benchMEM, DEFAULT_TUNEPME=off set: tuning stays on" "$(mdrun_args)" "-notunepme"
    grep -qx 'PME tuning:    on' <<<"${OUT}" && ok "benchMEM, DEFAULT_TUNEPME=off set: the job log says on" \
        || bad "PME tuning line" "PME tuning:    on" "$(grep 'PME tuning' <<<"${OUT}")"

    run_launcher "${arch}" MODEL=benchPEP-h TUNEPME=on
    [ "${RC}" -eq 0 ] && [ "$(mdrun_count)" -eq 1 ] && ok "benchPEP-h, TUNEPME=on: completes with one mdrun" \
        || bad "benchPEP-h, TUNEPME=on: one mdrun" "exit 0, 1 mdrun" "exit ${RC}, $(mdrun_count) mdrun"
    lacks_word "benchPEP-h, TUNEPME=on: no -notunepme" "$(mdrun_args)" "-notunepme"

    run_launcher "${arch}" MODEL=benchMEM TUNEPME=off
    has_words "benchMEM, TUNEPME=off: -notunepme" "$(mdrun_args)" "-notunepme"

    run_launcher "${arch}" MODEL=benchPEP-h TUNEPME=yes
    [ "${RC}" -ne 0 ] && grep -q "TUNEPME='yes' invalid (expected on or off)" <<<"${OUT}" \
        && ok "TUNEPME=yes is refused" || bad "TUNEPME=yes refused" "non-zero exit and a message" "exit ${RC}"
    [ "$(mdrun_count)" -eq 0 ] && ok "TUNEPME=yes: no mdrun" || bad "no mdrun" "0" "$(mdrun_count)"
done

summary "PME tuning tests"
