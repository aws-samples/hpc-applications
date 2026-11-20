#!/bin/bash
# =============================================================================
# The CUDA version the GPU single-simulation launcher (GPU/gromacs-benchmark.sbatch)
# gives its job log, its results block and the contribution record. It comes
# from nvcc, which the env script puts on the PATH when it loads the CUDA
# toolkit: "release 13.0" gives 13.0, and the record --char cuda_version=13.0.
# With no nvcc on the PATH, or an nvcc whose output has no release number, the
# job log and the results block say "unknown", and the record has no CUDA
# version at all: never the driver's version, nor the CUDA version nvidia-smi
# says the driver supports. The run is recorded either way, with its GPU count
# and GPU target.
#
# Runs the launcher with the stubs of harness.sh, its GPU stubs (gpu_stubs)
# included, on one GPU, given the stub L40S build's env script (GROMACS_ENV):
# STUB_CUDA=none is a node where that env script loads no CUDA toolkit. The
# cases without nvcc need a host without one on the stubs' PATH, and are
# skipped otherwise.
#
#   ./tests/test-gpu-cuda-version.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
gpu_stubs
recorder_calls() { grep -c 'BENCHMARK_CASE=' "${RECLOG}"; }
recorder_args() { sed -n 's/^.* ARGS: //p' "${RECLOG}" | head -1; }

# version <label> <version>: the last run's job log and results block give the
# CUDA version <version>, and it was recorded once
version() {
    if grep -qxF "CUDA version:   $2" <<<"${OUT}" && grep -qxF "CUDA version:     $2" <<<"${OUT}"; then
        ok "$1: the job log and the results block give the CUDA version $2"
    else
        bad "$1: the job log and the results block give the CUDA version $2" \
            "'CUDA version:   $2' and 'CUDA version:     $2'" "$(grep '^CUDA version:' <<<"${OUT}" | tr '\n' '|')"
    fi
    if [ "${RC}" -eq 0 ] && [ "$(recorder_calls)" -eq 1 ] \
            && has_all "$(recorder_args)" "--metric gpu_count=1" "--char gpu_target=l40s"; then
        ok "$1: the run is recorded once, with its GPU count and GPU target"
    else
        bad "$1: the run is recorded once, with its GPU count and GPU target" \
            "exit 0, 1 recorder call with --metric gpu_count=1 and --char gpu_target=l40s" \
            "exit ${RC}, $(recorder_calls) call(s): $(recorder_args)"
    fi
}
# has_all <haystack> <word sequence>...: the haystack holds each exact space-separated sequence
has_all() {
    local haystack=" $1 " w; shift
    for w in "$@"; do [[ "${haystack}" == *" ${w} "* ]] || return 1; done
}

echo "== GPU/gromacs-benchmark.sbatch: nvcc on the PATH =="
run_launcher GPU GROMACS_ENV="${GPU_TMPI_ENV}"
version "nvcc's release 13.0" 13.0
has_all "$(recorder_args)" "--char cuda_version=13.0" \
    && ok "nvcc's release 13.0: the record gets --char cuda_version=13.0" \
    || bad "nvcc's release 13.0: the record's CUDA version" "--char cuda_version=13.0" "$(recorder_args)"

for mode in no-release not-a-number; do
    run_launcher GPU GROMACS_ENV="${GPU_TMPI_ENV}" STUB_NVCC="${mode}"
    version "nvcc with ${mode}" unknown
    grep -q 'cuda_version' "${RECLOG}" \
        && bad "nvcc with ${mode}: no CUDA version in the record" "no cuda_version argument" "$(recorder_args)" \
        || ok "nvcc with ${mode}: no CUDA version in the record"
done

echo "== GPU/gromacs-benchmark.sbatch: no nvcc =="
if env -i PATH="${STUBS}/bin:/usr/local/bin:/usr/bin:/bin" bash -c 'command -v nvcc' >/dev/null 2>&1; then
    skipt "no nvcc: the job log, the results block and the record" "this host has an nvcc on the stubs' PATH"
else
    run_launcher GPU GROMACS_ENV="${GPU_TMPI_ENV}" STUB_CUDA=none
    version "no nvcc" unknown
    if ! grep -q 'cuda_version' "${RECLOG}" && ! grep -q '580\.00' "${RECLOG}"; then
        ok "no nvcc: no CUDA version in the record, and not the driver's version (nvidia-smi's banner)"
    else
        bad "no nvcc: no CUDA version in the record" "no cuda_version argument, no 580.00" "$(recorder_args)"
    fi
    grep -q '580\.00' <<<"${OUT}" \
        && bad "no nvcc: the driver's version nowhere in the job's output" "no 580.00" "$(grep '580\.00' <<<"${OUT}" | head -1)" \
        || ok "no nvcc: the driver's version nowhere in the job's output"
fi

summary "GPU CUDA version tests"
