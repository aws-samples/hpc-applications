#!/bin/bash
# =============================================================================
# x86/Fluent-Benchmark.2026R1.sbatch on hpc8a.96xlarge and hpc7a.96xlarge runs
# only at 24, 48, 72, 96, 120, 144, 168 or 192 ranks per node, the counts that
# load their 24 CCDs evenly (Utils/flexible-cores). See helpers-2026r1.sh.
#   * every supported count runs, on both types;
#   * another count (16, 32, 64, 100, 128, 191), a total that does not divide
#     evenly over the nodes, a total too long to be a rank count, and no
#     SLURM_NPROCS, stop the job with exit 1 and an ERROR line that names the
#     supported counts, before the run directory, the cache drop, the THP
#     setting and the harness;
#   * other instance types and sizes run at any count;
#   * both requests to the instance metadata give up within 5 seconds, and
#     use -f;
#   * when the instance type cannot be read (no answer in time, an HTTP error,
#     an answer cut off at the time limit, an empty answer, or an answer that
#     is not an instance type name, also one that holds a type name inside
#     other text or is in capitals), a count outside the set is refused, with
#     the counts named, on an AMD node with
#     192 cores (lscpu, flat or indented, read in English in any locale:
#     sockets x cores per socket), and runs on any other node (Intel with 192
#     cores, AMD with 96 on one or two sockets, also with 2 threads per core,
#     AMD with 2 x 128, no lscpu output), with a one-line NOTE that the check
#     was skipped; a supported count, and an instance type that reads (also in
#     a Turkish locale, where [a-z] leaves out i), run without lscpu or a NOTE;
#   * after an HTTP error, an answer cut off at the time limit, and an answer
#     that is not an instance type name (a proxy's page), the run directory's
#     name holds no instance type, and none of the page.
#
#   apps/Fluent/tests/test-2026r1-cores-per-node.sh
# =============================================================================
set -uo pipefail
# shellcheck source=helpers-2026r1.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers-2026r1.sh"
echo "2026 R1 script: ranks per node (${SBATCH#"${FLUENT_APP}/"})"

COUNTS="24, 48, 72, 96, 120, 144, 168 or 192 ranks per node"

ran() {  # <description>: the last job ran the harness
    if [ "${RC}" -eq 0 ] && [ -s "${STATE}/harness.args" ]; then ok "$1 -> runs"
    else bad "$1 -> runs" "exit 0 and the harness" "exit ${RC}, $(head -c 300 <<<"${ERR}")"; fi
}
refused() {  # <description> <ERROR line>: the last job stopped with that line, before any work
    if [ "${RC}" -eq 1 ] && has_line "${ERR}" "$2"; then ok "$1 -> refused, with the counts named"
    else bad "$1 -> refused, with the counts named" "exit 1: $2" "exit ${RC}: ${ERR}"; fi
    if [ -z "${WORKDIR}" ] && [ ! -e "${STATE}/harness.args" ] && [ ! -e "${STATE}/srun.log" ] \
            && [ -z "$(ls -A "${STATE}/base")" ]; then
        ok "$1 -> no run directory, cache drop, THP setting or harness"
    else
        bad "$1 -> stopped before any work" "nothing started" \
            "run dir '${WORKDIR}', harness $([ -e "${STATE}/harness.args" ] && echo yes || echo no), srun $([ -e "${STATE}/srun.log" ] && echo yes || echo no)"
    fi
}

# ---------------------------------------------------------------------------
# 1. The supported counts, 2 nodes, on both types.
# ---------------------------------------------------------------------------
for type in hpc8a.96xlarge hpc7a.96xlarge; do
    for rpn in 24 48 72 96 120 144 168 192; do
        run_2026r1 "ok-${type}-${rpn}" STUB_INSTANCE_TYPE="${type}" SLURM_NPROCS=$((2 * rpn)) SLURM_NTASKS=$((2 * rpn))
        ran "${type}, 2 nodes x ${rpn}"
    done
done

# ---------------------------------------------------------------------------
# 2. Other counts on both types.
# ---------------------------------------------------------------------------
for type in hpc8a.96xlarge hpc7a.96xlarge; do
    for rpn in 16 32 64 100 128 191; do
        run_2026r1 "no-${type}-${rpn}" STUB_INSTANCE_TYPE="${type}" SLURM_NPROCS=$((2 * rpn)) SLURM_NTASKS=$((2 * rpn))
        refused "${type}, 2 nodes x ${rpn}" \
            "ERROR: $((2 * rpn)) ranks on 2 node(s) (${rpn} per node) load the 24 CCDs of ${type} unevenly; run ${COUNTS} (Utils/flexible-cores). Not starting Fluent."
    done
