# shellcheck shell=bash
# shellcheck disable=SC2034  # OUT, RC, RUN, CASE and the script lists are read by the tests that source this file
# =============================================================================
# Shared by the tests in this directory (source it from a test): stubs for the
# commands the OpenFOAM benchmark scripts launch, a tiny case laid out like OCC
# DrivAer's, run_script, which runs one benchmark script with them, and the
# check helpers.
#
# No Slurm, no EC2, no OpenFOAM, no MPI, no AWS credentials, no network. The
# stubs never run a command on the host: the cache drops and THP settings the
# scripts launch through mpirun and srun are swallowed, sudo does nothing, and
# the aws and download stubs refuse every call.
#
# The stubs, and what a test can set for one run (run_script passes NAME=value
# pairs into the script's environment):
#   curl          IMDS: a token, and the instance type STUB_INSTANCE_TYPE
#                 (stub.96xlarge if unset; set but empty, IMDS gives none). Any
#                 other URL (a case or mesh download) is refused.
#   scontrol      two node records. srun and sudo do nothing; aws refuses.
#   decomposePar  writes the processor directories system/decomposeParDict
#                 asks for, and logs the call to DECOMPOSE_LOG.
#   mpirun        logs each launch to MPIRUN_LOG (job, application, arguments,
#                 I_MPI_PIN_PROCESSOR_LIST), then runs it: renumberMesh marks
#                 each processor mesh, potentialFoam prints End, and simpleFoam
#                 prints a solver log that ends at endTime of system/controlDict.
#                 STUB_RENUMBERMESH, STUB_POTENTIALFOAM or STUB_SIMPLEFOAM, when
#                 set, is a script run in place of that application, whose exit
#                 status mpirun returns.
#   recorder      logs what it was given to RECORDER_LOG, and exits with
#                 STUB_RECORDER_EXIT (0 if unset).
# =============================================================================
OF_APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(x86/openfoam-benchmark-openmpi.sbatch
         x86/openfoam-benchmark-intelmpi.sbatch
         Arm/openfoam-benchmark.sbatch)
pass=0; fail=0; skip=0

STUBS="$(mktemp -d)"
trap 'chmod -R u+w "${STUBS}" 2>/dev/null; rm -rf "${STUBS}"' EXIT

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "${STUBS}/bin" "${STUBS}/ompi5/bin" "${STUBS}/empty/submit"
cat > "${STUBS}/bin/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *api/token*)     echo "stub-token";;
  *instance-type*) echo "${STUB_INSTANCE_TYPE-stub.96xlarge}";;
  *) echo "curl stub: refusing $*" >&2; exit 22;;
esac
EOF
cat > "${STUBS}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show nodes <list>: two node records, as Slurm prints them.
for n in node1 node2; do
  echo "NodeName=${n} Arch=x86_64 CoresPerSocket=2"
  echo "   NodeAddr=${n} NodeHostName=${n} Version=25.05.0"
done
EOF
printf '#!/bin/bash\nexit 0\n' > "${STUBS}/bin/srun"
printf '#!/bin/bash\nexit 0\n' > "${STUBS}/bin/sudo"
cat > "${STUBS}/bin/aws" <<'EOF'
#!/bin/bash
echo "aws stub: refusing to call AWS from a test" >&2
exit 1
EOF
cat > "${STUBS}/bin/decomposePar" <<'EOF'
#!/bin/bash
# processor0..N-1 (N from system/decomposeParDict), each with a mesh file
# naming the job that decomposed it.
n=$(awk '/^numberOfSubdomains/ {gsub(";", "", $2); print $2}' system/decomposeParDict)
for ((i = 0; i < n; i++)); do
  mkdir -p "processor${i}/constant/polyMesh" "processor${i}/0"
  echo "decomposed by job ${SLURM_JOB_ID}" > "processor${i}/constant/polyMesh/owner"
  echo "U" > "processor${i}/0/U"
done
echo "job=${SLURM_JOB_ID} subdomains=${n}" >> "${DECOMPOSE_LOG}"
echo "End"
EOF
cat > "${STUBS}/bin/mpirun" <<'EOF'
#!/bin/bash
app=""; np=""; prev=""
for a in "$@"; do
  case "$a" in
    --version) echo "mpirun (Open MPI) 5.0.9"; exit 0;;
    renumberMesh|potentialFoam|simpleFoam) app="$a"; break;;
  esac
  [ "${prev}" = "-np" ] && np="$a"
  prev="$a"
