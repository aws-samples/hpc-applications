#!/bin/bash
# =============================================================================
# Shared stubs for the GROMACS shell tests (sourced by test-*.sh).
# =============================================================================
# run_launcher runs a CPU benchmark launcher (x86/ or Arm/gromacs-benchmark.sbatch)
# as Slurm would, with curl, scontrol, srun, sudo, fi_info, mpirun, ldd, aws and
# the GROMACS binaries replaced by stubs, so the whole script executes. The gmx and
# gmx_mpi stubs log their arguments and OpenMP environment and write a synthetic
# md.log; mpirun logs its command line and runs the gmx_mpi stub; srun, sudo and
# the cache drop touch nothing; the aws stub refuses every call.
#
# No Slurm, no EC2, no GROMACS, no MPI, no AWS credentials, no network.
#
# GROMACS_APP (default: this directory's parent) is the apps/Gromacs tree under
# test, so a test can be pointed at another revision's scripts.
# =============================================================================
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROMACS_APP="${GROMACS_APP:-$(cd "${TESTS_DIR}/.." && pwd)}"

pass=0; fail=0; skip=0
ok()   { printf '  PASS %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
skipt(){ printf '  SKIP %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }
summary() {
    printf '%s: %d passed, %d failed, %d skipped\n' "$1" "${pass}" "${fail}" "${skip}"
    [ "${fail}" -eq 0 ]
}

STUBS="$(mktemp -d)"
trap 'rm -rf "${STUBS}"' EXIT
mkdir -p "${STUBS}/bin"

cat > "${STUBS}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS stub (token, instance type, Region). Any other URL is a download: refused,
# with the URL logged, so no test reaches the network.
case "$*" in
  *api/token*)               echo "stub-token"; exit 0;;
  *meta-data/instance-type*) echo "${STUB_INSTANCE_TYPE:-hpc8a.96xlarge}"; exit 0;;
  *placement/region*)        echo "eu-north-1"; exit 0;;
esac
for a in "$@"; do case "$a" in https://*) echo "${a}" >> "${CURL_LOG}";; esac; done
exit 22
EOF
cat > "${STUBS}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show nodes <list>: one record per node of the job, as Slurm prints them.
for (( i = 1; i <= ${SLURM_JOB_NUM_NODES:-1}; i++ )); do
  echo "NodeName=node${i} Arch=x86_64 CoresPerSocket=96"
  echo "   NodeAddr=node${i} NodeHostName=node${i} Version=25.05.0"
done
EOF
cat > "${STUBS}/bin/srun" <<'EOF'
#!/bin/bash
# The launchers srun only the cache drop and the THP setting: swallow them.
exit 0
EOF
cat > "${STUBS}/bin/sudo" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "${STUBS}/bin/fi_info" <<'EOF'
#!/bin/bash
case "$*" in
  *--version*) echo "fi_info: 2.4.0"; echo "libfabric: 2.4.0amzn5.0";;
  *) echo "provider: efa"; echo "    fabric: efa"; echo "    domain: rdmap0s6-rdm"; echo "    version: 204.0";;
esac
EOF
cat > "${STUBS}/bin/mpirun" <<'EOF'
#!/bin/bash
# --version: as OpenMPI prints it. Otherwise log the command line and run the
# GROMACS binary among the arguments with the arguments after it.
if [ "$1" = "--version" ]; then echo "mpirun (Open MPI) 4.1.7"; exit 0; fi
printf '%s\n' "$*" >> "${MPIRUN_LOG}"
while [ $# -gt 0 ]; do
  case "$1" in */gmx_mpi|gmx_mpi) bin="$1"; shift; exec "${bin}" "$@";; esac
  shift
done
exit 0
EOF
cat > "${STUBS}/bin/ldd" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "${STUBS}/bin/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "${AWS_STUB_LOG}"
echo "aws stub: refusing to call AWS from a test" >&2
exit 1
EOF
# The contribution recorder: log that it was called, store nothing.
cat > "${STUBS}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
echo "BENCHMARK_CASE=${BENCHMARK_CASE:-} NS_PER_DAY=${NS_PER_DAY:-}" >> "${RECORDER_LOG}"
exit 0
EOF
# gmx and gmx_mpi: log each mdrun (arguments and OpenMP environment) and write an
# md.log with synthetic timings; `gmx dump` prints an atom count.
cat > "${STUBS}/gmx-stub" <<'EOF'
#!/bin/bash
name="$(basename "$0")"
if [ "$1" = "dump" ]; then echo "   natoms             = 81743"; exit 0; fi
if [ "$1" = "mdrun" ]; then
  {
    echo "BIN: ${name}"
    echo "ARGS: $*"
    echo "ENV: OMP_NUM_THREADS=${OMP_NUM_THREADS-<unset>} OMP_PLACES=${OMP_PLACES-<unset>} OMP_PROC_BIND=${OMP_PROC_BIND-<unset>}"
  } >> "${GMX_LOG}"
  cat > md.log <<'MD'
               Core t (s)   Wall t (s)        (%)
       Time:     1000.000       10.000    10000.0
                 (ns/day)    (hour/ns)
