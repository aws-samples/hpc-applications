#!/bin/bash
# =============================================================================
# LAMMPS -> AI-Powered HPC benchmark contribution recorder
# =============================================================================
# Records one LAMMPS benchmark run into the shared AI-Powered HPC DynamoDB
# dataset so it can train the HPC performance-prediction model.
#
# This script is SELF-CONTAINED: it has no dependency on any other file in this
# repository. Copy just this one file to your cluster (or `curl` it) and run it.
# (It lives alongside record_to_dynamodb.sh, the maintainers' internal uploader;
# this one is the portable, external-contributor entry point.)
#
# It is also SAFE by default:
#   * It ALWAYS writes the record as a local JSON file you can inspect/keep.
#   * It only calls `aws dynamodb put-item` when AWS credentials with write
#     access are available (or you pass --put). With no credentials it just
#     saves the JSON and tells you where it is, so you can send it to the
#     dataset owner or upload it to their contribution inbox. Nothing fails.
#   * `--dry-run` prints the record to stdout and touches neither disk nor AWS.
#
# ---------------------------------------------------------------------------
# What gets recorded (the canonical schema the model ingests)
# ---------------------------------------------------------------------------
# Required (the run is rejected by the model if any of these is missing):
#   instance_type, operating_system, num_cores, num_instances, libraries
# Strongly recommended (this is what makes the row USEFUL for training):
#   benchmark_case            the case/dataset name (e.g. lj, eam, rhodo)
#   time_to_solution_seconds  total solver wall-clock time (the model's target)
#   timesteps_per_sec         LAMMPS throughput (timesteps/s from the log)
#   atoms_million             system size in millions of atoms
# Optional but valuable:
#   analysis_type, lammps_version, cores_per_node
#
# The record lands in a DynamoDB table named  External_<Source>_Lammps  in the
# owner's account/region. The ingestion side reads every External_* table with
# an identity map, so the canonical attribute names below are consumed as-is.
#
# ---------------------------------------------------------------------------
# Quick start
# ---------------------------------------------------------------------------
#   # On a SLURM compute node, right after the run (auto-detects most fields):
#   ./record-benchmark.sh \
#       --case lj --atoms-million 8.0 \
#       --time-to-solution 312 --timesteps-per-sec 4820 \
#       --source AcmeCorp
#
#   # Off-cluster / replaying a result (pass everything explicitly):
#   ./record-benchmark.sh --case rhodo --atoms-million 0.032 \
#       --instance-type hpc7g.16xlarge --os "Amazon Linux 2" \
#       --num-cores 256 --num-nodes 4 --mpi openmpi --version 2Aug2023 \
#       --time-to-solution 168 --timesteps-per-sec 1190 \
#       --analysis-type md --source AcmeCorp --dry-run
#
# Run  ./record-benchmark.sh --help  for the full option list.
# =============================================================================

set -uo pipefail

# --- Application identity (do not change) ------------------------------------
readonly APPLICATION="lammps"
readonly APP_TABLE_SEGMENT="Lammps"   # matches Python str.capitalize("lammps")

# --- Defaults ----------------------------------------------------------------
SOURCE="${SOURCE:-Community}"
REGION="${DYNAMODB_REGION:-us-east-1}"
TABLE=""
OUTDIR="${PWD}"
DRY_RUN=0
DO_PUT="auto"           # auto | yes | no

# Canonical fields (may be supplied via flag or environment).
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
NUM_CORES="${NUM_CORES:-}"
NUM_INSTANCES="${NUM_INSTANCES:-}"
CORES_PER_NODE="${CORES_PER_NODE:-}"
MPI_IMPLEMENTATION="${MPI_IMPLEMENTATION:-}"
BENCHMARK_CASE="${BENCHMARK_CASE:-}"
RECORD_ID="${RECORD_ID:-}"
ENGINE_VERSION="${LAMMPS_VERSION:-}"

# LAMMPS performance metrics.
TIME_TO_SOLUTION="${TIME_TO_SOLUTION:-}"
TIMESTEPS_PER_SEC="${TIMESTEPS_PER_SEC:-}"

