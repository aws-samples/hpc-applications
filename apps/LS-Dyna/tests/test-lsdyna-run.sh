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

# A stub lscpu, first on the PATH: the summary lines lsdyna_amd_192_cores reads, for the
# CPU STUB_CPU names ("<vendor> <sockets> <cores per socket>").
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/lscpu" <<'EOF'
#!/bin/bash
read -r vendor sockets per_socket <<< "${STUB_CPU:?}"
printf '%-26s%s\n' "Vendor ID:" "${vendor}" "    Core(s) per socket:" "${per_socket}" "    Socket(s):" "${sockets}"
EOF
chmod +x "${TMP}/bin/lscpu"
PATH="${TMP}/bin:${PATH}"

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
# An unknown type below a full node: lscpu decides.
STUB_CPU="AuthenticAMD 2 96" lsdyna_pinning "" 144 192 2>/dev/null
is "unknown type, 192 AMD cores, 144: the 144 list" "$?/${I_MPI_PIN_PROCESSOR_LIST:-unset}" "0/$(lsdyna_pin_list 144)"
err="$(STUB_CPU="AuthenticAMD 2 96" lsdyna_pinning "" 64 192 2>&1 >/dev/null)"; rc=$?
is "unknown type, 192 AMD cores, 64: refused" "${rc}" "1"
case "${err}" in
    *"of hpc8a.96xlarge or hpc7a.96xlarge unevenly"*"use 24, 48, 72, 96, 120, 144, 168 or 192"*)
        ok "unknown type, 192 AMD cores, 64: the reason names both types and the supported counts" ;;
    *) bad "unknown type, 192 AMD cores, 64: the reason" "both types and the supported counts" "${err}" ;;
esac
STUB_CPU="GenuineIntel 2 96" lsdyna_pinning "" 64 192 2>"${TMP}/note" >"${TMP}/stdout"
is "unknown type, 192 Intel cores, 64: Intel MPI's own placement" \
    "$?/${I_MPI_PIN_PROCESSOR_LIST:-unset}/${I_MPI_PIN_ORDER:-unset}" "0/unset/unset"
is "unknown type, 192 Intel cores, 64: one NOTE line on stderr, nothing on stdout" \
    "$(grep -c '^NOTE: .* is skipped for 64 ranks per node$' "${TMP}/note")/$(grep -c '' "${TMP}/note")/$(grep -c '' "${TMP}/stdout")" \
    "1/1/0"
lsdyna_pinning hpc6a.48xlarge 48 96 2>/dev/null
is "hpc6a at 48: Intel MPI's own placement" "$?/${I_MPI_PIN_PROCESSOR_LIST:-unset}/${I_MPI_PIN_ORDER:-unset}" "0/unset/unset"
lsdyna_pinning hpc8a.96xlarge 200 192 2>/dev/null; is "more ranks than cores: refused" "$?" "1"
# Exactly 192 AMD cores: a 2 x 128 AMD node is not an hpc8a/hpc7a.96xlarge.
STUB_CPU="AuthenticAMD 2 128" lsdyna_pinning "" 144 256 2>"${TMP}/note256" >/dev/null
is "unknown type, 256 AMD cores, 144: Intel MPI's own placement" \
    "$?/${I_MPI_PIN_PROCESSOR_LIST:-unset}/${I_MPI_PIN_ORDER:-unset}" "0/unset/unset"
is "unknown type, 256 AMD cores, 144: one NOTE line" \
    "$(grep -c '^NOTE: .* is skipped for 144 ranks per node$' "${TMP}/note256")/$(grep -c '' "${TMP}/note256")" "1/1"
# Sockets x cores per socket: one socket of 192 AMD cores counts as 192, one socket of 96 does not.
STUB_CPU="AuthenticAMD 1 192" lsdyna_pinning "" 144 192 2>/dev/null
is "unknown type, one socket of 192 AMD cores, 144: the 144 list" "$?/${I_MPI_PIN_PROCESSOR_LIST:-unset}" "0/$(lsdyna_pin_list 144)"
STUB_CPU="AuthenticAMD 1 96" lsdyna_pinning "" 48 96 2>"${TMP}/note96" >/dev/null
is "unknown type, one socket of 96 AMD cores, 48: Intel MPI's own placement and one NOTE line" \
    "$?/${I_MPI_PIN_PROCESSOR_LIST:-unset}/${I_MPI_PIN_ORDER:-unset}/$(grep -c '^NOTE: .* is skipped for 48 ranks per node$' "${TMP}/note96")/$(grep -c '' "${TMP}/note96")" \
    "0/unset/unset/1/1"
# lscpu is read, and the NOTE printed, only for an unknown type below a full node.
mkdir -p "${TMP}/bin2"
printf '#!/bin/bash\necho called >> "%s"\nexec "%s" "$@"\n' "${TMP}/lscpu-calls" "${TMP}/bin/lscpu" > "${TMP}/bin2/lscpu"
chmod +x "${TMP}/bin2/lscpu"
STUB_CPU="GenuineIntel 2 96" lsdyna_pinning "" 192 192 2>"${TMP}/note-full" >/dev/null
is "unknown type, full node: compact and no NOTE" "$?/${I_MPI_PIN_ORDER:-unset}/$(grep -c '' "${TMP}/note-full")" "0/compact/0"
lscpu_calls() {  # lscpu_calls <STUB_CPU> <lsdyna_pinning's arguments>: how many times lscpu ran
    : > "${TMP}/lscpu-calls"
    ( PATH="${TMP}/bin2:${PATH}"; hash -r; STUB_CPU="$1"; export STUB_CPU; shift; lsdyna_pinning "$@" >/dev/null 2>&1 )
    grep -c '' "${TMP}/lscpu-calls"
}
is "no lscpu call: unknown type, full node" "$(lscpu_calls "GenuineIntel 2 96" "" 192 192)" "0"
is "no lscpu call: unknown type, more ranks than cores" "$(lscpu_calls "GenuineIntel 2 96" "" 200 192)" "0"
is "no lscpu call: hpc8a.96xlarge at 144" "$(lscpu_calls "AuthenticAMD 2 96" hpc8a.96xlarge 144 192)" "0"
is "no lscpu call: c8i.96xlarge at 64" "$(lscpu_calls "GenuineIntel 2 96" c8i.96xlarge 64 192)" "0"
is "one lscpu call: unknown type at 144 on 192 AMD cores" "$(lscpu_calls "AuthenticAMD 2 96" "" 144 192)" "1"

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
