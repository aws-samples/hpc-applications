#!/bin/bash
# =============================================================================
# Helpers for LS-Dyna.sbatch (sourced; never run on its own)
# =============================================================================
# Each function is small and side-effect free apart from what it says it sets,
# so tests/test-lsdyna-run.sh can check it without Slurm, EC2, MPI or a solver.
# =============================================================================

# Official core lists for an under-populated hpc8a.96xlarge or hpc7a.96xlarge:
# every one of the 24 CCDs (8 cores each, one L3 per CCD) gets the same number of
# ranks. The same lists as Utils/flexible-cores/hello-cpu.intelmpi.explicit.sbatch.
# lsdyna_pin_list <ranks per node>: print the list, or return 1 for a count that
# has none (192 is a full node: no list needed).
lsdyna_pin_list() {
    case "${1:-}" in
        24)  echo "0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160,168,176,184" ;;
        48)  echo "0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,64,68,72,76,80,84,88,92,96,100,104,108,112,116,120,124,128,132,136,140,144,148,152,156,160,164,168,172,176,180,184,188" ;;
        72)  echo "0,1,2,8,9,10,16,17,18,24,25,26,32,33,34,40,41,42,48,49,50,56,57,58,64,65,66,72,73,74,80,81,82,88,89,90,96,97,98,104,105,106,112,113,114,120,121,122,128,129,130,136,137,138,144,145,146,152,153,154,160,161,162,168,169,170,176,177,178,184,185,186" ;;
        96)  echo "0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62,64,66,68,70,72,74,76,78,80,82,84,86,88,90,92,94,96,98,100,102,104,106,108,110,112,114,116,118,120,122,124,126,128,130,132,134,136,138,140,142,144,146,148,150,152,154,156,158,160,162,164,166,168,170,172,174,176,178,180,182,184,186,188,190" ;;
        120) echo "0,1,2,3,4,8,9,10,11,12,16,17,18,19,20,24,25,26,27,28,32,33,34,35,36,40,41,42,43,44,48,49,50,51,52,56,57,58,59,60,64,65,66,67,68,72,73,74,75,76,80,81,82,83,84,88,89,90,91,92,96,97,98,99,100,104,105,106,107,108,112,113,114,115,116,120,121,122,123,124,128,129,130,131,132,136,137,138,139,140,144,145,146,147,148,152,153,154,155,156,160,161,162,163,164,168,169,170,171,172,176,177,178,179,180,184,185,186,187,188" ;;
        144) echo "0,1,2,3,4,5,8,9,10,11,12,13,16,17,18,19,20,21,24,25,26,27,28,29,32,33,34,35,36,37,40,41,42,43,44,45,48,49,50,51,52,53,56,57,58,59,60,61,64,65,66,67,68,69,72,73,74,75,76,77,80,81,82,83,84,85,88,89,90,91,92,93,96,97,98,99,100,101,104,105,106,107,108,109,112,113,114,115,116,117,120,121,122,123,124,125,128,129,130,131,132,133,136,137,138,139,140,141,144,145,146,147,148,149,152,153,154,155,156,157,160,161,162,163,164,165,168,169,170,171,172,173,176,177,178,179,180,181,184,185,186,187,188,189" ;;
        168) echo "0,1,2,3,4,5,6,8,9,10,11,12,13,14,16,17,18,19,20,21,22,24,25,26,27,28,29,30,32,33,34,35,36,37,38,40,41,42,43,44,45,46,48,49,50,51,52,53,54,56,57,58,59,60,61,62,64,65,66,67,68,69,70,72,73,74,75,76,77,78,80,81,82,83,84,85,86,88,89,90,91,92,93,94,96,97,98,99,100,101,102,104,105,106,107,108,109,110,112,113,114,115,116,117,118,120,121,122,123,124,125,126,128,129,130,131,132,133,134,136,137,138,139,140,141,142,144,145,146,147,148,149,150,152,153,154,155,156,157,158,160,161,162,163,164,165,166,168,169,170,171,172,173,174,176,177,178,179,180,181,182,184,185,186,187,188,189,190" ;;
        *)   return 1 ;;
    esac
}

