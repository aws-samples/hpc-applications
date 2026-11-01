#!/bin/bash
# =============================================================================
# Flexible cores in the x86 launcher: on hpc8a.96xlarge and hpc7a.96xlarge it runs
# only 24, 48, 72, 96, 120, 144, 168 or 192 cores per node (ranks x threads per
# rank) and refuses any other count before the run directory is made, naming the
# supported counts and saying that it places a count below 192 from the node's
# first core. A supported count below 192 is pinned as before; other instance
# types and sizes get no list and no check.
# When IMDS gives no instance type (no answer, an HTTP error, or an answer that is
# not an instance type name, capitals included) and the count is outside the set,
# a node that lscpu shows as AMD with 192 cores (sockets x cores per socket,
# exactly) gets the same check, and any other node runs, with a one-line NOTE on
# stderr that the check was skipped: no run is refused only because IMDS did not
# answer. A supported count needs no instance type: no lscpu, no NOTE. A type name
# with an i reads as one in a Turkish locale too, where [a-z] leaves out i. Every
# IMDS read has curl's time limits (--connect-timeout 2, --max-time 5) and -f, so
# that no answer within a few seconds, or an HTTP error, leaves the type unknown.
# lscpu is read in the C locale, so its cores read in a German locale too, where
# its labels are German.
#
#   ./tests/test-flexible-cores.sh
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

SUPPORTED="use 24, 48, 72, 96, 120, 144, 168 or 192 cores per node"
FIRST_CORE="This launcher places a count below 192 from the node's first core"
NO_TYPE="NOTE: no instance type from IMDS"
APPLIES="${NO_TYPE}; lscpu shows a 192-core AMD node, which could be an hpc8a.96xlarge or hpc7a.96xlarge, so their cores-per-node check applies"
SKIPPED="${NO_TYPE}, and lscpu does not show a 192-core AMD node, so the flexible-cores check for hpc8a.96xlarge and hpc7a.96xlarge is skipped"

# refused <label>: the last run stopped before mdrun and before its run directory,
# saying on stderr which counts to use and how this launcher places them
refused() {
    if [ "${RC}" -ne 0 ] && grep -qF "${SUPPORTED}" <<<"${ERR}" && grep -qF "${FIRST_CORE}" <<<"${ERR}" \
            && [ "$(mdrun_count)" -eq 0 ] && [ ! -e "${BASE}/Run" ]; then
        ok "$1: refused before mdrun, naming the supported counts"
    else
        bad "$1: refused" "non-zero exit, the supported counts and the placement on stderr, no mdrun, no run directory" \
            "exit ${RC}, $(mdrun_count) mdrun, $(grep -c '^ERROR' <<<"${OUT}") ERROR line(s)"
    fi
}
# error_names <label> <count> <node>: the refusal's first line names the count and the node
error_names() {
    local want="ERROR: $2 cores per node ($2 ranks, THREADS_PER_RANK=1) would load the 24 CCDs of $3 unevenly"
    grep -qxF "${want}" <<<"${ERR}" && ok "$1: the error names the count and ${3}" \
        || bad "$1: the error line" "${want}" "$(grep '^ERROR' <<<"${OUT}" | head -1)"
}
# runs <label>: the last run completed with one mdrun
runs() {
    if [ "${RC}" -eq 0 ] && [ "$(mdrun_count)" -eq 1 ]; then
        ok "$1: runs"
    else
        bad "$1: runs" "exit 0, 1 mdrun" "exit ${RC}, $(mdrun_count) mdrun: $(grep -E '^(ERROR|NOTE)' <<<"${OUT}" | head -1)"
    fi
}
# note <label> <line>: the last run printed the line once, on stderr, and no other IMDS note;
# no_note <label>: it printed no IMDS note
note() {
    if [ "$(grep -cxF "$2" <<<"${ERR}")" -eq 1 ] && [ "$(grep -cF "${NO_TYPE}" <<<"${OUT}")" -eq 1 ]; then
        ok "$1: one NOTE line on stderr"
    else
        bad "$1: the NOTE" "'$2' once, on stderr" "$(grep -F "${NO_TYPE}" <<<"${OUT}" | head -2 | tr '\n' '|')"
    fi
}
no_note() {
    if grep -qF "${NO_TYPE}" <<<"${OUT}"; then
        bad "$1: no IMDS NOTE" "none" "$(grep -F "${NO_TYPE}" <<<"${OUT}" | head -1)"
    else
        ok "$1: no IMDS NOTE"
    fi
}
# imds_bounded <label>: the last run read the instance type from IMDS, and every IMDS
# call it made had --connect-timeout 2, --max-time 5 and -f (--fail)
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
# no_lscpu <label>: the last run did not call lscpu
no_lscpu() {
    if [ -s "${LSCPULOG}" ]; then
        bad "$1: lscpu not asked" "no lscpu call" "$(grep -c . "${LSCPULOG}") call(s)"
    else
        ok "$1: lscpu not asked"
    fi
}
# unknown_type <label>: the last run's directory and job log name the instance type "unknown"
unknown_type() {
    if compgen -G "${BASE}/Run/gromacs/benchMEM/test/4242-1xunknown-192x1-*" > /dev/null \
            && grep -qxF 'Nodes:         1 x unknown' <<<"${OUT}"; then
        ok "$1: the run directory and the job log name the type unknown"
    else
        bad "$1: unknown type" "4242-1xunknown-192x1-..., 'Nodes: 1 x unknown'" \
            "$(ls "${BASE}/Run/gromacs/benchMEM/test" 2>/dev/null | head -1), $(grep '^Nodes:' <<<"${OUT}" | head -1)"
    fi
}

