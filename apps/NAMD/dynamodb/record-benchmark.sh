#!/bin/bash
# =============================================================================
# NAMD -> AI-Powered HPC benchmark contribution recorder
# =============================================================================
# Records one NAMD benchmark run into the shared AI-Powered HPC DynamoDB
# dataset so it can train the HPC performance-prediction model.
#
# This script is SELF-CONTAINED: no dependency on any other file. Copy just this
# one file to your cluster (or `curl` it) and run it.
#
# SAFE by default:
#   * Always writes the record as a local JSON file you can inspect/keep.
#   * Calls `aws dynamodb put-item` only when AWS write access is available (or
#     you pass --put); otherwise it just saves the JSON. Nothing fails.
#   * `--dry-run` prints the record to stdout and touches neither disk nor AWS.
#
# ---------------------------------------------------------------------------
# What gets recorded (the canonical schema the model ingests)
# ---------------------------------------------------------------------------
# Required (the run is rejected by the model if any of these is missing):
#   instance_type, operating_system, num_cores, num_instances, libraries
# Strongly recommended (this is what makes the row USEFUL for training):
#   benchmark_case            the dataset/case name (e.g. STMV)
#   time_to_solution_seconds  total wall-clock time (NAMD's WallClock)
#   ns_per_day                NAMD simulation rate (1 / days_per_ns)
#   days_per_ns               the last "Benchmark time:" line's days/ns
#   atoms_million             system size in millions of atoms
# Optional but valuable:
#   nsteps, timestep_fs, namd_version, namd_platform, cores_per_node
#
# The record lands in a DynamoDB table named  External_<Source>_Namd  in the
# owner's account/region. The ingestion side reads the record by the canonical
# attribute names below, so keep them as they are.
#
# ---------------------------------------------------------------------------
# Quick start
# ---------------------------------------------------------------------------
#   # On a SLURM compute node, in the run directory, right after the run
#   # (reads namd.out and auto-detects most fields):
#   ./record-benchmark.sh --case STMV --source AcmeCorp
#
#   # Off-cluster / replaying a result (pass everything explicitly):
#   ./record-benchmark.sh --case ApoA1 --atoms-million 0.092224 \
#       --instance-type hpc7a.96xlarge --os "Amazon Linux 2023" \
#       --num-cores 192 --num-nodes 1 --mpi openmpi --version 3.0.2 \
#       --days-per-ns 0.05 --time-to-solution 60 --source AcmeCorp --dry-run
#
# Run  ./record-benchmark.sh --help  for the full option list.
# =============================================================================

set -uo pipefail

readonly APPLICATION="namd"
readonly APP_TABLE_SEGMENT="Namd"   # matches Python str.capitalize("namd")

SOURCE="${SOURCE:-Community}"
REGION="${DYNAMODB_REGION:-us-east-1}"
TABLE=""
OUTDIR="${PWD}"
DRY_RUN=0
DO_PUT="auto"

INSTANCE_TYPE="${INSTANCE_TYPE:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
NUM_CORES="${NUM_CORES:-}"
NUM_INSTANCES="${NUM_INSTANCES:-}"
CORES_PER_NODE="${CORES_PER_NODE:-}"
MPI_IMPLEMENTATION="${MPI_IMPLEMENTATION:-}"
BENCHMARK_CASE="${BENCHMARK_CASE:-}"
RECORD_ID="${RECORD_ID:-}"
ENGINE_VERSION="${NAMD_VERSION:-}"

TIME_TO_SOLUTION="${TIME_TO_SOLUTION:-}"
NS_PER_DAY="${NS_PER_DAY:-}"
DAYS_PER_NS="${DAYS_PER_NS:-}"

DISCIPLINE="MD"           # NAMD is a molecular-dynamics engine
ATOMS_MILLION="${ATOMS_MILLION:-}"
ANALYSIS_TYPE="${ANALYSIS_TYPE:-}"
NSTEPS=""
TIMESTEP_FS=""
NAMD_PLATFORM=""

