#!/bin/bash
# =============================================================================
# Shared by the tests of the Fluent launch scripts other than
# x86/Fluent-Benchmark.2026R1.sbatch: source it.
# =============================================================================
# It sources helpers-2026r1.sh, for the PASS/FAIL counters and its stubs of
# curl, lscpu, scontrol, srun, mpirun, module and sudo, and adds, first on the
# PATH:
#   aws       `aws s3 cp [--quiet] s3://<bucket>/<name> <dest>` copies
#             STUB_S3_DIR/<name> (the case's archive) to <dest>; every call is
#             logged, and any other call is refused, so that no test can reach
#             AWS
#   recorder-stub
#             logs its arguments and the variables the scripts pass
# and stubs of the Ansys programs the scripts start, in one install tree,
# ${WORK}/ansys/ansys_inc/<version> (v242 and v261):
#   fluentbench.pl  the classic benchmark harness, started as
#             fluentbench.pl <case> -t<cores> <options>: records its arguments
#             and working directory, writes STUB_OUT where fluentbench.pl
#             writes its output of the case and core count, <case>-<cores>.out
#             (STUB_OUT_NAME names it otherwise), and STUB_SESSION_TRN where
#             Fluent writes its own session transcript,
#             fluent-20261026-120000-1000.trn, prints STUB_STDOUT, and exits
#             with STUB_RC
#   fluent    Fluent itself, which the journal scripts start: records its
#             arguments and working directory, writes STUB_SESSION_TRN as
#             its own session transcript, fluent-20261026-120000-1000.trn,
#             prints a line, and exits with STUB_FLUENT_RC
#   python    Fluent's bundled Python, with the 2026 R1 harness: the stub of
#             helpers-2026r1.sh, which writes STUB_TRANSCRIPT where the harness
#             writes its transcript of the case and core count
# The Arm scripts name their install as /fsx/ansys_inc, so they run from a copy
# that names the stub tree instead and differs from the script in that line
# alone (checked here).
#
# run_launcher runs a script ASSEMBLED, in an empty environment (env -i), as a
# 2-node job of 384 ranks on hpc8a.96xlarge: a benchmark script with the
# synthetic case sedan_4m (STUB_S3_DIR/sedan_4m.tar), a journal script with a
# synthetic journal, case and data file.
#
# No Slurm, no EC2, no Fluent, no MPI, no AWS credentials, no network: the
# stubs run nothing on the host, HOME is a temporary directory, and every
# value in the fixtures is synthetic.
# =============================================================================
# shellcheck source=helpers-2026r1.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-2026r1.sh"

mkdir -p "${WORK}/lbin" "${WORK}/arm" "${WORK}/s3" "${WORK}/case"

cat > "${WORK}/lbin/aws" <<'EOF'
#!/bin/bash
# `aws s3 cp [--quiet] s3://<bucket>/<name> <dest>`: copies STUB_S3_DIR/<name>,
# the case's archive, to <dest>. Every call is logged to aws.log; any other
# call is refused, so that no test can reach AWS.
printf '%s\n' "$*" >> "${STUB_STATE}/aws.log"
if [ "${1:-}" = s3 ] && [ "${2:-}" = cp ]; then
    shift 2
    [ "${1:-}" = --quiet ] && shift
    case "${1:-}" in
        s3://*) [ -f "${STUB_S3_DIR}/${1##*/}" ] && exec cp "${STUB_S3_DIR}/${1##*/}" "${2:-.}" ;;
    esac
fi
echo "aws stub: refused" >&2
exit 1
EOF
cat > "${WORK}/lbin/recorder-stub" <<'EOF'
#!/bin/bash
# Logs how the script called the recorder: each argument, then the variables it passes.
{
    echo "CALL"
    for a in "$@"; do echo "ARG ${a}"; done
    for v in FLUENT_VERSION RUN_DIR BENCHMARK_CASE BENCHMARK_METHOD SOLVER_MODE NUM_ITERATIONS MIUPS SOLVER_RATING \
             TIME_PER_ITERATION SOLVER_SPEED TRANSCRIPT; do
        echo "${v}=${!v-}"
    done
} >> "${STUB_STATE}/recorder.log"
echo "[stub recorder] called"
exit 0
EOF

