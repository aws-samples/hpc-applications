#!/bin/bash
# =============================================================================
# What the CPU launchers hand the contribution recorder besides the result, so
# that records of runs made with other settings stay apart, under the names the
# dataset already uses for them: the run length (--metric nsteps=<nsteps>),
# whether PME tuning was left on (--char pme_tuning=on|off, off when the mdrun
# command line has -notunepme) and the OpenMP threads per rank
# (--metric threads_per_rank=<n>). The real recorder, in --dry-run, writes the
# two numbers as numbers and pme_tuning as text, and no timesteps field.
#
#   ./tests/test-record-fields.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

recorder_args() { sed -n 's/.* ARGS: //p' "${RECLOG}" | tail -1; }
# the PME tuning the last mdrun ran with
pme_ran() { if [[ " $(mdrun_args) " == *" -notunepme "* ]]; then echo off; else echo on; fi; }

# The real contribution recorder in --dry-run: it prints the record and touches
# neither a file nor AWS.
DRYRUN_OUT="${STUBS}/dryrun.out"
cat > "${STUBS}/bin/recorder-dryrun.sh" <<EOF
#!/bin/bash
exec bash "${GROMACS_APP}/dynamodb/record-benchmark.sh" --dry-run "\$@" > "${DRYRUN_OUT}" 2>&1
EOF
chmod +x "${STUBS}/bin/recorder-dryrun.sh"

for arch in x86 Arm; do
    echo "== ${arch}/gromacs-benchmark.sbatch =="

    run_launcher "${arch}"
    has_words "benchMEM, defaults: 50,000 steps, PME tuning on, 1 thread per rank" "$(recorder_args)" \
        "--metric nsteps=50000 --char pme_tuning=on --metric threads_per_rank=1"

    run_launcher "${arch}" MODEL=benchPEP-h
    has_words "benchPEP-h: 5,000 steps and the PME tuning mdrun ran with ($(pme_ran))" "$(recorder_args)" \
        "--metric nsteps=5000 --char pme_tuning=$(pme_ran) --metric threads_per_rank=1"

    run_launcher "${arch}" MODEL=benchMEM TIMESTEPS=1234 THREADS_PER_RANK=4
    has_words "TIMESTEPS=1234, THREADS_PER_RANK=4: both recorded" "$(recorder_args)" \
        "--metric nsteps=1234 --char pme_tuning=on --metric threads_per_rank=4"

    run_launcher "${arch}" SLURM_JOB_NUM_NODES=2 MODEL=benchPEP-h
    has_words "two nodes: the same fields" "$(recorder_args)" \
        "--metric nsteps=5000 --char pme_tuning=$(pme_ran) --metric threads_per_rank=1"

    : > "${DRYRUN_OUT}"
    run_launcher "${arch}" CONTRIB_RECORDER="${STUBS}/bin/recorder-dryrun.sh" SLURM_NTASKS=192 MODEL=benchPEP-h
    for field in '"nsteps": {"N": "5000"}' "\"pme_tuning\": {\"S\": \"$(pme_ran)\"}" \
            '"threads_per_rank": {"N": "1"}'; do
        grep -qF "${field}" "${DRYRUN_OUT}" && ok "the recorder's dry-run record holds ${field}" \
            || bad "dry-run record" "${field}" "$(grep -E 'DRY RUN|ERROR' "${DRYRUN_OUT}" | head -2 | tr '\n' '|')"
    done
    if grep -qF '"timesteps"' "${DRYRUN_OUT}"; then
        bad "no timesteps field" "none" "$(grep -F '"timesteps"' "${DRYRUN_OUT}")"
    else
        ok "the recorder's dry-run record has no timesteps field"
    fi
done

echo "== the stubs kept AWS out of it =="
[ -s "${STUBS}/aws-calls.log" ] && bad "no AWS call" "none" "$(head -1 "${STUBS}/aws-calls.log")" \
    || ok "no test called AWS"

summary "record field tests"