echo "== x86/gromacs-benchmark.sbatch: the instance type from IMDS =="
for t in hpc8a.96xlarge hpc7a.96xlarge; do
    for c in 24 48 72 96 120 144 168 192; do
        run_launcher x86 STUB_INSTANCE_TYPE="${t}" SLURM_NTASKS_PER_NODE="${c}"
        runs "${t}, ${c} cores per node"
    done
    for c in 16 32 64 128 190; do
        run_launcher x86 STUB_INSTANCE_TYPE="${t}" SLURM_NTASKS_PER_NODE="${c}"
        refused "${t}, ${c} cores per node"
        if [ "${c}" = 64 ]; then
            error_names "${t}, 64 cores per node" 64 "${t}"
            no_note "${t}, 64 cores per node"
        fi
    done
    run_launcher x86 STUB_INSTANCE_TYPE="${t}" SLURM_JOB_NUM_NODES=2 SLURM_NTASKS_PER_NODE=32
    refused "${t}, two nodes of 32 cores"
    run_launcher x86 STUB_INSTANCE_TYPE="${t}" THREADS_PER_RANK=5
    refused "${t}, 38 ranks x 5 threads (190 cores per node)"
done

run_launcher x86 STUB_INSTANCE_TYPE=hpc8a.96xlarge SLURM_NTASKS_PER_NODE=96
has_words "hpc8a.96xlarge, 96 cores per node: pinned as before" "$(mdrun_args)" \
    "-ntmpi 96 -ntomp 1 -pin on -pinoffset 0 -pinstride 1"
imds_bounded "hpc8a.96xlarge from IMDS"
run_launcher x86 STUB_INSTANCE_TYPE=hpc8a.96xlarge SLURM_NTASKS_PER_NODE=96 THREADS_PER_RANK=4
runs "hpc8a.96xlarge, 24 ranks x 4 threads (96 cores per node)"
run_launcher x86 STUB_INSTANCE_TYPE=hpc7a.96xlarge SLURM_JOB_NUM_NODES=2 SLURM_NTASKS_PER_NODE=144
runs "hpc7a.96xlarge, two nodes of 144 cores"
has_words "hpc7a.96xlarge, two nodes of 144 cores: mpirun as before" "$(head -1 "${MPILOG}")" \
    "-np 288 --hostfile hostfile --bind-to core --map-by slot"

# Other types: no list and no check, even on a 192-core AMD CPU (m8a.48xlarge).
for spec in hpc6a.48xlarge:64:amd-96 hpc7a.48xlarge:64:amd-96 c8i.96xlarge:100:intel-192 m8a.48xlarge:100:amd-192; do
    IFS=: read -r itype count cpu <<<"${spec}"
    run_launcher x86 STUB_INSTANCE_TYPE="${itype}" STUB_LSCPU="${cpu}" SLURM_NTASKS_PER_NODE="${count}"
    runs "${itype}, ${count} cores per node (no list on this type)"
    no_note "${itype}"
