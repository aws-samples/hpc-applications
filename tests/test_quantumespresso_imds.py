"""How the Quantum ESPRESSO benchmark launchers read the instance type from the instance metadata.

apps/QuantumEspresso/x86/qe-benchmark.sbatch and apps/QuantumEspresso/Arm/qe-benchmark.sbatch name their run directory
and the results block ("instance :") after the instance type, read from the instance metadata (IMDSv2). Each request
gives up after 3 seconds and fails on an HTTP error (curl -f), and no answer never ends the job, under the launchers'
`set -euo pipefail` included. No answer, an HTTP error, an answer cut off at the time limit, and an answer that is not
an instance type name (tested in the C locale), such as a proxy's page, a type name in capitals or a type name inside
other text, name the type "unknown", as no answer always did: the job runs to its end, and neither the run directory's
name nor the results block has anything of the answer.

The launchers keep pw.x's scratch under /tmp, so these tests run a copy of each that keeps it under a temporary
directory instead and differs from the launcher in that path alone (checked here). They run it with stubs of curl
(the instance metadata), uname, lscpu, nproc, fi_info, sudo, sync, srun and pw.x, a synthetic AUSURF112 deck and
build manifest, and a PATH that holds no other curl, aws, MPI or Slurm command: srun runs nothing (it prints what a
run prints at its end), and sudo writes nothing (the THP setting, the cache drop). Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_quantumespresso_imds.py -q
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
LAUNCHERS = {"x86": REPO / "apps" / "QuantumEspresso" / "x86" / "qe-benchmark.sbatch",
             "Arm": REPO / "apps" / "QuantumEspresso" / "Arm" / "qe-benchmark.sbatch"}
MACHINES = {"x86": "x86_64", "Arm": "aarch64"}
BASH = shutil.which("bash")

pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

# Host commands the launchers must not find: the stubs stand in for them.
HIDDEN = frozenset({"aws", "curl", "fi_info", "jq", "ldd", "lscpu", "module", "mpirun", "mpiexec", "nproc", "srun",
                    "sbatch", "scontrol", "squeue", "sinfo", "sudo", "sync", "uname"})

# The stub curl. It logs each request's arguments to CURL_LOG and answers as STUB_IMDS says:
#   answer      the token request with a token, the instance type request with STUB_ANSWER (no newline added);
#   no-answer   nothing, and curl's exit at its --max-time (28), for every request;
#   http-error  an HTTP 401 for every request: with -f (--fail) nothing and exit 22, as curl does, else the page;
#   cut-off     for the instance type, STUB_ANSWER less its last five characters, then exit 28, as curl ends a
#               transfer at its --max-time.
# Any other request (a download of the deck) is refused.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
case "$*" in
    *169.254.169.254*) ;;
    *) echo "curl stub: refusing $*" >&2; exit 7 ;;
esac
fail=0
for a in "$@"; do case "${a}" in --fail) fail=1 ;; --*) ;; -*f*) fail=1 ;; esac; done
case "${STUB_IMDS:-answer}" in
    no-answer) exit 28 ;;
    http-error)
        [ "${fail}" = 1 ] && exit 22
        printf '%s\n' '<html><head><title>401 - Unauthorized</title></head>' '<body><h1>401 - Unauthorized</h1></body></html>'
        exit 0 ;;
esac
case "$*" in
    *latest/api/token*) printf '%s' stub-token; exit 0 ;;
    *meta-data/instance-type*)
        [ "${STUB_IMDS:-answer}" = cut-off ] && { printf '%s' "${STUB_ANSWER%?????}"; exit 28; }
        printf '%s' "${STUB_ANSWER}"; exit 0 ;;
esac
exit 22
"""

