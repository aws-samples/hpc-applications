#!/bin/bash
# =============================================================================
# Rank placement of the x86 benchmark scripts (../README.md, "Fewer ranks per
# node"; Utils/flexible-cores), each run end to end with the stubs of stubs.sh.
# What it pins, on hpc8a.96xlarge and hpc7a.96xlarge:
#   * a full node (192 ranks) keeps rank i on core i, with no list;
#   * 24, 48, 72, 96, 120, 144 or 168 ranks per node: the solver phases run with
#     that count's flexible-cores list, the one in Utils/flexible-cores (OpenMPI:
#     --bind-to cpu-list:ordered --cpu-list in place of --bind-to core
#     --map-by slot; Intel MPI: I_MPI_PIN_PROCESSOR_LIST), and the cache drop
#     and THP launches are as before;
#   * any other count is refused before the run directory is made, naming the
#     supported counts, and nothing runs.
# Other instance types and sizes get no list and no refusal, at any count. A
# type IMDS gives is taken as it is: no NOTE and no lscpu, also in a locale in
# which [a-z] does not hold "i" (tr_TR.UTF-8, where it is installed).
# When IMDS gives no instance type (no answer, an empty answer, an HTTP error
# page for the token or for the instance type, an answer cut off at the time
# limit, or an answer that is not an instance type name), lscpu decides, read
# in the C locale. It is a stub here,
# so the host's CPU never decides a case:
#   * a node with 192 AMD cores (2 x 96 or 1 x 192, with one or two threads per
#     core, in either layout lscpu prints, and from a German locale) gets the
#     same list or refusal, naming both types, after a NOTE that says why;
#   * any other node (192 Intel cores; AMD 2 x 48 with two threads per core,
#     1 x 96 or 2 x 128; no lscpu, or an lscpu that prints nothing) runs with no
#     list, and one NOTE on stderr says that the check was skipped;
#   * a full node (192 ranks) runs rank i on core i, with no NOTE and no lscpu;
#   * a page's text reaches neither the run directory's name nor the report;
#   * both IMDS calls ask curl to fail on an HTTP error, with a 2-second connect
#     and a 5-second total timeout.
# The scripts' lists are those of Utils/flexible-cores, and each puts the same
# number of ranks on each of the 24 CCDs.
#
#   apps/OpenFoam/tests/test-flexible-cores.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"
UTILS="$(cd "${OF_APP}/../../Utils/flexible-cores" && pwd)"
X86=(x86/openfoam-benchmark-openmpi.sbatch x86/openfoam-benchmark-intelmpi.sbatch)
# curl for an IMDS that gives no instance type, put first in PATH; each call is
# logged to CURL_LOG:
#   imds-type-error   the instance-type request answers 401;
#   imds-token-error  the token request answers 403, and so the instance-type
#                     request 401;
#   imds-down         no answer: curl prints nothing and exits 28 (a timeout);
#   imds-page         the instance-type request answers 200 with an HTML page
#                     that holds a type's name, which -f does not make an error;
#   imds-cut-off      the instance-type request is cut off at curl's time
#                     limit: curl prints the start of a type name, hpc8a.96x,
#                     and exits 28.
# As curl does, an error page is printed with exit 0, unless curl is given -f
# (--fail): then it prints nothing and exits 22.
for mode in type-error token-error down page cut-off; do
    mkdir -p "${STUBS}/imds-${mode}"
    printf '#!/bin/bash\nmode=%s\n' "${mode}" > "${STUBS}/imds-${mode}/curl"
    cat >> "${STUBS}/imds-${mode}/curl" <<'EOF'
printf '%s\n' "$*" >> "${CURL_LOG}"
fail=""
for a in "$@"; do
  case "${a}" in --fail) fail=1;; --*) ;; -*f*) fail=1;; esac
done
case "$*" in
  *api/token*|*instance-type*) ;;
  *) echo "curl stub: refusing $*" >&2; exit 22;;
esac
[ "${mode}" != down ] || exit 28
case "$*" in
  *api/token*) if [ "${mode}" != token-error ]; then echo "stub-token"; exit 0; fi
               status="403 - Forbidden";;
  *)           if [ "${mode}" = page ]; then
                 printf '<!DOCTYPE html>\n<html><body><p>hpc8a.96xlarge</p></body></html>\n'; exit 0
               fi
               if [ "${mode}" = cut-off ]; then printf 'hpc8a.96x'; exit 28; fi
               status="401 - Unauthorized";;
