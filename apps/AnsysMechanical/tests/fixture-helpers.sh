#!/bin/bash
# =============================================================================
# Fixtures that must be GENERATED rather than committed.
# =============================================================================
# MAPDL pads its output lines with trailing spaces, and the benign-block pattern
# is anchored at both ends, so a block that is not trimmed on the right fails to
# match and a perfectly good run is rejected. Testing that needs a log with real
# trailing whitespace.
#
# Such a file cannot safely live in the repository: `git diff --check` reports it,
# and any editor, linter or pre-commit hook that trims trailing whitespace would
# silently destroy the one property the fixture exists to test - while leaving the
# test green. Generating it at run time makes the intent explicit and tamper-proof.

# write_padded_benign_log <path>
# A genuine fixed-iteration termination whose lines carry trailing padding.
write_padded_benign_log() {
    local out="$1"
    {
        printf ' Ansys Mechanical Enterprise\n'
        printf '\n'
        printf ' SOLVE FOR LS 1 OF 1\n'
        printf '\n'
        printf ' *** ERROR ***                           CP =     456.000   TIME= 09:00:00   \n'
        printf ' The number of iterations exceeds 1.  The run is terminated at the        \n'
        printf " user's request.                                                          \n"
        printf '\n'
        printf ' *---------------------------------------------------------------------------*\n'
        printf ' |                    DISTRIBUTED ANSYS RUN COMPLETED                        |\n'
        printf ' |        Elapsed Time (sec) =      456.000       Date  =  08/29/2026        |\n'
        printf ' *---------------------------------------------------------------------------*\n'
    } > "${out}"
    # Fail loudly if the padding did not survive - without it the test is vacuous.
    if ! grep -q ' $' "${out}"; then
        echo "ERROR: generated fixture ${out} has no trailing whitespace; the test would be vacuous." >&2
        return 1
    fi
}