# lsdyna_pinning <instance type or ""> <ranks per node> <physical cores per node>
# Sets Intel MPI's pinning for one rank per core, and LSDYNA_PINNING to what it
# chose (call it in the job's shell, not in $(...), so the settings stay):
#   - a full node: I_MPI_PIN_ORDER=compact (one rank on every core, in order);
#   - hpc8a/hpc7a.96xlarge at 24, 48, ..., 168 ranks per node: the official list;
#   - any other instance type below its core count: Intel MPI's own placement.
# With no instance type (""), a node below its core count that lscpu shows with
# 192 AMD cores (lsdyna_amd_192_cores) could be an hpc8a/hpc7a.96xlarge, so it gets
# their list, or their refusal; any other node gets Intel MPI's own placement, with
# a one-line NOTE on stderr that the check is skipped. lscpu is read only then.
# Returns 1, with the reason on stderr, for a count that would load the CCDs of an
# hpc8a/hpc7a.96xlarge (or of such a node) unevenly, and for more ranks than cores.
lsdyna_pinning() {
    local itype="$1" rpn="$2" cores="$3" list node="$1" why="" flex=0
    unset I_MPI_PIN_PROCESSOR_LIST I_MPI_PIN_ORDER
    export I_MPI_PIN=1
    LSDYNA_PINNING=""
    if [ "${rpn}" -gt "${cores}" ]; then
        echo "ERROR: ${rpn} ranks per node on ${cores} physical cores" >&2
        return 1
    fi
    if [ "${rpn}" -eq "${cores}" ]; then
        export I_MPI_PIN_ORDER=compact
        LSDYNA_PINNING="compact: one rank on each of the ${cores} cores"
        return 0
    fi
    case "${itype}" in
        hpc8a.96xlarge|hpc7a.96xlarge)
            flex=1 ;;
        "")
            if lsdyna_amd_192_cores; then
                flex=1; node="hpc8a.96xlarge or hpc7a.96xlarge"
                why="the instance metadata did not name the instance type, and this node has 192 AMD cores,"
                why+=" as those two do"
            else
                echo "NOTE: the instance metadata did not name the instance type, and lscpu does not show the 192 AMD" \
                     "cores of hpc8a.96xlarge and hpc7a.96xlarge, so their ranks-per-node check (Utils/flexible-cores)" \
                     "is skipped for ${rpn} ranks per node" >&2
            fi ;;
    esac
    if [ "${flex}" -eq 1 ]; then
        if ! list="$(lsdyna_pin_list "${rpn}")"; then
            echo "ERROR: ${rpn} ranks per node load the 24 CCDs of ${node} unevenly${why:+ (${why})};" \
                 "use 24, 48, 72, 96, 120, 144, 168 or 192 (Utils/flexible-cores)" >&2
            return 1
        fi
        export I_MPI_PIN_PROCESSOR_LIST="${list}"
        LSDYNA_PINNING="flexible-cores list for ${rpn} of 192 cores (the same number of ranks on every CCD)"
        LSDYNA_PINNING+="${why:+, as on ${node} (${why})}"
    elif [ -z "${itype}" ]; then
        LSDYNA_PINNING="Intel MPI's own placement for ${rpn} of ${cores} cores on a node whose instance type is unknown"
        LSDYNA_PINNING+=" (I_MPI_DEBUG=5 prints where each rank runs)"
    else
        LSDYNA_PINNING="Intel MPI's own placement for ${rpn} of ${cores} cores on ${itype}"
        LSDYNA_PINNING+=" (no published list for this type; I_MPI_DEBUG=5 prints where each rank runs)"
    fi
}

# lsdyna_amd_192_cores: returns 0 when lscpu shows an AMD processor (vendor
# AuthenticAMD) with 192 cores (sockets x cores per socket), as hpc8a.96xlarge and
# hpc7a.96xlarge have, and 1 otherwise, lscpu missing or unreadable included.
# lscpu is read in the C locale: in other locales its labels are translated.
lsdyna_amd_192_cores() {
    [ "$(LC_ALL=C lscpu 2>/dev/null | awk -F: '
        { k = $1; sub(/^[[:space:]]+/, "", k); v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v) }
        k == "Vendor ID" { vendor = v }
        k == "Socket(s)" { sockets = v }
        k == "Core(s) per socket" { cores = v }
        END { if (vendor == "AuthenticAMD" && sockets ~ /^[0-9]+$/ && cores ~ /^[0-9]+$/ &&
                  sockets * cores == 192) print "yes" }')" = yes ]
}

# lsdyna_ranks_per_node: the ranks Slurm placed on every node, from
# SLURM_NTASKS_PER_NODE, else SLURM_TASKS_PER_NODE ("192(x2)" or "192"). Returns 1
# when the nodes hold different counts ("96,95"): mpirun -ppn needs one count.
lsdyna_ranks_per_node() {
    local t="${SLURM_TASKS_PER_NODE:-}"
    if [[ "${SLURM_NTASKS_PER_NODE:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "${SLURM_NTASKS_PER_NODE}"; return 0
    fi
    if [[ "${t}" =~ ^([1-9][0-9]*)(\(x[1-9][0-9]*\))?$ ]]; then
        echo "${BASH_REMATCH[1]}"; return 0
    fi
    return 1
}

# lsdyna_licence: chooses LSTC_LICENSE from the environment and exports it.
#   LSTC_LICENSE already set   kept as given
#   ANSYSLMD_LICENSE_FILE set  ansys (Ansys's licensing, for Ansys's and LSTC's builds)
#   LSTC_LICENSE_SERVER set    network (an LSTC licence server)
# Returns 1, with the reason on stderr, when neither server is set.
lsdyna_licence() {
    if [ -n "${LSTC_LICENSE:-}" ]; then
        export LSTC_LICENSE
    elif [ -n "${ANSYSLMD_LICENSE_FILE:-}" ]; then
        export LSTC_LICENSE=ansys
    elif [ -n "${LSTC_LICENSE_SERVER:-}" ]; then
        export LSTC_LICENSE=network
    fi
    case "${LSTC_LICENSE:-}" in
        ansys|Ansys|ANSYS)
            [ -n "${ANSYSLMD_LICENSE_FILE:-}" ] && return 0
            echo "ERROR: LSTC_LICENSE=${LSTC_LICENSE} needs ANSYSLMD_LICENSE_FILE=<port>@<server>" >&2 ;;
        network)
            [ -n "${LSTC_LICENSE_SERVER:-}" ] && return 0
            echo "ERROR: LSTC_LICENSE=network needs LSTC_LICENSE_SERVER=<host>" >&2 ;;
        "")
            echo "ERROR: no licence server: set ANSYSLMD_LICENSE_FILE=<port>@<server> (Ansys licensing)" \
                 "or LSTC_LICENSE_SERVER=<host> (an LSTC licence server)" >&2 ;;
        *)
            return 0 ;;
    esac
    return 1
}

