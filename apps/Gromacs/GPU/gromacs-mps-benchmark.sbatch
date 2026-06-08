#!/bin/bash
# GROMACS NVIDIA MPS GPU-sharing benchmark.
#
# Runs N independent GROMACS simulations CONCURRENTLY on ONE GPU via the NVIDIA
# CUDA Multi-Process Service (MPS), and reports AGGREGATE throughput (the sum of
# the per-simulation ns/day).
#
# Why MPS: a single small/medium GROMACS simulation under-utilizes a modern
# datacenter GPU, so the throughput-optimal way to use the GPU is to pack
# several independent simulations onto it. This is the opposite of trying to
# scale ONE simulation across multiple GPUs, which is communication-bound over
# PCIe and anti-scales for these systems. For ensemble / high-throughput
# workloads (parameter scans, replica ensembles, free-energy windows), MPS is
# the recommended GROMACS-on-GPU pattern.
#
# Validated on AWS g6e (L40S) and g7e (Blackwell RTX PRO 6000), GROMACS v2026.1
# + CUDA 13, against the upstream Zenodo benchmark suite (record 3893789).
#
# Requires:
#   * an MPI-enabled CUDA GROMACS build (gmx_mpi) — MPS shares the GPU across
#     separate OS processes, so each simulation is its own MPI rank
#   * nvidia-cuda-mps-control on the compute node (ships with the CUDA toolkit;
#     on AWS it is present on the GPU DLAMI / ParallelCluster GPU AMIs)
#
# Override via --export=ALL,...:
#   GROMACS_ENV  env script for an MPI-enabled CUDA build (sets PATH to gmx_mpi)
#   TPR          absolute path to the .tpr to run
#   NPROC        number of concurrent sims sharing the GPU (default 4)
#   OMP          OMP threads per sim (default 1 — parallelism is across procs,
#                not threads, under MPS)
#   NSTLIST      neighbour-list rebuild interval (default 150; 100-300 is the
#                GPU sweet spot — fewer rebuilds, larger lists, more GPU work)
#   NSTEPS       steps per sim (default 10000)
#   CUDA_GRAPH   1 to enable GMX_CUDA_GRAPH (helps small systems markedly),
#                default 0
#   GPU_UPDATE   -update target: auto|gpu|cpu (default auto). Systems with 3+
#                consecutively coupled constraints cannot use 'gpu' (GPU LINCS),
#                so 'auto' lets GROMACS pick a valid path per system.
#   BASE_DIR     run-output root (default /fsx/gromacs)
#
# Example (4 villin sims sharing one GPU):
#   sbatch -p g7e --gres=gpu:1 \
#     --export=ALL,GROMACS_ENV=/fsx/gromacs/<build>/gromacs-<tag>-ompi-env.sh,\
# TPR=/fsx/gromacs/benchmarks/villin/villin.tpr,NPROC=4,CUDA_GRAPH=1 \
#     GPU/gromacs-mps-benchmark.sbatch

#SBATCH --job-name=gmx-mps
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=/fsx/gromacs/logs/mps_%j.out
#SBATCH --error=/fsx/gromacs/logs/mps_%j.err

set -uo pipefail

GROMACS_ENV="${GROMACS_ENV:?set GROMACS_ENV to an MPI CUDA build env script}"
TPR="${TPR:?set TPR to a .tpr path}"
NPROC="${NPROC:-4}"
OMP="${OMP:-1}"
NSTLIST="${NSTLIST:-150}"
NSTEPS="${NSTEPS:-10000}"
CUDA_GRAPH="${CUDA_GRAPH:-0}"
GPU_UPDATE="${GPU_UPDATE:-auto}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"

echo "=== GROMACS MPS benchmark $(date) ==="
echo "Host: $(hostname)  NPROC=${NPROC} OMP=${OMP} NSTLIST=${NSTLIST} NSTEPS=${NSTEPS} CUDA_GRAPH=${CUDA_GRAPH}"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

set +u
# shellcheck source=/dev/null
source "${GROMACS_ENV}"
set -u
GMX_MPI="$(command -v gmx_mpi)"
if [ -z "${GMX_MPI}" ]; then
    echo "ERROR: gmx_mpi not found on PATH after sourcing ${GROMACS_ENV}" >&2
    echo "       MPS requires an MPI-enabled CUDA build (separate processes share the GPU)." >&2
    exit 1