STUBS = {
    "curl": CURL_STUB,
    "uname": "#!/bin/bash\nif [ \"${1:-}\" = -m ]; then echo \"${STUB_MACHINE}\"; else echo Linux; fi\n",
    # Four cores, one thread each.
    "lscpu": "#!/bin/bash\nprintf '%s\\n' '# The following is the parsable format' '# CORE' 0 1 2 3\n",
    "nproc": "#!/bin/bash\necho 4\n",
    "fi_info": "#!/bin/bash\nexit 1\n",
    "sudo": "#!/bin/bash\ncat > /dev/null\nexit 0\n",
    "sync": "#!/bin/bash\nexit 0\n",
    # srun runs nothing: it prints what pw.x prints at the end of a run.
    "srun": "#!/bin/bash\npwd > \"${STATE}/srun.cwd\"\nprintf '%s\\n' \"$*\" > \"${STATE}/srun.args\"\n"
            "printf '%s\\n' '     PWSCF        :      1.00s CPU      2.00s WALL' '' '   JOB DONE.'\n",
}

TYPES = {"x86": "hpc7a.96xlarge", "Arm": "c8g.48xlarge"}

# The run directory: BASE_DIR/Run/<job name>/<cluster>/<job id>-<nodes>x<instance type>-<ranks>-<date>.
RUN_DIR = re.compile(r"4242-1x(?P<type>[^/]*)-4-\d{2}-\d{2}-\d{4}-\d{2}-\d{2}")

NOT_TYPE_NAMES = [
    pytest.param("<html><body>Request denied by proxy.example.com</body></html>", id="a proxy's page"),
    pytest.param("Request denied by proxy.example.com", id="other text, then a host name"),
    pytest.param("CAPITALS", id="capitals"),
    pytest.param("TYPE: not found", id="a type name, then other text"),
    pytest.param("TYPE\n<p>Request checked by proxy.example.com", id="a type name, then a second line"),
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


def runnable_copy(arch: str, work: Path) -> Path:
    """The launcher, with pw.x's scratch moved from /tmp to `work`: the copy differs from it in that path alone."""
    text = LAUNCHERS[arch].read_text()
    assert text.count("SCRATCH=/tmp/") == 1, "the launcher sets its scratch in more places than one"
    copy = work / LAUNCHERS[arch].name
    copy.write_text(text.replace("SCRATCH=/tmp/", f"SCRATCH={work}/tmp/"))
    assert copy.read_text().replace(f"SCRATCH={work}/tmp/", "SCRATCH=/tmp/") == text
    return copy


def run(arch: str, work: Path, tools: Path, imds: str = "answer", answer: str | None = None, locale: str = "C"):
    """Run a copy of one launcher as a 1-node job of 4 ranks, from `work`, with the stub curl answering as `imds` and
    `answer` (by default the launcher's own instance type) say. Returns the process, the run directory's name (None
    unless exactly one was made), and the requests the stub logged."""
    stubs, state, base = work / "stubs", work / "state", work / "qe"
    install, deck = base / "7.5" / "gcc-stub", base / "benchmarks" / "AUSURF112"
    for d in (stubs, state, install / "bin", deck, work / "tmp"):
        d.mkdir(parents=True)
    for name, text in STUBS.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    (install / "bin" / "pw.x").write_text("#!/bin/bash\nexit 0\n")
    (install / "bin" / "pw.x").chmod(0o755)
    (install / "build-manifest.json").write_text('{"target": "stub", "qe_version": "7.5"}\n')
    (deck / "ausurf.in").write_text(" &CONTROL\n    pseudo_dir = './'\n    outdir = './'\n /\n")
    (deck / "Au.pbe-nd-van.UPF").write_text("<UPF synthetic>\n")
    log = state / "curl-requests.txt"
    log.touch()
    env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": locale, "CURL_LOG": str(log),
           "STUB_IMDS": imds, "STUB_ANSWER": TYPES[arch] if answer is None else answer,
           "STUB_MACHINE": MACHINES[arch], "STATE": str(state), "BASE_DIR": str(base),
           "QE_PW_PATH": str(install / "bin" / "pw.x"), "NTASKS": "4", "SLURM_JOB_NAME": "qe-ausurf112",
           "SLURM_JOB_ID": "4242", "SLURM_JOB_NUM_NODES": "1", "SLURM_CLUSTER_NAME": "test"}
    proc = subprocess.run([BASH, str(runnable_copy(arch, work))], cwd=work, env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, errors="replace", timeout=120)
    runs = base / "Run" / "qe-ausurf112" / "test"
    made = sorted(p.name for p in runs.iterdir()) if runs.is_dir() else []
    return proc, (made[0] if len(made) == 1 else None), log.read_text().splitlines()