# lsdyna_write_pfile <shipped pfile or ""> <out> <global dir> <local dir> <lstc_reduce 0|1>
# Writes the run's pfile: the shipped one without its directory section, everything
# else verbatim, then "dir { global <global> local <local> }". With lstc_reduce 1,
# "lstc_reduce" goes into the general section (one is added when the pfile has
# none). A pfile is case-insensitive and free format (Appendix O of the keyword
# manual): sections are "<name> { ... }" on one line or more, and the shipped
# TopCrunch pfiles abbreviate the names ("dir", "gen", "decomp").
lsdyna_write_pfile() {
    local shipped="${1:-}" out="$2" global="$3" local_dir="$4" reduce="${5:-0}"
    [ -n "${shipped}" ] || shipped=/dev/null
    awk -v reduce="${reduce}" '
        # The section a line starts, as "directory" or "general" for any abbreviation of
        # two letters or more, else its first word.
        function section(line,   name) {
            name = tolower(line); sub(/^[ \t]*/, "", name); sub(/[ \t{].*$/, "", name)
            if (length(name) >= 2 && index("directory", name) == 1) return "directory"
            if (length(name) >= 2 && index("general", name) == 1) return "general"
            return name
        }
        skipping == 0 && section($0) == "directory" { skipping = 1; opened = 0 }
        skipping == 1 {
            if (index($0, "{")) opened = 1
            if (opened && index($0, "}")) skipping = 0
            next
        }
        reduce == 1 && !added && section($0) == "general" { want = 1 }
        want && index($0, "{") {
            if (tolower($0) !~ /lstc_reduce/) sub(/\{/, "{ lstc_reduce")
            want = 0; added = 1
        }
        { print }
        END { if (reduce == 1 && !added) print "general { lstc_reduce }" }
    ' "${shipped}" > "${out}" || return 1
    printf 'dir { global %s local %s }\n' "${global}" "${local_dir}" >> "${out}"
}

# lsdyna_inputs_clean <directory>: returns 1 (naming the file on stderr) when the
# directory holds output of an earlier LS-DYNA run. The run directory links every
# file of the deck's directory, and LS-DYNA would write through such a link.
lsdyna_inputs_clean() {
    local d="$1" f
    for f in d3hsp messag mes0000 d3plot glstat binout0000 status.out; do
        if [ -e "${d}/${f}" ]; then
            echo "ERROR: ${d} holds ${f} from an earlier LS-DYNA run; keep the model's input files in a" \
                 "directory of their own" >&2
            return 1
        fi
    done
}

# lsdyna_termination <file>...: "normal", "error" or "none", from LS-DYNA's own
# termination line in d3hsp or the solver's output (an error wins).
lsdyna_termination() {
    if grep -aqs 'E r r o r   t e r m i n a t i o n' "$@"; then echo error
    elif grep -aqs 'N o r m a l    t e r m i n a t i o n' "$@"; then echo normal
    else echo none; fi
}

# lsdyna_elapsed <d3hsp>: LS-DYNA's own elapsed seconds, from
# "Elapsed time N seconds for C cycles using P MPP procs"; nothing if absent.
lsdyna_elapsed() {
    awk '/^ *Elapsed time +[0-9]+ seconds for +[0-9]+ cycles using +[0-9]+ MPP procs/ { e = $3 }
         END { if (e != "") print e }' "$1" 2>/dev/null
}

# lsdyna_revision <d3hsp>: the banner's revision ("R13.1-138-g8429c8a10f"); the
# version is the part before the first "-".
lsdyna_revision() {
    awk '/\| *Revision *:/ { r = $0; sub(/.*Revision *: */, "", r); sub(/[ \t|]+$/, "", r); print r; exit }' \
        "$1" 2>/dev/null
}