Performance:      100.000        0.240
MD
  exit 0
fi
exit 0
EOF
chmod +x "${STUBS}"/bin/* "${STUBS}/gmx-stub"
: > "${STUBS}/aws-calls.log"

# make_install <base> <dir under base> <tmpi env name> <ompi env name>: a stub install
# tree as the build scripts lay it out, with the gmx / gmx_mpi stubs and env scripts.
make_install() {
    local base="$1" dir="$2" tenv="$3" oenv="$4" root
    root="${base}/${dir}/v2024.4"
    mkdir -p "${root}/tmpi/bin" "${root}/ompi/bin"
    cp "${STUBS}/gmx-stub" "${root}/tmpi/bin/gmx"
    cp "${STUBS}/gmx-stub" "${root}/ompi/bin/gmx_mpi"
    for v in tmpi ompi; do
        local f="${tenv}"; [ "${v}" = ompi ] && f="${oenv}"
        cat > "${root}/${f}" <<ENV
export GROMACS_ROOT="${root}/${v}"
export GROMACS_TAG="v2024.4"
export PATH="\${GROMACS_ROOT}/bin:\${PATH}"
export GMXLIB="\${GROMACS_ROOT}/share/gromacs/top"
ENV
    done
}

# run_launcher <x86|Arm> [NAME=value...]
# Runs one CPU launcher in a clean environment (1 node, 192 tasks per node,
# MODEL=benchMEM unless overridden) with a fresh BASE_DIR holding stub installs and
# a staged .tpr for every MODEL. Sets OUT (stdout and stderr), RC, BASE, and the
# logs GMXLOG (one BIN/ARGS/ENV block per mdrun), MPILOG (mpirun command lines),
# CURLLOG (download URLs) and RECLOG (recorder calls).
run_launcher() {
    local arch="$1"; shift
    BASE="$(mktemp -d "${STUBS}/case.XXXXXX")"
    GMXLOG="${BASE}/gmx.log"; MPILOG="${BASE}/mpirun.log"; CURLLOG="${BASE}/curl.log"; RECLOG="${BASE}/recorder.log"
    : > "${GMXLOG}"; : > "${MPILOG}"; : > "${CURLLOG}"; : > "${RECLOG}"
    make_install "${BASE}" x86_64 gromacs-v2024.4-tmpi-env.sh gromacs-v2024.4-ompi-env.sh
    make_install "${BASE}" aarch64-graviton4-ompi5 gromacs-v2024.4-tmpi-env.sh gromacs-v2024.4-ompi5-env.sh
    for m in benchMEM benchPEP-h STMV RNAse; do
        mkdir -p "${BASE}/benchmarks/${m}"; echo "stub tpr" > "${BASE}/benchmarks/${m}/${m}.tpr"
    done
    # OUT and RC are read by the test files that source this one.
    # shellcheck disable=SC2034
    OUT="$(cd "${BASE}" && env -i \
        PATH="${STUBS}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${BASE}" LANG=C \
        BASE_DIR="${BASE}" GMX_LOG="${GMXLOG}" MPIRUN_LOG="${MPILOG}" CURL_LOG="${CURLLOG}" \
        RECORDER_LOG="${RECLOG}" AWS_STUB_LOG="${STUBS}/aws-calls.log" \
        CONTRIB_RECORDER="${STUBS}/bin/recorder-stub.sh" \
        SLURM_JOB_ID=4242 SLURM_JOB_NAME=gromacs SLURM_CLUSTER_NAME=test \
        SLURM_JOB_NUM_NODES=1 SLURM_NTASKS_PER_NODE=192 SLURM_NODELIST="node[1-8]" \
        SLURM_SUBMIT_DIR="${GROMACS_APP}/${arch}" \
        "$@" \
        bash "${GROMACS_APP}/${arch}/gromacs-benchmark.sbatch" 2>&1)"
    # shellcheck disable=SC2034
    RC=$?
}

# mdrun_args: the ARGS line of the (one) mdrun the last run made
mdrun_args() { sed -n 's/^ARGS: //p' "${GMXLOG}" | tail -1; }
mdrun_env()  { sed -n 's/^ENV: //p' "${GMXLOG}" | tail -1; }
mdrun_bin()  { sed -n 's/^BIN: //p' "${GMXLOG}" | tail -1; }
mdrun_count(){ grep -c '^ARGS: ' "${GMXLOG}"; }

# has_words <label> <haystack> <words>: the haystack holds the exact space-separated word sequence;
# lacks_word <label> <haystack> <word>: it does not hold the word
has_words() {
    if [[ " $2 " == *" $3 "* ]]; then ok "$1"; else bad "$1" "… $3 …" "$2"; fi
}
lacks_word() {
    if [[ " $2 " == *" $3 "* ]]; then bad "$1" "no '$3'" "$2"; else ok "$1"; fi
}
