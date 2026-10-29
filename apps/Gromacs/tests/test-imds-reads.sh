#!/bin/bash
# =============================================================================
# The instance-metadata reads of the Arm and GPU launchers
# (Arm/gromacs-benchmark.sbatch, GPU/gromacs-benchmark.sbatch). Both name the
# run directory and the job log after the instance type, and nothing else
# depends on it: neither has a flexible-cores list or check. Every IMDS read has
# curl's time limits (--connect-timeout 2, --max-time 5) and -f, and no answer,
# an answer cut off at the time limit, an HTTP error, or an answer that is not
# an instance type name (capitals included, or a type name inside other text)
# leaves the type unknown: the run goes on, its directory and job log name the
# type "unknown", lscpu is not asked and no NOTE is printed. No run stops only
# because IMDS did not answer. On both launchers a type name with an i reads as
# one in a Turkish locale too, where [a-z] leaves out i.
#
# The GPU launcher runs with the stubs of harness.sh and two of its own: an
# nvidia-smi that shows one GPU, and a stub GPU build whose env script it is
# given (GROMACS_ENV).
#
#   ./tests/test-imds-reads.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

# nvidia-smi, for the GPU launcher: one GPU (-L), a topology matrix (topo -m),
# the GPU's name (--query-gpu) and, with no argument, a banner with the CUDA
# version.
cat > "${STUBS}/bin/nvidia-smi" <<'EOF'
#!/bin/bash
case "$*" in
  -L)            echo "GPU 0: NVIDIA L40S (UUID: GPU-00000000-0000-0000-0000-000000000000)" ;;
  "topo -m")     printf '\tGPU0\tCPU Affinity\nGPU0\t X \t0-3\n' ;;
  --query-gpu=*) echo "NVIDIA L40S" ;;
  *)             echo "| NVIDIA-SMI 580.00    Driver Version: 580.00    CUDA Version: 13.0 |" ;;
esac
EOF
chmod +x "${STUBS}/bin/nvidia-smi"
# A stub GPU build, laid out as build_gromacs_gpu.sbatch lays out an L40S build.
make_install "${STUBS}" x86_64-cuda13-l40s gromacs-v2024.4-tmpi-env.sh gromacs-v2024.4-ompi5-env.sh
GPU_ENV="${STUBS}/x86_64-cuda13-l40s/v2024.4/gromacs-v2024.4-tmpi-env.sh"

