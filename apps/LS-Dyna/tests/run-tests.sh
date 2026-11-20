#!/bin/bash
# Run every LS-Dyna shell test. No Slurm, no EC2, no licensed solver, no AWS
# credentials, no network.
#
#   apps/LS-Dyna/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "${HERE}"/test-*.sh; do
    echo "### $(basename "${t}")"
    bash "${t}" || rc=1
    echo
done
echo "### syntax check (bash -n)"
for f in "${HERE}/../LS-Dyna.sbatch" \
         "${HERE}/../model-fixes.sh" \
         "${HERE}/../lib/lsdyna-run.sh" \
         "${HERE}/../dynamodb/record-benchmark.sh" \
         "${HERE}"/*.sh; do
    name="${f#"${HERE}/../"}"; name="${name/#"${HERE}"/tests}"
    if bash -n "${f}" 2>/dev/null; then
        printf '  ok   %s\n' "${name}"
    else
        printf '  FAIL %s\n' "${name}"; bash -n "${f}"; rc=1
    fi
done
echo
if [ "${rc}" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TEST FAILURES — see above"; fi
exit "${rc}"
