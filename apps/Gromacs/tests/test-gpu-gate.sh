#!/bin/bash
# =============================================================================
# The GPU single-simulation launcher (GPU/gromacs-benchmark.sbatch) has the CPU
# launchers' success gate (test-mdlog-gate.sh): the contribution recorder is
# called only when md.log gives a positive ns/day. A run whose md.log has no
# Performance line, or a rate of 0, still completes with its results block,
# but is not recorded. Checked on one GPU (Thread_MPI), on two GPUs of one node
# (Thread_MPI) and on two GPUs under mpirun (Library_MPI).
#
# Runs the launcher with the stubs of harness.sh, plus nvidia-smi (STUB_GPUS
# GPUs, one by default), nvcc (CUDA 13.0) and a stub CUDA install whose env
# scripts the run names in GROMACS_ENV (an L40S build, by its path).
#
#   ./tests/test-gpu-gate.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
recorder_calls() { grep -c 'BENCHMARK_CASE=' "${RECLOG}"; }

cat > "${STUBS}/bin/nvidia-smi" <<'EOF'
#!/bin/bash
# nvidia-smi stub: STUB_GPUS GPUs (default 1). -L lists them, topo -m prints
# their matrix, --query-gpu prints their name, and with no argument the
# summary gives the CUDA version.
n="${STUB_GPUS:-1}"
case "${1:-}" in
  -L) for (( i = 0; i < n; i++ )); do echo "GPU ${i}: NVIDIA L40S (UUID: GPU-stub-${i})"; done;;
  topo) printf '        '; for (( i = 0; i < n; i++ )); do printf 'GPU%d    ' "${i}"; done; echo
        for (( i = 0; i < n; i++ )); do
          printf 'GPU%d    ' "${i}"
          for (( j = 0; j < n; j++ )); do if (( i == j )); then printf ' X      '; else printf 'SYS     '; fi; done
          echo
        done;;
  --query-gpu=*) for (( i = 0; i < n; i++ )); do echo "NVIDIA L40S, 46068 MiB"; done;;
  *) echo "| NVIDIA-SMI 580.00   Driver Version: 580.00   CUDA Version: 13.0 |";;
esac
EOF
cat > "${STUBS}/bin/nvcc" <<'EOF'
#!/bin/bash
# nvcc stub: --version names CUDA 13.0, as the toolkit prints it.
printf '%s\n' 'nvcc: NVIDIA (R) Cuda compiler driver' 'Cuda compilation tools, release 13.0, V13.0.48'
EOF
chmod +x "${STUBS}/bin/nvidia-smi" "${STUBS}/bin/nvcc"
make_install "${STUBS}/cuda" x86_64-cuda13.0-l40s gromacs-v2024.4-tmpi-env.sh gromacs-v2024.4-ompi-env.sh
TMPI_ENV="${STUBS}/cuda/x86_64-cuda13.0-l40s/v2024.4/gromacs-v2024.4-tmpi-env.sh"
OMPI_ENV="${STUBS}/cuda/x86_64-cuda13.0-l40s/v2024.4/gromacs-v2024.4-ompi-env.sh"

echo "== GPU/gromacs-benchmark.sbatch =="
run_launcher GPU GROMACS_ENV="${TMPI_ENV}"
[ "${RC}" -eq 0 ] && [ "$(mdrun_bin)" = gmx ] && [ "$(mdrun_count)" -eq 1 ] \
    && ok "one GPU: Thread_MPI gmx runs mdrun once, and the job exits 0" \
    || bad "one GPU: gmx runs once, exit 0" "exit 0, gmx, 1 mdrun" "exit ${RC}, $(mdrun_bin), $(mdrun_count) mdrun"
has_words "one GPU: mdrun gets -gpu_id 0" "$(mdrun_args)" "-gpu_id 0"
[ "$(recorder_calls)" -eq 1 ] && ok "a positive ns/day: the run is recorded once" \
    || bad "a positive ns/day: recorded once" "1 recorder call" "$(recorder_calls) call(s)"
