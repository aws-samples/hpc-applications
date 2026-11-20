#!/bin/bash
# Run every WRF shell test. No Slurm, no EC2, no WRF, no MPI, no AWS
# credentials, no network.
#
#   apps/WRF/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
for t in "${HERE}"/test-*.sh; do
    echo "### $(basename "${t}")"
    bash "${t}" || rc=1
    echo
done

echo "### syntax check (bash -n)"
for f in "${HERE}"/../x86/*.sbatch "${HERE}"/../x86/*.sh \
         "${HERE}"/../Arm/*.sbatch \
         "${HERE}"/../lib/*.sh \
         "${HERE}"/../dynamodb/record-benchmark.sh \
         "${HERE}"/*.sh; do
    if bash -n "${f}" 2>/dev/null; then
        printf '  ok   %s\n' "${f#"${HERE}/../"}"
    else
        printf '  FAIL %s\n' "${f#"${HERE}/../"}"; bash -n "${f}"; rc=1
    fi
done

echo
if [ "${rc}" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TEST FAILURES — see above"; fi
exit "${rc}"
