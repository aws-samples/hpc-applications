#!/bin/bash
# =============================================================================
# x86/Fluent-Benchmark.2026R1.sbatch end to end, with the stubs of
# helpers-2026r1.sh: what the script does around the harness.
#   * the run directory, its host file and the copy of the script;
#   * the page-cache drop and the THP setting, through srun, once per node;
#   * the harness's command line: -mpiopt as one argument, the iteration
#     counts only when they are set, -solver, and EXTRA_FLUENT_ARGS split into
#     words at the end;
#   * the recorder, called once, gets the version, the run directory, the
#     case, the method, the solver mode and the timed iteration count (200 when
#     ITERATIONS is not set); this directory's recorder in --dry-run would
#     store the case, its size, that count and the harness's MIUPS;
#   * a run whose harness writes no transcript is not recorded, a NOTE says
#     so, and the job still exits 0; a recorder that cannot be found is named
#     in a NOTE; nothing reaches AWS.
#
#   apps/Fluent/tests/test-2026r1-e2e.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-2026r1.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-2026r1.sh"
echo "2026 R1 script end to end (${SBATCH#"${FLUENT_APP}/"})"

# ---------------------------------------------------------------------------
# 1. A run the harness completes: 2 x hpc8a.96xlarge, 384 ranks, sedan_4m.
# ---------------------------------------------------------------------------
run_2026r1 completed
[ "${RC}" -eq 0 ] && ok "the job exits 0" || bad "the job exits 0" "exit 0" "exit ${RC}"
want="$(readlink -m "${STATE}/base/fluent-e2e")/sedan_4m/v261-2026R1-cpu/4242-2xhpc8a.96xlarge-384-"
case "${WORKDIR}" in
    "${want}"*) ok "the run directory is <base>/<job name>/<case>/v261-2026R1-cpu/<job>-<nodes>x<type>-<ranks>-<date>" ;;
    *) bad "the run directory" "${want}<date>" "${WORKDIR}" ;;
esac
if [ "$(cat "${WORKDIR}/hostfile" 2>/dev/null)" = "$(printf 'node1\nnode2')" ]; then
    ok "the host file lists each node once"
else
    bad "the host file lists each node once" "node1 node2" "$(tr '\n' ' ' < "${WORKDIR}/hostfile" 2>/dev/null)"
fi
cmp -s "${SBATCH}" "${WORKDIR}/$(basename "${SBATCH}")" \
    && ok "the script is copied into the run directory" \
    || bad "the script is copied into the run directory" "a copy" "none"
srun_log="$(cat "${STATE}/srun.log" 2>/dev/null)"
if [ "$(printf '%s\n' "${srun_log}" | grep -c '^--ntasks=2 --ntasks-per-node=1 /bin/bash -c ')" = "2" ] \
        && grep -q 'drop_caches' <<< "${srun_log}" \
        && grep -q 'transparent_hugepage/enabled' <<< "${srun_log}"; then
    ok "the cache drop and the THP setting run through srun, one task per node"
else
    bad "the cache drop and the THP setting run through srun" "2 srun calls, one task per node" "${srun_log}"
fi
expected_args="$(printf '%s\n' "${STATE}/ansys/ansys_inc/v261/fluent/bench/bin/fluent_benchmark_gpu.py" \
    -cores 384 -cases sedan_4m -iterations 25 -warmup_iterations 10 \
    -cflush "-mpiopt=-genv I_MPI_DEBUG 5" -peth.efa -cnf=./hostfile -platform=intel -nosyslog -noloadchk \
    -ssh -mpi=intel -norm)"
if [ "$(cat "${STATE}/harness.args")" = "${expected_args}" ]; then
    ok "the harness's command line, with -mpiopt as one argument"
else
    bad "the harness's command line" "${expected_args//$'\n'/ | }" "$(tr '\n' '|' < "${STATE}/harness.args")"
fi
[ "$(cat "${STATE}/harness.cwd")" = "${WORKDIR}" ] && ok "the harness runs in the run directory" \
    || bad "the harness runs in the run directory" "${WORKDIR}" "$(cat "${STATE}/harness.cwd")"
grep -qxF "[stub harness] sedan_4m on 384 cores" "${WORKDIR}/output.4242.out" 2>/dev/null \
    && ok "the harness's output is kept in output.<job>.out" \
    || bad "the harness's output is kept in output.<job>.out" "the harness's line" "$(cat "${WORKDIR}/output.4242.out" 2>/dev/null)"
[ "$(recorder_calls)" = "1" ] && ok "the recorder runs once" || bad "the recorder runs once" "1" "$(recorder_calls)"
recorder_has "RUN_DIR=${WORKDIR}" && ok "the recorder gets RUN_DIR, the run directory" \
    || bad "the recorder gets RUN_DIR" "RUN_DIR=${WORKDIR}" "$(grep RUN_DIR "${STATE}/recorder.log" 2>/dev/null)"
for want in "FLUENT_VERSION=v261" "BENCHMARK_CASE=sedan_4m" "BENCHMARK_METHOD=fluent_benchmark_harness" \
            "SOLVER_MODE=cpu" "NUM_ITERATIONS=25"; do
    recorder_has "${want}" && ok "the recorder gets ${want}" \
        || bad "the recorder gets ${want%%=*}" "${want}" "$(tr '\n' '|' < "${STATE}/recorder.log" 2>/dev/null)"
