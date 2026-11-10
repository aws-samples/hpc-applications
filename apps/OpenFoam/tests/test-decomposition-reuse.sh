#!/bin/bash
# =============================================================================
# The benchmark scripts' decomposition step with DECOMP_CACHE (../README.md,
# "Reusing a decomposition"), each script run end to end with the stubs of
# stubs.sh. What it pins:
#   * without DECOMP_CACHE, decomposePar runs in the job and nothing is saved;
#   * the first run of a case and layout runs decomposePar and saves its
#     processor* directories before renumberMesh changes them, through a
#     partial directory named after the cluster, the job and the process;
#   * the next run of the same case and layout, by the same script or another
#     one, copies them and runs no decomposePar, and the saved copy stays as it
#     was;
#   * another layout, a changed case file (in 0.orig, constant/polyMesh or
#     system/include), a saved copy with a processor directory or its .complete
#     marker missing, or a relative DECOMP_CACHE: decomposePar runs, and no
#     saved copy is changed;
#   * a case without system/include saves and reuses its decomposition too;
#   * a save that cannot be completed (a cache that cannot be written, a copy
#     that stops part way, another job's save of the same layout first, a
#     partial directory of the same name already there): the run completes and
#     records, removes only the directory it created, and changes no other;
#   * a job ended with SIGTERM while it saves removes its partial directory;
#   * every run still reports its decomposition time and passes the simpleFoam
#     phase to the recorder as the time to solution.
#
#   apps/OpenFoam/tests/test-decomposition-reuse.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"

# The case's fields take values from system/include/caseDefinition, as OCC
# DrivAer's do; NOINC is a case without system/include.
mkdir -p "${CASE}/system/include"; echo 'Uinf 1;' > "${CASE}/system/include/caseDefinition"
NOINC="${STUBS}/noinc/occDrivAerStaticMesh"; make_case "${NOINC}"

# ---------------------------------------------------------------------------
# Stubs for single runs, each in a directory of its own put first in PATH.
# Every one passes through to the real command but for the one call it is for.
# ---------------------------------------------------------------------------
# cp, for a copy into a partial directory (cp -a -t <target> <directories>):
#   stops   copies the first directory, then ends with an error;
#   other   first, another job's complete save of the same layout appears;
#   term    copies the first directory, then the job gets SIGTERM.
for mode in stops other term; do
    mkdir -p "${STUBS}/cp-${mode}"
    cat > "${STUBS}/cp-${mode}/cp" <<EOF
#!/bin/bash
mode=${mode}
EOF
    cat >> "${STUBS}/cp-${mode}/cp" <<'EOF'
target=""; srcs=(); next=""
for a in "$@"; do
  if [ "${next}" = t ]; then target="${a}"; next=""; continue; fi
  case "${a}" in -t) next=t;; -*) ;; *) srcs+=("${a}");; esac
done
case "${target}" in
  *.partial.*)
    echo "${target}" >> "${PARTIAL_LOG}"
    case "${mode}" in
      stops) command -p cp -a "${srcs[0]}" "${target}/"; exit 1;;
      other) entry="${target%.partial.*}"
             if [ ! -e "${entry}" ]; then
               command -p mkdir -p "${entry}" && echo "saved by another job" > "${entry}/marker"
             fi;;
      term)  command -p cp -a "${srcs[0]}" "${target}/"
             # The benchmark script is the parent of xargs, which runs this cp.
             kill -TERM "$(awk '/^PPid:/ {print $2}' "/proc/${PPID}/status")"
             exit 1;;
    esac;;
esac
command -p cp "$@"
EOF
    chmod +x "${STUBS}/cp-${mode}/cp"
done
# mkdir, for the partial directory (made without -p): another writer's
# directory of that name, with a file in it, appears just before.
mkdir -p "${STUBS}/mkdir-taken"
cat > "${STUBS}/mkdir-taken/mkdir" <<'EOF'
#!/bin/bash
last="${!#}"
case " $* " in
  *" -p "*) ;;
  *) case "${last}" in
       *.partial.*) command -p mkdir "${last}" && echo "another writer" > "${last}/marker";;
     esac;;