esac
[ -z "${fail}" ] || exit 22
printf '<?xml version="1.0" encoding="iso-8859-1"?>\n<!DOCTYPE html>\n<html><head><title>%s</title></head><body><h1>%s</h1></body></html>\n' \
  "${status}" "${status}"
EOF
    chmod +x "${STUBS}/imds-${mode}/curl"
done
# lscpu, first in PATH in the stubs' bin; each call is logged to lscpu.log with
# the locale it ran in. It describes the node STUB_LSCPU names, "<vendor id>
# <sockets> <cores per socket> <threads per core>" (by default an Intel node of
# 2 x 48 cores), as util-linux 2.37 prints it, with the BIOS vendor line lscpu
# adds when it can read one; "tree:" first gives the indented layout of
# util-linux 2.38 and later. Its labels are German when the messages locale
# (LC_ALL, else LC_MESSAGES, else LANG) is, as lscpu prints them there.
# "missing" answers as a node without lscpu (exit 127), "fails" as an lscpu
# that prints nothing (exit 1).
printf '#!/bin/bash\nlog=%q\n' "${STUBS}/lscpu.log" > "${STUBS}/bin/lscpu"
cat >> "${STUBS}/bin/lscpu" <<'EOF'
loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
printf 'lscpu\tlocale=%s\n' "${loc}" >> "${log}"
shape="${STUB_LSCPU:-GenuineIntel 2 48 1}"
case "${shape}" in
  missing) echo "lscpu: command not found" >&2; exit 127;;
  fails)   exit 1;;
esac
in1=""; in2=""
case "${shape}" in tree:*) in1="  "; in2="    "; shape="${shape#tree:}";; esac
read -r vendor sockets cores threads <<<"${shape}"
case "${vendor}" in
  AuthenticAMD) bios="Advanced Micro Devices, Inc."; model="AMD EPYC 9R45";;
  *)            bios="Intel(R) Corporation"; model="Intel(R) Xeon(R) 6975P-C";;
esac
case "${loc}" in
  de*) l=(Architektur "CPU(s)" Anbieterkennung BIOS-Anbieterkennung Modellname "Thread(s) pro Kern" "Kern(e) pro Sockel" Sockel);;
  *)   l=(Architecture "CPU(s)" "Vendor ID" "BIOS Vendor ID" "Model name" "Thread(s) per core" "Core(s) per socket" "Socket(s)");;
