#!/bin/bash
# =============================================================================
# The other Fluent launch scripts end to end, with the stubs of
# helpers-launchers.sh: the classic benchmark scripts (x86/Fluent-Benchmark.IMPI,
# x86/Fluent-Benchmark.OMPI, Arm/Fluent-benchmark), the GPU benchmark script
# (gpu/Fluent-Benchmark-GPU) and the journal scripts (x86/Fluent.IMPI,
# x86/Fluent.OMPI, Arm/Fluent, gpu/Fluent-GPU, gpu/Fluent-GPU.OMPI). For each, a
# run that completes:
#   * exits 0, in a run directory under BASE_DIR that holds the host file (each
#     node once) and a copy of the script;
#   * stages its input there: the case's files from the archive, or the journal,
#     case and data file;
#   * starts the Ansys program once, in the run directory, and keeps its output
#     in output.<job>.out where the script tees it;
#   * calls the recorder once, with the version and the run directory;
#   * asks AWS for the case's archive only.
#
#   apps/Fluent/tests/test-launchers-e2e.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-launchers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-launchers.sh"
echo "The other launch scripts end to end"

for s in "${BENCHMARK_SCRIPTS[@]}" "${GPU_BENCHMARK_SCRIPT}" "${JOURNAL_SCRIPTS[@]}"; do
    echo "== ${s}"
    run_launcher "${s}" "e2e-${s//\//-}"
    [ "${RC}" -eq 0 ] && ok "${s}: the job exits 0" || bad "${s}: the job exits 0" "exit 0" "exit ${RC}: ${ERR}"
    # Most scripts resolve the run directory's path (readlink -m), so compare resolved paths.
    case "$(readlink -m "${WORKDIR:-none}")" in
        "$(readlink -m "${STATE}/base")/"*) [ -d "${WORKDIR}" ] && ok "${s}: the run directory is under BASE_DIR" \
                                               || bad "${s}: the run directory exists" "${WORKDIR}" "none" ;;
        *) bad "${s}: the run directory is under BASE_DIR" "${STATE}/base/..." "${WORKDIR:-none}" ;;
    esac
    if [ "$(cat "${WORKDIR}/hostfile" 2>/dev/null)" = "$(printf 'node1\nnode2')" ]; then
        ok "${s}: the host file lists each node once"
    else
        bad "${s}: the host file lists each node once" "node1 node2" "$(tr '\n' ' ' < "${WORKDIR}/hostfile" 2>/dev/null)"
    fi
    cmp -s "$(script_path "${s}")" "${WORKDIR}/$(basename "${s}")" \
        && ok "${s}: the script is copied into the run directory" \
        || bad "${s}: the script is copied into the run directory" "a copy" "none"
    case "${s}" in
        *enchmark*) staged=(sedan_4m.cas.gz sedan_4m.dat.gz) ;;
        *)          staged=(run.jou model.cas.gz model.dat.gz) ;;
    esac
    missing=""
    for f in "${staged[@]}"; do [ -s "${WORKDIR}/${f}" ] || missing="${missing} ${f}"; done
    [ -z "${missing}" ] && ok "${s}: its input is staged in the run directory (${staged[*]})" \
        || bad "${s}: its input is staged in the run directory" "${staged[*]}" "missing:${missing}"
    [ "$(solver_calls)" = "1" ] && ok "${s}: the Ansys program starts once" \
        || bad "${s}: the Ansys program starts once" "1" "$(solver_calls)"
    cwd="$(cat "${STATE}/solver.cwd" "${STATE}/harness.cwd" 2>/dev/null)"
    [ "${cwd}" = "${WORKDIR}" ] && ok "${s}: it runs in the run directory" \
        || bad "${s}: it runs in the run directory" "${WORKDIR}" "${cwd}"
    if [ "${s}" != Arm/Fluent-benchmark.sbatch ]; then
        grep -q '^\[stub ' "${WORKDIR}/output.4242.out" 2>/dev/null \
            && ok "${s}: its output is kept in output.<job>.out" \
            || bad "${s}: its output is kept in output.<job>.out" "the stub's line" \
                   "$(cat "${WORKDIR}/output.4242.out" 2>/dev/null)"
    fi
    [ "$(recorder_calls)" = "1" ] && ok "${s}: the recorder runs once" \
        || bad "${s}: the recorder runs once" "1" "$(recorder_calls)"
    for want in "FLUENT_VERSION=v261" "RUN_DIR=${WORKDIR}"; do
        recorder_has "${want}" && ok "${s}: the recorder gets ${want%%=*}" \
            || bad "${s}: the recorder gets ${want%%=*}" "${want}" "$(tr '\n' '|' < "${STATE}/recorder.log" 2>/dev/null)"
    done
    case "${s}" in
        *enchmark*) want_aws="s3 cp --quiet s3://YOUR_BUCKET/sedan_4m.tar ."; what="for the case's archive only" ;;
        *)          want_aws=""; what="nothing" ;;
    esac
    [ "$(cat "${STATE}/aws.log" 2>/dev/null)" = "${want_aws}" ] && ok "${s}: AWS is asked ${what}" \
        || bad "${s}: AWS is asked ${what}" "${want_aws:-no call}" "$(tr '\n' '|' < "${STATE}/aws.log" 2>/dev/null)"
done

summary "The other launch scripts end to end"