ANSYS_STUB="${WORK}/ansys/ansys_inc"
for v in v242 v261; do
    mkdir -p "${ANSYS_STUB}/${v}/fluent/bin" "${ANSYS_STUB}/${v}/commonfiles/CPython/3_10/linx64/Release/python/bin"
    cat > "${ANSYS_STUB}/${v}/fluent/bin/fluentbench.pl" <<'EOF'
#!/bin/bash
# fluentbench.pl <case> -t<cores> <options>: records its arguments and working
# directory, writes STUB_OUT as its output of the case and core count,
# <case>-<cores>.out (STUB_OUT_NAME names it otherwise), and STUB_SESSION_TRN
# as Fluent's own session transcript, fluent-20261026-120000-1000.trn, prints
# STUB_STDOUT, and exits with STUB_RC.
echo "CALL" >> "${STUB_STATE}/solver.calls"
printf '%s\n' "$0" "$@" > "${STUB_STATE}/solver.args"
pwd > "${STUB_STATE}/solver.cwd"
case_name="${1:-}"; cores=""
for a in "$@"; do case "${a}" in -t[0-9]*) cores="${a#-t}" ;; esac; done
[ -n "${STUB_OUT:-}" ] && cp "${STUB_OUT}" "${STUB_OUT_NAME:-${case_name}-${cores}.out}"
[ -n "${STUB_SESSION_TRN:-}" ] && cp "${STUB_SESSION_TRN}" fluent-20261026-120000-1000.trn
[ -n "${STUB_STDOUT:-}" ] && cat "${STUB_STDOUT}"
echo "[stub fluentbench.pl] ${case_name} on ${cores} cores"
exit "${STUB_RC:-0}"
EOF
    cat > "${ANSYS_STUB}/${v}/fluent/bin/fluent" <<'EOF'
#!/bin/bash
# Fluent, as the journal scripts start it: records its arguments and working
# directory, writes STUB_SESSION_TRN as its own session transcript,
# fluent-20261026-120000-1000.trn, prints a line, and exits with STUB_FLUENT_RC.
echo "CALL" >> "${STUB_STATE}/solver.calls"
printf '%s\n' "$0" "$@" > "${STUB_STATE}/solver.args"
pwd > "${STUB_STATE}/solver.cwd"
[ -n "${STUB_SESSION_TRN:-}" ] && cp "${STUB_SESSION_TRN}" fluent-20261026-120000-1000.trn
echo "[stub fluent] $*"
exit "${STUB_FLUENT_RC:-0}"
EOF
    cp "${WORK}/bin/harness-python" "${ANSYS_STUB}/${v}/commonfiles/CPython/3_10/linx64/Release/python/bin/python"
done
chmod +x "${WORK}"/lbin/* "${ANSYS_STUB}"/*/fluent/bin/* "${ANSYS_STUB}"/*/commonfiles/CPython/3_10/linx64/Release/python/bin/python

# The Arm scripts' copies, which name the stub tree instead of /fsx/ansys_inc.
for s in Fluent-benchmark.sbatch Fluent.sbatch; do
    sed "s|/fsx/ansys_inc/|${WORK}/ansys/ansys_inc/|g" "${FLUENT_APP}/Arm/${s}" > "${WORK}/arm/${s}"
    if [ "$(diff "${FLUENT_APP}/Arm/${s}" "${WORK}/arm/${s}" | grep -c '^>')" != 1 ]; then
        echo "ERROR: the test copy of Arm/${s} must differ from the script in its install path alone" >&2
        exit 1
    fi
done

# The synthetic case, as Ansys's archives lay it out, and a journal with its case and data.
mkdir -p "${WORK}/dataset/bench/fluent/v6/sedan_4m/cas_dat"
echo "synthetic case" > "${WORK}/dataset/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m.cas.gz"
echo "synthetic data" > "${WORK}/dataset/bench/fluent/v6/sedan_4m/cas_dat/sedan_4m.dat.gz"
tar cf "${WORK}/s3/sedan_4m.tar" -C "${WORK}/dataset" bench
printf '; synthetic journal\n/solve/iterate 2\nexit yes\n' > "${WORK}/case/run.jou"
echo "synthetic case" > "${WORK}/case/model.cas.gz"
echo "synthetic data" > "${WORK}/case/model.dat.gz"