esac
row() { printf '%-37s %s\n' "$1:" "$2"; }
row "${l[0]}" x86_64
row "${l[1]}" "$((sockets * cores * threads))"
row "${l[2]}" "${vendor}"
row "${in1}${l[3]}" "${bios}"
row "${in1}${l[4]}" "${model}"
row "${in2}${l[5]}" "${threads}"
row "${in2}${l[6]}" "${cores}"
row "${in2}${l[7]}" "${sockets}"
EOF
chmod +x "${STUBS}/bin/lscpu"
: > "${STUBS}/lscpu.log"
# For a run whose stderr is kept apart: bash reads BASH_ENV before the script,
# so the script's stderr (and its stubs') goes to stderr.txt, and OUT holds its
# stdout only.
printf 'exec 2>>%q\n' "${STUBS}/stderr.txt" > "${STUBS}/stderr-env.sh"
# utils_list <count>: the list of Utils/flexible-cores/hello-cpu.openmpi.explicit.sbatch for that count.
utils_list() {
    awk -v c="$1)" '$1 == c {f = 1; next} f && /OPEN_MPI_PROCESSOR_LIST=/ {
        sub(/.*OPEN_MPI_PROCESSOR_LIST="/, ""); sub(/".*/, ""); print; exit}' "${UTILS}/hello-cpu.openmpi.explicit.sbatch"
}
# script_list <script> <count>: the list the script holds for that count.
script_list() {
    awk -v c="$2)" '$1 == c && /echo "/ {sub(/.*echo "/, ""); sub(/".*/, ""); print; exit}' "${OF_APP}/$1"
}
# placed <label> <script> <job> <list | "">: how the solver phases and the cache drop were launched.
placed() {
    local app args
    for app in renumberMesh potentialFoam simpleFoam; do
        args=" $(launch_field "$3" "${app}" 3) "
        if [ "$2" = x86/openfoam-benchmark-openmpi.sbatch ]; then
            if [ -n "$4" ]; then
                case "${args}" in
                    *" --bind-to cpu-list:ordered --cpu-list $4 "*" ${app} "*) ok "$1: ${app} is bound to the list" ;;
                    *) bad "$1: ${app} is bound to the list" "--bind-to cpu-list:ordered --cpu-list $4" "${args}" ;;
                esac
                case "${args}" in
                    *" --bind-to core "*|*" --map-by slot "*) bad "$1: ${app} has no other binding" "no --bind-to core / --map-by slot" "${args}" ;;
                    *) ok "$1: ${app} has no other binding" ;;
                esac
            else
                case "${args}" in
                    *" --bind-to core --map-by slot "*) ok "$1: ${app} runs rank i on core i" ;;
                    *) bad "$1: ${app} runs rank i on core i" "--bind-to core --map-by slot" "${args}" ;;
                esac
                case "${args}" in
                    *" --cpu-list "*) bad "$1: ${app} has no list" "no --cpu-list" "${args}" ;;
                    *) ok "$1: ${app} has no list" ;;
                esac
            fi
        else
            check "$1: ${app} pinned with ${4:+the list}${4:-no list}" "${4:-<unset>}" "$(launch_field "$3" "${app}" 4)"
        fi
    done
    if [ "$2" = x86/openfoam-benchmark-openmpi.sbatch ]; then
        case " $(launch_field "$3" - 3) " in
            *" --map-by ppr:1:node "*" --bind-to core --map-by slot "*) ok "$1: the cache drop and THP launch as before" ;;
            *) bad "$1: the cache drop and THP launch as before" "--map-by ppr:1:node ... --bind-to core --map-by slot" \
                   "$(launch_field "$3" - 3)" ;;
        esac
    fi
}
# ---------------------------------------------------------------------------
# When IMDS gives no instance type
# ---------------------------------------------------------------------------
TWO="hpc8a.96xlarge or hpc7a.96xlarge"
APPLIES="NOTE: IMDS gave no instance type, and lscpu shows 192 AMD cores, as on an hpc8a.96xlarge or hpc7a.96xlarge, so the flexible-cores check applies."
skipped_note() {  # skipped_note <ranks per node>: the NOTE of a node lscpu does not show as one of the two types
    echo "NOTE: IMDS gave no instance type, and lscpu does not show the 192 AMD cores of an hpc8a.96xlarge or hpc7a.96xlarge, so the flexible-cores check is skipped: $1 ranks per node run with no list."
}
lines() {  # lines <exact line> [<file>]: how many times OUT, or the file, holds that line
    if [ -n "${2:-}" ]; then grep -cxF -- "$1" "$2"; else grep -cxF -- "$1" <<<"${OUT}"; fi
}
quiet() {  # quiet <label>: OUT holds no NOTE about the instance type
    check "$1: no NOTE about the instance type" 0 "$(grep -c '^NOTE: IMDS gave no instance type' <<<"${OUT}")"
}
lscpu_calls() { awk 'END {print NR}' "${STUBS}/lscpu.log"; }
asked_once() {  # asked_once <label>: lscpu was asked once, in the C locale
    check "$1: lscpu asked once, in the C locale" "1 C" \
        "$(awk -F'\t' '{n++; l = $2} END {sub(/^locale=/, "", l); print n + 0, l}' "${STUBS}/lscpu.log")"
}
# node <STUB_LSCPU>: the node, as the checks name it.
node() {
    local v so c t
    case "$1" in
        missing) echo "no lscpu" ;;
        fails)   echo "an lscpu that prints nothing" ;;
        tree:*)  echo "$(node "${1#tree:}"), indented" ;;
        *) read -r v so c t <<<"$1"
           case "${v}" in AuthenticAMD) v=AMD ;; GenuineIntel) v=Intel ;; esac
           if [ "${t}" = 1 ]; then echo "${v} ${so} x ${c} cores"; else echo "${v} ${so} x ${c} cores, ${t} threads per core"; fi ;;
    esac
}
# untyped <imds> <STUB_LSCPU> <ranks per node> [NAME=value...]: run ${s} on a
# node whose IMDS gives no instance type. <imds> is a curl mode above, or
# "answer" for the stubs' own curl, which answers STUB_INSTANCE_TYPE (pass it as
# NAME=value). Clears the curl and lscpu logs first.
untyped() {
    local imds="$1" cpu="$2" n="$3" path="${STUBS}/bin:/usr/local/bin:/usr/bin:/bin"
    shift 3
    [ "${imds}" = answer ] || path="${STUBS}/imds-${imds}:${path}"
    : > "${STUBS}/curl.log"; : > "${STUBS}/lscpu.log"
    job=$((job + 1))
    run_script "${s}" "${job}" "PATH=${path}" CURL_LOG="${STUBS}/curl.log" STUB_LSCPU="${cpu}" \
        SLURM_NTASKS_PER_NODE="${n}" "$@"
}
# refused_both <label> <ranks per node>: refused as on the two types, naming both.
refused_both() {
    check "$1: refused (exit 1)" 1 "${RC}"
    has "$1: ERROR naming both types and the supported counts" \
        "ERROR: $2 ranks per node would load the 24 CCDs of ${TWO} unevenly; the supported counts are 24, 48, 72, 96, 120, 144, 168 and 192 (see Utils/flexible-cores)"
    check "$1: one NOTE that the check applies" 1 "$(lines "${APPLIES}")"
    check "$1: no NOTE that the check was skipped" 0 "$(lines "$(skipped_note "$2")")"
    check "$1: no run directory" "" "${RUN}"
    check "$1: nothing runs" "0 0" "$(decompositions "${job}") $(launches "${job}" simpleFoam)"
    asked_once "$1"
}
# bound_both <label> <ranks per node>: runs with the list for the count, naming both types.
bound_both() {
    completes "$1" "${job}"
    placed "$1" "${s}" "${job}" "$(utils_list "$2")"
    has "$1: the job log says so" "Binding $2 ranks per node to the flexible-cores list of ${TWO}"
    check "$1: one NOTE that the check applies" 1 "$(lines "${APPLIES}")"
    check "$1: no NOTE that the check was skipped" 0 "$(lines "$(skipped_note "$2")")"
    asked_once "$1"
}
# skipped_run <label> <ranks per node>: runs with no list, after one NOTE that the check was skipped.
skipped_run() {
    completes "$1" "${job}"
    placed "$1" "${s}" "${job}" ""
    check "$1: one NOTE that the check was skipped" 1 "$(lines "$(skipped_note "$2")")"
    check "$1: no NOTE that the check applies" 0 "$(lines "${APPLIES}")"
    check "$1: no ERROR" 0 "$(grep -c '^ERROR' <<<"${OUT}")"
    asked_once "$1"
}
# full_untyped <label>: a full node runs rank i on core i, with no NOTE and no lscpu.
full_untyped() {
    completes "$1" "${job}"
    placed "$1" "${s}" "${job}" ""
    quiet "$1"
    check "$1: lscpu is not asked" 0 "$(lscpu_calls)"
}
echo "== the lists =="
for c in 24 48 72 96 120 144 168; do
    want="$(utils_list "${c}")"
    per_ccd="$(tr ',' '\n' <<<"${want}" | awk -v n="${c}" '{k[int($1 / 8)]++} END {
        m = 0; for (i in k) {m++; if (k[i] != n / 24) bad = 1}; print (m == 24 && !bad) ? "balanced" : "unbalanced"}')"
    check "${c} ranks per node: Utils/flexible-cores puts $((c / 24)) on each of the 24 CCDs" balanced "${per_ccd}"
    for s in "${X86[@]}"; do
        check "${c} ranks per node: ${s} holds the list of Utils/flexible-cores" "${want}" "$(script_list "${s}" "${c}")"
    done
