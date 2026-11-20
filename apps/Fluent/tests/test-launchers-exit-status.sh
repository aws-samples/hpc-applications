#!/bin/bash
# =============================================================================
# The classic benchmark scripts (x86/Fluent-Benchmark.IMPI.sbatch,
# x86/Fluent-Benchmark.OMPI.sbatch, Arm/Fluent-benchmark.sbatch), the GPU
# benchmark script (gpu/Fluent-Benchmark-GPU.sbatch) and the journal scripts
# (x86/Fluent.IMPI.sbatch, x86/Fluent.OMPI.sbatch, Arm/Fluent.sbatch,
# gpu/Fluent-GPU.sbatch, gpu/Fluent-GPU.OMPI.sbatch) end the job, after the
# recording, with the exit status of the program they start: fluentbench.pl's,
# the 2026 R1 harness's or Fluent's, read past the tee that keeps its output,
# as the CFX and OptiStruct scripts and the STAR-CCM+ batch scripts end with
# their solver's. See helpers-launchers.sh. For each:
#   * the program exits 0, 2 or 137 (killed) -> the job exits 0, 2 or 137, and
#     output.<job>.out keeps the program's output where the script tees it
#     (all but Arm/Fluent-benchmark.sbatch);
#   * a recorder that exits 3 does not change it: the job exits 0, or 2 when
#     the program exits 2, and the NOTE "benchmark recorder failed
#     (non-fatal); the solve was unaffected." says so where the recorder ran;
#     with no recorder to be found, the job exits 0, or 2;
#   * the gates are unchanged: a benchmark script records a run whose output
#     file (or transcript) gives the case's rating, whatever the program's
#     status, so such a run that the program ends with status 2 or 137 is
#     recorded, and the job exits 2 or 137; a journal script records a run
#     only when Fluent exits with status 0.
#
#   apps/Fluent/tests/test-launchers-exit-status.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"
echo "The launch scripts: the job's exit status"

NOTE_FAILED="NOTE: benchmark recorder failed (non-fatal); the solve was unaffected."
NOTE_NOT_FOUND="NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record."

# A recorder that logs its call, as the recorder stub does, then exits 3.
cat > "${WORK}/lbin/recorder-fails" <<'EOF'
#!/bin/bash
# Logs its call, as the recorder stub does, then exits 3.
echo "CALL" >> "${STUB_STATE}/recorder.log"
echo "[failing recorder] called"
exit 3
EOF
chmod +x "${WORK}/lbin/recorder-fails"

# status_var <script>: the stub variable that sets the exit status of the program the script starts
status_var() {
    case "$1" in
        "${GPU_BENCHMARK_SCRIPT}") echo STUB_HARNESS_RC ;;
        *enchmark*)                echo STUB_RC ;;
        *)                         echo STUB_FLUENT_RC ;;
    esac
}
# stub_line <script>: how the line that the program's stub prints starts
stub_line() {
    case "$1" in
        "${GPU_BENCHMARK_SCRIPT}") echo "[stub harness] " ;;
        *enchmark*)                echo "[stub fluentbench.pl] " ;;
        *)                         echo "[stub fluent] " ;;
    esac
}
# exits <description> <status>: the last job exited with that status
exits() {
    [ "${RC}" -eq "$2" ] && ok "$1 -> the job exits $2" || bad "$1 -> the job exits $2" "exit $2" "exit ${RC}"
}
# calls <description> <n>: the last job called the recorder n times
calls() {
    [ "$(recorder_calls)" = "$2" ] && ok "$1 -> $2 recorder call(s)" \
        || bad "$1 -> $2 recorder call(s)" "$2" "$(recorder_calls)"
}
# note <description> <line>: the last job printed that line on its error stream
note() {
    has_line "${ERR}" "$2" && ok "$1 -> the NOTE \"$2\"" || bad "$1 -> the NOTE" "$2" "${ERR}"
}

for s in "${BENCHMARK_SCRIPTS[@]}" "${GPU_BENCHMARK_SCRIPT}" "${JOURNAL_SCRIPTS[@]}"; do
    echo "== ${s}"
    n="${s//\//-}"
    v="$(status_var "${s}")"
    case "${s}" in *enchmark*) kind=benchmark ;; *) kind=journal ;; esac
    # -----------------------------------------------------------------------
    # 1. The program's status is the job's; the gate is as before.
    # -----------------------------------------------------------------------
    for rc in 0 2 137; do
        run_launcher "${s}" "${n}-rc${rc}" "${v}=${rc}"
        exits "${s}: the program exits ${rc}" "${rc}"
        if [ "${kind}" = benchmark ] || [ "${rc}" -eq 0 ]; then
            calls "${s}: the program exits ${rc}" 1
        else
            calls "${s}: the program exits ${rc}" 0
        fi
        [ "${s}" = Arm/Fluent-benchmark.sbatch ] && continue   # the one script that does not tee
        if grep -qF -- "$(stub_line "${s}")" "${WORKDIR}/output.4242.out" 2>/dev/null; then
            ok "${s}: the program exits ${rc} -> output.<job>.out keeps its output"
        else
            bad "${s}: the program exits ${rc} -> output.<job>.out keeps its output" "the stub's line" \
                "$(cat "${WORKDIR}/output.4242.out" 2>/dev/null)"
        fi
    done
    # -----------------------------------------------------------------------
    # 2. The recorder's status never is.
    # -----------------------------------------------------------------------
    run_launcher "${s}" "${n}-recorder-fails" DYNAMODB_RECORDER="${WORK}/lbin/recorder-fails"
    calls "${s}: the recorder exits 3" 1
    note "${s}: the recorder exits 3" "${NOTE_FAILED}"
    exits "${s}: the recorder exits 3" 0
    run_launcher "${s}" "${n}-recorder-fails-rc2" DYNAMODB_RECORDER="${WORK}/lbin/recorder-fails" "${v}=2"
    if [ "${kind}" = benchmark ]; then
        calls "${s}: the program exits 2, the recorder 3" 1
        note "${s}: the program exits 2, the recorder 3" "${NOTE_FAILED}"
    else
        calls "${s}: the program exits 2, the recorder 3" 0
        note "${s}: the program exits 2, the recorder 3" "NOTE: solver exited 2; skipping benchmark recording."
    fi
    exits "${s}: the program exits 2, the recorder 3" 2
    run_launcher "${s}" "${n}-no-recorder" DYNAMODB_RECORDER=
    note "${s}: no recorder" "${NOTE_NOT_FOUND}"
    exits "${s}: no recorder" 0
    run_launcher "${s}" "${n}-no-recorder-rc2" DYNAMODB_RECORDER= "${v}=2"
    if [ "${kind}" = benchmark ]; then
        note "${s}: the program exits 2, no recorder" "${NOTE_NOT_FOUND}"
    else
        note "${s}: the program exits 2, no recorder" "NOTE: solver exited 2; skipping benchmark recording."
    fi
    exits "${s}: the program exits 2, no recorder" 2
done

summary "The launch scripts: the job's exit status"
