#!/bin/bash
#SBATCH --job-name=ior
#SBATCH --constraint=hpc8a.96xlarge
#SBATCH --partition=hpc8a
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --output=ior-%j.out
#
# Parametric IOR launcher for parallel-filesystem (Amazon FSx for Lustre)
# throughput benchmarking. One script for all configurations — everything is
# controlled via environment variables with sensible defaults.
#
# IOR writes then reads a dataset across all MPI ranks and reports the
# AGGREGATE bandwidth (MiB/s) and IOPS. Two access patterns are supported:
#   * file-per-process (fpp, default) — each rank uses its own file; the
#     highest-throughput pattern and the easiest for Lustre to stripe.
#   * single-shared-file (ssf)        — all ranks share one file; stresses
#     shared-file locking and OST striping.
#
# Examples:
#   # defaults: OpenMPI, POSIX, file-per-process, 2 nodes
#   sbatch ior.sbatch
#
#   # single shared file, MPI-IO, larger transfers
#   IOR_FILEMODE=ssf IOR_API=MPIIO IOR_TRANSFER=4m sbatch ior.sbatch
#
#   # scale out and push more ranks/node
#   sbatch -N 8 --export=ALL,IOR_TASKS_PER_NODE=16 ior.sbatch
#
#   # also run the mdtest metadata benchmark
#   IOR_MDTEST=1 sbatch ior.sbatch
#
# Environment variables (all optional):
#   IOR_MPI            openmpi | intelmpi          (default openmpi)
#   IOR_API            POSIX | MPIIO               (default POSIX)
#   IOR_FILEMODE       fpp | ssf                   (default fpp)
#   IOR_BLOCK          per-task block size         (default 4g)
#   IOR_TRANSFER       size of each I/O call       (default 1m)
#   IOR_SEGMENTS       segments per task           (default 1)
#   IOR_ITER           iterations (reps)           (default 3)
#   IOR_TASKS_PER_NODE MPI ranks per node          (default 12)
#   IOR_DIR            test directory on the FS    (default /fsx/ior-test)
#   IOR_STRIPE_COUNT   Lustre stripe count (-1=all OSTs)  (default -1)
#   IOR_STRIPE_SIZE    Lustre stripe size          (default 1M)
#   IOR_MDTEST         1 to also run mdtest         (default 0)
#   IOR_EXTRA          extra args appended to ior

set -uo pipefail

IOR_MPI="${IOR_MPI:-openmpi}"
IOR_API="${IOR_API:-POSIX}"
IOR_FILEMODE="${IOR_FILEMODE:-fpp}"
IOR_BLOCK="${IOR_BLOCK:-4g}"
IOR_TRANSFER="${IOR_TRANSFER:-1m}"
IOR_SEGMENTS="${IOR_SEGMENTS:-1}"
IOR_ITER="${IOR_ITER:-3}"
IOR_TASKS_PER_NODE="${IOR_TASKS_PER_NODE:-12}"
IOR_DIR="${IOR_DIR:-/fsx/ior-test}"
IOR_STRIPE_COUNT="${IOR_STRIPE_COUNT:--1}"
IOR_STRIPE_SIZE="${IOR_STRIPE_SIZE:-1M}"
IOR_MDTEST="${IOR_MDTEST:-0}"
IOR_EXTRA="${IOR_EXTRA:-}"

NODES="${SLURM_JOB_NUM_NODES:-1}"
NTASKS=$(( NODES * IOR_TASKS_PER_NODE ))

# --- Select the MPI stack and the matching IOR install -------------------
case "${IOR_MPI}" in
  openmpi)
    module load openmpi libfabric-aws
    IOR_HOME="/fsx/IOR-OpenMPI/install"
    PLACEMENT=(--map-by "ppr:${IOR_TASKS_PER_NODE}:node")
    ;;
  intelmpi)
    module load intelmpi libfabric-aws
    IOR_HOME="/fsx/IOR-IntelMPI/install"
    PLACEMENT=(-ppn "${IOR_TASKS_PER_NODE}")
    ;;
  *) echo "ERROR: IOR_MPI must be 'openmpi' or 'intelmpi' (got '${IOR_MPI}')" >&2; exit 1 ;;
esac
IOR_BIN="${IOR_HOME}/bin/ior"
MDTEST_BIN="${IOR_HOME}/bin/mdtest"
if [ ! -x "${IOR_BIN}" ]; then
  echo "ERROR: ${IOR_BIN} not found — build it first with build_ior_${IOR_MPI}.sh" >&2
  exit 1