# Directory scanned for namd.out to recover metrics not passed in
# (defaults to the current dir, which is the run dir when called from a job).
RUN_DIR="${RUN_DIR:-$PWD}"

declare -a EXTRA_METRICS=()
declare -a EXTRA_CHARS=()

usage() {
    sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

OPTIONS
  Identity / destination:
    --source LABEL            Your org/handle, e.g. AcmeCorp (default: Community).
                              Becomes External_<LABEL>_Namd + provenance.
    --table NAME              Override the destination table name entirely.
    --region REGION           AWS region of the table (default: us-east-1).
    --id ID                   Record id (DynamoDB key). Auto-generated if omitted.

  Core run configuration (auto-detected on SLURM/EC2 when omitted):
    --instance-type TYPE      EC2 instance type (e.g. hpc7a.96xlarge).
    --os NAME                 Operating system (e.g. "Amazon Linux 2023").
    --num-cores N             Total cores used: nodes x processes per node x
                              (worker threads + 1 communication thread).
    --num-nodes N             Number of instances/nodes used.
    --cores-per-node N        Cores per node (derived from the two above if omitted).
    --mpi NAME                MPI implementation under Charm++ (e.g. openmpi).
    --version VER             NAMD version (e.g. 3.0.2).

  Result + dataset description (recommended):
    --case NAME               Benchmark case / dataset id (e.g. ApoA1, ATPase, STMV).
    --time-to-solution SEC    Total wall-clock seconds (NAMD's WallClock).
    --days-per-ns X           NAMD's days/ns, from its last "Benchmark time:" line.
    --ns-per-day X            NAMD simulation rate (ns/day); 1 / days-per-ns if omitted.
    --atoms-million X         System size in millions of atoms.
    --analysis-type T         Ensemble / sim type (e.g. NVE, NPT).
    --discipline D            Defaults to MD.
    --metric NAME=VALUE       Any extra numeric performance metric (repeatable).
    --char NAME=VALUE         Any extra dataset characteristic (repeatable).

  Behavior:
    --put                     Force the DynamoDB put-item (error out if it fails).
                              With no AWS CLI on the PATH, keep the JSON and exit 0.
    --no-put                  Never call AWS; only write the JSON file.
    --dry-run                 Print the record to stdout; touch no file and no AWS.
    --run-dir DIR             Dir to scan for namd.out when metrics aren't supplied
                              (default: current dir). Lets a launch script call
                              the recorder with no arguments.
    --out DIR                 Directory for the saved JSON (default: current dir).
    -h, --help                Show this help.

  From namd.out in the run directory it reads, when not given: the last
  "Benchmark time:" line's days/ns, WallClock (time_to_solution_seconds), the
  "Info: <N> ATOMS" line (atoms_million), "Info: NAMD <version> for <platform>"
  (namd_version, namd_platform), "Info: NUMBER OF STEPS" (nsteps) and
  "Info: TIMESTEP" (timestep_fs).
EOF
}

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
        --days-per-ns)        DAYS_PER_NS="$2"; shift 2;;
        --ns-per-day)         NS_PER_DAY="$2"; shift 2;;
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

# imds <path>: the instance metadata's answer at <path> (IMDSv2), or nothing.
# Each request gives up after 2 seconds (1 to connect), and an HTTP error, or an
# answer cut off at that limit, gives nothing.
imds() {
    local path="$1" token answer
    token=$(curl -fsS --connect-timeout 1 --max-time 2 -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || return 0
    answer=$(curl -fsS --connect-timeout 1 --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null) || return 0
    printf '%s' "$answer"
}
# imds_instance_type: the instance type from the instance metadata, when the
# answer is an instance type name (tested in the C locale: in some locales [a-z]
# leaves out i). Anything else, a proxy's page for example, counts as none.
imds_instance_type() {
    local itype
    itype="$(imds instance-type)"
    if ( LC_ALL=C; [[ "$itype" =~ ^[a-z][a-z0-9-]*\.[a-z0-9-]+$ ]] ); then printf '%s' "$itype"; fi
}
json_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
# A number: a decimal, with an exponent or not (NAMD prints a small days/ns as
# 1.5e-05).
is_number() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; }

