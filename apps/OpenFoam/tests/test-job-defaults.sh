#!/bin/bash
# =============================================================================
# The x86 benchmark scripts' Slurm defaults (../README.md, "Benchmark"): they
# run on hpc8a.96xlarge (the hpc8a partition, 192 ranks per node) and default
# to the largest node count at which hpc8a.96xlarge kept 60% efficiency or
# more on the 236M mesh, as the README's 236M table gives it, with the time
# limit chosen for 200 iterations there: the scripts' default END_TIME, which
# is checked too, since the limit holds only for it. No script is run.
#
#   apps/OpenFoam/tests/test-job-defaults.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"

sbatch_value() {  # sbatch_value <script> <option>: its #SBATCH default
    awk -v o="$2" '$1 == "#SBATCH" && index($2, o) == 1 {sub(o, "", $2); sub(/^=/, "", $2); print $2; exit}' "${OF_APP}/$1"
}
# The 236M table: the largest node count whose hpc8a.96xlarge efficiency is 60% or more.
knee_nodes="$(awk '
    /^### OCC DrivAer 236M/ {t = 1; next}
    t && /^### / {exit}
    t && /^\| Nodes \|/ {for (i = 2; i <= NF; i++) if ($i ~ /hpc8a\.96xlarge/) c = i; next}
    t && c && /^\| [0-9]+ \|/ {
        n = $2 + 0; cell = $c
        if (match(cell, /\([0-9]+%\)/)) {e = substr(cell, RSTART + 1, RLENGTH - 3) + 0; if (e >= 60) last = n}
    }
    END {print last}' FS='|' "${OF_APP}/README.md")"
check "the README's 236M table: hpc8a.96xlarge keeps 60% or more up to 8 nodes" 8 "${knee_nodes}"

for s in x86/openfoam-benchmark-openmpi.sbatch x86/openfoam-benchmark-intelmpi.sbatch; do
    echo "== ${s} =="
    check "${s}: the hpc8a partition" hpc8a "$(awk '$1 == "#SBATCH" && $2 == "-p" {print $3; exit}' "${OF_APP}/${s}")"
    check "${s}: 192 ranks per node" 192 "$(sbatch_value "${s}" --ntasks-per-node)"
    check "${s}: the node count of the README's 60% knee" "${knee_nodes}" "$(sbatch_value "${s}" --nodes)"
    check "${s}: the time limit for 200 iterations there" 02:00:00 "$(sbatch_value "${s}" --time)"
    check "${s}: 200 iterations by default (END_TIME), the run length that limit is for" 200 \
        "$(sed -n 's/^END_TIME="\${END_TIME:-\([0-9]*\)}"$/\1/p' "${OF_APP}/${s}")"
done

finish "job defaults"
