#!/bin/bash
# =============================================================================
# Unit tests for lib/lsdyna-run.sh (the helpers LS-Dyna.sbatch sources)
# =============================================================================
# No Slurm, no EC2, no MPI, no licensed solver, no AWS credentials, no network.
#
#   ./tests/test-lsdyna-run.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
# shellcheck source=../lib/lsdyna-run.sh
. "${HERE}/../lib/lsdyna-run.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "== the flexible-cores lists =="
for n in 24 48 72 96 120 144 168; do
    list="$(lsdyna_pin_list "${n}")"
    count="$(printf '%s' "${list}" | tr ',' '\n' | grep -c .)"
    # Ranks per CCD: CCD k holds cores 8k to 8k+7.
    per_ccd="$(printf '%s' "${list}" | tr ',' '\n' | awk '{ c[int($1 / 8)]++ } END { for (k = 0; k < 24; k++) printf "%d ", c[k] + 0 }')"
    want="$(awk -v n="${n}" 'BEGIN { for (k = 0; k < 24; k++) printf "%d ", n / 24 }')"
    if [ "${count}" = "${n}" ] && [ "${per_ccd}" = "${want}" ]; then
        ok "${n} per node: ${n} distinct cores, $(( n / 24 )) on each of the 24 CCDs"
    else
        bad "${n} per node" "${n} cores, ${want}" "${count} cores, ${per_ccd}"
    fi
done
for n in 16 32 64 128 192; do
    if lsdyna_pin_list "${n}" >/dev/null; then bad "no list for ${n}" "return 1" "a list"; else ok "no list for ${n}"; fi
done

echo "== pinning =="
lsdyna_pinning hpc8a.96xlarge 144 192 2>/dev/null
is "hpc8a at 144: the 144 list" "${I_MPI_PIN_PROCESSOR_LIST:-}" "$(lsdyna_pin_list 144)"
is "hpc8a at 144: no pin order" "${I_MPI_PIN_ORDER:-unset}" "unset"
lsdyna_pinning hpc7a.96xlarge 96 192 2>/dev/null
is "hpc7a at 96: the 96 list" "${I_MPI_PIN_PROCESSOR_LIST:-}" "$(lsdyna_pin_list 96)"
lsdyna_pinning hpc8a.96xlarge 192 192 2>/dev/null
is "hpc8a full: compact" "${I_MPI_PIN_ORDER:-}/${I_MPI_PIN_PROCESSOR_LIST:-unset}" "compact/unset"
lsdyna_pinning hpc6a.48xlarge 96 96 2>/dev/null
is "hpc6a full: compact" "${I_MPI_PIN_ORDER:-}" "compact"
lsdyna_pinning "" 192 192 2>/dev/null
is "unknown type, full node: compact" "$?/${I_MPI_PIN_ORDER:-}" "0/compact"
err="$(lsdyna_pinning hpc8a.96xlarge 64 192 2>&1 >/dev/null)"; rc=$?
is "hpc8a at 64: refused" "${rc}" "1"
case "${err}" in *unevenly*) ok "hpc8a at 64: the reason names the uneven CCDs";; *) bad "reason" "unevenly" "${err}";; esac
lsdyna_pinning hpc7a.96xlarge 128 192 2>/dev/null; is "hpc7a at 128: refused" "$?" "1"
lsdyna_pinning "" 144 192 2>/dev/null; is "unknown type at 144: refused" "$?" "1"
lsdyna_pinning hpc6a.48xlarge 48 96 2>/dev/null
is "hpc6a at 48: Intel MPI's own placement" "$?/${I_MPI_PIN_PROCESSOR_LIST:-unset}/${I_MPI_PIN_ORDER:-unset}" "0/unset/unset"
lsdyna_pinning hpc8a.96xlarge 200 192 2>/dev/null; is "more ranks than cores: refused" "$?" "1"

echo "== ranks per node =="
is "--ntasks-per-node" "$(SLURM_NTASKS_PER_NODE=144 SLURM_TASKS_PER_NODE='144(x2)' lsdyna_ranks_per_node)" "144"
is "uniform tasks per node" "$(unset SLURM_NTASKS_PER_NODE; SLURM_TASKS_PER_NODE='192(x4)' lsdyna_ranks_per_node)" "192"
is "one node" "$(unset SLURM_NTASKS_PER_NODE; SLURM_TASKS_PER_NODE='96' lsdyna_ranks_per_node)" "96"
( unset SLURM_NTASKS_PER_NODE; SLURM_TASKS_PER_NODE='96,95' lsdyna_ranks_per_node >/dev/null )
is "uneven tasks per node: refused" "$?" "1"

