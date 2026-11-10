#!/bin/bash
# =============================================================================
# How the other Fluent launch scripts read the instance type from the instance
# metadata, with the stubs of helpers-launchers.sh: the classic benchmark
# scripts (x86/Fluent-Benchmark.IMPI, x86/Fluent-Benchmark.OMPI,
# Arm/Fluent-benchmark), the GPU benchmark script (gpu/Fluent-Benchmark-GPU)
# and the journal scripts (x86/Fluent.IMPI, x86/Fluent.OMPI, Arm/Fluent,
# gpu/Fluent-GPU, gpu/Fluent-GPU.OMPI). The type names only the run directory.
# For each script:
#   * both requests to the instance metadata give up within 5 seconds, and use
#     -f;
#   * the instance type names the run directory, and so does a type name with
#     an i in a Turkish locale, where [a-z] leaves out i (SKIP where that
#     locale is not installed);
#   * with no answer, an HTTP error, an answer cut off at the time limit, or an
#     answer that is not an instance type name (a proxy's page, a host name
#     after other text, capitals, a type name before other text, a type name
#     and a second line), the job runs to its end, in a run directory whose
#     name has no instance type and nothing of the answer.
# The GPU benchmark script also writes each node's instance id, which each
# node reads from its own instance metadata through mpirun, to instance-ids.
# Here a stub mpirun runs that command once per node: both of its requests
# give up within 5 seconds and use -f, and with no answer, an HTTP error, or
# an answer cut off at the time limit, the node's line has no id.
#
#   apps/Fluent/tests/test-launchers-imds.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"
echo "The other launch scripts: the instance type from the instance metadata"

TR=""
if grep -qiE '^tr_TR\.utf-?8$' <<< "$(locale -a 2>/dev/null)"; then TR=1; fi
# Answers that are not an instance type name.
NOT_TYPES=("<html><body>Request denied by proxy.example.com</body></html>"
           "Request denied by proxy.example.com"
           "HPC8A.96XLARGE"
           "hpc8a.96xlarge: not found"
           "hpc8a.96xlarge"$'\n'"<p>Request checked by proxy.example.com")

# named <label> <instance type, or empty for none>: the job ran to its end (exit
# 0, the Ansys program and the recorder once each), in a run directory named
# 4242-2x<type>-384-<date>.
named() {
    if [ "${RC}" -eq 0 ] && [ "$(solver_calls)" = 1 ] && [ "$(recorder_calls)" = 1 ]; then
        ok "$1: the job runs to its end"
    else
        bad "$1: the job runs to its end" "exit 0, the Ansys program and the recorder once each" \
            "exit ${RC}, $(solver_calls) and $(recorder_calls); stderr: ${ERR}"
    fi
    case "${WORKDIR##*/}" in
        "4242-2x$2-384-"[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            if [ -d "${WORKDIR}" ]; then ok "$1: the run directory is 4242-2x$2-384-<date>"
            else bad "$1: the run directory exists" "${WORKDIR}" "none"; fi ;;
        *) bad "$1: the run directory is 4242-2x$2-384-<date>" "4242-2x$2-384-<date>" "${WORKDIR}" ;;
    esac
}
# limits <label> <requests>: that many requests to the instance metadata, each
# with -f (or --fail), and a --connect-timeout and a --max-time of 1 to 5.
limits() {
    local n b f
    n="$(grep -cF '169.254.169.254' "${STATE}/curl.log" 2>/dev/null)"
    b="$(grep -F '169.254.169.254' "${STATE}/curl.log" 2>/dev/null \
        | grep -E -- '--connect-timeout [1-5]( |$)' | grep -cE -- '--max-time [1-5]( |$)')"
    f="$(grep -F '169.254.169.254' "${STATE}/curl.log" 2>/dev/null \
        | grep -cE -- '(^| )(-[A-Za-z]*f[A-Za-z]*|--fail)( |$)')"
    if [ "${n}" = "$2" ] && [ "${b}" = "$2" ] && [ "${f}" = "$2" ]; then
        ok "$1: the $2 requests to the instance metadata give up within 5 seconds, and use -f"
    else
        bad "$1: the $2 requests to the instance metadata give up within 5 seconds, and use -f" \
            "$2 requests, each with -f, --connect-timeout and --max-time of 1 to 5" \
            "$(tr '\n' '|' < "${STATE}/curl.log" 2>/dev/null)"
    fi
}