fi
echo "gmx_mpi: ${GMX_MPI}"

# --- Start the MPS control daemon on this node (idempotent) ---
export CUDA_MPS_PIPE_DIRECTORY=/tmp/nvidia-mps
export CUDA_MPS_LOG_DIRECTORY=/var/log/nvidia-mps
mkdir -p "${CUDA_MPS_PIPE_DIRECTORY}" /var/log/nvidia-mps 2>/dev/null || sudo mkdir -p /var/log/nvidia-mps
if ! pgrep -x nvidia-cuda-mps-control >/dev/null 2>&1; then
    echo "starting MPS control daemon"
    nvidia-cuda-mps-control -d || sudo nvidia-cuda-mps-control -d || echo "WARN: could not start MPS daemon"
else
    echo "MPS control daemon already running"
fi

# Give each process an equal share of the GPU's SM threads.
export CUDA_MPS_ACTIVE_THREAD_PERCENTAGE=$(( 100 / NPROC ))
echo "CUDA_MPS_ACTIVE_THREAD_PERCENTAGE=${CUDA_MPS_ACTIVE_THREAD_PERCENTAGE}"

export OMP_NUM_THREADS="${OMP}"
[ "${CUDA_GRAPH}" = "1" ] && export GMX_CUDA_GRAPH=1

WORK="${BASE_DIR}/Run/mps/${SLURM_JOB_ID}-$(basename "${TPR}" .tpr)-${NPROC}p-${OMP}t-nstl${NSTLIST}"
mkdir -p "${WORK}"; cd "${WORK}" || { echo "ERROR: cannot cd into ${WORK}" >&2; exit 1; }
echo "Workdir: ${WORK}"

# Launch NPROC independent sims sharing the GPU via MPS. Each is its own
# single-rank mpirun; --bind-to none is critical (NUMA misplacement otherwise
# costs 13-48%). The GMX_CUDA_GRAPH forward is conditional on it being set.
for i in $(seq 1 "${NPROC}"); do
  mkdir -p "run_${i}" && (
    cd "run_${i}" || exit 1
    mpirun -np 1 \
      -x LD_LIBRARY_PATH -x PATH -x GMXLIB \
      -x CUDA_MPS_PIPE_DIRECTORY -x CUDA_MPS_ACTIVE_THREAD_PERCENTAGE \
      -x OMP_NUM_THREADS ${GMX_CUDA_GRAPH:+-x GMX_CUDA_GRAPH} \
      --bind-to none \
      "${GMX_MPI}" mdrun -s "${TPR}" \
      -ntomp "${OMP}" \
      -nb gpu -bonded gpu -update "${GPU_UPDATE}" -pme gpu -notunepme \
      -nsteps "${NSTEPS}" -resethway -noconfout -nstlist "${NSTLIST}" \
      -deffnm md > mdrun.log 2>&1
  ) &
done
wait
echo "=== all ${NPROC} sims finished ==="

# Aggregate throughput = sum of per-process ns/day.
AGG=0; n_ok=0
for i in $(seq 1 "${NPROC}"); do
  ns="$(grep -E '^Performance:' "run_${i}/md.log" 2>/dev/null | tail -1 | awk '{print $2}')"
  if [ -n "${ns}" ]; then
    echo "  run_${i}: ${ns} ns/day"
    AGG="$(awk "BEGIN{print ${AGG} + ${ns}}")"
    n_ok=$((n_ok+1))
  else
    echo "  run_${i}: NO RESULT"
  fi
done

echo ""
echo "================================================================================"
echo "GROMACS MPS result"
echo "  GPU:               ${GPU_NAME}"
echo "  System:            $(basename "${TPR}")"
echo "  Concurrent sims:   ${NPROC} (${n_ok} produced a result)"
echo "  OMP/sim:           ${OMP}   nstlist=${NSTLIST}   cuda_graph=${CUDA_GRAPH}"
echo "  Aggregate ns/day:  ${AGG}"
echo "================================================================================"
# Machine-readable line for sweep collectors:
echo "MPSRESULT gpu='${GPU_NAME}' sys=$(basename "${TPR}" .tpr) nproc=${NPROC} omp=${OMP} nstlist=${NSTLIST} cuda_graph=${CUDA_GRAPH} agg_ns_per_day=${AGG} n_ok=${n_ok}"
