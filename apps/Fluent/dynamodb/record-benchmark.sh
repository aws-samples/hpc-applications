#!/bin/bash
# =============================================================================
# Ansys Fluent -> AI-Powered HPC benchmark contribution recorder
# =============================================================================
# Records one Ansys Fluent benchmark run into the shared AI-Powered HPC DynamoDB
# dataset so it can train the HPC performance-prediction model.
#
# This script is SELF-CONTAINED: it has no dependency on any other file in this
# repository. Copy just this one file to your cluster (or `curl` it) and run it.
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
#   benchmark_case            the dataset/case name (e.g. f1_racecar_140m)
#   time_to_solution_seconds  total solver wall-clock time (the model's target).
#                             If you omit it but pass --time-per-iteration and
#                             --num-iterations, it is computed (per-iter x iters).
#   num_cells_million         mesh size in millions of cells
# Optional but valuable:
#   solver_rating, solver_speed, time_per_iteration_seconds, num_iterations,
#   turbulence_model, solver_type, analysis_type, cell_type, fluent_version
#
# The record lands in a DynamoDB table named  External_<Source>_Fluent  in the
# owner's account/region. The ingestion side reads every External_* table with
# an identity map, so the canonical attribute names below are consumed as-is.
#
# Fluent reports per-iteration timing in the solver .out/.trn:
#   "Solver wall time per iteration" -> --time-per-iteration
#   "Solver rating"                  -> --solver-rating
#   "Solver speed"                   -> --solver-speed
# The standard Fluent benchmarks run a fixed iteration count (--num-iterations);
# total solve time = per-iteration x iterations.
#
# ---------------------------------------------------------------------------
# Quick start
# ---------------------------------------------------------------------------
#   # On a SLURM compute node, right after the solve (auto-detects most fields):
#   ./record-benchmark.sh \
#       --case f1_racecar_140m --num-cells-million 140 \
#       --time-per-iteration 0.42 --num-iterations 25 \
#       --solver-rating 2057 --source AcmeCorp
#
#   # Off-cluster / replaying a result (pass everything explicitly):
#   ./record-benchmark.sh --case aircraft_wing_14m --num-cells-million 14 \
#       --instance-type hpc7a.96xlarge --os "Amazon Linux 2" \
#       --num-cores 192 --num-nodes 2 --mpi intelmpi --version 2024R2 \
#       --time-to-solution 437 --turbulence-model k-omega-sst \
#       --solver-type steady-pressure-based --source AcmeCorp --dry-run
#
# Run  ./record-benchmark.sh --help  for the full option list.
# =============================================================================

set -uo pipefail

# --- Application identity (do not change) ------------------------------------
readonly APPLICATION="fluent"
readonly APP_TABLE_SEGMENT="Fluent"   # matches Python str.capitalize("fluent")

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
ENGINE_VERSION="${FLUENT_VERSION:-}"

# Fluent performance metrics (env-overridable so a launch script can export them).
TIME_TO_SOLUTION="${TIME_TO_SOLUTION:-}"
TIME_PER_ITERATION="${TIME_PER_ITERATION:-}"
SOLVER_RATING="${SOLVER_RATING:-}"
SOLVER_SPEED="${SOLVER_SPEED:-}"

# Fluent dataset characteristics (also env-overridable).
DISCIPLINE="CFD"          # always true for Fluent; override if you must
NUM_CELLS_MILLION="${NUM_CELLS_MILLION:-}"
NUM_ITERATIONS="${NUM_ITERATIONS:-}"
TURBULENCE_MODEL="${TURBULENCE_MODEL:-}"
SOLVER_TYPE="${SOLVER_TYPE:-}"
ANALYSIS_TYPE="${ANALYSIS_TYPE:-}"
CELL_TYPE="${CELL_TYPE:-}"

# Directory scanned for the solver log to recover metrics in zero-arg use
# (defaults to the current dir, which is the run dir when called from a job).
RUN_DIR="${RUN_DIR:-$PWD}"

# Generic extra metrics/characteristics (repeatable --metric/--char name=value).
declare -a EXTRA_METRICS=()
declare -a EXTRA_CHARS=()

