"""How Utils/record-results/Fluent-Benchmarks.sh reads the availability zone from the instance metadata.

The script writes a Fluent benchmark's record as JSON, with the availability zone, read from the instance metadata
(IMDSv2), as aws_region, then puts it in DynamoDB. It asks for its own token, in its own variable, so the record no
longer depends on a TOKEN exported by the job, and a caller's TOKEN is left as it is. Each request gives up after 5
seconds (2 to connect) and fails on an HTTP error (curl -f). No answer, an HTTP error, an answer cut off at the time
limit, and an answer that is not a zone name (tested in the C locale), such as a proxy's page, a zone name in capitals
or inside other text, or an instance type name, count as no answer: aws_region is empty, and the record stays valid
JSON. A Local Zone's name counts as a zone name.

These tests run the script itself with stubs of curl (the instance metadata, which here answers only requests that
carry its token, as on an instance that requires IMDSv2), aws (which logs the call and contacts nothing), mpirun,
fi_info, scontrol and uname, and a PATH that holds no other curl, aws, MPI or Slurm command, from a temporary
directory. Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_record_results_imds.py -q
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "Utils" / "record-results" / "Fluent-Benchmarks.sh"
BASH = shutil.which("bash")

pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

# Host commands the script must not find: the stubs stand in for them.
HIDDEN = frozenset({"aws", "curl", "fi_info", "mpirun", "mpiexec", "scontrol", "srun", "sbatch", "squeue", "sinfo",
                    "sudo", "uname"})

# The stub curl. It logs each request's arguments to CURL_LOG and answers as STUB_IMDS says:
#   answer      the token request with a token, the zone request with STUB_ANSWER (no newline added), or, when the
#               request does not carry that token, an HTTP 401;
#   no-answer   nothing, and curl's exit at its --max-time (28), for every request;
#   http-error  an HTTP 401 for every request;
#   cut-off     for the zone, STUB_ANSWER less its last five characters, then exit 28, as curl ends a transfer at its
#               --max-time.
# An HTTP 401 is, with -f (--fail), nothing and exit 22, as curl does, else the instance metadata's page.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
case "$*" in
    *169.254.169.254*) ;;
    *) echo "curl stub: refusing $*" >&2; exit 7 ;;
esac
fail=0
for a in "$@"; do case "${a}" in --fail) fail=1 ;; --*) ;; -*f*) fail=1 ;; esac; done
unauthorized() {
    [ "${fail}" = 1 ] && exit 22
    printf '%s\n' '<?xml version="1.0" encoding="iso-8859-1"?>' '<html><head><title>401 - Unauthorized</title></head>' \
        '<body><h1>401 - Unauthorized</h1></body></html>'
    exit 0
}
case "${STUB_IMDS:-answer}" in
    no-answer) exit 28 ;;
    http-error) unauthorized ;;
esac
case "$*" in
    *latest/api/token*) printf '%s' stub-token; exit 0 ;;
    *placement/availability-zone*)
        case "$*" in *"X-aws-ec2-metadata-token: stub-token "*) ;; *) unauthorized ;; esac
        [ "${STUB_IMDS:-answer}" = cut-off ] && { printf '%s' "${STUB_ANSWER%?????}"; exit 28; }
        printf '%s' "${STUB_ANSWER}"; exit 0 ;;
esac
exit 22
"""

STUBS = {
    "curl": CURL_STUB,
    "aws": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"${STATE}/aws.log\"\nexit 0\n",
    "mpirun": "#!/bin/bash\necho 'mpirun (Open MPI) 4.1.7'\n",
    "fi_info": "#!/bin/bash\nif [ \"${1:-}\" = --version ]; then printf '%s\\n' 'fi_info: 2.4.0' 'libfabric: 2.4.0'; "
               "else printf '%s\\n' 'provider: efa' '    version: 201.0'; fi\n",
    "scontrol": "#!/bin/bash\necho 'ClusterName = test'\n",
    "uname": "#!/bin/bash\necho 'Linux node1 6.12.0 #1 SMP x86_64 GNU/Linux'\n",
}

ZONE = "us-east-2b"
CASE = "aircraft_wing_14m"

NOT_ZONE_NAMES = [
    pytest.param("<html><body>Request denied by proxy.example.com</body></html>", id="a proxy's page"),
    pytest.param("Request denied by proxy.example.com", id="other text, then a host name"),
    pytest.param("Not found: us-east-2b", id="other text, then a zone name"),
    pytest.param("US-EAST-2B", id="capitals"),
    pytest.param("us-east-2b: not found", id="a zone name, then other text"),
    pytest.param("us-east-2b\n<p>Request checked by proxy.example.com", id="a zone name, then a second line"),
    pytest.param("hpc7a.96xlarge", id="an instance type name"),
]


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


