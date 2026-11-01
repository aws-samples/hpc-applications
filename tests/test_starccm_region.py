"""How the STAR-CCM+ 21.02 x86 submit scripts find the Region of the PoD key's Parameter Store lookup.

With no key from -l or PODLIC, apps/StarCCM/scripts/21.02/x86/submit_batch.sbatch reads the key when the job starts,
with `aws ssm get-parameter`, from the Parameter Store parameter that PODLIC_SSM_PARAMETER names. When neither
AWS_REGION nor AWS_DEFAULT_REGION is set, it first reads the Region from the instance metadata (IMDSv2). Each request
gives up after 5 seconds (2 to connect) and fails on an HTTP error (curl -f). A Region name becomes AWS_REGION for the
lookup. No answer, an HTTP error, an answer cut off at the time limit, and an answer that is not a Region name (tested
in the C locale), such as a proxy's page or a Region name inside other text, count as no answer: the script sets no
Region, so the AWS CLI looks for one itself, and the job goes on. The key reaches STAR-CCM+ in LM_PROJECT only: no line
prints, logs or stores it.

The script names STAR-CCM+'s install under /fsx and puts /opt/slurm/bin first on its PATH, so these tests run a copy
of it that names temporary directories instead and differs from the script in those paths alone (checked here). They
run it with stubs of curl (the instance metadata), aws (the lookup: it notes the Region it is given and answers a
synthetic key), srun, STAR-CCM+ and the recorder, and a PATH that holds no other curl, aws, Slurm or sudo command: srun
runs none of the commands it is given (the cache drop, the THP setting). Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_starccm_region.py -q
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT_DIR = REPO / "apps" / "StarCCM" / "scripts" / "21.02" / "x86"
SCRIPTS = ("submit_batch.sbatch",)
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

PARAMETER = "/synthetic/starccm/pod-key"
KEY = "SYNTHETIC-POD-KEY-0123456789"
# The lookup, as the script runs it.
LOOKUP = ["ssm", "get-parameter", "--name", PARAMETER, "--with-decryption", "--query", "Parameter.Value", "--output",
          "text"]
# Host commands the script must not find: the stubs stand in for them.
HIDDEN = frozenset({"aws", "aws_completer", "curl", "srun", "sbatch", "scontrol", "squeue", "sinfo", "sudo", "mpirun",
                    "mpiexec", "starccm+"})
# The stub curl. It logs each request's arguments to CURL_LOG and answers as STUB_IMDS says:
#   answer      only the instance metadata's token and Region paths, at http://169.254.169.254: the token request
#               (latest/api/token) with a token, but only when it is a PUT that carries
#               X-aws-ec2-metadata-token-ttl-seconds with a whole number of seconds from 1 to 21600, and the Region
#               request (latest/meta-data/placement/region) with STUB_ANSWER (no newline added), but only when it is
#               a GET that carries that token in X-aws-ec2-metadata-token. Any other request to these two paths gets
#               http-error's 401 (an instance that requires IMDSv2 answers some with a 400 or a 405 instead;
#               under -f, curl's exit is 22 for each), and a request to any other URL gets curl's exit 7;
#   no-answer   nothing, and curl's exit at its --max-time (28), for every request;
#   http-error  an HTTP 401 for every request: with -f (--fail) nothing and exit 22, as curl does, else the page;
#   cut-off     as answer, but after STUB_ANSWER the Region request ends with exit 28, as curl ends a transfer at its
#               --max-time.
# Header names are compared in the C locale without regard to case, as in HTTP, and a header whose value is blank is
# not sent, as curl sends none.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
LC_ALL=C
token=stub-token fail=0 method=GET url="" ttl="" given=""
unauthorized() {
    [ "${fail}" = 1 ] && exit 22
    printf '%s\n' '<html><head><title>401 - Unauthorized</title></head>' '<body><h1>401 - Unauthorized</h1></body></html>'
    exit 0
}
header() {
    local name=${1%%:*} value=${1#*:}
    [ "${name}" != "$1" ] || return 0
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [ -n "${value}" ] || return 0
    shopt -s nocasematch
    case "${name}" in
        x-aws-ec2-metadata-token-ttl-seconds) ttl=${value} ;;
        x-aws-ec2-metadata-token) given=${value} ;;
    esac
    shopt -u nocasematch
}
while [ $# -gt 0 ]; do
    case "$1" in
        -X|--request) method=${2-}; shift ;;
        -X*) method=${1#-X} ;;
        -H|--header) header "${2-}"; shift ;;
        -H*) header "${1#-H}" ;;
        --fail) fail=1 ;;
        --connect-timeout|--max-time|-m) shift ;;
        --*) ;;
        http://*|https://*) url=$1 ;;
        -*f*) fail=1 ;;
    esac
    shift
done
case "${STUB_IMDS:-answer}" in
    no-answer) exit 28 ;;
    http-error) unauthorized ;;
esac
case "${url}" in
    http://169.254.169.254/latest/api/token)
        [ "${method}" = PUT ] && [[ "${ttl}" =~ ^[1-9][0-9]{0,4}$ ]] && [ "${ttl}" -le 21600 ] || unauthorized
        printf '%s' "${token}"
        exit 0 ;;
    http://169.254.169.254/latest/meta-data/placement/region)
        [ "${method}" = GET ] && [ "${given}" = "${token}" ] || unauthorized
        printf '%s' "${STUB_ANSWER}"
        [ "${STUB_IMDS:-answer}" = cut-off ] && exit 28
        exit 0 ;;
esac
echo "curl stub: refusing ${url}" >&2
exit 7
"""
# The stub aws. For each call it notes, in its own directory, the arguments (one per line), and AWS_REGION and
# AWS_DEFAULT_REGION as they are when they are set; then it answers the key, as `--output text` does.
AWS_STUB = r"""#!/bin/bash
n=1
while [ -e "${STATE}/aws-call-${n}" ]; do n=$((n + 1)); done
d="${STATE}/aws-call-${n}"
mkdir "${d}"
printf '%s\n' "$@" > "${d}/args"
[ "${AWS_REGION+set}" = set ] && printf '%s' "${AWS_REGION}" > "${d}/AWS_REGION"
[ "${AWS_DEFAULT_REGION+set}" = set ] && printf '%s' "${AWS_DEFAULT_REGION}" > "${d}/AWS_DEFAULT_REGION"
printf '%s\n' "${STUB_KEY}"
"""
# The stub STAR-CCM+: it notes its arguments, its LC_ALL ("unset" when it has none), and whether LM_PROJECT holds the
# key (never the key itself).
STARCCM_STUB = r"""#!/bin/bash
printf '%s\n' "$@" > "${STATE}/starccm.args"
printf '%s' "${LC_ALL-unset}" > "${STATE}/starccm.lc_all"
if [ "${LM_PROJECT+set}" != set ]; then echo unset; elif [ "${LM_PROJECT}" = "${STUB_KEY}" ]; then echo key
else echo other; fi > "${STATE}/starccm.lm_project"
echo "[stub STAR-CCM+] done"
"""
STUBS = {
    "curl": CURL_STUB,
    "aws": AWS_STUB,
    "srun": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"${STATE}/srun.log\"\nexit 0\n",
    "recorder": "#!/bin/bash\necho call >> \"${STATE}/recorder.log\"\n",
}
NOT_REGION_NAMES = {
    "a proxy's page": "<html><head><title>Proxy</title></head><body>Request denied by proxy.example.com</body></html>",
    "other text, then a Region name": "Request denied by proxy.example.com for eu-north-1",
    "a Region name, then other text": "eu-north-1: request denied by proxy.example.com",
    "a zone name": "eu-north-1a",
    "hyphenated text that ends in digits": "error-code-403",
}


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory) -> Path:
    """A directory of links to the host's commands, without the HIDDEN ones."""
    tools = tmp_path_factory.mktemp("host-tools")
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        try:
            entries = list(os.scandir(directory or "."))
        except OSError:
            continue
        for entry in entries:
            link = tools / entry.name
            if entry.name in HIDDEN or link.is_symlink():
                continue
            try:
                if entry.is_file() and os.access(entry.path, os.X_OK):
                    link.symlink_to(entry.path)
            except OSError:
                continue
    return tools