done
run_2026r1 uneven SLURM_NPROCS=385 SLURM_NTASKS=385
refused "385 ranks on 2 nodes, which do not divide evenly" \
    "ERROR: 385 ranks on 2 node(s) load the 24 CCDs of hpc8a.96xlarge unevenly; run ${COUNTS} (Utils/flexible-cores). Not starting Fluent."
# 2^64 + 192 reads as 192 in bash arithmetic: the script takes 7 digits at most.
run_2026r1 too-long SLURM_NPROCS=18446744073709551808 SLURM_JOB_NUM_NODES=1 SLURM_NODELIST=node1 STUB_NODES=node1
refused "a rank count of 20 digits" \
    "ERROR: 18446744073709551808 ranks on 1 node(s) load the 24 CCDs of hpc8a.96xlarge unevenly; run ${COUNTS} (Utils/flexible-cores). Not starting Fluent."
run_2026r1 no-nprocs SLURM_NPROCS= SLURM_NTASKS=
refused "no SLURM_NPROCS" \
    "ERROR: ? ranks on 2 node(s) load the 24 CCDs of hpc8a.96xlarge unevenly; run ${COUNTS} (Utils/flexible-cores). Not starting Fluent."

# ---------------------------------------------------------------------------
# 3. Other instance types and sizes: no check.
# ---------------------------------------------------------------------------
run_2026r1 hpc6a STUB_INSTANCE_TYPE=hpc6a.48xlarge SLURM_NPROCS=64 SLURM_NTASKS=64
ran "hpc6a.48xlarge, 2 nodes x 32"
run_2026r1 hpc7a-small STUB_INSTANCE_TYPE=hpc7a.48xlarge SLURM_NPROCS=100 SLURM_NTASKS=100
ran "hpc7a.48xlarge, 2 nodes x 50"
run_2026r1 c8i STUB_INSTANCE_TYPE=c8i.96xlarge SLURM_NPROCS=385 SLURM_NTASKS=385
ran "c8i.96xlarge, 385 ranks on 2 nodes"

# ---------------------------------------------------------------------------
# 4. The instance type cannot be read.
# ---------------------------------------------------------------------------
# Both requests to the instance metadata carry a connect and a total time
# limit of at most 5 seconds, and -f, which turns an HTTP error into no answer.
run_2026r1 imds-limits
n_calls="$(grep -cF '169.254.169.254' "${STATE}/curl.log" 2>/dev/null)"
n_bounded="$(grep -F '169.254.169.254' "${STATE}/curl.log" 2>/dev/null \
    | grep -E -- '--connect-timeout [1-5]( |$)' | grep -cE -- '--max-time [1-5]( |$)')"
n_fail="$(grep -F '169.254.169.254' "${STATE}/curl.log" 2>/dev/null \
    | grep -cE -- '(^| )(-[A-Za-z]*f[A-Za-z]*|--fail)( |$)')"
if [ "${n_calls}" = 2 ] && [ "${n_bounded}" = 2 ] && [ "${n_fail}" = 2 ]; then
    ok "both requests to the instance metadata give up within 5 seconds (--connect-timeout, --max-time), and -f turns an HTTP error into no answer"
else
    bad "both requests to the instance metadata give up within 5 seconds, with -f" \
        "2 requests, each with -f, and --connect-timeout and --max-time of 1 to 5" "$(tr '\n' '|' < "${STATE}/curl.log" 2>/dev/null)"
fi

# Nodes, as lscpu describes them: "<vendor id> <sockets> <cores per socket>
# [<threads per core>]".
AMD_192="AuthenticAMD 2 96"
AMD_192_ONE_SOCKET="AuthenticAMD 1 192"
INTEL_192="GenuineIntel 2 96"
AMD_96="AuthenticAMD 2 48"
AMD_96_SMT="AuthenticAMD 2 48 2"
AMD_96_ONE_SOCKET="AuthenticAMD 1 96"
AMD_256="AuthenticAMD 2 128"
ON_AMD_192="ERROR: 200 ranks on 2 node(s) (100 per node) load the 24 CCDs of hpc8a.96xlarge or hpc7a.96xlarge unevenly (the instance metadata did not name the instance type, and this node has 192 AMD cores, as those two do); run ${COUNTS} (Utils/flexible-cores). Not starting Fluent."
SKIPPED="NOTE: the instance metadata did not name the instance type, and lscpu does not show the 192 AMD cores of hpc8a.96xlarge and hpc7a.96xlarge, so their ranks-per-node check (Utils/flexible-cores) is skipped for 200 ranks on 2 node(s) (100 per node)."
ran_with_note() {  # <description>: the last job ran the harness, and printed the NOTE once
    ran "$1"
    if [ "$(printf '%s\n' "${ERR}" | grep -cxF -- "${SKIPPED}")" = 1 ]; then
        ok "$1 -> one NOTE line: the check was skipped"
    else
        bad "$1 -> one NOTE line: the check was skipped" "${SKIPPED}" "${ERR}"
    fi
}
quiet() {  # <description>: the last job ran no lscpu and printed no NOTE about the check
    if [ ! -e "${STATE}/lscpu.log" ] && ! grep -q 'check (Utils/flexible-cores) is skipped' <<< "${ERR}"; then
        ok "$1 -> no lscpu, no NOTE"
    else
        bad "$1 -> no lscpu, no NOTE" "neither" \
            "lscpu $([ -e "${STATE}/lscpu.log" ] && echo run || echo 'not run'); stderr: ${ERR}"
    fi
}

