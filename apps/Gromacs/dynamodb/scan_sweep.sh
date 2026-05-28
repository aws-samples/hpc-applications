#!/bin/bash
# Pull means of a Phase 1 scaling sweep from the Gromacs_Benchmarks table.
# Mirrors the manual-scan pattern used by Doc/img/LAMMPS/generate_charts.py
# (which has the per-replicate ns/day values pasted in as numeric literals
# at the top of the script).
#
# Usage:
#   ./scan_sweep.sh                       # latest sweep (last 24 hours)
#   ./scan_sweep.sh --since 2026-05-26    # all rows on/after the date
#   ./scan_sweep.sh --raw                 # dump every matching row as JSON
#
# Output (default): one row per (instance, nodes, model) cell with the
# per-replicate ns/day list and the mean. This is what
# Doc/img/Gromacs/generate_charts.py expects to copy in as numeric literals.
#
#   instance        nodes  model         ns_per_day_replicates           mean_ns_per_day
#   hpc8a.96xlarge  1      benchMEM      [144.741, 144.812, 144.598]     144.717
#   hpc8a.96xlarge  2      benchMEM      [273.5, 274.1, 273.0]           273.533
#   ...
#
# When the sweep is fresh (table just populated by scaling_sweep_manifest.sh),
# --since is sufficient. For older sweeps use --since with the explicit date
# the manifest was run.
# ---------------------------------------------------------------------------

set -euo pipefail

REGION="${REGION:-us-east-1}"
TABLE="${TABLE:-Gromacs_Benchmarks}"
SINCE=""
RAW=0

while (( $# > 0 )); do
    case "$1" in
        --since)
            shift
            SINCE="$1"
            ;;
        --raw)
            RAW=1
            ;;
        --table)
            shift
            TABLE="$1"
            ;;
        --region)
            shift
            REGION="$1"
            ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg '$1'" >&2
            exit 1
            ;;
    esac
    shift
done

# Default: last 24 hours
if [ -z "${SINCE}" ]; then
    SINCE="$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null \
              || date -u -v-1d +%Y-%m-%d)"
fi

# Validate prerequisites
command -v aws    >/dev/null || { echo "ERROR: aws CLI required"  >&2; exit 1; }
command -v jq     >/dev/null || { echo "ERROR: jq required"        >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 required" >&2; exit 1; }

# Scan with timestamp filter (Gromacs_Benchmarks is small enough that scan
# is fine; if the table grows huge, switch to a GSI on timestamp).
RAW_JSON="$(aws dynamodb scan \
    --table-name "${TABLE}" \
    --region "${REGION}" \
    --filter-expression '#ts >= :since' \
    --expression-attribute-names '{"#ts":"timestamp"}' \
    --expression-attribute-values "{\":since\":{\"S\":\"${SINCE}\"}}" \
    --output json --no-cli-pager)"

if (( RAW )); then
    echo "${RAW_JSON}"
    exit 0
fi

# Group by (instance_type, nodes, model); collect ns_per_day per cell;
# emit one line per cell with the list and the mean.
echo "${RAW_JSON}" | python3 -c '
import json, sys, statistics
data = json.load(sys.stdin)
rows = data.get("Items", [])
def attr(item, name, kind):
    v = item.get(name, {})
    return v.get(kind, "")
groups = {}
for it in rows:
    inst  = attr(it, "instance_type", "S")
    nodes = attr(it, "nodes",         "N")
    model = attr(it, "model",         "S")
    nspd  = attr(it, "ns_per_day",    "N")
    if not (inst and nodes and model and nspd):
        continue
    try:
        nspd_f = float(nspd)
    except ValueError:
        continue
    groups.setdefault((inst, int(nodes), model), []).append(nspd_f)
print(f"{\"instance\":<20}{\"nodes\":>6}{\"model\":>14}{\"ns_per_day_replicates\":>34}{\"mean_ns_per_day\":>20}")
for (inst, nodes, model), reps in sorted(groups.items()):
    reps_sorted = sorted(reps)
    mean = statistics.mean(reps_sorted) if reps_sorted else 0.0
    reps_str = "[" + ", ".join(f"{x:.3f}" for x in reps_sorted) + "]"
    print(f"{inst:<20}{nodes:>6}{model:>14}{reps_str:>34}{mean:>20.3f}")
'
