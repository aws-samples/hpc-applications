#!/bin/bash
# =============================================================================
# model-fixes.sh: the documented input changes that let public LS-DYNA benchmark
# models run on current releases (see "Model compatibility" in Readme.md)
# =============================================================================
# Each fix writes an edited copy and never touches its input. It refuses (exit 1)
# a file that does not hold exactly the text it edits, so it never edits another
# model's file blindly.
#
#   ./model-fixes.sh pfile-region  <pfile>                   <out>
#       TopCrunch 3cars and neon pfiles: "decomp { silist <ids> [<transformation>] }"
#       becomes "decomp { region { silist <ids> [<t>] } [<t>] }". LS-DYNA R12.2.2,
#       R13.1, R14.1.1 and R16.1.1 refuse a silist outside a region (Error 50192).
#   ./model-fixes.sh 3cars-joint27 3cars_shell2_150ms.k      <out>
#       TopCrunch 3cars: its revolute joint between the coincident nodes 1800808,
#       1800806, 1800809 and 1800807, which R13.1, R14.1.1 and R16.1.1 refuse
#       (Error 21424), as the spherical joint it amounts to (nodes 1 and 2).
#   ./model-fixes.sh camry-meshfix camry-detailed-v5a.key    <out>
#       CCSA 2012 Toyota Camry detailed model v5a: three overlapping solids of the rear
#       seat foam (part 2001025), which R17.0's input check refuses (Errors 21535 and
#       21536). Wedge 2028692 lies inside hex 2033910, and hex 2033993 overlaps hex
#       2033910 there too. The wedge goes, and hex 2033993 keeps only its part beyond
#       its common face with hex 2033910, as a wedge: about 9 cm3 of foam that the
#       mesh models twice.
#
# Then put the edited file in place of the original in a copy of the model's
# directory (the other files can be links), and run that copy.
# =============================================================================
set -uo pipefail

usage() {
    sed -n '/^#   \.\/model-fixes.sh/,/^# Then/p' "$0" | sed 's/^# \{0,1\}//; /^Then/d'
    exit 2
}

[ "$#" -eq 3 ] || usage
FIX="$1"; IN="$2"; OUT="$3"
[ -f "${IN}" ] || { echo "ERROR: no file ${IN}" >&2; exit 1; }
if [ -e "${OUT}" ] && [ "$(readlink -f "${OUT}")" = "$(readlink -f "${IN}")" ]; then
    echo "ERROR: ${OUT} is the input file; write the edited copy elsewhere" >&2
    exit 1
fi
TMP="$(mktemp "${OUT}.XXXXXX")" || exit 1
trap 'rm -f "${TMP}"' EXIT

case "${FIX}" in
    pfile-region)
        # The decomp section is one line in the TopCrunch pfiles; any other form is refused.
        awk '
            function section(line,   name) {
                name = tolower(line); sub(/^[ \t]*/, "", name); sub(/[ \t{].*$/, "", name)
                return name
            }
            section($0) == "decomp" || section($0) == "decomposition" {
                s = $0
                if (!sub(/^[ \t]*[A-Za-z]+[ \t]*\{[ \t]*/, "", s) || !sub(/[ \t]*\}[ \t]*$/, "", s) || index(s, "{")) {
                    bad = 1; next
                }
                n = split(s, tok, /[ \t]+/)
                if (tolower(tok[1]) != "silist") { bad = 1; next }
                ids = ""
                for (i = 2; i <= n && tok[i] ~ /^[0-9]+$/; i++) ids = ids " " tok[i]
                t = ""
                for (; i <= n; i++) t = t " " tok[i]
                if (ids == "") { bad = 1; next }
                print "decomp { region { silist" ids t " }" t " }"
                rewritten++
                next
            }
            { print }
            END { exit (bad || rewritten != 1) }
        ' "${IN}" > "${TMP}" \
            || { echo "ERROR: ${IN} has no one-line \"decomp { silist ... }\" section to rewrite" >&2; exit 1; }
        ;;
    3cars-joint27)
        # The keyword, its comment lines, then the data line with the four nodes.
        awk '
            held != "" && /^\$/ { cmt = cmt $0 "\n"; next }
            held != "" {
                if (toupper(held) ~ /^\*CONSTRAINED_JOINT_REVOLUTE *$/ &&
                    $0 ~ /^ +1800808 +1800806 +1800809 +1800807( |$)/) {
                    print "*CONSTRAINED_JOINT_SPHERICAL"
                    printf "%s", cmt
                    print substr($0, 1, 20) "         0         0" substr($0, 41)
                    n++; held = ""; cmt = ""; next
                }
                print held; printf "%s", cmt; held = ""; cmt = ""
            }
            toupper($0) ~ /^\*CONSTRAINED_JOINT_REVOLUTE/ { held = $0; next }
            { print }
            END { if (held != "") { print held; printf "%s", cmt }; exit n != 1 }
        ' "${IN}" > "${TMP}" \
            || { echo "ERROR: ${IN} does not hold 3cars revolute joint 1800808 1800806 1800809 1800807" >&2; exit 1; }
        ;;
    camry-meshfix)
        # Only in an *ELEMENT_SOLID section, each element line exactly as the CCSA file holds
        # it. The new wedge keeps LS-DYNA's degenerate-hex form (N5 = N6, N7 = N8).
        awk '
            /^\*/ { solid = (toupper($0) ~ /^\*ELEMENT_SOLID *$/) }
            solid && $0 == " 2028692 2001025 2114029 2115364 2115381 2114030 2115006 2115006 2115009 2115009" {
                n++; next }
            solid && $0 == " 2033993 2001025 2115423 2115424 2115381 2115364 2115006 2115009 2114030 2114029" {
                print " 2033993 2001025 2115364 2115423 2115424 2115381 2115006 2115006 2115009 2115009"
                n++; next }
            { print }
            END { exit n != 2 }
        ' "${IN}" > "${TMP}" \
            || { echo "ERROR: ${IN} does not hold the Camry v5a solids 2028692 and 2033993 as CCSA ships them" >&2; exit 1; }
        ;;
    *)
        usage ;;
esac

mv -f "${TMP}" "${OUT}" || exit 1
trap - EXIT
echo "${FIX}: wrote ${OUT}; the change:"
diff "${IN}" "${OUT}"
exit 0