# LAMMPS dataset characteristics.
DISCIPLINE="MD"           # always true for LAMMPS; override if you must
ANALYSIS_TYPE="${ANALYSIS_TYPE:-}"
ATOMS_MILLION="${ATOMS_MILLION:-}"

# Directory scanned for log.lammps to recover metrics in zero-arg use
# (defaults to the current dir, which is the run dir when called from a job).
RUN_DIR="${RUN_DIR:-$PWD}"

# Generic extra metrics/characteristics (repeatable --metric/--char name=value).
declare -a EXTRA_METRICS=()
declare -a EXTRA_CHARS=()

usage() {
    sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

OPTIONS
  Identity / destination:
    --source LABEL            Your org/handle, e.g. AcmeCorp (default: Community).
                              Becomes the table suffix External_<LABEL>_Lammps and
                              the record's external provenance. Letters/digits only.
    --table NAME              Override the destination table name entirely.
    --region REGION           AWS region of the table (default: us-east-1).
    --id ID                   Record id (DynamoDB key). Auto-generated if omitted.

  Core run configuration (auto-detected on SLURM/EC2 when omitted):
    --instance-type TYPE      EC2 instance type (e.g. hpc7g.16xlarge).
    --os NAME                 Operating system (e.g. "Amazon Linux 2").
    --num-cores N             Total cores (MPI ranks) used.
    --num-nodes N             Number of instances/nodes used.
    --cores-per-node N        Cores per node (derived from the two above if omitted).
    --mpi NAME                MPI implementation (e.g. openmpi, intelmpi).
    --version VER             LAMMPS version (e.g. 2Aug2023).

  Result + dataset description (recommended):
    --case NAME               Benchmark case / dataset id (e.g. lj, eam, rhodo).
    --time-to-solution SEC    Total run wall-clock seconds (the model target).
    --timesteps-per-sec X     LAMMPS throughput in timesteps/second (from the log).
    --atoms-million X         System size in millions of atoms.
    --analysis-type T         md | minimization | nemd | ...
    --discipline D            Defaults to MD.
    --metric NAME=VALUE       Any extra numeric performance metric (repeatable).
    --char NAME=VALUE         Any extra dataset characteristic (repeatable).

  Behavior:
    --put                     Force the DynamoDB put-item (error out if it fails).
    --no-put                  Never call AWS; only write the JSON file.
    --dry-run                 Print the record to stdout; touch no file and no AWS.
    --run-dir DIR             Dir to scan for log.lammps when metrics aren't
                              supplied (default: current dir). Enables zero-arg use.
    --out DIR                 Directory for the saved JSON (default: current dir).
    -h, --help                Show this help.
EOF
}

# --- Argument parsing --------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --source)             SOURCE="$2"; shift 2;;
        --table)              TABLE="$2"; shift 2;;
        --region)             REGION="$2"; shift 2;;
        --id)                 RECORD_ID="$2"; shift 2;;
        --instance-type)      INSTANCE_TYPE="$2"; shift 2;;
        --os)                 OPERATING_SYSTEM="$2"; shift 2;;
        --num-cores)          NUM_CORES="$2"; shift 2;;
        --num-nodes)          NUM_INSTANCES="$2"; shift 2;;
        --cores-per-node)     CORES_PER_NODE="$2"; shift 2;;
        --mpi)                MPI_IMPLEMENTATION="$2"; shift 2;;
        --version)            ENGINE_VERSION="$2"; shift 2;;
        --case)               BENCHMARK_CASE="$2"; shift 2;;
        --time-to-solution)   TIME_TO_SOLUTION="$2"; shift 2;;
        --timesteps-per-sec)  TIMESTEPS_PER_SEC="$2"; shift 2;;
        --atoms-million)      ATOMS_MILLION="$2"; shift 2;;
        --analysis-type)      ANALYSIS_TYPE="$2"; shift 2;;
        --discipline)         DISCIPLINE="$2"; shift 2;;
        --metric)             EXTRA_METRICS+=("$2"); shift 2;;
        --char)               EXTRA_CHARS+=("$2"); shift 2;;
        --put)                DO_PUT="yes"; shift;;
        --no-put)             DO_PUT="no"; shift;;
        --dry-run)            DRY_RUN=1; shift;;
        --run-dir)            RUN_DIR="$2"; shift 2;;
        --out)                OUTDIR="$2"; shift 2;;
        -h|--help)            usage; exit 0;;
        *) echo "ERROR: unknown option '$1' (try --help)" >&2; exit 2;;
    esac
