#!/bin/bash
# =============================================================================
# OpenMP binding in the CPU launchers: a Thread_MPI run (one node) gets no
# OMP_PLACES or OMP_PROC_BIND, so gmx -pin on pins every rank; mpirun's ranks
# (more nodes, or the Library_MPI build on one) still get OMP_PLACES=cores and
# OMP_PROC_BIND=close, forwarded with -x.
#
#   ./tests/test-binding.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

for arch in x86 Arm; do
    echo "== ${arch}/gromacs-benchmark.sbatch =="
    case "${arch}" in
        x86) ompi_env="x86_64/v2024.4/gromacs-v2024.4-ompi-env.sh" ;;
        Arm) ompi_env="aarch64-graviton4-ompi5/v2024.4/gromacs-v2024.4-ompi5-env.sh" ;;
    esac

    run_launcher "${arch}"
    [ "${RC}" -eq 0 ] && ok "one node: completes (exit 0)" || bad "one node completes" "exit 0" "exit ${RC}"
    [ "$(mdrun_env)" = "OMP_NUM_THREADS=1 OMP_PLACES=<unset> OMP_PROC_BIND=<unset>" ] \
        && ok "one node: gmx runs with neither OMP_PLACES nor OMP_PROC_BIND" \
        || bad "one node: no OpenMP binding variables" "OMP_NUM_THREADS=1 OMP_PLACES=<unset> OMP_PROC_BIND=<unset>" "$(mdrun_env)"
    has_words "one node: gmx pins the ranks itself" "$(mdrun_args)" "-pin on -pinoffset 0 -pinstride 1"

    run_launcher "${arch}" THREADS_PER_RANK=4
    [ "$(mdrun_env)" = "OMP_NUM_THREADS=4 OMP_PLACES=<unset> OMP_PROC_BIND=<unset>" ] \
        && ok "one node, 4 threads per rank: OMP_NUM_THREADS=4 and no binding variables" \
        || bad "one node, 4 threads" "OMP_NUM_THREADS=4 OMP_PLACES=<unset> OMP_PROC_BIND=<unset>" "$(mdrun_env)"

    run_launcher "${arch}" OMP_PLACES=threads OMP_PROC_BIND=spread
    [ "$(mdrun_env)" = "OMP_NUM_THREADS=1 OMP_PLACES=<unset> OMP_PROC_BIND=<unset>" ] \
        && ok "one node: binding variables from the submitting shell do not reach gmx" \
        || bad "submit-time variables dropped" "OMP_PLACES=<unset> OMP_PROC_BIND=<unset>" "$(mdrun_env)"

    run_launcher "${arch}" SLURM_JOB_NUM_NODES=2 THREADS_PER_RANK=4
    [ "$(mdrun_env)" = "OMP_NUM_THREADS=4 OMP_PLACES=cores OMP_PROC_BIND=close" ] \
        && ok "two nodes: gmx_mpi's ranks keep OMP_PLACES=cores OMP_PROC_BIND=close" \
        || bad "two nodes keep the binding" "OMP_NUM_THREADS=4 OMP_PLACES=cores OMP_PROC_BIND=close" "$(mdrun_env)"
    has_words "two nodes: mpirun forwards them" "$(head -1 "${MPILOG}")" "-x OMP_NUM_THREADS -x OMP_PLACES -x OMP_PROC_BIND"

    # The Library_MPI build on one node (GROMACS_ENV names its env script) runs under mpirun.
    case_base="$(mktemp -d "${STUBS}/ompi1.XXXXXX")"
    make_install "${case_base}" "$(dirname "$(dirname "${ompi_env}")")" gromacs-v2024.4-tmpi-env.sh "$(basename "${ompi_env}")"
    run_launcher "${arch}" GROMACS_ENV="${case_base}/${ompi_env}"
    [ "$(mdrun_bin)" = gmx_mpi ] && [ "$(mdrun_env)" = "OMP_NUM_THREADS=1 OMP_PLACES=cores OMP_PROC_BIND=close" ] \
        && ok "one node with the Library_MPI build: mpirun's ranks keep the binding variables" \
        || bad "one node, Library_MPI" "gmx_mpi, OMP_PLACES=cores OMP_PROC_BIND=close" "$(mdrun_bin), $(mdrun_env)"
done

summary "Thread_MPI binding tests"