fi

echo "================================================================================"
echo "IOR run $(date)"
echo "  MPI=${IOR_MPI}  API=${IOR_API}  mode=${IOR_FILEMODE}"
echo "  nodes=${NODES}  tasks/node=${IOR_TASKS_PER_NODE}  total ranks=${NTASKS}"
echo "  block=${IOR_BLOCK}  transfer=${IOR_TRANSFER}  segments=${IOR_SEGMENTS}  iters=${IOR_ITER}"
echo "  dir=${IOR_DIR}  stripe_count=${IOR_STRIPE_COUNT}  stripe_size=${IOR_STRIPE_SIZE}"
echo "================================================================================"

# --- Prepare the test directory and apply a Lustre stripe layout ---------
# Striping the directory makes every file created under it inherit the layout,
# spreading I/O across OSTs. -1 stripes across all available OSTs (best for
# aggregate throughput on FSx for Lustre).
mkdir -p "${IOR_DIR}"
if command -v lfs >/dev/null 2>&1; then
  if lfs setstripe -c "${IOR_STRIPE_COUNT}" -S "${IOR_STRIPE_SIZE}" "${IOR_DIR}" 2>/dev/null; then
    echo "Lustre stripe layout applied to ${IOR_DIR}:"
    lfs getstripe -d "${IOR_DIR}" 2>/dev/null | sed 's/^/    /'
  else
    echo "WARN: 'lfs setstripe' failed (not Lustre, or no permission); using the directory default layout"
  fi
else
  echo "NOTE: 'lfs' not found — not a Lustre mount; skipping stripe configuration"
fi

# --- Build the IOR argument list -----------------------------------------
# -w write, -r read, -e fsync after write (data must reach storage, not just
# the client page cache), -g barriers between phases, -C reorder tasks so each
# rank reads a file written by a DIFFERENT node (defeats the client read cache),
# -i iterations, -b per-task block, -t transfer size, -s segments.
IOR_ARGS=(-a "${IOR_API}" -b "${IOR_BLOCK}" -t "${IOR_TRANSFER}" -s "${IOR_SEGMENTS}"
          -w -r -e -g -C -i "${IOR_ITER}" -o "${IOR_DIR}/iorfile")
if [ "${IOR_FILEMODE}" = "fpp" ]; then
  IOR_ARGS+=(-F)              # one file per process
elif [ "${IOR_FILEMODE}" != "ssf" ]; then
  echo "ERROR: IOR_FILEMODE must be 'fpp' or 'ssf' (got '${IOR_FILEMODE}')" >&2; exit 1
fi
# shellcheck disable=SC2206
[ -n "${IOR_EXTRA}" ] && IOR_ARGS+=(${IOR_EXTRA})

# Aggregate dataset size (informational): ranks x block x segments. For a
# rigorous cache-defeating read, this should exceed the aggregate client RAM;
# -C plus the page-cache drop below also mitigate caching.
echo "Aggregate dataset ~ ${NTASKS} ranks x ${IOR_BLOCK} x ${IOR_SEGMENTS} segments (see the IOR summary for the exact MiB)."

# --- Drop page caches on every node so reads come from the filesystem ----
echo "==> Dropping page caches on all nodes (best-effort)"
srun --ntasks="${NODES}" --ntasks-per-node=1 \
  bash -c 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true'

# --- Run IOR --------------------------------------------------------------
echo "==> ior ${IOR_ARGS[*]}"
mpirun -np "${NTASKS}" "${PLACEMENT[@]}" "${IOR_BIN}" "${IOR_ARGS[@]}"

# --- Optional metadata benchmark (mdtest) --------------------------------
if [ "${IOR_MDTEST}" = "1" ] && [ -x "${MDTEST_BIN}" ]; then
  echo ""
  echo "==> mdtest metadata benchmark (create/stat/remove of 0-byte files)"
  # -n files per rank, -u unique working dir per task, -F files only (no dirs),
  # -i iterations. Tune -n up for a heavier metadata load.
  mpirun -np "${NTASKS}" "${PLACEMENT[@]}" \
    "${MDTEST_BIN}" -n 10000 -u -F -i 2 -d "${IOR_DIR}/mdtest"
fi

echo ""
echo "==> Done. Read the 'Max Write' / 'Max Read' (MiB/s) lines in the IOR summary above."