echo "== licence =="
is "Ansys server: ansys" "$(unset LSTC_LICENSE LSTC_LICENSE_SERVER; export ANSYSLMD_LICENSE_FILE=1055@licence-host; lsdyna_licence && echo "${LSTC_LICENSE}")" "ansys"
is "LSTC server: network" "$(unset LSTC_LICENSE ANSYSLMD_LICENSE_FILE; export LSTC_LICENSE_SERVER=licence-host; lsdyna_licence && echo "${LSTC_LICENSE}")" "network"
is "LSTC_LICENSE kept" "$(export LSTC_LICENSE=Ansys ANSYSLMD_LICENSE_FILE=1055@licence-host; lsdyna_licence && echo "${LSTC_LICENSE}")" "Ansys"
( unset LSTC_LICENSE ANSYSLMD_LICENSE_FILE LSTC_LICENSE_SERVER; lsdyna_licence 2>/dev/null ); is "no server: refused" "$?" "1"
( unset ANSYSLMD_LICENSE_FILE LSTC_LICENSE_SERVER; LSTC_LICENSE=ansys lsdyna_licence 2>/dev/null ); is "ansys without its server: refused" "$?" "1"

echo "== the run's pfile =="
lsdyna_write_pfile "${FIX}/pfile-3cars-32" "${TMP}/p1" /run /run/local 0
is "3cars: dir replaced, the rest verbatim" "$(cat "${TMP}/p1")" "$(printf 'gen { nodump nobeamout dboutonly }\ndecomp { silist 6 sy 48 }\ndir { global /run local /run/local }')"
lsdyna_write_pfile "${FIX}/pfile-3cars-32" "${TMP}/p2" /run /run/local 1
is "3cars + lstc_reduce: in its gen section" "$(head -1 "${TMP}/p2")" "gen { lstc_reduce nodump nobeamout dboutonly }"
lsdyna_write_pfile "${FIX}/pfile-car2car" "${TMP}/p3" /run /run/local 0
is "car2car: its two-line dir section replaced" "$(cat "${TMP}/p3")" "dir { global /run local /run/local }"
lsdyna_write_pfile "${FIX}/pfile-car2car" "${TMP}/p4" /run /run/local 1
is "car2car + lstc_reduce: a general section added" "$(cat "${TMP}/p4")" "$(printf 'general { lstc_reduce }\ndir { global /run local /run/local }')"
lsdyna_write_pfile "" "${TMP}/p5" /run /run/local 0
is "no pfile: the directories only" "$(cat "${TMP}/p5")" "dir { global /run local /run/local }"
lsdyna_write_pfile "${FIX}/pfile-multiline" "${TMP}/p6" /run /run/local 1
is "multi-line sections, any case: lstc_reduce on the brace line, Directory dropped" "$(cat "${TMP}/p6")" \
    "$(printf 'General\n{ lstc_reduce\n  nodump\n}\ncontact {\n  inititer 3\n}\ndir { global /run local /run/local }')"
lsdyna_write_pfile "${FIX}/pfile-neon" "${TMP}/p7" /run /run/local 1
is "neon + lstc_reduce" "$(grep -c . "${TMP}/p7")/$(head -1 "${TMP}/p7")" "3/general { lstc_reduce nodump }"
lsdyna_write_pfile "${TMP}/p2" "${TMP}/p8" /run /run/local 1
is "lstc_reduce already there: not added twice" "$(grep -o lstc_reduce "${TMP}/p8" | grep -c .)" "1"

echo "== inputs, termination, elapsed time, revision =="
mkdir -p "${TMP}/model"; : > "${TMP}/model/deck.k"
lsdyna_inputs_clean "${TMP}/model"; is "a directory of inputs is clean" "$?" "0"
: > "${TMP}/model/d3hsp"
lsdyna_inputs_clean "${TMP}/model" 2>/dev/null; is "an earlier run's d3hsp: refused" "$?" "1"
cat > "${TMP}/d3hsp" <<'EOF'
     |  Version : mpp s R13                              |
     |  Revision: R13.1-138-g8429c8a10f                  |
 N o r m a l    t e r m i n a t i o n                          01/01/26 00:00:00
 Elapsed time    1234 seconds for    5678 cycles using   144 MPP procs
 N o r m a l    t e r m i n a t i o n                          01/01/26 00:00:01
EOF
is "normal termination" "$(lsdyna_termination "${TMP}/d3hsp")" "normal"
is "elapsed time" "$(lsdyna_elapsed "${TMP}/d3hsp")" "1234"
is "revision" "$(lsdyna_revision "${TMP}/d3hsp")" "R13.1-138-g8429c8a10f"
printf ' E r r o r   t e r m i n a t i o n                          01/01/26 00:00:00\n' > "${TMP}/out"
is "an error wins over a normal line elsewhere" "$(lsdyna_termination "${TMP}/d3hsp" "${TMP}/out")" "error"
is "no termination line" "$(lsdyna_termination "${TMP}/model/deck.k")" "none"
is "no elapsed line" "$(lsdyna_elapsed "${TMP}/out")" ""

echo
echo "lsdyna-run: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