def runnable_copy(script: str, work: Path, stubs: Path) -> Path:
    """The script, with /fsx/Siemens/ moved under `work` and /opt/slurm/bin replaced by the stubs' directory: the copy
    differs from the script in those paths alone."""
    text = (SCRIPT_DIR / script).read_text()
    assert text.count("/fsx/Siemens/") == 1 and text.count("/opt/slurm/bin") == 1, \
        "the script names its install or Slurm's directory in other places"
    copy = work / script
    copy.write_text(text.replace("/fsx/Siemens/", f"{work}/fsx/Siemens/").replace("/opt/slurm/bin", str(stubs)))
    assert copy.read_text().replace(f"{work}/fsx/Siemens/", "/fsx/Siemens/").replace(str(stubs), "/opt/slurm/bin") \
        == text
    return copy


def run(script: str, work: Path, tools: Path, imds: str = "answer", answer: str = "eu-north-1", locale: str = "POSIX",
        env_extra: dict[str, str] | None = None):
    """Run the copy of `script` as a 2-node job, from `work`, with the stub curl answering as `imds` and `answer` say.
    Returns the process, the requests the stub curl logged, and the lookups the stub aws saw: one dict per call, with
    its arguments and the AWS_REGION and AWS_DEFAULT_REGION it was given (None for one that is not set). The job's
    LC_ALL is `locale`, POSIX by default: the C locale under another name, so that the Region-name test's C locale
    would show in STAR-CCM+'s LC_ALL if it left its subshell."""
    stubs, state = work / "stubs", work / "state"
    starccm = work / "fsx" / "Siemens" / "21.02.007" / "STAR-CCM+21.02.007" / "star" / "bin" / "starccm+"
    for d in (stubs, state, starccm.parent):
        d.mkdir(parents=True)
    for path, text in [*((stubs / name, text) for name, text in STUBS.items()), (starccm, STARCCM_STUB)]:
        path.write_text(text)
        path.chmod(0o755)
    log = state / "curl-requests.txt"
    log.touch()
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": locale, "CURL_LOG": str(log),
           "STUB_IMDS": imds, "STUB_ANSWER": answer, "STUB_KEY": KEY, "STATE": str(state),
           "PODLIC_SSM_PARAMETER": PARAMETER, "DYNAMODB_RECORDER": str(stubs / "recorder"),
           "SLURM_JOB_NUM_NODES": "2", "SLURM_SUBMIT_DIR": str(work), **(env_extra or {})}
    proc = subprocess.run([BASH, str(runnable_copy(script, work, stubs)), "-v", "21.02.007", "-s",
                           str(work / "synthetic.sim")], cwd=work, env=env, capture_output=True, text=True,
                          errors="replace", timeout=120)
    lookups = []
    for d in sorted(state.glob("aws-call-*"), key=lambda p: int(p.name.rsplit("-", 1)[1])):
        lookups.append({"args": (d / "args").read_text().splitlines(),
                        **{v: (d / v).read_text() if (d / v).exists() else None
                           for v in ("AWS_REGION", "AWS_DEFAULT_REGION")}})
    return proc, log.read_text().splitlines(), lookups