def assert_runs_in(proc, run_dir: str | None, work: Path, itype: str) -> None:
    """The job ran to its end (pw.x's run in the run directory, and the results block), in one run directory named
    after `itype`, and the results block names it."""
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert run_dir is not None, proc.stdout
    m = RUN_DIR.fullmatch(run_dir)
    assert m and m.group("type") == itype, run_dir
    run_path = work / "qe" / "Run" / "qe-ausurf112" / "test" / run_dir
    assert (work / "state" / "srun.cwd").read_text().strip() == str(run_path)
    lines = proc.stdout.splitlines()
    assert f" instance         : {itype}" in lines, proc.stdout
    assert f" output           : {run_path}/ausurf.out" in lines, proc.stdout


def answer_for(arch: str, template: str) -> str:
    """A non-type answer built around the launcher's own type name, in capitals where the template says so."""
    return template.replace("CAPITALS", TYPES[arch].upper()).replace("TYPE", TYPES[arch])


@pytest.mark.parametrize("arch", LAUNCHERS)
def test_the_instance_type_names_the_run_directory_and_the_results(arch, tmp_path, host_tools):
    proc, run_dir, _ = run(arch, tmp_path, host_tools)
    assert_runs_in(proc, run_dir, tmp_path, TYPES[arch])


@pytest.mark.parametrize("arch", LAUNCHERS)
def test_both_requests_give_up_within_5_seconds_and_fail_on_an_http_error(arch, tmp_path, host_tools):
    _, _, requests = run(arch, tmp_path, host_tools)
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "meta-data/instance-type" in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--max-time [1-5]( |$)", request), request


@pytest.mark.parametrize("imds", ["no-answer", "http-error", "cut-off"])
@pytest.mark.parametrize("arch", LAUNCHERS)
def test_no_answer_an_http_error_and_a_cut_off_answer_name_the_type_unknown(arch, imds, tmp_path, host_tools):
    """The job runs to its end, under `set -e` too; the run directory and the results block name the type "unknown",
    with nothing of an error page and not the start of a type name cut off at the time limit."""
    proc, run_dir, _ = run(arch, tmp_path, host_tools, imds)
    assert_runs_in(proc, run_dir, tmp_path, "unknown")


@pytest.mark.parametrize("template", NOT_TYPE_NAMES)
@pytest.mark.parametrize("arch", LAUNCHERS)
def test_an_answer_that_is_not_a_type_name_names_the_type_unknown(arch, template, tmp_path, host_tools):
    """A proxy's page, a host name after other text, a type name in capitals, a type name before other text, and a
    type name followed by a second line are not instance type names."""
    proc, run_dir, _ = run(arch, tmp_path, host_tools, answer=answer_for(arch, template))
    assert_runs_in(proc, run_dir, tmp_path, "unknown")


@pytest.mark.parametrize("arch", LAUNCHERS)
def test_a_type_name_with_an_i_reads_in_a_turkish_locale(arch, tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    itype = {"x86": "c8i.96xlarge", "Arm": "im4gn.16xlarge"}[arch]
    proc, run_dir, _ = run(arch, tmp_path, host_tools, answer=itype, locale="tr_TR.UTF-8")
    assert_runs_in(proc, run_dir, tmp_path, itype)