for s in "${BENCHMARK_SCRIPTS[@]}" "${GPU_BENCHMARK_SCRIPT}" "${JOURNAL_SCRIPTS[@]}"; do
    n="imds-${s//\//-}"
    echo "== ${s}"
    run_launcher "${s}" "${n}-type"
    named "${s}, hpc8a.96xlarge from the instance metadata" hpc8a.96xlarge
    limits "${s}" 2
    for mode in no-answer http-error cut-off; do
        run_launcher "${s}" "${n}-${mode}" STUB_IMDS="${mode}"
        named "${s}, the instance metadata ${mode}" ""
    done
    i=0
    for answer in "${NOT_TYPES[@]}"; do
        i=$((i + 1))
        run_launcher "${s}" "${n}-not-a-type-${i}" STUB_INSTANCE_TYPE="${answer}"
        named "${s}, the answer '${answer//$'\n'/\\n}'" ""
    done
    if [ -n "${TR}" ]; then
        run_launcher "${s}" "${n}-turkish" STUB_INSTANCE_TYPE=c8i.96xlarge LANG=tr_TR.UTF-8
        named "${s}, c8i.96xlarge in a Turkish locale" c8i.96xlarge
    else
        skipt "${s}, c8i.96xlarge in a Turkish locale" "the tr_TR.UTF-8 locale is not installed"
    fi
done

# The GPU benchmark script's instance ids: this mpirun, first on the PATH, runs
# the command that reads them once per node, as on the job's 2 nodes.
mkdir -p "${WORK}/ids-bin"
cat > "${WORK}/ids-bin/mpirun" <<'EOF'
#!/bin/bash
# As the mpirun stub of helpers-2026r1.sh (it answers --version and logs every
# call), but `mpirun -np <n> ... /bin/bash -c <command>`, with a command that
# reads the instance id from the instance metadata, runs <command> <n> times,
# as on <n> nodes. It runs no other command.
if [ "${1:-}" = "--version" ]; then
    echo "Intel(R) MPI Library for Linux* OS, Version 2021.18 Build 20260101 (id: 0)"
    exit 0
fi
printf '%s\n' "$*" >> "${STUB_STATE}/mpirun.log"
np=1; prev=""; cmd=""
for a in "$@"; do
    case "${prev}" in -np) np="${a}" ;; -c) cmd="${a}" ;; esac
    prev="${a}"
done
case "${cmd}" in
    *meta-data/instance-id*) for ((i = 0; i < np; i++)); do /bin/bash -c "${cmd}"; done ;;
esac
exit 0
EOF
printf '#!/bin/bash\necho node1\n' > "${WORK}/ids-bin/hostname"
chmod +x "${WORK}/ids-bin/mpirun" "${WORK}/ids-bin/hostname"
IDS_PATH="${WORK}/ids-bin:${WORK}/lbin:${WORK}/bin:/usr/bin:/bin"
# ids <label> <the line each node should write>: the job ran to its end, and
# instance-ids holds that line for each of the 2 nodes.
ids() {
    named "$1" "$3"
    if [ "$(cat "${WORKDIR}/instance-ids" 2>/dev/null)" = "$(printf '%s\n%s' "$2" "$2")" ]; then
        ok "$1: instance-ids has '$2' for each node"
    else
        bad "$1: instance-ids has '$2' for each node" "$2 (twice)" \
            "$(tr '\n' '|' < "${WORKDIR}/instance-ids" 2>/dev/null)"
    fi
}
echo "== ${GPU_BENCHMARK_SCRIPT}: each node's instance id"
run_launcher "${GPU_BENCHMARK_SCRIPT}" ids-answer PATH="${IDS_PATH}"
ids "the instance id from each node's instance metadata" "i-0123456789abcdef0:node1" hpc8a.96xlarge
limits "the instance type, then each node's instance id" 6
for mode in no-answer http-error cut-off; do
    run_launcher "${GPU_BENCHMARK_SCRIPT}" "ids-${mode}" PATH="${IDS_PATH}" STUB_IMDS="${mode}"
    ids "the instance metadata ${mode}: no instance id" ":node1" ""
done

summary "The other launch scripts: the instance type from the instance metadata"