def assert_started_with_the_key(proc, work: Path, locale: str = "POSIX") -> None:
    """The job ran to its end and started STAR-CCM+ with the key in LM_PROJECT and with the LC_ALL that run() gave
    the job (`locale`), and no line printed, logged or stored the key: not on STAR-CCM+'s command line, not in the
    job's output, not in any file under `work`."""
    state = work / "state"
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert (state / "starccm.lm_project").read_text().split() == ["key"]
    assert (state / "starccm.lc_all").read_text() == locale
    assert KEY not in (state / "starccm.args").read_text()
    assert KEY not in proc.stdout + proc.stderr
    for f in work.rglob("*"):
        if f.is_file():
            assert KEY.encode() not in f.read_bytes(), f


def assert_read_then_lookup(proc, work: Path, requests, lookups, region: str | None, locale: str = "POSIX") -> None:
    """Both requests to the instance metadata, the token's then the Region's, carry -f, --connect-timeout and a
    --max-time of at most 5 seconds; then the lookup ran once, with AWS_REGION `region` (None: not set) and no
    AWS_DEFAULT_REGION; and STAR-CCM+ started with the key and with LC_ALL `locale`."""
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "meta-data/placement/region" in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout [1-5]( |$)", request), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request
    assert lookups == [{"args": LOOKUP, "AWS_REGION": region, "AWS_DEFAULT_REGION": None}], lookups
    assert_started_with_the_key(proc, work, locale)