# No answer within the time limits: curl exits 28 and prints nothing.
run_2026r1 noanswer-amd192 STUB_IMDS=no-answer STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "no answer, an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 noanswer-amd192-1s STUB_IMDS=no-answer STUB_CPU="${AMD_192_ONE_SOCKET}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "no answer, an AMD node with 1 x 192 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 noanswer-amd192-tree STUB_IMDS=no-answer STUB_CPU="${AMD_192} indented" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "no answer, an AMD node with 2 x 96 cores in lscpu's indented layout, 2 nodes x 100" "${ON_AMD_192}"
# The job's locale is German, where lscpu prints its keys in German.
run_2026r1 noanswer-amd192-de STUB_IMDS=no-answer STUB_CPU="${AMD_192}" LC_ALL=de_DE.UTF-8 SLURM_NPROCS=200 SLURM_NTASKS=200
refused "no answer, an AMD node with 2 x 96 cores, a German locale, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 noanswer-intel192 STUB_IMDS=no-answer STUB_CPU="${INTEL_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "no answer, an Intel node with 2 x 96 cores, 2 nodes x 100"
run_2026r1 noanswer-amd96 STUB_IMDS=no-answer STUB_CPU="${AMD_96}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "no answer, an AMD node with 2 x 48 cores, 2 nodes x 100"
run_2026r1 noanswer-amd96-smt STUB_IMDS=no-answer STUB_CPU="${AMD_96_SMT}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "no answer, an AMD node with 2 x 48 cores and 2 threads per core (192 CPUs), 2 nodes x 100"
run_2026r1 noanswer-amd96-1s STUB_IMDS=no-answer STUB_CPU="${AMD_96_ONE_SOCKET}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "no answer, an AMD node with 1 x 96 cores, 2 nodes x 100"
run_2026r1 noanswer-amd256 STUB_IMDS=no-answer STUB_CPU="${AMD_256}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "no answer, an AMD node with 2 x 128 cores, 2 nodes x 100"
run_2026r1 noanswer-nolscpu STUB_IMDS=no-answer STUB_CPU=none SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "no answer, no lscpu output, 2 nodes x 100"
run_2026r1 noanswer-96 STUB_IMDS=no-answer STUB_CPU="${AMD_192}" SLURM_NPROCS=192 SLURM_NTASKS=192
ran "no answer, an AMD node with 2 x 96 cores, 2 nodes x 96"
quiet "no answer, 2 nodes x 96"

# An HTTP error (401) for the instance type.
run_2026r1 httperror-amd192 STUB_IMDS=http-error STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "an HTTP error, an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 httperror-intel192 STUB_IMDS=http-error STUB_CPU="${INTEL_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "an HTTP error, an Intel node with 2 x 96 cores, 2 nodes x 100"
# At a supported count the job runs, and curl -f keeps the error page out of
# the run directory's name.
run_2026r1 httperror-96 STUB_IMDS=http-error STUB_CPU="${AMD_192}" SLURM_NPROCS=192 SLURM_NTASKS=192
ran "an HTTP error, 2 nodes x 96"
quiet "an HTTP error, 2 nodes x 96"
case "${WORKDIR}" in
    */4242-2x-192-*) ok "an HTTP error, 2 nodes x 96 -> no instance type in the run directory's name" ;;
    *) bad "an HTTP error, 2 nodes x 96 -> no instance type in the run directory's name" \
           ".../4242-2x-192-<date>" "${WORKDIR}" ;;