done

# ---------------------------------------------------------------------------
# 2. ITERATIONS and WARMUP_ITERATIONS not set: the harness's own defaults.
# ---------------------------------------------------------------------------
run_2026r1 defaults ITERATIONS= WARMUP_ITERATIONS=
if grep -qxE -- '-(warmup_)?iterations' "${STATE}/harness.args"; then
    bad "no iteration count is passed to the harness" "neither option" "$(tr '\n' ' ' < "${STATE}/harness.args")"
else
    ok "no iteration count is passed to the harness"
fi
recorder_has "NUM_ITERATIONS=200" && ok "the recorder gets NUM_ITERATIONS=200, the harness's default" \
    || bad "the recorder gets NUM_ITERATIONS=200" "NUM_ITERATIONS=200" "$(grep NUM_ITERATIONS "${STATE}/recorder.log")"

# ---------------------------------------------------------------------------
# 3. SOLVER and EXTRA_FLUENT_ARGS.
# ---------------------------------------------------------------------------
run_2026r1 extra SOLVER=coupled EXTRA_FLUENT_ARGS="3ddp -gu"
expected_args="$(printf '%s\n' "${STATE}/ansys/ansys_inc/v261/fluent/bench/bin/fluent_benchmark_gpu.py" \
    -cores 384 -cases sedan_4m -iterations 25 -warmup_iterations 10 -solver coupled \
    -cflush "-mpiopt=-genv I_MPI_DEBUG 5" -peth.efa -cnf=./hostfile -platform=intel -nosyslog -noloadchk \
    -ssh -mpi=intel -norm 3ddp -gu)"
if [ "$(cat "${STATE}/harness.args")" = "${expected_args}" ]; then
    ok "SOLVER gives -solver; EXTRA_FLUENT_ARGS is split into words, after the script's flags"
else
    bad "SOLVER and EXTRA_FLUENT_ARGS" "${expected_args//$'\n'/ | }" "$(tr '\n' '|' < "${STATE}/harness.args")"
fi

# ---------------------------------------------------------------------------
# 4. The harness writes no transcript (it stops before the case): no record.
# ---------------------------------------------------------------------------
run_2026r1 no-transcript STUB_TRANSCRIPT= STUB_HARNESS_RC=1
[ "$(recorder_calls)" = "0" ] && ok "no transcript -> not recorded" \
    || bad "no transcript -> not recorded" "no recorder call" "$(recorder_calls) call(s)"
has_line "${ERR}" "NOTE: no MIUPS result found in transcripts; skipping benchmark recording." \
    && ok "no transcript -> the NOTE that skips the recording" \
    || bad "no transcript -> the NOTE that skips the recording" "the NOTE" "${ERR}"
[ "${RC}" -eq 0 ] && ok "no transcript -> the job still exits 0" || bad "no transcript -> the job exits 0" "exit 0" "exit ${RC}"

# ---------------------------------------------------------------------------
# 5. This directory's recorder, in --dry-run: the item it would store.
# ---------------------------------------------------------------------------
run_2026r1 real-recorder DYNAMODB_RECORDER="${WORK}/bin/real-recorder"
item="$(sed -n '/^{/,$p' "${STATE}/recorder.json" 2>/dev/null)"
for want in '"benchmark_case": {"S": "sedan_4m"}' '"num_cells_million": {"N": "4"}' \
            '"num_iterations": {"N": "25"}' '"miups": {"N": "12.34"}' '"case_read_seconds": {"N": "1.234"}' \
            '"benchmark_method": {"S": "fluent_benchmark_harness"}' '"solver_mode": {"S": "cpu"}' \
            '"instance_type": {"S": "hpc8a.96xlarge"}' '"num_cores": {"N": "384"}' '"num_instances": {"N": "2"}'; do
    grep -qF -- "${want}" <<< "${item}" && ok "the item would store ${want}" \
        || bad "the item would store ${want}" "${want}" "$(printf '%s' "${item}" | tr '\n' ' ')"
done
if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${item}" | python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null \
        && ok "the item is valid JSON" || bad "the item is valid JSON" "valid JSON" "$(printf '%s' "${item}" | tr '\n' ' ')"
else
    skipt "the item is valid JSON" "no python3"
fi

# ---------------------------------------------------------------------------
# 6. No recorder to be found.
# ---------------------------------------------------------------------------
run_2026r1 no-recorder DYNAMODB_RECORDER=
has_line "${ERR}" "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." \
    && ok "no recorder -> a NOTE says how to point at it" || bad "no recorder -> a NOTE" "the NOTE" "${ERR}"

# ---------------------------------------------------------------------------
# 7. Nothing above reached AWS.
# ---------------------------------------------------------------------------
if compgen -G "${WORK}/*/aws.log" > /dev/null; then
    bad "no case calls aws" "no aws call" "$(cat "${WORK}"/*/aws.log)"
else
    ok "no case calls aws"
fi

summary "2026 R1 script end to end"