# launch <Arm|GPU> [NAME=value...]: run_launcher on one node, the GPU launcher with the stub GPU build
launch() {
    ARCH="$1"; shift
    if [ "${ARCH}" = GPU ]; then
        run_launcher GPU GROMACS_ENV="${GPU_ENV}" "$@"
    else
        run_launcher Arm "$@"
    fi
}
# runs <label>: the last run completed with one mdrun
runs() {
    if [ "${RC}" -eq 0 ] && [ "$(mdrun_count)" -eq 1 ]; then
        ok "$1: runs"
    else
        bad "$1: runs" "exit 0, 1 mdrun" "exit ${RC}, $(mdrun_count) mdrun: $(grep -E '^(ERROR|NOTE)' <<<"${OUT}" | head -1)"
    fi
}
# named <label> <type>: the last run's only directory, its job log and its results block name the instance type
named() {
    local tag="192x1" dirs
    [ "${ARCH}" = GPU ] && tag="1gl40s"
    dirs="$(find "${BASE}/Run" -mindepth 4 -maxdepth 4 2>/dev/null)"
    if [[ "${dirs}" == "${BASE}/Run/gromacs/benchMEM/test/4242-1x$2-${tag}-"* && "${dirs}" != *$'\n'* ]] \
            && grep -qxF "Nodes:         1 x $2" <<<"${OUT}" && grep -qxF "Nodes:            1 x $2" <<<"${OUT}"; then
        ok "$1: the run directory, the job log and the results block name the type $2"
    else
        bad "$1: the type $2" "4242-1x$2-${tag}-..., 'Nodes: 1 x $2' twice" \
            "${dirs#"${BASE}/Run/"}, $(grep '^Nodes:' <<<"${OUT}" | tr '\n' '|')"
    fi
}
# imds_bounded <label>: the last run read the instance type from IMDS, and every IMDS call it made had
# --connect-timeout 2, --max-time 5 and -f (--fail)
imds_bounded() {
    local calls unbounded
    calls="$(grep -c . "${IMDSLOG}")"
    unbounded="$(awk '{
        f = 0
        for (i = 1; i <= NF; i++) if ($i == "--fail" || $i ~ /^-[a-zA-Z]*f[a-zA-Z]*$/) f = 1
        line = " " $0 " "
        if (!f || index(line, " --connect-timeout 2 ") == 0 || index(line, " --max-time 5 ") == 0) n++
    } END { print n + 0 }' "${IMDSLOG}")"
    if grep -q 'meta-data/instance-type' "${IMDSLOG}" && [ "${unbounded}" -eq 0 ]; then
        ok "$1: every IMDS read (${calls}) has --connect-timeout 2, --max-time 5 and -f"
    else
        bad "$1: the IMDS reads' time limits" "every read with --connect-timeout 2, --max-time 5 and -f" \
            "${unbounded} of ${calls} read(s) without them: $(head -1 "${IMDSLOG}")"
    fi
}
# quiet <label>: the last run asked lscpu nothing and printed no NOTE
quiet() {
    if [ ! -s "${LSCPULOG}" ] && ! grep -q '^NOTE' <<<"${ERR}"; then
        ok "$1: no lscpu, no NOTE"
    else
        bad "$1: no lscpu, no NOTE" "no lscpu call, no NOTE" \
            "$(grep -c . "${LSCPULOG}") lscpu call(s); $(grep '^NOTE' <<<"${ERR}" | head -1)"
    fi
}

for arch in Arm GPU; do
    case "${arch}" in
        Arm) itype=m8g.48xlarge; caps=M8G.48XLARGE ;;
        GPU) itype=g6e.xlarge;   caps=G6E.XLARGE ;;
    esac
    echo "== ${arch}/gromacs-benchmark.sbatch: the instance type from IMDS =="
    launch "${arch}" STUB_INSTANCE_TYPE="${itype}"
    runs "${itype} from IMDS"
    named "${itype} from IMDS" "${itype}"
    imds_bounded "${itype} from IMDS"
    quiet "${itype} from IMDS"

    echo "== ${arch}/gromacs-benchmark.sbatch: no instance type from IMDS =="
    for mode in none cut-off http-error not-a-type; do
        launch "${arch}" STUB_IMDS="${mode}"
        runs "IMDS ${mode}"
        named "IMDS ${mode}" unknown
        imds_bounded "IMDS ${mode}"
        quiet "IMDS ${mode}"
    done
    # Not a type name: capitals, and a type name inside other text (a page naming a host, a type and more).
    for answer in "${caps}" "Request denied by proxy.example.com" "${itype}: not found"; do
        launch "${arch}" STUB_INSTANCE_TYPE="${answer}"
        runs "the answer '${answer}'"
        named "the answer '${answer}'" unknown
    done

    # The type names only the run directory and the job log, so both launchers get
    # the same type name with an i.
    echo "== ${arch}/gromacs-benchmark.sbatch: a type name with an i, in a Turkish locale =="
    launch "${arch}" STUB_INSTANCE_TYPE=im4gn.16xlarge LANG=tr_TR.UTF-8
    runs "im4gn.16xlarge in a Turkish locale"
    named "im4gn.16xlarge in a Turkish locale" im4gn.16xlarge
done

echo "== the stubs kept AWS and the network out of it =="
[ -s "${STUBS}/aws-calls.log" ] && bad "no AWS call" "none" "$(head -1 "${STUBS}/aws-calls.log")" || ok "no test called AWS"

summary "instance-metadata tests"
