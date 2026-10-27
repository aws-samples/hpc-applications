#!/bin/bash
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=192
#SBATCH --constraint=hpc7a.24xlarge
#SBATCH --partition=hpc7a
#SBATCH --chdir=/fsx/slurm-out/cfx

######################## EFA settings ######################## 
#export I_MPI_DEBUG=5
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_MULTIRAIL=1
export I_MPI_ADJUST_REDUCE=2 
export I_MPI_ADJUST_ALLREDUCE=2
export I_MPI_ADJUST_BCAST=1
######################## EFA settings ######################## 

cfxversion=${cfxversion:-"v242"}
def_file=${def_file:-"/fsx/CFX/Dataset/perf_Airfoil_100M_R16.def"}
basedir=${basedir:-"/fsx"}

CFX_DIR="/fsx/ansys_inc/${cfxversion}/CFX/bin"

export ANSYSLMD_LICENSE_FILE=${ANSYSLMD_LICENSE_FILE:-"1055@172.31.89.151"}

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
workdir="$(readlink -m "${basedir}/${SLURM_JOB_NAME%.*}")/Run/${SLURM_JOB_ID}-${SLURM_JOB_NUM_NODES}x$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)-${SLURM_NPROCS}-$(date "+%d-%m-%Y-%H-%M")"

echo "Execution directory is: ${workdir}"
mkdir -p "${workdir}" && cd "${workdir}"

echo "building the MPI hostfile"
HOST_LIST=$(scontrol show hostname $SLURM_NODELIST)

cp $0 .
ln -s "${def_file}" .

_rec_t0="$(date +%s)"
"${CFX_DIR}/cfx5solve" -batch -def $def_file -parallel -start-method 'Intel MPI Distributed Parallel' -par-dist "$HOST_LIST" -part $SLURM_NPROCS -part-large

# ---------------------------------------------------------------------------
# Record this benchmark to the AI-Powered HPC dataset (best-effort, non-fatal).
# The recorder self-collects host details from the environment; this launch
# script times the solve (wall clock) and passes it, so no arguments are
# needed. Only a SUCCESSFUL solve is recorded, and the job's exit status is
# preserved (a recorder problem never changes it). Point DYNAMODB_RECORDER at
# the script if it isn't found automatically; set SOURCE=<YourOrg> to tag your
# contributions. See apps/CFX/dynamodb/README.md and apps/BENCHMARK-RECORDERS.md.
# ---------------------------------------------------------------------------
_rec_rc=$?
_rec_secs=$(( $(date +%s) - ${_rec_t0:-$(date +%s)} ))
[ "${_rec_secs}" -gt 0 ] 2>/dev/null || _rec_secs=""

# ---------------------------------------------------------------------------
# The time of the iterations. The wall clock above also covers partitioning
# and cfx5solve's own start-up and wrap-up, which do not get faster with more
# cores. The solver writes its output file (<case>_NNN.out) to this directory,
# with the iterations' own time on its "CFD Solver wall clock seconds:" line
# and one "OUTER LOOP ITERATION =" line per iteration of a steady-state run:
# compare node counts on these. The record's time_to_solution_seconds stays
# the wall clock. N/A when there is no output file, or no number on that line.
# ---------------------------------------------------------------------------
_iter_out=""
for _f in "${workdir}/$(basename "${def_file}" .def)"_[0-9][0-9][0-9].out; do
    [ -f "${_f}" ] && _iter_out="${_f}"    # the glob sorts: the last is the newest run
done
if [ -n "${_iter_out}" ]; then
    CFX_OUTPUT_NAME="${_iter_out##*/}" LC_ALL=C awk '
        /CFD Solver wall clock seconds:/ {
            v = $NF; sub(/\r$/, "", v)
            if (v ~ /^[0-9]+(\.[0-9]*)?([Ee][-+]?[0-9]+)?$/) { t = v + 0; have = 1 }
        }
        /OUTER LOOP ITERATION =/         { n++ }
        END {
            f = ENVIRON["CFX_OUTPUT_NAME"]
            if (have) printf "Iteration time: %.2f s (CFD Solver wall clock seconds, %s)\n", t, f
            else      printf "Iteration time: N/A (no CFD Solver wall clock seconds value in %s)\n", f
            if (have && n > 0) printf "Time per iteration: %.3f s (%d outer loop iteration%s)\n", t / n, n, (n == 1 ? "" : "s")
            else if (have)     printf "Time per iteration: N/A (no outer loop iterations in %s)\n", f
            else               print "Time per iteration: N/A"
        }' "${_iter_out}" \
        || printf 'Iteration time: N/A (cannot read %s)\nTime per iteration: N/A\n' "${_iter_out##*/}"
else
    echo "Iteration time: N/A (no $(basename "${def_file}" .def)_NNN.out in ${workdir})"
    echo "Time per iteration: N/A"
fi

_recorder="${DYNAMODB_RECORDER:-}"
for _c in "${_recorder}" \
          "${SLURM_SUBMIT_DIR:-.}/dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/../dynamodb/record-benchmark.sh" \
          "${SLURM_SUBMIT_DIR:-.}/apps/CFX/dynamodb/record-benchmark.sh"; do
    if [ -n "${_c}" ] && [ -x "${_c}" ]; then _recorder="${_c}"; break; fi
done

# ---------------------------------------------------------------------------
# Only a run that ended normally is recorded: cfx5solve exited 0, and the
# output file read above holds a number on its "CFD Solver wall clock
# seconds:" line, which the solver run prints at its end. Without that value
# the run is not recorded, whatever cfx5solve exited with.
# ---------------------------------------------------------------------------
_rec_ok=""
if [ -n "${_iter_out}" ] && LC_ALL=C awk '
        /CFD Solver wall clock seconds:/ {
            v = $NF; sub(/\r$/, "", v)
            if (v ~ /^[0-9]+(\.[0-9]*)?([Ee][-+]?[0-9]+)?$/) have = 1
        }
        END { exit !have }' "${_iter_out}" 2>/dev/null; then
    _rec_ok=1
fi
if [ "${_rec_rc}" -eq 0 ] && [ -n "${_rec_ok}" ] && [ -n "${_recorder}" ] && [ -x "${_recorder}" ]; then
    CFX_VERSION="${cfxversion}" BENCHMARK_CASE="$(basename "${def_file}" .def)" \
    TIME_TO_SOLUTION="${_rec_secs}" RUN_DIR="${workdir}" "${_recorder}" \
        || echo "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected." >&2
elif [ "${_rec_rc}" -ne 0 ]; then
    echo "NOTE: solver exited ${_rec_rc}; skipping benchmark recording." >&2
elif [ -z "${_rec_ok}" ]; then
    echo "NOTE: no CFD Solver wall clock seconds value was read from the solver's output file; skipping benchmark recording." >&2
else
    echo "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record." >&2
fi
exit ${_rec_rc}