done
# A Turkish-locale case checks something only where tr_TR.UTF-8 is installed:
# elsewhere bash falls back to the C locale, where [a-z] holds i anyway, so each
# such case is skipped there, with a SKIP line.
TR=""
if grep -qiE '^tr_TR\.utf-?8$' <<< "$(locale -a 2>/dev/null)"; then TR=1; fi
if [ -n "${TR}" ]; then
    run_launcher x86 STUB_INSTANCE_TYPE=c8i.96xlarge STUB_LSCPU=intel-192 SLURM_NTASKS_PER_NODE=100 LANG=tr_TR.UTF-8
    runs "c8i.96xlarge in a Turkish locale, 100 cores per node (the type reads)"
    no_note "c8i.96xlarge in a Turkish locale"
    no_lscpu "c8i.96xlarge in a Turkish locale"
else
    skipt "c8i.96xlarge in a Turkish locale, 100 cores per node" "the tr_TR.UTF-8 locale is not installed"
fi

echo "== x86/gromacs-benchmark.sbatch: no instance type from IMDS =="
for mode in none http-error not-a-type; do
    run_launcher x86 STUB_IMDS="${mode}" STUB_LSCPU=amd-192 SLURM_NTASKS_PER_NODE=64
    refused "IMDS ${mode}, a 192-core AMD node, 64 cores per node"
    error_names "IMDS ${mode}, a 192-core AMD node, 64 cores per node" 64 "this 192-core AMD node"
    note "IMDS ${mode}, a 192-core AMD node, 64 cores per node" "${APPLIES}"
    imds_bounded "IMDS ${mode}"
    run_launcher x86 STUB_IMDS="${mode}" STUB_LSCPU=amd-192
    runs "IMDS ${mode}, a 192-core AMD node, 192 cores per node"
    unknown_type "IMDS ${mode}, a 192-core AMD node, 192 cores per node"
    no_note "IMDS ${mode}, a 192-core AMD node, 192 cores per node (a supported count)"
    run_launcher x86 STUB_IMDS="${mode}" STUB_LSCPU=intel-192 SLURM_NTASKS_PER_NODE=64
    runs "IMDS ${mode}, a 192-core Intel node, 64 cores per node"
    note "IMDS ${mode}, a 192-core Intel node, 64 cores per node" "${SKIPPED}"
done
for cpu in amd-96 amd-1x96 amd-256 none; do
    run_launcher x86 STUB_IMDS=none STUB_LSCPU="${cpu}" SLURM_NTASKS_PER_NODE=64
    runs "IMDS none, lscpu ${cpu}, 64 cores per node"
    note "IMDS none, lscpu ${cpu}, 64 cores per node" "${SKIPPED}"
done
# lscpu is read in the C locale: in a German locale its labels are German, and would hide the 192 AMD cores.
run_launcher x86 STUB_IMDS=none STUB_LSCPU=amd-192 SLURM_NTASKS_PER_NODE=64 LC_ALL=de_DE.UTF-8
refused "IMDS none, a 192-core AMD node, LC_ALL=de_DE.UTF-8 (lscpu read in the C locale), 64 cores per node"
note "IMDS none, a 192-core AMD node, LC_ALL=de_DE.UTF-8, 64 cores per node" "${APPLIES}"
run_launcher x86 STUB_IMDS=none STUB_LSCPU=intel-192 SLURM_NTASKS_PER_NODE=96
runs "IMDS none, a 192-core Intel node, 96 cores per node (a supported count)"
no_note "IMDS none, a 192-core Intel node, 96 cores per node"
no_lscpu "IMDS none, a 192-core Intel node, 96 cores per node"
run_launcher x86 STUB_INSTANCE_TYPE=HPC8A.96XLARGE STUB_LSCPU=amd-192 SLURM_NTASKS_PER_NODE=64
refused "the answer HPC8A.96XLARGE (capitals: not a type name), a 192-core AMD node, 64 cores per node"
error_names "the answer HPC8A.96XLARGE, a 192-core AMD node, 64 cores per node" 64 "this 192-core AMD node"
note "the answer HPC8A.96XLARGE, a 192-core AMD node, 64 cores per node" "${APPLIES}"
# A type name inside other text is not a type name: the test's ^ and $ (a page naming a host, a type and more).
for answer in "Request denied by proxy.example.com" "hpc8a.96xlarge: not found"; do
    run_launcher x86 STUB_INSTANCE_TYPE="${answer}" STUB_LSCPU=amd-192 SLURM_NTASKS_PER_NODE=64
    refused "the answer '${answer}', a 192-core AMD node, 64 cores per node"
done

summary "flexible-cores tests"