@pytest.mark.parametrize("script", SCRIPTS)
def test_a_region_name_from_the_instance_metadata_is_the_lookups_region(script, tmp_path, host_tools):
    proc, requests, lookups = run(script, tmp_path, host_tools)
    assert_read_then_lookup(proc, tmp_path, requests, lookups, "eu-north-1")


@pytest.mark.parametrize("script", SCRIPTS)
@pytest.mark.parametrize("imds", ["no-answer", "http-error"])
def test_no_answer_and_an_http_error_set_no_region(script, imds, tmp_path, host_tools):
    """The lookup runs with no AWS_REGION, as when no Region is set: not with an empty one, which the AWS CLI takes as
    the Region."""
    proc, requests, lookups = run(script, tmp_path, host_tools, imds)
    assert_read_then_lookup(proc, tmp_path, requests, lookups, None)


@pytest.mark.parametrize("script", SCRIPTS)
@pytest.mark.parametrize("answer", ["eu-north-", "eu-north-1"], ids=["part of a Region name", "a whole Region name"])
def test_an_answer_cut_off_at_the_time_limit_sets_no_region(script, answer, tmp_path, host_tools):
    """curl's exit at its --max-time (28) after part of the answer, or after what reads as a whole Region name: the
    answer counts as none."""
    proc, requests, lookups = run(script, tmp_path, host_tools, "cut-off", answer)
    assert_read_then_lookup(proc, tmp_path, requests, lookups, None)


@pytest.mark.parametrize("script", SCRIPTS)
@pytest.mark.parametrize("answer", list(NOT_REGION_NAMES.values()), ids=list(NOT_REGION_NAMES))
def test_an_answer_that_is_not_a_region_name_sets_no_region(script, answer, tmp_path, host_tools):
    """A proxy's page that answers 200, a Region name after other text (the test's ^), a Region name before other
    text (its $), a zone name (the test's Region name ends in digits) and hyphenated text that ends in digits (its
    Region name starts with two letters) are not Region names. Each comes with curl's exit 0, so that only the
    Region-name test can refuse it."""
    proc, requests, lookups = run(script, tmp_path, host_tools, answer=answer)
    assert_read_then_lookup(proc, tmp_path, requests, lookups, None)


@pytest.mark.parametrize("script", SCRIPTS)
def test_a_region_name_with_an_i_reads_in_a_turkish_locale(script, tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the Region name is tested in the C locale; STAR-CCM+ still starts in
    the job's own locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    proc, requests, lookups = run(script, tmp_path, host_tools, answer="il-central-1", locale="tr_TR.UTF-8")
    assert_read_then_lookup(proc, tmp_path, requests, lookups, "il-central-1", "tr_TR.UTF-8")


@pytest.mark.parametrize("script", SCRIPTS)
@pytest.mark.parametrize("variable", ["AWS_REGION", "AWS_DEFAULT_REGION"])
def test_a_region_already_set_is_the_lookups_and_the_metadata_is_not_asked(script, variable, tmp_path, host_tools):
    proc, requests, lookups = run(script, tmp_path, host_tools, env_extra={variable: "us-west-2"})
    assert requests == [], requests
    expected = {"args": LOOKUP, "AWS_REGION": None, "AWS_DEFAULT_REGION": None}
    expected[variable] = "us-west-2"
    assert lookups == [expected], lookups
    assert_started_with_the_key(proc, tmp_path)