usage() {
    sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

OPTIONS
  Identity / destination:
    --source LABEL            Your org/handle, e.g. AcmeCorp (default: Community).
                              Becomes the table suffix External_<LABEL>_Fluent and
                              the record's external provenance. Letters/digits only.
    --table NAME              Override the destination table name entirely.
    --region REGION           AWS region of the table (default: us-east-1).
    --id ID                   Record id (DynamoDB key). Auto-generated if omitted.

  Core run configuration (auto-detected on SLURM/EC2 when omitted):
    --instance-type TYPE      EC2 instance type (e.g. hpc7a.96xlarge).
    --os NAME                 Operating system (e.g. "Amazon Linux 2").
    --num-cores N             Total cores (MPI ranks) used.
    --num-nodes N             Number of instances/nodes used.
    --cores-per-node N        Cores per node (derived from the two above if omitted).
    --mpi NAME                MPI implementation (e.g. intelmpi, openmpi).
    --version VER             Fluent version (e.g. 2024R2).

  Result + dataset description (recommended):
    --case NAME               Benchmark case / dataset id (e.g. f1_racecar_140m).
    --time-to-solution SEC    Total solver wall-clock seconds (the model target).
    --time-per-iteration SEC  Solver wall time per iteration (Fluent .out).
    --num-iterations N        Iterations run (computes total = per-iter x iters).
    --solver-rating X         Fluent "Solver rating".
    --solver-speed X          Fluent "Solver speed".
    --num-cells-million X     Mesh size in millions of cells.
    --turbulence-model M      e.g. k-omega-sst, k-epsilon-realizable.
    --solver-type T           steady|transient; pressure-/density-based; coupled/segregated.
    --analysis-type T         steady | transient | RANS | ...
    --cell-type T             e.g. polyhedral, hex, tet.
    --metric NAME=VALUE       Any extra numeric performance metric (repeatable).
    --char NAME=VALUE         Any extra dataset characteristic (repeatable).

  Behavior:
    --put                     Force the DynamoDB put-item (error out if it fails).
    --no-put                  Never call AWS; only write the JSON file.
    --dry-run                 Print the record to stdout; touch no file and no AWS.
    --run-dir DIR             Dir to scan for the solver log when metrics aren't
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
        --time-per-iteration) TIME_PER_ITERATION="$2"; shift 2;;
        --num-iterations)     NUM_ITERATIONS="$2"; shift 2;;
        --solver-rating)      SOLVER_RATING="$2"; shift 2;;
        --solver-speed)       SOLVER_SPEED="$2"; shift 2;;
        --num-cells-million)  NUM_CELLS_MILLION="$2"; shift 2;;
        --turbulence-model)   TURBULENCE_MODEL="$2"; shift 2;;
        --solver-type)        SOLVER_TYPE="$2"; shift 2;;
        --analysis-type)      ANALYSIS_TYPE="$2"; shift 2;;
        --cell-type)          CELL_TYPE="$2"; shift 2;;
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

# --- Zero-arg fallback: recover Fluent result metrics from the solver log ----
# When a value wasn't supplied (flag or env), parse it from the Fluent solver
# output in RUN_DIR, using the same patterns as Utils/record-results. This lets
# the recorder run with no arguments when called at the end of a benchmark job.
if ls "$RUN_DIR"/*.out >/dev/null 2>&1; then
    [ -n "$TIME_PER_ITERATION" ] || TIME_PER_ITERATION="$(grep -h 'Solver wall time per iteration' "$RUN_DIR"/*.out 2>/dev/null | awk '{print $7}' | head -1)"
    [ -n "$SOLVER_SPEED" ]       || SOLVER_SPEED="$(grep -h 'Solver speed' "$RUN_DIR"/*.out 2>/dev/null | awk '{print $4}' | head -1)"
    [ -n "$SOLVER_RATING" ]      || SOLVER_RATING="$(grep -h 'Solver rating' "$RUN_DIR"/*.out 2>/dev/null | awk '{print $4}' | head -1)"
fi
if [ -z "$ENGINE_VERSION" ]; then
    ENGINE_VERSION="$(grep -hoE 'ANSYS Fluent [0-9]{4} R[0-9]+' "$RUN_DIR"/*.trn "$RUN_DIR"/*.out 2>/dev/null | head -1 | sed -E 's/.*([0-9]{4}) R([0-9]+)/\1R\2/')"
fi
if [ -z "$BENCHMARK_CASE" ]; then
    _cas="$(ls -1 "$RUN_DIR"/*.cas.gz "$RUN_DIR"/*.cas.h5 "$RUN_DIR"/*.cas 2>/dev/null | head -1)"
    [ -n "${_cas:-}" ] && BENCHMARK_CASE="$(basename "$_cas" | sed -E 's/\.(cas\.gz|cas\.h5|cas)$//')"
fi

# Fluent total solve time = per-iteration x iterations, when total not given directly.
if [ -z "$TIME_TO_SOLUTION" ] && is_number "${TIME_PER_ITERATION:-}" && is_number "${NUM_ITERATIONS:-}"; then
    TIME_TO_SOLUTION="$(awk "BEGIN{printf \"%.6g\", ${TIME_PER_ITERATION} * ${NUM_ITERATIONS}}")"
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

[ -n "$BENCHMARK_CASE" ]    || echo "NOTE: no --case given; the case/dataset name strongly improves model accuracy." >&2
[ -n "$TIME_TO_SOLUTION" ]  || echo "NOTE: no total solve time; pass --time-to-solution OR --time-per-iteration + --num-iterations." >&2
[ -n "$NUM_CELLS_MILLION" ] || echo "NOTE: no --num-cells-million given; mesh size is a key driver of runtime." >&2

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
[ -n "$ENGINE_VERSION" ]     && LIBS+=("fluent:${ENGINE_VERSION}")
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
add_n "time_per_iteration_seconds" "$TIME_PER_ITERATION"
add_n "solver_rating"        "$SOLVER_RATING"
add_n "solver_speed"         "$SOLVER_SPEED"
for pair in "${EXTRA_METRICS[@]:-}"; do [ -n "$pair" ] && add_kv add_n "$pair"; done
# Dataset characteristics
add_s "discipline"           "$DISCIPLINE"
add_n "num_cells_million"    "$NUM_CELLS_MILLION"
add_n "num_iterations"       "$NUM_ITERATIONS"
add_s "turbulence_model"     "$TURBULENCE_MODEL"
add_s "solver_type"          "$SOLVER_TYPE"
add_s "analysis_type"        "$ANALYSIS_TYPE"
add_s "cell_type"            "$CELL_TYPE"
for pair in "${EXTRA_CHARS[@]:-}"; do [ -n "$pair" ] && add_kv add_s "$pair"; done
# Application-specific setting (Fluent version is an ingested extra attribute)
add_s "fluent_version"       "$ENGINE_VERSION"
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