# Each attribute is written once. The --metric and --char values are added
# last, so one that names an attribute the record already holds is left out,
# with a WARN.
declare -a ITEM_LINES=()
declare -A SEEN=()
seen() {
    if [ -n "${SEEN[$1]+set}" ]; then echo "WARN: ignoring a second value for '$1'" >&2; return 0; fi
    SEEN[$1]=1; return 1
}
add_s() { [ -n "${2:-}" ] || return 0; seen "$1" && return 0; ITEM_LINES+=("    \"$1\": {\"S\": \"$(json_escape "$2")\"}"); }
add_n() {
    [ -n "${2:-}" ] || return 0
    if ! is_number "$2"; then echo "WARN: ignoring non-numeric value for '$1': '$2'" >&2; return 0; fi
    seen "$1" && return 0
    ITEM_LINES+=("    \"$1\": {\"N\": \"$2\"}")
}
add_kv() {
    local fn="$1" pair="$2" name="${2%%=*}" val="${2#*=}"
    if [ "$pair" = "$name" ] || [ -z "$name" ]; then echo "WARN: ignoring malformed '$pair' (expected name=value)" >&2; return 0; fi
    "$fn" "$name" "$val"
}

[ -n "$INSTANCE_TYPE" ]    || INSTANCE_TYPE="$(imds_instance_type)"
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