grep -q 'BENCHMARK_CASE=benchMEM NS_PER_DAY=100.000 ARGS: --metric gpu_count=1 --char cuda_version=13.0 --char gpu_target=l40s' \
    "${RECLOG}" && ok "the recorder gets the model, md.log's ns/day, the GPU count, CUDA version and GPU target" \
    || bad "the recorder's model, rate and GPU fields" \
           "BENCHMARK_CASE=benchMEM NS_PER_DAY=100.000 ARGS: --metric gpu_count=1 --char cuda_version=13.0 --char gpu_target=l40s" \
           "$(head -1 "${RECLOG}")"

run_launcher GPU GROMACS_ENV="${TMPI_ENV}" STUB_NS_PER_DAY=
[ "${RC}" -eq 0 ] && [ "$(mdrun_count)" -eq 1 ] && ok "no Performance line: the job still completes" \
    || bad "no Performance line: completes" "exit 0, 1 mdrun" "exit ${RC}, $(mdrun_count) mdrun"
grep -qx 'ns/day:           n/a' <<<"${OUT}" && ok "no Performance line: the results block says n/a" \
    || bad "results block" "ns/day:           n/a" "$(grep 'ns/day' <<<"${OUT}" | head -2 | tr '\n' '|')"
[ "$(recorder_calls)" -eq 0 ] && ok "no Performance line: the recorder is not called" \
    || bad "no Performance line: not recorded" "no recorder call" "$(head -1 "${RECLOG}")"
grep -qx 'NOTE: md.log gives no positive ns/day, so this run is not recorded.' <<<"${ERR}" \
    && ok "no Performance line: the job log says why" \
    || bad "the gate's note" "NOTE: md.log gives no positive ns/day, so this run is not recorded." \
           "$(grep 'NOTE' <<<"${ERR}" | tr '\n' '|')"

run_launcher GPU GROMACS_ENV="${TMPI_ENV}" STUB_NS_PER_DAY=0.000
[ "${RC}" -eq 0 ] && [ "$(recorder_calls)" -eq 0 ] && ok "ns/day 0.000: completes, not recorded" \
    || bad "ns/day 0.000: not recorded" "exit 0, no recorder call" "exit ${RC}, $(recorder_calls) call(s)"

run_launcher GPU GROMACS_ENV="${TMPI_ENV}" STUB_GPUS=2 GPU_COUNT=2 STUB_NS_PER_DAY=
if [ "${RC}" -eq 0 ] && [ "$(mdrun_bin)" = gmx ] && [ "$(recorder_calls)" -eq 0 ]; then
    has_words "two GPUs (Thread_MPI), no Performance line: completes, not recorded" "$(mdrun_args)" "-ntmpi 2 -npme 1"
else
    bad "two GPUs (Thread_MPI), no Performance line" "exit 0, gmx -ntmpi 2, no recorder call" \
        "exit ${RC}, $(mdrun_bin), $(recorder_calls) call(s)"
fi

run_launcher GPU GROMACS_ENV="${OMPI_ENV}" STUB_GPUS=2 GPU_COUNT=2
[ "${RC}" -eq 0 ] && [ "$(mdrun_bin)" = gmx_mpi ] && [ -s "${MPILOG}" ] && [ "$(recorder_calls)" -eq 1 ] \
    && ok "two GPUs under mpirun (Library_MPI), a positive ns/day: recorded once" \
    || bad "two GPUs under mpirun, a positive ns/day" "exit 0, gmx_mpi under mpirun, 1 recorder call" \
           "exit ${RC}, $(mdrun_bin), $(recorder_calls) call(s)"
run_launcher GPU GROMACS_ENV="${OMPI_ENV}" STUB_GPUS=2 GPU_COUNT=2 STUB_NS_PER_DAY=
[ "${RC}" -eq 0 ] && [ "$(mdrun_bin)" = gmx_mpi ] && [ "$(recorder_calls)" -eq 0 ] \
    && ok "two GPUs under mpirun (Library_MPI), no Performance line: completes, not recorded" \
    || bad "two GPUs under mpirun, no Performance line" "exit 0, gmx_mpi, no recorder call" \
           "exit ${RC}, $(mdrun_bin), $(recorder_calls) call(s)"

summary "GPU md.log gate tests"