esac
command -p mkdir "$@"
EOF
chmod +x "${STUBS}/mkdir-taken/mkdir"
PARTIAL_LOG="${STUBS}/partial.log"; : > "${PARTIAL_LOG}"
with_path() { echo "PATH=${STUBS}/$1:${STUBS}/bin:/usr/local/bin:/usr/bin:/bin"; }   # with_path <stub directory>
# run_with <stub directory> <script> <job> [NAME=value...]: run_script with that stub first in PATH.
run_with() {
    local dir="$1"; shift
    run_script "$1" "$2" "$(with_path "${dir}")" PARTIAL_LOG="${PARTIAL_LOG}" "${@:3}"
}

processor_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d -name 'processor*' 2>/dev/null | wc -l; }
owner() { tr '\n' '|' < "$1/processor0/constant/polyMesh/owner" 2>/dev/null; }
partials() { find "$1" -name '*.partial.*' 2>/dev/null | wc -l; }
# not_saved <label> <entry>: the NOTE, and the report says decomposePar ran.
not_saved() {
    has "$1: NOTE" "NOTE: the decomposition was not saved to $2; the run goes on."
    has "$1: the report says decomposePar ran" "Decomposed:       decomposePar in this job"
}

job=100
for s in "${SCRIPTS[@]}"; do
    echo "== ${s} =="
    if skip_arm_here "${s}"; then
        skipt "${s}" "this host has a module system, which the Arm launcher loads, and which could put a real MPI first in PATH"
        continue
    fi
    CACHE="${STUBS}/cache-$(basename "${s}" .sbatch)"
    ENTRY="${CACHE}/occDrivAerStaticMesh/2x4"

    job=$((job + 1)); run_script "${s}" "${job}"
    completes "no DECOMP_CACHE" "${job}"
    check "no DECOMP_CACHE: decomposePar runs once" 1 "$(decompositions "${job}")"
    has "no DECOMP_CACHE: the report says so" "Decomposed:       decomposePar in this job"
    [ ! -e "${CACHE}" ] && ok "no DECOMP_CACHE: nothing is saved" || bad "no DECOMP_CACHE: nothing is saved" "no ${CACHE}" "it exists"

    job=$((job + 1)); first="${job}"; run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}"
    completes "first run" "${job}"
    check "first run: decomposePar runs once" 1 "$(decompositions "${job}")"
    has "first run: the report names the saved copy" "Decomposed:       decomposePar in this job, saved to ${ENTRY}"
    [ -f "${ENTRY}/.complete" ] && [ -s "${ENTRY}/inputs.txt" ] && ok "first run: the saved copy is complete" \
        || bad "first run: the saved copy is complete" ".complete and inputs.txt in ${ENTRY}" "$(ls -A "${ENTRY}" 2>&1 | tr '\n' ' ')"
    check "first run: all 8 processor directories are saved" 8 "$(processor_dirs "${ENTRY}")"
    check "first run: saved before renumberMesh changed them" "decomposed by job ${first}|" "$(owner "${ENTRY}")"
    check "first run: renumberMesh changed the run's own copy" "decomposed by job ${first}|renumbered|" "$(owner "${RUN}")"
    check "first run: no partial copy is left" 0 "$(partials "${CACHE}")"

    job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}"
    completes "same case and layout" "${job}"
    check "same case and layout: no decomposePar" 0 "$(decompositions "${job}")"
    has "same case and layout: the report names the copy reused" "Decomposed:       reused from ${ENTRY}"
    check "same case and layout: the run has all 8 processor directories" 8 "$(processor_dirs "${RUN}")"
    check "same case and layout: they are the saved ones, renumbered in the run" \
        "decomposed by job ${first}|renumbered|" "$(owner "${RUN}")"
    check "same case and layout: the saved copy is unchanged" "decomposed by job ${first}|" "$(owner "${ENTRY}")"

    job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}" SLURM_NTASKS_PER_NODE=2
    completes "another layout" "${job}"
    check "another layout (2 x 2): decomposePar runs" 1 "$(decompositions "${job}")"
    check "another layout: saved apart, with its 4 processor directories" 4 \
        "$(processor_dirs "${CACHE}/occDrivAerStaticMesh/2x2")"
    check "another layout: the 2 x 4 copy is unchanged" "decomposed by job ${first}|" "$(owner "${ENTRY}")"

    for f in 0.orig/U constant/polyMesh/points system/include/caseDefinition; do
        touch -r "${CASE}/${f}" "${STUBS}/mtime"
        touch -d '2001-02-03 04:05:06' "${CASE}/${f}"
        job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}"
        touch -r "${STUBS}/mtime" "${CASE}/${f}"
        completes "a changed ${f}" "${job}"
        check "a changed ${f}: decomposePar runs" 1 "$(decompositions "${job}")"
        has "a changed ${f}: NOTE" "NOTE: ${ENTRY} holds no decomposition of this case and layout; decomposing in this job and leaving it as it is."
        check "a changed ${f}: the saved copy is left as it is" "decomposed by job ${first}|" "$(owner "${ENTRY}")"
    done

    rm -rf "${CACHE}/occDrivAerStaticMesh/2x2/processor3"
    job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}" SLURM_NTASKS_PER_NODE=2
    completes "a processor directory missing" "${job}"
    check "a saved copy with a processor directory missing: decomposePar runs" 1 "$(decompositions "${job}")"
    check "a processor directory missing: the saved copy is left as it is" 3 \
        "$(processor_dirs "${CACHE}/occDrivAerStaticMesh/2x2")"

    job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}" SLURM_NTASKS_PER_NODE=3
    rm -f "${CACHE}/occDrivAerStaticMesh/2x3/.complete"
    job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}" SLURM_NTASKS_PER_NODE=3
    completes "no .complete marker" "${job}"
    check "a saved copy without its .complete marker: decomposePar runs" 1 "$(decompositions "${job}")"
    has "no .complete marker: NOTE" \
        "NOTE: ${CACHE}/occDrivAerStaticMesh/2x3 holds no decomposition of this case and layout; decomposing in this job and leaving it as it is."
    [ ! -e "${CACHE}/occDrivAerStaticMesh/2x3/.complete" ] && [ "$(processor_dirs "${CACHE}/occDrivAerStaticMesh/2x3")" -eq 6 ] \
        && ok "no .complete marker: the saved copy is left as it is" \
        || bad "no .complete marker: the saved copy is left as it is" "6 processor directories, no .complete" \
               "$(ls -A "${CACHE}/occDrivAerStaticMesh/2x3" | tr '\n' ' ')"

    job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE=relative-cache
    completes "a relative DECOMP_CACHE" "${job}"
    check "a relative DECOMP_CACHE: decomposePar runs" 1 "$(decompositions "${job}")"
    has "a relative DECOMP_CACHE: NOTE" "NOTE: DECOMP_CACHE must be an absolute path (got 'relative-cache'); not using it."
    check "a relative DECOMP_CACHE: nothing is saved" 0 "$(find "${STUBS}" -name relative-cache | wc -l)"

    C6="${STUBS}/cache-noinc-$(basename "${s}" .sbatch)"
    job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${NOINC}" DECOMP_CACHE="${C6}"
    completes "a case without system/include" "${job}"
    has "a case without system/include: the first run saves its decomposition" \
        "Decomposed:       decomposePar in this job, saved to ${C6}/occDrivAerStaticMesh/2x4"
    job=$((job + 1)); run_script "${s}" "${job}" CASE_SRC="${NOINC}" DECOMP_CACHE="${C6}"
    completes "a case without system/include, the next run" "${job}"
    has "a case without system/include: the next run reuses it" "Decomposed:       reused from ${C6}/occDrivAerStaticMesh/2x4"

    if [ "$(id -u)" -eq 0 ]; then
        skipt "a cache directory that cannot be written" "running as root, who can write it anyway"
    else
        mkdir -p "${STUBS}/locked"; chmod a-w "${STUBS}/locked"
        job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${STUBS}/locked/cache"
        completes "a cache that cannot be written" "${job}"
        not_saved "a cache that cannot be written" "${STUBS}/locked/cache/occDrivAerStaticMesh/2x4"
        check "a cache that cannot be written: nothing is left there" 0 "$(find "${STUBS}/locked" -mindepth 1 | wc -l)"
        chmod u+w "${STUBS}/locked"; rm -rf "${STUBS}/locked"
    fi

    C2="${STUBS}/cache-stops-$(basename "${s}" .sbatch)"
    job=$((job + 1)); run_with cp-stops "${s}" "${job}" DECOMP_CACHE="${C2}"
    completes "a copy that stops part way" "${job}"
    not_saved "a copy that stops part way" "${C2}/occDrivAerStaticMesh/2x4"
    # The path is matched as a string, so a TMPDIR with "+", "(" or "[" in it changes nothing.
    if P="${C2}/occDrivAerStaticMesh/2x4.partial.test.${job}." awk 'index($0, ENVIRON["P"]) == 1 &&
            substr($0, length(ENVIRON["P"]) + 1) ~ /^[0-9]+$/ {f = 1} END {exit !f}' "${PARTIAL_LOG}"; then
        ok "a copy that stops part way: the partial directory is named after the cluster, the job and the process"
    else
        bad "a copy that stops part way: the partial directory is named after the cluster, the job and the process" \
            "${C2}/occDrivAerStaticMesh/2x4.partial.test.${job}.<pid>" "$(tail -1 "${PARTIAL_LOG}")"
    fi
    check "a copy that stops part way: its partial directory is removed" 0 "$(partials "${C2}")"
    [ ! -e "${C2}/occDrivAerStaticMesh/2x4" ] && ok "a copy that stops part way: nothing is saved" \
        || bad "a copy that stops part way: nothing is saved" "no ${C2}/occDrivAerStaticMesh/2x4" "it exists"

    C3="${STUBS}/cache-other-$(basename "${s}" .sbatch)"
    job=$((job + 1)); run_with cp-other "${s}" "${job}" DECOMP_CACHE="${C3}"
    completes "another job saved the layout first" "${job}"
    not_saved "another job saved the layout first" "${C3}/occDrivAerStaticMesh/2x4"
    check "another job saved the layout first: its copy is left as it is" "marker" \
        "$(ls -A "${C3}/occDrivAerStaticMesh/2x4" | tr '\n' ' ' | sed 's/ $//')"
    check "another job saved the layout first: this run's partial directory is removed" 0 "$(partials "${C3}")"

    C4="${STUBS}/cache-taken-$(basename "${s}" .sbatch)"
    job=$((job + 1)); run_with mkdir-taken "${s}" "${job}" DECOMP_CACHE="${C4}"
    completes "a partial directory of the same name" "${job}"
    not_saved "a partial directory of the same name" "${C4}/occDrivAerStaticMesh/2x4"
    check "a partial directory of the same name: it is neither used nor removed" "another writer" \
        "$(cat "${C4}"/occDrivAerStaticMesh/2x4.partial.*/marker 2>/dev/null)"
    check "a partial directory of the same name: nothing else is copied into it" 1 \
        "$(find "${C4}"/occDrivAerStaticMesh/2x4.partial.* -mindepth 1 2>/dev/null | wc -l)"

    C5="${STUBS}/cache-term-$(basename "${s}" .sbatch)"
    job=$((job + 1)); run_with cp-term "${s}" "${job}" DECOMP_CACHE="${C5}"
    check "SIGTERM while it saves: the job ends (exit 143)" 143 "${RC}"
    check "SIGTERM while it saves: its partial directory is removed" 0 "$(partials "${C5}")"
    [ ! -e "${C5}/occDrivAerStaticMesh/2x4" ] && ok "SIGTERM while it saves: nothing is saved" \
        || bad "SIGTERM while it saves: nothing is saved" "no ${C5}/occDrivAerStaticMesh/2x4" "it exists"
    check "SIGTERM while it saves: simpleFoam never starts" 0 "$(launches "${job}" simpleFoam)"
done

echo "== one cache, every script =="
CACHE="${STUBS}/cache-$(basename "${SCRIPTS[0]}" .sbatch)"
ENTRY="${CACHE}/occDrivAerStaticMesh/2x4"
for s in "${SCRIPTS[@]:1}"; do
    if skip_arm_here "${s}"; then skipt "${s} with ${SCRIPTS[0]}'s cache" "module system, as above"; continue; fi
    job=$((job + 1)); run_script "${s}" "${job}" DECOMP_CACHE="${CACHE}"
    completes "${s} with ${SCRIPTS[0]}'s cache" "${job}"
    check "${s}: no decomposePar" 0 "$(decompositions "${job}")"
    has "${s}: the report names the copy reused" "Decomposed:       reused from ${ENTRY}"
done

finish "decomposition reuse tests"