done
job=600
AMD="AuthenticAMD 2 96 1"; INTEL="GenuineIntel 2 96 1"
for s in "${X86[@]}"; do
    echo "== ${s} =="
    : > "${STUBS}/lscpu.log"
    for t in hpc8a.96xlarge hpc7a.96xlarge; do
        job=$((job + 1)); run_script "${s}" "${job}" STUB_INSTANCE_TYPE="${t}" SLURM_NTASKS_PER_NODE=192
        completes "${t}, 192 ranks per node" "${job}"
        placed "${t}, 192 ranks per node" "${s}" "${job}" ""
        quiet "${t}, 192 ranks per node"
        case "${t}" in hpc8a.96xlarge) counts="24 48 72 96 120 144 168" ;; *) counts="48 96" ;; esac
        for c in ${counts}; do
            job=$((job + 1)); run_script "${s}" "${job}" STUB_INSTANCE_TYPE="${t}" SLURM_NTASKS_PER_NODE="${c}"
            completes "${t}, ${c} ranks per node" "${job}"
            placed "${t}, ${c} ranks per node" "${s}" "${job}" "$(utils_list "${c}")"
            has "${t}, ${c} ranks per node: the job log says so" \
                "Binding ${c} ranks per node to the flexible-cores list of ${t}"
            quiet "${t}, ${c} ranks per node"
        done
        case "${t}" in hpc8a.96xlarge) counts="16 32 64 128 100 191 384" ;; *) counts="64" ;; esac
        for c in ${counts}; do
            job=$((job + 1)); run_script "${s}" "${job}" STUB_INSTANCE_TYPE="${t}" SLURM_NTASKS_PER_NODE="${c}"
            check "${t}, ${c} ranks per node: refused (exit 1)" 1 "${RC}"
            has "${t}, ${c} ranks per node: ERROR naming the supported counts" \
                "ERROR: ${c} ranks per node would load the 24 CCDs of ${t} unevenly; the supported counts are 24, 48, 72, 96, 120, 144, 168 and 192 (see Utils/flexible-cores)"
            check "${t}, ${c} ranks per node: no run directory" "" "${RUN}"
            check "${t}, ${c} ranks per node: nothing runs" "0 0" "$(decompositions "${job}") $(launches "${job}" simpleFoam)"
            quiet "${t}, ${c} ranks per node"
        done
    done
    for tc in hpc7a.48xlarge:48 hpc7a.48xlarge:24 hpc7a.24xlarge:24 hpc6a.48xlarge:48 m8a.48xlarge:96 c8i.96xlarge:64; do
        t="${tc%:*}"; c="${tc#*:}"
        job=$((job + 1)); run_script "${s}" "${job}" STUB_INSTANCE_TYPE="${t}" SLURM_NTASKS_PER_NODE="${c}"
        completes "${t}, ${c} ranks per node" "${job}"
        placed "${t}, ${c} ranks per node: no list" "${s}" "${job}" ""
        quiet "${t}, ${c} ranks per node"
    done
    # In these locales [a-z] does not hold "i" (where they are installed): the
    # type is read in the C locale, so it still reads.
    for tl in hpc6id.32xlarge:LANG c8i.96xlarge:LC_ALL; do
        t="${tl%:*}"; l="${tl#*:}=tr_TR.UTF-8"
        job=$((job + 1)); run_script "${s}" "${job}" STUB_INSTANCE_TYPE="${t}" SLURM_NTASKS_PER_NODE=64 "${l}"
        completes "${t} from a Turkish locale (${l}), 64 ranks per node" "${job}"
        placed "${t} from a Turkish locale (${l}), 64 ranks per node: no list" "${s}" "${job}" ""
        quiet "${t} from a Turkish locale (${l}), 64 ranks per node"
        case "${RUN}" in
            */"${job}-2x${t}-128-"*) ok "${t} from a Turkish locale (${l}): the run directory names the type" ;;
            *) bad "${t} from a Turkish locale (${l}): the run directory names the type" "<...>/${job}-2x${t}-128-<date>" "${RUN}" ;;
        esac
    done
    check "an instance type IMDS gives: lscpu is never asked" 0 "$(lscpu_calls)"

    echo "== ${s}: no instance type from IMDS =="
    # Each way IMDS can give no type, on a 192-core AMD node and on a 192-core Intel node.
    for imds in down type-error token-error page cut-off; do
        case "${imds}" in
            down)        what="no answer from IMDS" ;;
            type-error)  what="an IMDS error page for the instance type" ;;
            token-error) what="an IMDS error page for the token" ;;
            page)        what="an IMDS page that is not a type name" ;;
            cut-off)     what="an IMDS answer cut off at the time limit" ;;
        esac
        untyped "${imds}" "${AMD}" 64
        refused_both "${what}, $(node "${AMD}"), 64 ranks per node" 64
        check "${what}: both IMDS calls fail on an HTTP error, with a 2 s connect and a 5 s total timeout" 2 \
            "$(grep -c '^-fs --connect-timeout 2 --max-time 5 .*169\.254\.169\.254' "${STUBS}/curl.log")"
        untyped "${imds}" "${INTEL}" 64
        skipped_run "${what}, $(node "${INTEL}"), 64 ranks per node" 64
        case "${RUN}" in
            */"${job}-2x-128-"*) ok "${what}: the run directory names no instance type" ;;
            *) bad "${what}: the run directory names no instance type" "<...>/${job}-2x-128-<date>" "${RUN}" ;;
        esac
        has "${what}: the report names no instance type" "Instance type:    "
    done
    # Answers that are not an instance type name, from the stubs' own curl.
    NONTYPE=("" "<p>hpc8a.96xlarge" "hpc8a.96xlarge</p>" "HPC8A.96XLARGE" "unavailable" $'hpc8a.96xlarge\nhpc8a.96xlarge')
    NONTYPE_WHAT=("an empty answer" "an answer with text before a type's name" "an answer with text after a type's name"
                  "an answer in capitals" "an answer with no dot" "an answer of two lines")
    for i in "${!NONTYPE[@]}"; do
        untyped answer "${AMD}" 64 STUB_INSTANCE_TYPE="${NONTYPE[$i]}"
        refused_both "${NONTYPE_WHAT[$i]}, $(node "${AMD}"), 64 ranks per node" 64
    done
    # The nodes lscpu shows as AMD with 192 cores, and the others.
    for cpu in "tree:${AMD}" "AuthenticAMD 1 192 1" "AuthenticAMD 2 96 2"; do
        untyped down "${cpu}" 64
        refused_both "no answer from IMDS, $(node "${cpu}"), 64 ranks per node" 64
    done
    untyped down "${AMD}" 64 LC_ALL=de_DE.UTF-8
    refused_both "no answer from IMDS, $(node "${AMD}"), 64 ranks per node, from a German locale (LC_ALL)" 64
    for cpu in "AuthenticAMD 2 48 2" "AuthenticAMD 1 96 1" "AuthenticAMD 2 128 1" "GenuineIntel 2 48 1" missing fails; do
        untyped down "${cpu}" 64
        skipped_run "no answer from IMDS, $(node "${cpu}"), 64 ranks per node" 64
    done
    # Other counts, and a full node.
    untyped down "${AMD}" 96
    bound_both "no answer from IMDS, $(node "${AMD}"), 96 ranks per node" 96
    untyped down "${AMD}" 384
    refused_both "no answer from IMDS, $(node "${AMD}"), 384 ranks per node" 384
    untyped down "${INTEL}" 96
    skipped_run "no answer from IMDS, $(node "${INTEL}"), 96 ranks per node" 96
    for cpu in "${AMD}" "${INTEL}"; do
        untyped down "${cpu}" 192
        full_untyped "no answer from IMDS, $(node "${cpu}"), 192 ranks per node"
    done
    # Where the lines go: the NOTEs and the ERROR to stderr, none to stdout.
    : > "${STUBS}/stderr.txt"
    untyped down "${INTEL}" 64 BASH_ENV="${STUBS}/stderr-env.sh"
    check "no answer from IMDS, $(node "${INTEL}"): the NOTE is on stderr, not on stdout" "1 0" \
        "$(lines "$(skipped_note 64)" "${STUBS}/stderr.txt") $(lines "$(skipped_note 64)")"
    : > "${STUBS}/stderr.txt"
    untyped down "${AMD}" 64 BASH_ENV="${STUBS}/stderr-env.sh"
    check "no answer from IMDS, $(node "${AMD}"): the NOTE and the ERROR are on stderr, not on stdout" "1 1 0" \
        "$(lines "${APPLIES}" "${STUBS}/stderr.txt") $(grep -c '^ERROR: 64 ranks per node' "${STUBS}/stderr.txt") $(grep -c '^NOTE\|^ERROR' <<<"${OUT}")"
done
finish "flexible cores"