done
if [ -n "${MPIRUN_LOG:-}" ]; then
  printf '%s\t%s\t%s\t%s\n' "${SLURM_JOB_ID:-}" "${app:--}" "$*" "${I_MPI_PIN_PROCESSOR_LIST-<unset>}" >> "${MPIRUN_LOG}"
fi
[ -n "${app}" ] || exit 0   # the cache drop and THP settings: swallowed
hook="STUB_$(printf '%s' "${app}" | tr '[:lower:]' '[:upper:]')"
if [ -n "${!hook:-}" ]; then
  bash "${!hook}"
  exit $?
fi
case "${app}" in
  renumberMesh)
    # -overwrite: renumber the decomposed mesh in place.
    for d in processor*/constant/polyMesh; do
      [ -d "${d}" ] && echo "renumbered" >> "${d}/owner"
    done
    echo "End";;
  potentialFoam) echo "End";;
  simpleFoam)
    end=$(awk '/^[[:space:]]*endTime[[:space:]]/ {gsub(";", "", $2); print $2; exit}' system/controlDict)
    echo "nProcs : ${np}"
    for t in 1 "${end}"; do
      echo "Time = ${t}"
      echo "ExecutionTime = 0.${t} s  ClockTime = 1 s"
    done
    echo "End"
    echo "Finalising parallel run";;
esac
exit 0
EOF
cat > "${STUBS}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
printf 'job=%s\tBENCHMARK_CASE=%s\tMESH_CELLS_MILLION=%s\tTIME_TO_SOLUTION=%s\targs=%s\n' \
  "${SLURM_JOB_ID:-}" "${BENCHMARK_CASE-}" "${MESH_CELLS_MILLION-}" "${TIME_TO_SOLUTION-}" "$*" >> "${RECORDER_LOG}"
