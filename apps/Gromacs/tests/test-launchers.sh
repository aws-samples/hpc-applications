#!/bin/bash
# =============================================================================
# End-to-end tests of the CPU benchmark launchers as ASSEMBLED
# (x86/gromacs-benchmark.sbatch, Arm/gromacs-benchmark.sbatch), with the stubs
# of harness.sh: which binary runs, how the ranks and threads are laid out, the
# mdrun options every run gets, the results block, and the input checks.
#
#   ./tests/test-launchers.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

for arch in x86 Arm; do
    echo "== ${arch}/gromacs-benchmark.sbatch =="

    run_launcher "${arch}"
    [ "${RC}" -eq 0 ] && ok "one node, defaults: completes (exit 0)" || bad "one node completes" "exit 0" "exit ${RC}"
    [ "$(mdrun_bin)" = gmx ] && ok "one node: Thread_MPI gmx runs mdrun" || bad "one node: gmx" "gmx" "$(mdrun_bin)"
    [ "$(mdrun_count)" -eq 1 ] && ok "one node: mdrun runs once" || bad "one mdrun" "1" "$(mdrun_count)"
    [ -s "${MPILOG}" ] && bad "one node: no mpirun" "none" "$(head -1 "${MPILOG}")" || ok "one node: no mpirun"
    args="$(mdrun_args)"
    has_words "benchMEM: its .tpr and 50,000 steps" "${args}" "mdrun -s benchMEM.tpr -nsteps 50000"
    has_words "-resethway -noconfout -nstlist 100" "${args}" "-resethway -noconfout -nstlist 100 -deffnm md"
    has_words "one node: 192 Thread_MPI ranks x 1 thread, pinned by gmx" "${args}" \
        "-ntmpi 192 -ntomp 1 -pin on -pinoffset 0 -pinstride 1"
    grep -qx 'ns/day:           100.000' <<<"${OUT}" && ok "the results block gives md.log's ns/day" \
        || bad "results block" "ns/day:           100.000" "$(grep 'ns/day' <<<"${OUT}" | head -2 | tr '\n' '|')"
    grep -q 'BENCHMARK_CASE=benchMEM NS_PER_DAY=100.000' "${RECLOG}" && ok "the contribution recorder is called" \
        || bad "recorder call" "BENCHMARK_CASE=benchMEM NS_PER_DAY=100.000" "$(head -1 "${RECLOG}")"

    run_launcher "${arch}" MODEL=benchPEP-h
    has_words "benchPEP-h: its .tpr and 5,000 steps" "$(mdrun_args)" "mdrun -s benchPEP-h.tpr -nsteps 5000"

    run_launcher "${arch}" THREADS_PER_RANK=4
    has_words "one node, THREADS_PER_RANK=4: 48 ranks x 4 threads" "$(mdrun_args)" "-ntmpi 48 -ntomp 4 -pin on"

    run_launcher "${arch}" SLURM_JOB_NUM_NODES=2
    [ "${RC}" -eq 0 ] && ok "two nodes: completes (exit 0)" || bad "two nodes completes" "exit 0" "exit ${RC}"
    [ "$(mdrun_bin)" = gmx_mpi ] && ok "two nodes: gmx_mpi runs mdrun" || bad "two nodes: gmx_mpi" "gmx_mpi" "$(mdrun_bin)"
    launch="$(head -1 "${MPILOG}")"
    has_words "two nodes: 384 ranks, one per core" "${launch}" "-np 384 --hostfile hostfile --bind-to core --map-by slot"
    has_words "two nodes: OpenMPI over EFA (pml cm, mtl ofi)" "${launch}" "--mca pml cm --mca mtl ofi"
    lacks_word "two nodes: no -ntmpi" "$(mdrun_args)" "-ntmpi"
    has_words "two nodes: the same mdrun options" "$(mdrun_args)" "-resethway -noconfout -nstlist 100 -deffnm md"

    run_launcher "${arch}" SLURM_JOB_NUM_NODES=2 THREADS_PER_RANK=4
    launch="$(head -1 "${MPILOG}")"
    has_words "two nodes, THREADS_PER_RANK=4: 96 ranks, 48 per node, 4 cores each" "${launch}" \
        "-np 96 --hostfile hostfile --bind-to core --map-by ppr:48:node:PE=4"
    [[ "$(mdrun_env)" == "OMP_NUM_THREADS=4 "* ]] && ok "two nodes, THREADS_PER_RANK=4: OMP_NUM_THREADS=4" \
        || bad "OMP_NUM_THREADS=4" "OMP_NUM_THREADS=4 ..." "$(mdrun_env)"

    run_launcher "${arch}" THREADS_PER_RANK=0
    [ "${RC}" -ne 0 ] && grep -q "THREADS_PER_RANK='0' invalid" <<<"${OUT}" \
        && ok "THREADS_PER_RANK=0 is refused" || bad "THREADS_PER_RANK=0 refused" "non-zero exit and a message" "exit ${RC}"
    [ "$(mdrun_count)" -eq 0 ] && ok "THREADS_PER_RANK=0: no mdrun" || bad "no mdrun" "0" "$(mdrun_count)"

    run_launcher "${arch}" MODEL=bogus
    [ "${RC}" -ne 0 ] && grep -q "Unknown MODEL: 'bogus'" <<<"${OUT}" \
        && ok "an unknown MODEL is refused" || bad "unknown MODEL refused" "non-zero exit and a message" "exit ${RC}"
done

echo "== the stubs kept AWS and the network out of it =="
[ -s "${STUBS}/aws-calls.log" ] && bad "no AWS call" "none" "$(head -1 "${STUBS}/aws-calls.log")" || ok "no test called AWS"

summary "launcher tests"
