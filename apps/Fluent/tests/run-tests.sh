#!/bin/bash
# Run every Fluent shell test. No Slurm, no EC2, no Fluent, no MPI, no AWS
# credentials, no network.
#
#   apps/Fluent/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUENT_APP="$(cd "${HERE}/.." && pwd)"
rc=0
for t in "${HERE}"/test-*.sh; do
    echo "### $(basename "${t}")"
    bash "${t}" || rc=1
    echo
done
echo "### syntax check (bash -n)"
for f in "${FLUENT_APP}"/x86/*.sbatch "${FLUENT_APP}"/gpu/*.sbatch "${FLUENT_APP}"/Arm/*.sbatch \
         "${FLUENT_APP}/Fluent-Install.sh" "${FLUENT_APP}/dynamodb/record-benchmark.sh" \
         "${HERE}"/*.sh; do
    if bash -n "${f}" 2>/dev/null; then
        printf '  ok   %s\n' "${f#"${FLUENT_APP}/"}"
    else
        printf '  FAIL %s\n' "${f#"${FLUENT_APP}/"}"; bash -n "${f}"; rc=1
    fi
done
echo
if [ "${rc}" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TEST FAILURES — see above"; fi
exit "${rc}"