# --- Fallback: recover NAMD result metrics from namd.out ---------------------
# When a value wasn't supplied (flag or env), parse it from NAMD's output in
# RUN_DIR (namd.out, or another *.out or *.log with a "Benchmark time:" line).
# NAMD prints:
#     Info: NAMD <version> for <platform>
#     Info: TIMESTEP               <fs>
#     Info: NUMBER OF STEPS        <N>
#     Info: <N> ATOMS
#     Info: Benchmark time: <CPUs> CPUs <s> s/step <d> days/ns <MB> MB memory
#     WallClock: <s>  CPUTime: <s>  Memory: <MB> MB
# This lets the recorder run with no arguments at the end of a benchmark job.
_namdout=""
for _c in "$RUN_DIR"/namd.out "$RUN_DIR"/*.out "$RUN_DIR"/*.log; do
    [ -f "$_c" ] || continue
    if grep -q 'Benchmark time:' "$_c" 2>/dev/null; then _namdout="$_c"; break; fi
done
if [ -n "$_namdout" ]; then
    [ -n "$DAYS_PER_NS" ]      || DAYS_PER_NS="$(awk '/Benchmark time:/ { for (i = 2; i <= NF; i++) if ($i == "days/ns") d = $(i-1) } END { if (d != "") print d }' "$_namdout")"
    [ -n "$TIME_TO_SOLUTION" ] || TIME_TO_SOLUTION="$(awk '/^WallClock:/ { w = $2 } END { if (w != "") print w }' "$_namdout")"
    [ -n "$ATOMS_MILLION" ]    || ATOMS_MILLION="$(awk '/^Info: [0-9]+ ATOMS[[:space:]]*$/ { a = $2 } END { if (a != "") printf "%.6g", a / 1000000 }' "$_namdout")"
    [ -n "$ENGINE_VERSION" ]   || ENGINE_VERSION="$(awk '/^Info: NAMD [^ ]+ for / { print $3; exit }' "$_namdout")"
    NAMD_PLATFORM="$(awk '/^Info: NAMD [^ ]+ for / { print $5; exit }' "$_namdout")"
    NSTEPS="$(awk '/^Info: NUMBER OF STEPS[[:space:]]/ { print $NF; exit }' "$_namdout")"
    TIMESTEP_FS="$(awk '/^Info: TIMESTEP[[:space:]]/ { print $NF; exit }' "$_namdout")"
fi
# ns/day = 1 / (days/ns), when no ns/day was given.
if [ -z "$NS_PER_DAY" ] && is_number "${DAYS_PER_NS:-}"; then
    NS_PER_DAY="$(awk -v d="$DAYS_PER_NS" 'BEGIN { if (d + 0 > 0) printf "%.6g", 1 / d }')"
fi

SOURCE="$(printf '%s' "$SOURCE" | tr -cd '[:alnum:]')"
[ -n "$SOURCE" ] || SOURCE="Community"
[ -n "$TABLE" ]  || TABLE="External_${SOURCE}_${APP_TABLE_SEGMENT}"

errors=0
require() { if [ -z "${2:-}" ]; then echo "ERROR: missing required field: $1" >&2; errors=1; fi; }
require "instance_type (--instance-type)" "$INSTANCE_TYPE"
require "operating_system (--os)"         "$OPERATING_SYSTEM"
require "num_cores (--num-cores)"         "$NUM_CORES"
require "num_instances (--num-nodes)"     "$NUM_INSTANCES"
if [ -z "${MPI_IMPLEMENTATION}${MPI_VERSION}${LIBFABRIC_VERSION}${EFA_VERSION}${ENGINE_VERSION}" ]; then
    echo "ERROR: cannot compose 'libraries' (provide at least --mpi or --version)" >&2; errors=1
fi
if [ "$errors" -ne 0 ]; then echo "Aborting: fill the missing field(s) above. See --help." >&2; exit 1; fi

[ -n "$BENCHMARK_CASE" ]   || echo "NOTE: no --case given; the case/dataset name strongly improves model accuracy." >&2
[ -n "$TIME_TO_SOLUTION" ] || echo "NOTE: no --time-to-solution given; this is the model's primary target metric." >&2
[ -n "$NS_PER_DAY" ]       || echo "NOTE: no --ns-per-day or --days-per-ns given, and no namd.out gives a days/ns." >&2
[ -n "$ATOMS_MILLION" ]    || echo "NOTE: no --atoms-million given; system size is a key driver of runtime." >&2

RECORDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -z "$RECORD_ID" ]; then
    _jid="${SLURM_JOB_ID:-$RANDOM}"; _case="${BENCHMARK_CASE:-run}"
    RECORD_ID="${APPLICATION}-${SOURCE}-${INSTANCE_TYPE:-na}-${NUM_CORES}c-${_case}-${RECORDED_AT//[:-]/}-${_jid}"
fi

declare -a LIBS=()
[ -n "$MPI_IMPLEMENTATION" ] && LIBS+=("mpi:${MPI_IMPLEMENTATION}")
[ -n "$MPI_VERSION" ]        && LIBS+=("mpi-version:${MPI_VERSION}")
[ -n "$LIBFABRIC_VERSION" ]  && LIBS+=("libfabric:${LIBFABRIC_VERSION}")
[ -n "$EFA_VERSION" ]        && LIBS+=("efa:${EFA_VERSION}")
[ -n "$ENGINE_VERSION" ]     && LIBS+=("namd:${ENGINE_VERSION}")
libraries_json=""
for lib in "${LIBS[@]}"; do
    frag="{\"S\": \"$(json_escape "$lib")\"}"
    if [ -z "$libraries_json" ]; then libraries_json="$frag"; else libraries_json="$libraries_json, $frag"; fi
done

add_s "record_id"            "$RECORD_ID"
add_s "application"          "$APPLICATION"
add_s "benchmark_case"       "$BENCHMARK_CASE"
add_s "instance_type"        "$INSTANCE_TYPE"
add_s "operating_system"     "$OPERATING_SYSTEM"
add_n "num_cores"            "$NUM_CORES"
add_n "num_instances"        "$NUM_INSTANCES"
add_n "cores_per_node"       "$CORES_PER_NODE"
add_s "mpi_implementation"   "$MPI_IMPLEMENTATION"
SEEN[libraries]=1
ITEM_LINES+=("    \"libraries\": {\"L\": [$libraries_json]}")
add_n "time_to_solution_seconds" "$TIME_TO_SOLUTION"
add_n "ns_per_day"           "$NS_PER_DAY"
add_n "days_per_ns"          "$DAYS_PER_NS"
add_n "nsteps"               "$NSTEPS"
add_n "timestep_fs"          "$TIMESTEP_FS"
add_s "discipline"           "$DISCIPLINE"
add_n "atoms_million"        "$ATOMS_MILLION"
add_s "analysis_type"        "$ANALYSIS_TYPE"
add_s "namd_version"         "$ENGINE_VERSION"
add_s "namd_platform"        "$NAMD_PLATFORM"
add_s "provenance_origin"    "external"
add_s "provenance_source_id" "$SOURCE"
add_s "recorded_at"          "$RECORDED_AT"
for pair in "${EXTRA_METRICS[@]:-}"; do [ -n "$pair" ] && add_kv add_n "$pair"; done
for pair in "${EXTRA_CHARS[@]:-}"; do [ -n "$pair" ] && add_kv add_s "$pair"; done

ITEM_JSON="{"$'\n'
for i in "${!ITEM_LINES[@]}"; do
    ITEM_JSON+="${ITEM_LINES[$i]}"
    [ "$i" -lt $(( ${#ITEM_LINES[@]} - 1 )) ] && ITEM_JSON+=","
    ITEM_JSON+=$'\n'
done
ITEM_JSON+="}"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "# DRY RUN — would write to table '${TABLE}' (region ${REGION}); no file, no AWS."
    echo "$ITEM_JSON"; exit 0
fi

mkdir -p "$OUTDIR"
JSON_FILE="${OUTDIR}/$(printf '%s' "$RECORD_ID" | tr -cd '[:alnum:]._-').json"
printf '%s\n' "$ITEM_JSON" > "$JSON_FILE"
echo "Record written: ${JSON_FILE}"

attempt_put=0
case "$DO_PUT" in
    yes) attempt_put=1;;
    no)  attempt_put=0;;
    auto) attempt_put=1;;
esac
if [ "$attempt_put" -eq 1 ]; then
    if ! command -v aws >/dev/null 2>&1; then
        echo "NOTE: AWS CLI not found; kept JSON only. To share it, attach ${JSON_FILE} to a Benchmark results issue:" >&2
        echo "      https://github.com/aws-samples/hpc-applications/issues/new?template=benchmark-results.yml" >&2
        echo "      The issue is public, and so are the JSON and its file's name: rename a confidential case in both first." >&2; exit 0
    fi
    put_err="$( aws dynamodb put-item --region "$REGION" --table-name "$TABLE" --item "file://${JSON_FILE}" 2>&1 )"
    if [ $? -eq 0 ]; then
        echo "Stored in DynamoDB: table=${TABLE} record_id=${RECORD_ID}"
    else
        if [ "$DO_PUT" = "yes" ]; then echo "ERROR: put-item failed: ${put_err}" >&2; exit 1; fi
        echo "NOTE: could not write to DynamoDB (expected without write access to the owner's account)." >&2
        echo "      Your result is saved at ${JSON_FILE}. To share it, attach it to a Benchmark results issue:" >&2
        echo "      https://github.com/aws-samples/hpc-applications/issues/new?template=benchmark-results.yml" >&2
        echo "      The issue is public, and so are the JSON and its file's name: rename a confidential case in both first." >&2
    fi
else
    echo "Skipped DynamoDB write (--no-put). JSON saved at ${JSON_FILE}."
fi
exit 0
