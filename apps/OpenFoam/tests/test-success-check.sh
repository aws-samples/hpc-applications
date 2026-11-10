#!/bin/bash
# =============================================================================
# The check before recording (../README.md, "Benchmark"), each benchmark script
# run end to end with the stubs of stubs.sh: a run is recorded only if
# simpleFoam completed every iteration on every rank. What it pins:
#   * a run that completed is recorded;
#   * a solver log that stops before endTime, one with no End after its last
#     iteration, an empty one, one whose nProcs is not the job's ranks, a FOAM
#     FATAL error in the solver's or another phase's log, or a rank that ended
#     on a signal (Open MPI's and Intel MPI's messages): the run is not
#     recorded, a NOTE says why, and the job still prints its report and ends
#     with exit status 0.
#
#   apps/OpenFoam/tests/test-success-check.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"

# Solver logs, each a script run in place of an application (stubs.sh: STUB_<APPLICATION>). Each reads
# endTime from the run's controlDict, and the number of ranks from its processor directories.
mkdir -p "${STUBS}/logs"
log_head='end="$(awk '"'"'/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}'"'"' system/controlDict)"
np="$(find . -maxdepth 1 -type d -name "processor*" | wc -l)"'
write_log() {  # write_log <name> <body>
    printf '#!/bin/bash\n%s\n%s\n' "${log_head}" "$2" > "${STUBS}/logs/$1"
}
write_log short   'echo "nProcs : ${np}"; echo "Time = 1"; echo "Time = $((end - 1))"; echo "End"'
write_log no-end  'echo "nProcs : ${np}"; echo "Time = 1"; echo "Time = ${end}"'
write_log empty   ':'
write_log nprocs  'echo "nProcs : $((np - 1))"; echo "Time = 1"; echo "Time = ${end}"; echo "End"'
write_log fatal   'echo "nProcs : ${np}"; echo "Time = 1"; echo "Time = ${end}"; echo "--> FOAM FATAL ERROR: (openfoam-2512)"; echo "End"'
write_log fatal-potential 'echo "--> FOAM FATAL IO ERROR: (openfoam-2512)"; echo "End"'
write_log signal-ompi 'echo "nProcs : ${np}"; echo "Time = 1"; echo "Time = ${end}"; echo "End"
echo "mpirun noticed that process rank 3 with PID 0 on node node2 exited on"
echo "signal 9 (Killed)."'
write_log signal-intel 'echo "nProcs : ${np}"; echo "Time = 1"; echo "Time = ${end}"; echo "End"
echo "=   BAD TERMINATION OF ONE OF YOUR APPLICATION PROCESSES"
echo "=   KILLED BY SIGNAL: 9 (Killed)"'

end_of() { awk '/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}' "$1/system/controlDict" 2>/dev/null; }
# not_recorded <label> <job> <reasons>: exit 0, the report printed, the recorder not called, and the NOTE.
not_recorded() {
    check "$1: completes (exit 0)" 0 "${RC}"
    if grep -qE '^simpleFoam: +[0-9.]+s$' <<<"${OUT}"; then ok "$1: the report is printed"
    else bad "$1: the report is printed" "simpleFoam: <n>s" "none"; fi
    check "$1: the recorder is not called" 0 "$(recorder_calls "$2")"
    has "$1: NOTE" "NOTE: the run is not recorded: $3."
}

job=400
for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    if skip_arm_here "${s}"; then
        skipt "${s}" "this host has a module system, which the Arm launcher loads, and which could put a real MPI first in PATH"
        continue
    fi

    job=$((job + 1)); run_script "${s}" "${job}"
    completes "a run that completed" "${job}"
    check "a run that completed: recorded once" 1 "$(recorder_calls "${job}")"

    job=$((job + 1)); run_script "${s}" "${job}" STUB_SIMPLEFOAM="${STUBS}/logs/short"
    end="$(end_of "${RUN}")"
    not_recorded "a solver log that stops before endTime" "${job}" "its last Time = is $((end - 1)), not endTime ${end}"

    job=$((job + 1)); run_script "${s}" "${job}" STUB_SIMPLEFOAM="${STUBS}/logs/no-end"
    not_recorded "no End after the last iteration" "${job}" "log.solver has no End after its last Time ="

    job=$((job + 1)); run_script "${s}" "${job}" STUB_SIMPLEFOAM="${STUBS}/logs/empty"
    not_recorded "an empty solver log" "${job}" \
        "log.solver has no End after its last Time =; its last Time = is missing, not endTime $(end_of "${RUN}"); its nProcs is missing, not the 8 ranks of this job"

    job=$((job + 1)); run_script "${s}" "${job}" STUB_SIMPLEFOAM="${STUBS}/logs/nprocs"
    not_recorded "nProcs is not the job's ranks" "${job}" "its nProcs is 7, not the 8 ranks of this job"

    job=$((job + 1)); run_script "${s}" "${job}" STUB_SIMPLEFOAM="${STUBS}/logs/fatal"
    not_recorded "a FOAM FATAL error in log.solver" "${job}" "a log reports a FOAM FATAL error"

    job=$((job + 1)); run_script "${s}" "${job}" STUB_POTENTIALFOAM="${STUBS}/logs/fatal-potential"
    not_recorded "a FOAM FATAL error in log.potential" "${job}" "a log reports a FOAM FATAL error"

    job=$((job + 1)); run_script "${s}" "${job}" STUB_SIMPLEFOAM="${STUBS}/logs/signal-ompi"
    not_recorded "a rank ended on a signal (Open MPI)" "${job}" "a log reports a rank that ended on a signal"

    job=$((job + 1)); run_script "${s}" "${job}" STUB_SIMPLEFOAM="${STUBS}/logs/signal-intel"
    not_recorded "a rank ended on a signal (Intel MPI)" "${job}" "a log reports a rank that ended on a signal"
done

finish "success check"