def run(work: Path, tools: Path, imds: str = "answer", answer: str = ZONE, locale: str = "C",
        command: list[str] | None = None):
    """Run the script (or `command`) in a run directory of a 2-node Fluent job of 384 ranks, with the stub curl
    answering as `imds` and `answer` say. Returns the process, the record (None unless it is valid JSON), and the
    requests the stub logged."""
    stubs, state, run_dir = work / "stubs", work / "state", work / "run"
    for d in (stubs, state, run_dir):
        d.mkdir(parents=True)
    for name, text in STUBS.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    (run_dir / "hostfile").write_text("node1\nnode2\n")
    (run_dir / f"{CASE}-1.out").write_text("  Solver rating    =   1000.0\n")
    log = state / "curl-requests.txt"
    log.touch()
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": locale, "CURL_LOG": str(log),
           "STUB_IMDS": imds, "STUB_ANSWER": answer, "STATE": str(state), "benchmark_name": CASE,
           "workdir": str(run_dir), "instanceType": "hpc7a.96xlarge", "FLUENT_ARCH": "lnamd64",
           "fluentversion": "v261", "libfabric_version": "2.4.0", "SLURM_JOB_ID": "4242", "SLURM_NPROCS": "384",
           "SLURM_JOB_NUM_NODES": "2"}
    proc = subprocess.run(command or [BASH, str(SCRIPT)], cwd=run_dir, env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, errors="replace", timeout=120)
    try:
        record = json.loads((run_dir / f"{CASE}.json").read_text())
    except (OSError, ValueError):
        record = None
    return proc, record, log.read_text().splitlines()


def assert_records(proc, record, work: Path, zone: str) -> None:
    """The script wrote valid JSON with `zone` ("" for none) as aws_region, and put that file once, in the table the
    script names."""
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert record is not None, (work / "run" / f"{CASE}.json").read_text()
    assert record["aws_region"] == {"S": zone}, record["aws_region"]
    assert record["dataset"] == {"S": CASE} and record["jobid"] == {"S": "4242"}, record
    table = re.search(r'^dynamodb_table_name="([^"]+)"$', SCRIPT.read_text(), re.MULTILINE)
    assert table, "the script sets no dynamodb_table_name"
    calls = (work / "state" / "aws.log").read_text().splitlines()
    assert calls == [f"dynamodb --region us-east-1 put-item --table-name {table.group(1)} --item file://{CASE}.json"]


def test_the_zone_is_recorded(tmp_path, host_tools):
    proc, record, _ = run(tmp_path, host_tools)
    assert_records(proc, record, tmp_path, ZONE)


def test_both_requests_give_up_within_5_seconds_fail_on_an_http_error_and_carry_a_token(tmp_path, host_tools):
    _, _, requests = run(tmp_path, host_tools)
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "placement/availability-zone" in requests[1], requests
    assert "X-aws-ec2-metadata-token: stub-token " in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout [1-5]( |$)", request), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request


@pytest.mark.parametrize("imds", ["no-answer", "http-error", "cut-off"])
def test_no_answer_an_http_error_and_a_cut_off_answer_record_no_zone(imds, tmp_path, host_tools):
    """The record is written, with an empty aws_region: nothing of an error page, and not the start of a zone name
    cut off at the time limit."""
    proc, record, _ = run(tmp_path, host_tools, imds)
    assert_records(proc, record, tmp_path, "")


@pytest.mark.parametrize("answer", NOT_ZONE_NAMES)
def test_an_answer_that_is_not_a_zone_name_counts_as_none(answer, tmp_path, host_tools):
    """A proxy's page, a host name or a zone name after other text, a zone name in capitals, a zone name before other
    text or followed by a second line, and an instance type name are not zone names."""
    proc, record, _ = run(tmp_path, host_tools, answer=answer)
    assert_records(proc, record, tmp_path, "")


def test_a_local_zone_name_is_recorded(tmp_path, host_tools):
    proc, record, _ = run(tmp_path, host_tools, answer="us-east-1-bos-1a")
    assert_records(proc, record, tmp_path, "us-east-1-bos-1a")


def test_a_zone_name_with_an_i_reads_in_a_turkish_locale(tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the zone name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    proc, record, _ = run(tmp_path, host_tools, answer="il-central-1a", locale="tr_TR.UTF-8")
    assert_records(proc, record, tmp_path, "il-central-1a")


def test_a_callers_token_is_left_as_it_is(tmp_path, host_tools):
    """Sourced by a job that holds its own TOKEN, the script asks for a token of its own, and leaves the job's."""
    token_file = tmp_path / "state" / "caller-token"
    command = [BASH, "-c", 'TOKEN=caller-token; . "$1"; printf %s "${TOKEN}" > "$2"', "job", str(SCRIPT),
               str(token_file)]
    proc, record, requests = run(tmp_path, host_tools, command=command)
    assert_records(proc, record, tmp_path, ZONE)
    assert token_file.read_text() == "caller-token"
    assert "X-aws-ec2-metadata-token: stub-token " in requests[1], requests