exit "${STUB_RECORDER_EXIT:-0}"
EOF
chmod +x "${STUBS}"/bin/*
ln -s ../../bin/mpirun "${STUBS}/ompi5/bin/mpirun"   # the Arm launcher puts ${MPI_ROOT}/bin first in PATH
: > "${STUBS}/openfoam-env.sh"

# make_case <dir> [<note>]: a tiny case laid out like OCC DrivAer's. Its
# controlDict runs 4,000 iterations, as the case ships; its owner file's header
# carries the note OpenFOAM writes there (by default the 236M mesh's cell
# count), or none if <note> is empty.
make_case() {
    local dir="$1" note="${2-nPoints:12  nCells:235741179  nFaces:30  nInternalFaces:10}" f
    mkdir -p "${dir}/system" "${dir}/constant/polyMesh" "${dir}/0.orig"
    printf 'application       simpleFoam;\nstartTime         0;\nendTime           4000;\ndeltaT            1;\n#include "FOwallClockTimeStatistics"\n' \
        > "${dir}/system/controlDict"
    for f in points faces neighbour boundary; do echo "${f}" > "${dir}/constant/polyMesh/${f}"; done
    {
        printf 'FoamFile\n{\n    format      binary;\n'
        if [ -n "${note}" ]; then printf '    note        "%s";\n' "${note}"; fi
        printf '    class       labelList;\n    object      owner;\n}\n3\n(0 0 1)\n'
    } > "${dir}/constant/polyMesh/owner"
    echo "nu 1.5e-05;" > "${dir}/constant/transportProperties"
    for f in U p k omega nut; do echo "${f}" > "${dir}/0.orig/${f}"; done
}
# The default case, under the default CASE_SRC's name.
CASE="${STUBS}/occ-drivaer/occDrivAerStaticMesh"
make_case "${CASE}"

# ---------------------------------------------------------------------------
# run_script <script> <job id> [NAME=value...]: run one benchmark script in a
# clean environment on 2 nodes x 4 ranks, from its own directory; NAME=value
# pairs override the defaults. Sets OUT (stdout and stderr), RC and RUN (the
# run directory, empty if none was made).
# ---------------------------------------------------------------------------
run_script() {
    local script="$1" job="$2"; shift 2
    OUT="$(cd "${STUBS}" && env -i \
        PATH="${STUBS}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${STUBS}" LANG=C \
        OPENFOAM_ENV="${STUBS}/openfoam-env.sh" CASE_SRC="${CASE}" BASE_DIR="${STUBS}/runs" \
        DECOMPOSE_LOG="${STUBS}/decompose.log" MPIRUN_LOG="${STUBS}/mpirun.log" \
        RECORDER_LOG="${STUBS}/recorder.log" DYNAMODB_RECORDER="${STUBS}/bin/recorder-stub.sh" \
        I_MPI_ROOT="${STUBS}/intelmpi" MPI_ROOT="${STUBS}/ompi5" \
        SLURM_JOB_ID="${job}" SLURM_JOB_NAME="$(basename "${script}")" SLURM_CLUSTER_NAME=test \
        SLURM_JOB_NUM_NODES=2 SLURM_NTASKS_PER_NODE=4 SLURM_NODELIST="node[1-2]" \
        SLURM_SUBMIT_DIR="${OF_APP}/$(dirname "${script}")" \
        "$@" \
        bash "${OF_APP}/${script}" 2>&1)"
    RC=$?
    RUN="$(sed -n 's/^Execution directory: //p' <<<"${OUT}" | head -1)"
}
# skip_arm_here <script>: true for the Arm launcher on a host with a module
# system, which the launcher loads and which could put a real MPI first in PATH.
skip_arm_here() {
    [ "${1#Arm/}" != "$1" ] && { [ -e /etc/profile.d/modules.sh ] || [ -e /usr/share/Modules/init/bash ]; }
}

# ---------------------------------------------------------------------------
# What the stubs logged for one job
# ---------------------------------------------------------------------------
touch "${STUBS}/decompose.log" "${STUBS}/mpirun.log" "${STUBS}/recorder.log"
decompositions() {  # decompositions <job>: how many times decomposePar ran
    awk -v j="job=$1" '$1 == j {n++} END {print n + 0}' "${STUBS}/decompose.log"
}
launches() {  # launches <job> <application>: how many times mpirun launched it
    awk -F'\t' -v j="$1" -v a="$2" '$1 == j && $2 == a {n++} END {print n + 0}' "${STUBS}/mpirun.log"
}
launch_field() {  # launch_field <job> <application> <3: arguments | 4: I_MPI_PIN_PROCESSOR_LIST>, last launch
    awk -F'\t' -v j="$1" -v a="$2" -v f="$3" '$1 == j && $2 == a {v = $f} END {print v}' "${STUBS}/mpirun.log"
}
recorded() {  # recorded <job> <field>: what the recorder was given (empty if it was not called)
    awk -F'\t' -v j="job=$1" -v f="$2=" \
        '$1 == j {for (i = 2; i <= NF; i++) if (index($i, f) == 1) v = substr($i, length(f) + 1)} END {print v}' \
        "${STUBS}/recorder.log"
}
recorder_calls() {  # recorder_calls <job>
    awk -F'\t' -v j="job=$1" '$1 == j {n++} END {print n + 0}' "${STUBS}/recorder.log"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }
check() {  # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}
has() {  # has <label> <exact line>: the output holds that line
    if grep -qxF -- "$2" <<<"${OUT}"; then ok "$1"
    else bad "$1" "$2" "$(grep -E '^(Decompos|NOTE|ERROR|Reusing)' <<<"${OUT}" | head -6 | tr '\n' '|')"; fi
}
# completes <label> <job>: exit 0, the decomposition time reported, and the
# recorder given the report's simpleFoam time.
completes() {
    local solve rec
    check "$1: completes (exit 0)" 0 "${RC}"
    if grep -q '^Decomposition time: [0-9.]*s$' <<<"${OUT}"; then ok "$1: decomposition time reported"
    else bad "$1: decomposition time reported" "Decomposition time: <n>s" "$(grep '^Decomposition' <<<"${OUT}" | tr '\n' '|')"; fi
    solve="$(sed -n 's/^simpleFoam: *\([0-9.]*\)s$/\1/p' <<<"${OUT}")"
    rec="$(recorded "$2" TIME_TO_SOLUTION)"
    if [ -n "${solve}" ] && [ "${solve}" = "${rec}" ]; then ok "$1: the recorder gets the simpleFoam time"
    else bad "$1: the recorder gets the simpleFoam time" "TIME_TO_SOLUTION=${solve:-<report value>}" "${rec:-none}"; fi
}
# finish <suite>: print the counts; non-zero status if a check failed.
finish() {
    printf '%s: %d passed, %d failed, %d skipped\n' "$1" "${pass}" "${fail}" "${skip}"
    [ "${fail}" -eq 0 ]
}