esac
# An answer cut off at the time limit (the start of the type name,
# hpc8a.96x, then curl's exit 28) counts as none, though what came through has
# the shape of a type name.
run_2026r1 cutoff-amd192 STUB_IMDS=cut-off STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "an answer cut off at the time limit, an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 cutoff-intel192 STUB_IMDS=cut-off STUB_CPU="${INTEL_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "an answer cut off at the time limit, an Intel node with 2 x 96 cores, 2 nodes x 100"
run_2026r1 cutoff-96 STUB_IMDS=cut-off STUB_CPU="${AMD_192}" SLURM_NPROCS=192 SLURM_NTASKS=192
ran "an answer cut off at the time limit, 2 nodes x 96"
case "${WORKDIR}" in
    */4242-2x-192-*) ok "an answer cut off at the time limit, 2 nodes x 96 -> no instance type in the run directory's name" ;;
    *) bad "an answer cut off at the time limit, 2 nodes x 96 -> no instance type in the run directory's name" \
           ".../4242-2x-192-<date>" "${WORKDIR}" ;;
esac
# An answer that is not an instance type name counts as none too: at a
# supported count the job runs, and a proxy's page does not name the run
# directory either.
run_2026r1 proxy-96 STUB_INSTANCE_TYPE='Access denied by proxy.example.com' STUB_CPU="${AMD_192}" \
    SLURM_NPROCS=192 SLURM_NTASKS=192
ran "a proxy's page, 2 nodes x 96"
quiet "a proxy's page, 2 nodes x 96"
case "${WORKDIR}" in
    */4242-2x-192-*) ok "a proxy's page, 2 nodes x 96 -> no instance type in the run directory's name, and none of the page" ;;
    *) bad "a proxy's page, 2 nodes x 96 -> no instance type in the run directory's name, and none of the page" \
           ".../4242-2x-192-<date>" "${WORKDIR}" ;;
esac

# An answer that is not an instance type name: a word, an empty answer, an
# instance type name inside other text.
run_2026r1 word-amd192 STUB_INSTANCE_TYPE=unknown STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "the answer 'unknown', an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 word-intel192 STUB_INSTANCE_TYPE=unknown STUB_CPU="${INTEL_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "the answer 'unknown', an Intel node with 2 x 96 cores, 2 nodes x 100"
run_2026r1 empty-amd192 STUB_INSTANCE_TYPE= STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "an empty answer, an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 empty-intel192 STUB_INSTANCE_TYPE= STUB_CPU="${INTEL_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran_with_note "an empty answer, an Intel node with 2 x 96 cores, 2 nodes x 100"
run_2026r1 typelast-amd192 STUB_INSTANCE_TYPE='Not found: hpc8a.96xlarge' STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "the answer 'Not found: hpc8a.96xlarge', an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 typefirst-amd192 STUB_INSTANCE_TYPE='hpc8a.96xlarge: not found' STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "the answer 'hpc8a.96xlarge: not found', an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"
run_2026r1 upper-amd192 STUB_INSTANCE_TYPE=HPC8A.96XLARGE STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
refused "the answer 'HPC8A.96XLARGE', an AMD node with 2 x 96 cores, 2 nodes x 100" "${ON_AMD_192}"

# An instance type that reads, on an AMD node with 192 cores: lscpu is not run.
run_2026r1 m8a-amd192 STUB_INSTANCE_TYPE=m8a.48xlarge STUB_CPU="${AMD_192}" SLURM_NPROCS=200 SLURM_NTASKS=200
ran "m8a.48xlarge, an AMD node with 2 x 96 cores, 2 nodes x 100"
quiet "m8a.48xlarge, 2 nodes x 100"
# A type name with an i reads as one in a Turkish locale too, where [a-z] leaves out i.
# A Turkish-locale case checks something only where tr_TR.UTF-8 is installed:
# elsewhere bash falls back to the C locale, where [a-z] holds i anyway, so each
# such case is skipped there, with a SKIP line.
TR=""
if grep -qiE '^tr_TR\.utf-?8$' <<< "$(locale -a 2>/dev/null)"; then TR=1; fi
if [ -n "${TR}" ]; then
    run_2026r1 tr-c8i STUB_INSTANCE_TYPE=c8i.96xlarge STUB_CPU="${INTEL_192}" LANG=tr_TR.UTF-8 SLURM_NPROCS=200 SLURM_NTASKS=200
    ran "c8i.96xlarge, a Turkish locale, 2 nodes x 100"
    quiet "c8i.96xlarge, a Turkish locale, 2 nodes x 100"
else
    skipt "c8i.96xlarge, a Turkish locale, 2 nodes x 100" "the tr_TR.UTF-8 locale is not installed"
fi

summary "2026 R1 script: ranks per node"
