#!/bin/bash
# Run every LAMMPS shell test. No Slurm, no EC2, no LAMMPS, no MPI, no AWS
# credentials, no network.
#
#   apps/LAMMPS/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "${HERE}"/test-*.sh; do
    echo "### $(basename "${t}")"
    bash "${t}" || rc=1
    echo
done
echo "### syntax check (bash -n)"
for f in "${HERE}"/../x86/*.sbatch \
         "${HERE}"/../Arm/*.sbatch \
         "${HERE}"/../dynamodb/*.sh \
         "${HERE}"/*.sh; do
    label="${f#"${HERE}/../"}"
    [ "${label}" = "${f}" ] && label="tests/${f#"${HERE}/"}"
    if bash -n "${f}" 2>/dev/null; then
        printf '  ok   %s\n' "${label}"
    else
        printf '  FAIL %s\n' "${label}"; bash -n "${f}"; rc=1
    fi
done
echo
if [ "${rc}" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TEST FAILURES — see above"; fi
exit "${rc}"