done

# --- Helpers -----------------------------------------------------------------
imds() {
    local path="$1" token
    token=$(curl -fsS --connect-timeout 1 --max-time 2 -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || return 0
    curl -fsS --connect-timeout 1 --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null || return 0
}

json_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

is_number() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

declare -a ITEM_LINES=()
add_s() {
    [ -n "${2:-}" ] || return 0
    ITEM_LINES+=("    \"$1\": {\"S\": \"$(json_escape "$2")\"}")
}
add_n() {
    [ -n "${2:-}" ] || return 0
    if ! is_number "$2"; then
        echo "WARN: ignoring non-numeric value for '$1': '$2'" >&2; return 0
    fi
    ITEM_LINES+=("    \"$1\": {\"N\": \"$2\"}")
}
add_kv() {
    local fn="$1" pair="$2" name="${2%%=*}" val="${2#*=}"
    if [ "$pair" = "$name" ] || [ -z "$name" ]; then
        echo "WARN: ignoring malformed '$pair' (expected name=value)" >&2; return 0
    fi
    "$fn" "$name" "$val"
}

# --- Auto-detect environment (only fills values not already supplied) --------
[ -n "$INSTANCE_TYPE" ]    || INSTANCE_TYPE="$(imds instance-type)"
[ -n "$NUM_CORES" ]        || NUM_CORES="${SLURM_NTASKS:-${SLURM_NPROCS:-}}"
[ -n "$NUM_INSTANCES" ]    || NUM_INSTANCES="${SLURM_JOB_NUM_NODES:-}"
if [ -z "$OPERATING_SYSTEM" ] && [ -r /etc/os-release ]; then
    OPERATING_SYSTEM="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
fi
if [ -z "$CORES_PER_NODE" ] && is_number "${NUM_CORES:-}" && is_number "${NUM_INSTANCES:-}" \
        && [ "${NUM_INSTANCES:-0}" -gt 0 ] 2>/dev/null; then
    CORES_PER_NODE=$(( (NUM_CORES / NUM_INSTANCES) + (NUM_CORES % NUM_INSTANCES > 0) ))
fi
if [ -z "$MPI_IMPLEMENTATION" ] && command -v mpirun >/dev/null 2>&1; then
    _mpiv="$(mpirun --version 2>&1)"
    if   echo "$_mpiv" | grep -qi "Intel";    then MPI_IMPLEMENTATION="intelmpi"
    elif echo "$_mpiv" | grep -qi "Open MPI"; then MPI_IMPLEMENTATION="openmpi"
    fi
fi

MPI_VERSION="$(mpirun --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
LIBFABRIC_VERSION="$(fi_info --version 2>/dev/null | awk '/libfabric:/ {print $2; exit}')"
EFA_VERSION="$(fi_info -p efa -t FI_EP_RDM 2>/dev/null | awk '/version:/ {print $2; exit}')"

# --- Zero-arg fallback: recover LAMMPS result metrics from log.lammps --------
# When a value wasn't supplied (flag or env), parse it from LAMMPS's log.lammps
# in RUN_DIR. LAMMPS prints near the end:
#     Loop time of <t> on <P> procs for <N> steps with <A> atoms
# (fields $4=loop time, $9=steps, $12=atoms). time_to_solution = loop time;
# timesteps_per_sec = steps / loop time. The version banner "LAMMPS (<date>)"
# supplies the version. This lets the recorder run with no arguments.
_llog=""
for _c in "$RUN_DIR"/log.lammps "$RUN_DIR"/log.run "$RUN_DIR"/*.log; do
    [ -f "$_c" ] || continue
    if grep -qE '^Loop time of' "$_c" 2>/dev/null; then _llog="$_c"; break; fi
done
if [ -n "$_llog" ]; then
    _loop="$(grep -E '^Loop time of' "$_llog" 2>/dev/null | tail -1)"
    _lt="$(printf '%s\n' "$_loop" | awk '{print $4}')"
    _ls="$(printf '%s\n' "$_loop" | awk '{print $9}')"
    _at="$(printf '%s\n' "$_loop" | awk '{print $12}')"
    [ -n "$TIME_TO_SOLUTION" ]  || TIME_TO_SOLUTION="$_lt"
    [ -n "$TIMESTEPS_PER_SEC" ] || TIMESTEPS_PER_SEC="$(awk -v a="$_lt" -v s="$_ls" 'BEGIN{if (a+0>0 && s!="") printf "%.4f", s/a}')"
    [ -n "$ATOMS_MILLION" ]     || ATOMS_MILLION="$(awk -v x="$_at" 'BEGIN{if (x+0>0) printf "%.6g", x/1000000}')"
fi
if [ -z "$ENGINE_VERSION" ]; then
    ENGINE_VERSION="$(grep -hoE 'LAMMPS \([^)]*\)' "$RUN_DIR"/log.lammps "$RUN_DIR"/log.run 2>/dev/null | head -1 | sed -E 's/^LAMMPS \(//; s/\)$//')"
fi

# --- Normalize source + table ------------------------------------------------
SOURCE="$(printf '%s' "$SOURCE" | tr -cd '[:alnum:]')"
[ -n "$SOURCE" ] || SOURCE="Community"
[ -n "$TABLE" ]  || TABLE="External_${SOURCE}_${APP_TABLE_SEGMENT}"

# --- Validate required fields ------------------------------------------------
errors=0
require() { if [ -z "${2:-}" ]; then echo "ERROR: missing required field: $1" >&2; errors=1; fi; }
require "instance_type (--instance-type)" "$INSTANCE_TYPE"
require "operating_system (--os)"         "$OPERATING_SYSTEM"
require "num_cores (--num-cores)"         "$NUM_CORES"
require "num_instances (--num-nodes)"     "$NUM_INSTANCES"
if [ -z "${MPI_IMPLEMENTATION}${MPI_VERSION}${LIBFABRIC_VERSION}${EFA_VERSION}${ENGINE_VERSION}" ]; then
    echo "ERROR: cannot compose 'libraries' (provide at least --mpi or --version)" >&2
    errors=1
fi
if [ "$errors" -ne 0 ]; then
    echo "Aborting: fill the missing field(s) above. See --help." >&2
    exit 1
fi

[ -n "$BENCHMARK_CASE" ]   || echo "NOTE: no --case given; the case/dataset name strongly improves model accuracy." >&2
[ -n "$TIME_TO_SOLUTION" ] || echo "NOTE: no --time-to-solution given; this is the model's primary target metric." >&2
[ -n "$ATOMS_MILLION" ]    || echo "NOTE: no --atoms-million given; system size is a key driver of runtime." >&2

# --- Identity / timestamps ---------------------------------------------------
RECORDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -z "$RECORD_ID" ]; then
    _jid="${SLURM_JOB_ID:-$RANDOM}"
    _case="${BENCHMARK_CASE:-run}"
    RECORD_ID="${APPLICATION}-${SOURCE}-${INSTANCE_TYPE:-na}-${NUM_CORES}c-${_case}-${RECORDED_AT//[:-]/}-${_jid}"
fi

# --- Build the libraries list ------------------------------------------------
declare -a LIBS=()
[ -n "$MPI_IMPLEMENTATION" ] && LIBS+=("mpi:${MPI_IMPLEMENTATION}")
[ -n "$MPI_VERSION" ]        && LIBS+=("mpi-version:${MPI_VERSION}")
[ -n "$LIBFABRIC_VERSION" ]  && LIBS+=("libfabric:${LIBFABRIC_VERSION}")
[ -n "$EFA_VERSION" ]        && LIBS+=("efa:${EFA_VERSION}")
[ -n "$ENGINE_VERSION" ]     && LIBS+=("lammps:${ENGINE_VERSION}")
libraries_json=""
for lib in "${LIBS[@]}"; do
    frag="{\"S\": \"$(json_escape "$lib")\"}"
    if [ -z "$libraries_json" ]; then libraries_json="$frag"; else libraries_json="$libraries_json, $frag"; fi
done

# --- Assemble the canonical DynamoDB item ------------------------------------
add_s "record_id"            "$RECORD_ID"
add_s "application"          "$APPLICATION"
add_s "benchmark_case"       "$BENCHMARK_CASE"
add_s "instance_type"        "$INSTANCE_TYPE"
add_s "operating_system"     "$OPERATING_SYSTEM"
add_n "num_cores"            "$NUM_CORES"
add_n "num_instances"        "$NUM_INSTANCES"
add_n "cores_per_node"       "$CORES_PER_NODE"
add_s "mpi_implementation"   "$MPI_IMPLEMENTATION"
ITEM_LINES+=("    \"libraries\": {\"L\": [$libraries_json]}")
# Performance metrics
add_n "time_to_solution_seconds" "$TIME_TO_SOLUTION"
add_n "timesteps_per_sec"    "$TIMESTEPS_PER_SEC"
for pair in "${EXTRA_METRICS[@]:-}"; do [ -n "$pair" ] && add_kv add_n "$pair"; done
# Dataset characteristics
add_s "discipline"           "$DISCIPLINE"
add_s "analysis_type"        "$ANALYSIS_TYPE"
add_n "atoms_million"        "$ATOMS_MILLION"
for pair in "${EXTRA_CHARS[@]:-}"; do [ -n "$pair" ] && add_kv add_s "$pair"; done
# Engine version (kept as metadata; also captured inside libraries)
add_s "lammps_version"       "$ENGINE_VERSION"
# Provenance (tags this row as an external contribution from <source>)
add_s "provenance_origin"    "external"
add_s "provenance_source_id" "$SOURCE"
add_s "recorded_at"          "$RECORDED_AT"

ITEM_JSON="{"$'\n'
for i in "${!ITEM_LINES[@]}"; do
    ITEM_JSON+="${ITEM_LINES[$i]}"
    [ "$i" -lt $(( ${#ITEM_LINES[@]} - 1 )) ] && ITEM_JSON+=","
    ITEM_JSON+=$'\n'
done
ITEM_JSON+="}"

# --- Output ------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "# DRY RUN — would write to table '${TABLE}' (region ${REGION}); no file, no AWS."
    echo "$ITEM_JSON"
    exit 0
fi

mkdir -p "$OUTDIR"
JSON_FILE="${OUTDIR}/$(printf '%s' "$RECORD_ID" | tr -cd '[:alnum:]._-').json"
printf '%s\n' "$ITEM_JSON" > "$JSON_FILE"
echo "Record written: ${JSON_FILE}"

attempt_put=0
case "$DO_PUT" in
    yes) attempt_put=1;;
    no)  attempt_put=0;;
    auto) if command -v aws >/dev/null 2>&1; then attempt_put=1; fi;;
esac

if [ "$attempt_put" -eq 1 ]; then
    if ! command -v aws >/dev/null 2>&1; then
        echo "NOTE: AWS CLI not found; kept JSON only. Send ${JSON_FILE} to the dataset owner." >&2
        exit 0
    fi
    put_err="$( aws dynamodb put-item --region "$REGION" --table-name "$TABLE" \
                    --item "file://${JSON_FILE}" 2>&1 )"
    if [ $? -eq 0 ]; then
        echo "Stored in DynamoDB: table=${TABLE} record_id=${RECORD_ID}"
    else
        if [ "$DO_PUT" = "yes" ]; then
            echo "ERROR: put-item failed: ${put_err}" >&2
            exit 1
        fi
        echo "NOTE: could not write to DynamoDB (this is expected without write access to the owner's account)." >&2
        echo "      Your result is saved at ${JSON_FILE} — send it to the dataset owner or upload it to their contribution inbox." >&2
    fi
else
    echo "Skipped DynamoDB write (--no-put). JSON saved at ${JSON_FILE}."
fi
exit 0
