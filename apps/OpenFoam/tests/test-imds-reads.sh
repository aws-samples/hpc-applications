#!/bin/bash
# =============================================================================
# How the Arm launcher reads the instance type from IMDS, the launcher run end
# to end with the stubs of stubs.sh. The type names only the run directory and
# the job log (the "Instance type:" lines of the banner and of the report).
# What it pins:
#   * both IMDS requests give up within 5 seconds (2 to connect), and use -f;
#   * the instance type names the run directory and both "Instance type:"
#     lines, and so does a type name with an i in a Turkish locale, where [a-z]
#     leaves out i (SKIP where that locale is not installed);
#   * with no answer, an HTTP error, an answer cut off at the time limit, or an
#     answer that is not an instance type name (a page, a host name after other
#     text, capitals, a type name before other text, a type name and a second
#     line), the job runs to its end, and neither the run directory's name nor
#     the job log has an instance type or any of the answer.
#
#   apps/OpenFoam/tests/test-imds-reads.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stubs.sh
source "${HERE}/stubs.sh"
ARM=Arm/openfoam-benchmark.sbatch
# curl for these runs, put first in PATH; IMDS answers as STUB_IMDS says, and
# each call is logged to CURL_LOG:
#   answer      a token, then STUB_INSTANCE_TYPE (m8g.48xlarge if unset);
#   no-answer   nothing, exit 28: no answer within the time limit;
#   http-error  401 for every request: with -f (--fail) nothing and exit 22, as
#               curl does, else the error page and exit 0;
#   cut-off     for the instance type, its first characters (the type less its
#               last five), then exit 28, as curl ends a transfer at its time
#               limit.
# Any other URL (a case or mesh download) is refused.
mkdir -p "${STUBS}/imds"
cat > "${STUBS}/imds/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
case "$*" in
  *api/token*|*instance-type*) ;;
  *) echo "curl stub: refusing $*" >&2; exit 22;;
esac
fail=""
for a in "$@"; do
  case "${a}" in --fail) fail=1;; --*) ;; -*f*) fail=1;; esac
done
case "${STUB_IMDS:-answer}" in
  no-answer) exit 28;;
  http-error)
    [ -z "${fail}" ] || exit 22
    printf '<?xml version="1.0" encoding="iso-8859-1"?>\n<!DOCTYPE html>\n<html><head><title>401 - Unauthorized</title></head><body><h1>401 - Unauthorized</h1></body></html>\n'
    exit 0;;
esac
case "$*" in
  *api/token*) echo "stub-token"; exit 0;;
esac
t="${STUB_INSTANCE_TYPE-m8g.48xlarge}"
if [ "${STUB_IMDS:-answer}" = cut-off ]; then printf '%s' "${t%?????}"; exit 28; fi
printf '%s\n' "${t}"
EOF
chmod +x "${STUBS}/imds/curl"
IMDS_PATH="PATH=${STUBS}/imds:${STUBS}/bin:/usr/local/bin:/usr/bin:/bin"
# Answers that are not an instance type name.
NOT_TYPES=("<html><body>Request denied by proxy.example.com</body></html>"
           "Request denied by proxy.example.com"
           "M8G.48XLARGE"
           "m8g.48xlarge: not found"
           "m8g.48xlarge"$'\n'"<p>Request checked by proxy.example.com")

# arm <NAME=value...>: run the Arm launcher with this test's curl, the next job id.
arm() {
    : > "${STUBS}/curl.log"
    job=$((job + 1))
    run_script "${ARM}" "${job}" "${IMDS_PATH}" CURL_LOG="${STUBS}/curl.log" "$@"
}
# named <label> <instance type, or empty for none>: the job ran to its end, in a
# run directory named <job>-2x<type>-8-<date>, and both "Instance type:" lines
# name that type.
named() {
    completes "$1" "${job}"
    case "${RUN##*/}" in
        "${job}-2x$2-8-"[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            if [ -d "${RUN}" ]; then ok "$1: the run directory is ${job}-2x$2-8-<date>"
            else bad "$1: the run directory exists" "${RUN}" "none"; fi ;;
        *) bad "$1: the run directory is ${job}-2x$2-8-<date>" "<...>/${job}-2x$2-8-<date>" "${RUN}" ;;
    esac
    has "$1: the banner's instance type" "Instance type: $2"
    has "$1: the report's instance type" "Instance type:    $2"
}

job=900
echo "== ${ARM} =="
if skip_arm_here "${ARM}"; then
    skipt "${ARM}" "this host has a module system, which the Arm launcher loads, and which could put a real MPI first in PATH"
else
    arm
    named "m8g.48xlarge from IMDS" m8g.48xlarge
    check "both IMDS requests fail on an HTTP error, with a 2 s connect and a 5 s total timeout" 2 \
        "$(grep -c '^-fs --connect-timeout 2 --max-time 5 .*169\.254\.169\.254' "${STUBS}/curl.log")"
    for mode in no-answer http-error cut-off; do
        arm STUB_IMDS="${mode}"
        named "IMDS ${mode}" ""
    done
    for answer in "${NOT_TYPES[@]}"; do
        arm STUB_INSTANCE_TYPE="${answer}"
        named "the answer '${answer//$'\n'/\\n}'" ""
    done
    if grep -qiE '^tr_TR\.utf-?8$' <<< "$(locale -a 2>/dev/null)"; then
        arm STUB_INSTANCE_TYPE=im4gn.16xlarge LANG=tr_TR.UTF-8
        named "im4gn.16xlarge from IMDS, in a Turkish locale" im4gn.16xlarge
    else
        skipt "im4gn.16xlarge from IMDS, in a Turkish locale" "the tr_TR.UTF-8 locale is not installed"
    fi
fi
finish "instance metadata"