# The launch scripts these tests run, from apps/Fluent (the test files read these lists).
# shellcheck disable=SC2034
BENCHMARK_SCRIPTS=(x86/Fluent-Benchmark.IMPI.sbatch x86/Fluent-Benchmark.OMPI.sbatch Arm/Fluent-benchmark.sbatch)
# shellcheck disable=SC2034
GPU_BENCHMARK_SCRIPT=gpu/Fluent-Benchmark-GPU.sbatch
# shellcheck disable=SC2034
JOURNAL_SCRIPTS=(x86/Fluent.IMPI.sbatch x86/Fluent.OMPI.sbatch Arm/Fluent.sbatch
                 gpu/Fluent-GPU.sbatch gpu/Fluent-GPU.OMPI.sbatch)

# script_path <script, from apps/Fluent>: the file run_launcher runs
script_path() {
    case "$1" in
        Arm/*) echo "${WORK}/arm/${1#Arm/}" ;;
        *)     echo "${FLUENT_APP}/$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# run_launcher <script, from apps/Fluent> <name> [VAR=value ...]
# Runs the script from a new directory as a 2-node job of 384 ranks on
# hpc8a.96xlarge. A benchmark script gets version v261 and the case
# s3://YOUR_BUCKET/sedan_4m.tar (BENCHMARK_NAME=sedan_4m), which the aws stub
# serves from STUB_S3_DIR; fluentbench.pl writes fixtures/fluentbench-rated.out
# and the 2026 R1 harness fixtures/steady-25-iterations.trn. A journal script
# gets version v261 and a synthetic journal, case and data file; Fluent exits
# 0. The recorder is the recorder stub. Each VAR=value replaces one of these
# settings or adds a variable. RUN_URI, when set, replaces the benchmark
# script's second argument, the case's archive.
# Sets OUT and ERR (the job's output and error streams), RC (its exit status),
# STATE (the case's directory, with the stubs' logs) and WORKDIR (the run
# directory the job printed).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # the test files read RC, ERR and WORKDIR
run_launcher() {
    local script="$1" name="$2" args
    shift 2
    STATE="${WORK}/${name}"
    mkdir -p "${STATE}/home" "${STATE}/base" "${STATE}/submit"
    ln -sfn "${ANSYS_STUB}" "${STATE}/base/ansys_inc"   # the GPU scripts' install root is BASE_DIR
    case "${script}" in
        *enchmark*) args=(v261 "${RUN_URI:-s3://YOUR_BUCKET/sedan_4m.tar}") ;;
        *)          args=(v261 "${WORK}/case/run.jou" "${WORK}/case/model.cas.gz" "${WORK}/case/model.dat.gz") ;;
    esac
    OUT="$(cd "${STATE}" && env -i \
        PATH="${WORK}/lbin:${WORK}/bin:/usr/bin:/bin" HOME="${STATE}/home" LANG=C \
        STUB_STATE="${STATE}" STUB_INSTANCE_TYPE=hpc8a.96xlarge STUB_NODES="node1 node2" \
        STUB_S3_DIR="${WORK}/s3" STUB_OUT="${FIX}/fluentbench-rated.out" \
        STUB_TRANSCRIPT="${FIX}/steady-25-iterations.trn" \
        BASE_DIR="${STATE}/base" ANSYS_ROOT="${WORK}/ansys" \
        DYNAMODB_RECORDER="${WORK}/lbin/recorder-stub" BENCHMARK_NAME=sedan_4m \
        SLURM_JOB_NAME=fluent-e2e.sbatch SLURM_JOB_ID=4242 SLURM_JOBID=4242 \
        SLURM_JOB_NUM_NODES=2 SLURM_NPROCS=384 SLURM_NTASKS=384 SLURM_NTASKS_PER_NODE=192 \
        SLURM_NODELIST='node[1-2]' SLURM_SUBMIT_DIR="${STATE}/submit" \
        "$@" \
        bash "$(script_path "${script}")" "${args[@]}" 2> "${STATE}/stderr")"
    RC=$?
    ERR="$(cat "${STATE}/stderr")"
    WORKDIR="$(printf '%s\n' "${OUT}" | sed -n 's/^Execution directory is: //p')"
}

# solver_calls: how many times the Ansys program (fluentbench.pl, fluent or the
# 2026 R1 harness) was started in the last run
solver_calls() {
    local n=0
    [ -f "${STATE}/solver.calls" ] && n=$(grep -c '^CALL$' "${STATE}/solver.calls")
    [ -f "${STATE}/harness.args" ] && n=$((n + 1))
    echo "${n}"
}
