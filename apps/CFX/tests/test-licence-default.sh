#!/bin/bash
# =============================================================================
# The sbatch example's licence-server default.
# =============================================================================
# The example takes the Ansys licence server from ANSYSLMD_LICENSE_FILE
# (<port>@<host>). A value set in the submitting environment is used as it is;
# without one, the default is the placeholder 1055@<license-server>, and no
# licence-server address of any site is written in the script.
#
# The test evaluates the example's own ANSYSLMD_LICENSE_FILE line in a subshell,
# with and without the variable set, and reads the script for <port>@<IPv4
# address>. Nothing is run; no network.
#
#   ./tests/test-licence-default.sh
#   CFX_SBATCH=/path/to/CFX.sbatch ./tests/test-licence-default.sh   # another copy
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The sbatch example: CFX.sbatch, or CFX-mpirun.sbatch where it has that name.
SBATCH="${CFX_SBATCH:-}"
if [ -z "${SBATCH}" ]; then
    for _s in "${HERE}/../CFX.sbatch" "${HERE}/../CFX-mpirun.sbatch"; do
        if [ -f "${_s}" ]; then SBATCH="${_s}"; break; fi
    done
fi

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

if [ -z "${SBATCH}" ] || [ ! -f "${SBATCH}" ]; then
    echo "ERROR: no CFX sbatch example found next to ${HERE}" >&2
    exit 1
fi
echo "licence-server default tests (${SBATCH#"${HERE}/../"})"

lines="$(grep -E '^export ANSYSLMD_LICENSE_FILE=' "${SBATCH}")"
n="$(printf '%s\n' "${lines}" | grep -c .)"
if [ "${n}" = "1" ]; then ok "one ANSYSLMD_LICENSE_FILE line"
else bad "one ANSYSLMD_LICENSE_FILE line" "1" "${n}"; fi

# The line, evaluated as the job would, without the variable and with it.
unset_value="$(unset ANSYSLMD_LICENSE_FILE; eval "${lines}"; printf '%s' "${ANSYSLMD_LICENSE_FILE:-}")"
if [ "${unset_value}" = "1055@<license-server>" ]; then
    ok "not set in the environment -> the placeholder 1055@<license-server>"
else
    bad "not set in the environment -> the placeholder 1055@<license-server>" "1055@<license-server>" "${unset_value}"
fi
set_value="$(export ANSYSLMD_LICENSE_FILE=27000@licence-host; eval "${lines}"; printf '%s' "${ANSYSLMD_LICENSE_FILE:-}")"
if [ "${set_value}" = "27000@licence-host" ]; then
    ok "set in the environment -> used as it is"
else
    bad "set in the environment -> used as it is" "27000@licence-host" "${set_value}"
fi

# No <port>@<IPv4 address> anywhere in the script (comments included).
addr="$(grep -nE '[0-9]+@([0-9]{1,3}\.){3}[0-9]{1,3}' "${SBATCH}" | cut -d: -f1 | tr '\n' ' ')"
if [ -z "${addr}" ]; then ok "no <port>@<IPv4 address> in the script"
else bad "no <port>@<IPv4 address> in the script" "none" "on line(s) ${addr}"; fi

echo
printf 'licence-server default tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
