"""How Utils/OSU-Benchmarks/build_osu_benchmarks_openmpi.sh and build_osu_benchmarks_intelmpi.sh build OMB.

These tests pin:
- the settings (OSU_VERSION, OSU_SHA256, INSTALL_DIR, MAKE_JOBS), checked before any module loads and before the
  download: a value out of its range stops the script with exit status 1 and a message, and nothing is downloaded;
- the MPI: the Open MPI script loads the openmpi module, the Intel MPI script exports I_MPI_OFI_LIBRARY_INTERNAL=0 (a
  value the job gives is kept) before it loads intelmpi, then loads libfabric-aws, each module once; with no module
  command at all, the MPI on the PATH is used, with a NOTE; and mpirun --version must name the script's MPI, else the
  script stops before the download;
- the download (curl, failing on an HTTP error and giving up on an attempt after 5 minutes) of the release tarball,
  checked against OSU_SHA256 or the SHA-256 the script knows for the release (7.5.3's and 8.0b2's are pinned here); a
  release it does not know is built unchecked, with a NOTE;
- the build in a directory of its own under TMPDIR, in the unpacked source (which OMB 8.0b2's makefiles need):
  configure (CC=mpicc CXX=mpicxx and the prefix INSTALL_DIR/install), make -j MAKE_JOBS (nproc by default), make
  install, each step with its own log;
- a step that ends with another status than 0: the script ends with that status, after its message, the last 30 lines
  of the step's log and the kept build directory, and nothing is installed after it;
- once installed: the logs in INSTALL_DIR/logs/<version>-<UTC time>/, the record INSTALL_DIR/install/osu-build.txt
  (OMB version and SHA-256, mpirun's and mpicc's version lines, time, host), the build directory removed, and the files
  an earlier in-tree build left in INSTALL_DIR left as they are.

The scripts name /fsx/ (INSTALL_DIR's default) and source /etc/profile.d/modules.sh, so these tests run copies that
name a temporary directory and a stub modules.sh (its `module` function) instead, and differ from the scripts in those
paths alone (checked here). They run them with stubs of curl (serving a synthetic OMB tarball whose configure script
records how it was called), make, nproc and hostname, stub MPIs (mpirun, mpicc, mpicxx), and a PATH that holds no
other MPI, curl, make, module, Slurm, aws or sudo command: nothing is downloaded or compiled. Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_osu_build.py -q
"""
from __future__ import annotations

import gzip
import hashlib
import io
import os
import re
import shutil
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
OSU = REPO / "Utils" / "OSU-Benchmarks"
SCRIPTS = {"openmpi": OSU / "build_osu_benchmarks_openmpi.sh", "intelmpi": OSU / "build_osu_benchmarks_intelmpi.sh"}
DEFAULT_INSTALL = {"openmpi": "OSU-Benchmark-OpenMPI", "intelmpi": "OSU-Benchmark-IntelMPI"}
MODULES = "/etc/profile.d/modules.sh"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

# The release the scripts build when OSU_VERSION is unset.
DEFAULT_VERSION = "7.5.3"
# The SHA-256 the scripts know for each release.
KNOWN_SHA256 = {"7.5.3": "ab7f970659e14c9246f3eac43828573f519eabf34fff9734e6f831a862caea6b",
                "8.0b2": "2ea96f0d569b012e70eb5cf8d1025890a228e0dfdb3e84d202c3cf53ee34f1b7"}
URL = "https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-{}.tar.gz"
# The binaries the stub make installs, as OMB lays them out under <prefix>/libexec/osu-micro-benchmarks/mpi.
BINARIES = ("pt2pt/osu_latency", "pt2pt/osu_bw", "pt2pt/osu_bibw", "pt2pt/osu_mbw_mr", "pt2pt/osu_multi_lat",
            "collective/osu_allreduce", "collective/osu_alltoall")
NPROC = 6
HOSTNAME = "stub-head-node"

# Host commands the scripts must not find: the stubs stand in for some of them, and they run none of the others.
HIDDEN = frozenset({"curl", "wget", "make", "nproc", "hostname", "module", "mpirun", "mpiexec", "mpicc", "mpicxx",
                    "srun", "sbatch", "scontrol", "squeue", "sinfo", "aws", "sudo"})

# mpirun --version's first line for each stub MPI, and the line it prints after it.
MPI_VERSIONS = {
    "openmpi4": ["mpirun (Open MPI) 4.1.99", "", "Report bugs to https://www.example.invalid/"],
    "openmpi5": ["mpirun (Open MPI) 5.0.99stub", "", "Report bugs to https://www.example.invalid/"],
    "intelmpi": ["Intel(R) MPI Library for Linux* OS, Version 2021.99.0 Build 20990101 (id: stub)",
                 "Copyright 2003-2099, Intel Corporation."],
}
CC_VERSION = "gcc (GCC) 99.1.0 (synthetic)"
# Which stub MPI each module puts first on the PATH; STUB_WRONG_MPI=1 swaps them, as a module of another MPI would.
MODULES_STUB = r"""module() {
    printf '%s %s %s\n' "$1" "$2" "${I_MPI_OFI_LIBRARY_INTERNAL-unset}" >> "${STATE}/module.log"
    local mpi=""
    case "$1 $2" in
        "load openmpi") mpi=openmpi4; [ "${STUB_WRONG_MPI:-0}" = 1 ] && mpi=intelmpi ;;
        "load openmpi5") mpi=openmpi5; [ "${STUB_WRONG_MPI:-0}" = 1 ] && mpi=openmpi4 ;;
        "load intelmpi") mpi=intelmpi; [ "${STUB_WRONG_MPI:-0}" = 1 ] && mpi=openmpi4
                         export I_MPI_ROOT="${STUB_MPI_ROOT}/intelmpi" ;;
        "load libfabric-aws") export LD_LIBRARY_PATH="/stub/libfabric-aws/lib64:${LD_LIBRARY_PATH:-}" ;;
        *) echo "module stub: refusing $*" >&2; return 1 ;;
    esac
    [ -n "${mpi}" ] && export PATH="${STUB_MPI_ROOT}/${mpi}/bin:${PATH}"
    return 0
}
"""
# curl: logs its arguments and, for the OMB tarball's URL, writes STUB_TARBALL to the -o file, as STUB_CURL says:
# ok (the default), http-error (an HTTP 404: with -f nothing and exit 22, as curl does) or no-answer (exit 28).
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/curl.log"
out="" url="" prev=""
for a in "$@"; do
    [ "${prev}" = -o ] && out=${a}
    case "${a}" in https://*) url=${a} ;; esac
    prev=${a}
done
case "${url}" in
    https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-*.tar.gz) ;;
    *) echo "curl stub: refusing $*" >&2; exit 7 ;;
esac
case "${STUB_CURL:-ok}" in
    http-error) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
    no-answer) echo "curl: (28) Connection timed out after 10001 milliseconds" >&2; exit 28 ;;
esac
cp "${STUB_TARBALL}" "${out}"
"""
# make: logs its arguments and working directory. `make install` installs BINARIES under the prefix that the
# tarball's configure recorded in that directory; each call ends with STUB_MAKE_RC or STUB_INSTALL_RC.
MAKE_STUB = r"""#!/bin/bash
printf '%s|%s\n' "$*" "$(pwd)" >> "${STATE}/make.log"
if [ "$1" = install ]; then
    rc=${STUB_INSTALL_RC:-0}
    [ "${rc}" = 0 ] || { echo "make: *** [install] Error ${rc}"; exit "${rc}"; }
    prefix=$(cat config.prefix)
    for b in ${STUB_BINARIES}; do
        mkdir -p "${prefix}/libexec/osu-micro-benchmarks/mpi/${b%/*}"
        printf '#!/bin/bash\n' > "${prefix}/libexec/osu-micro-benchmarks/mpi/${b}"
        chmod +x "${prefix}/libexec/osu-micro-benchmarks/mpi/${b}"
    done
    exit 0
fi
for i in $(seq 1 40); do echo "make: compiling synthetic unit ${i}"; done
[ "${STUB_MAKE_RC:-0}" = 0 ] || { echo "make: *** [all] Error ${STUB_MAKE_RC}"; exit "${STUB_MAKE_RC}"; }
"""
# The tarball's configure: records its arguments and working directory, and the prefix for the stub make; prints 40
# lines, then ends with STUB_CONFIGURE_RC.
CONFIGURE = r"""#!/bin/bash
printf '%s\n' "$@" > "${STATE}/configure.args"
pwd > "${STATE}/configure.cwd"
printf '%s\n' "$0" > "${STATE}/configure.path"
for a in "$@"; do case "${a}" in --prefix=*) printf '%s\n' "${a#--prefix=}" > config.prefix ;; esac; done
for i in $(seq 1 40); do echo "checking for synthetic feature ${i}... yes"; done
rc=${STUB_CONFIGURE_RC:-0}
[ "${rc}" = 0 ] || { echo "configure: error: synthetic error ${rc}"; exit "${rc}"; }
"""


def mpi_stub(flavour: str, tool: str) -> str:
    """A stub mpirun, mpicc or mpicxx: --version prints the MPI's (or the compiler's) version lines."""
    lines = MPI_VERSIONS[flavour] if tool == "mpirun" else [CC_VERSION, "Copyright (C) 2099 synthetic"]
    printed = "".join(f"printf '%s\\n' {line!r}\n" for line in lines)
    return f"#!/bin/bash\nif [ \"$*\" = --version ]; then\n{printed}exit 0\nfi\nexit 1\n"


@dataclass
class Build:
    proc: subprocess.CompletedProcess
    work: Path
    install: Path               # INSTALL_DIR
    curl: list[str]             # each curl call's arguments
    modules: list[list[str]]    # each module call: its two arguments and I_MPI_OFI_LIBRARY_INTERNAL at that moment
    make: list[tuple[str, str]] # each make call: its arguments and working directory
    configure: list[str] | None  # configure's arguments, if it ran
    configure_cwd: str | None
    configure_path: str | None
    left: list[Path]            # what is left under TMPDIR

    @property
    def err(self) -> list[str]:
        return self.proc.stderr.splitlines()

    @property
    def out(self) -> list[str]:
        return self.proc.stdout.splitlines()


def host_tools_dir(tmp_path_factory, hidden=HIDDEN) -> Path:
    """A directory of links to the host's commands, without the hidden ones."""
    tools = tmp_path_factory.mktemp("host-tools")
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        try:
            entries = list(os.scandir(directory or "."))
        except OSError:
            continue
        for entry in entries:
            link = tools / entry.name
            if entry.name in hidden or link.is_symlink():
                continue
            try:
                if entry.is_file() and os.access(entry.path, os.X_OK):
                    link.symlink_to(entry.path)
            except OSError:
                continue
    return tools


def make_tarball(path: Path, version: str) -> str:
    """A synthetic OMB release tarball, the same bytes for the same version: its top directory holds the recording
    configure and a README. Returns its SHA-256."""
    top = f"osu-micro-benchmarks-{version}"
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, text, mode in ((f"{top}/configure", CONFIGURE, 0o755), (f"{top}/README", "synthetic\n", 0o644)):
            data = text.encode()
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), mode
            tar.addfile(info, io.BytesIO(data))
    path.write_bytes(gzip.compress(raw.getvalue(), mtime=0))
    return hashlib.sha256(path.read_bytes()).hexdigest()


@pytest.fixture(scope="session")
def host_tools(tmp_path_factory) -> Path:
    return host_tools_dir(tmp_path_factory)


def runnable_copy(script: Path, work: Path) -> Path:
    """The script, with /fsx/ moved under `work` and /etc/profile.d/modules.sh replaced by `work`/modules.sh: the copy
    differs from the script in those paths alone."""
    text = script.read_text()
    assert str(work) not in text
    copy = work / script.name
    copy.write_text(text.replace(MODULES, str(work / "modules.sh")).replace("/fsx/", f"{work}/fsx/"))
    assert copy.read_text().replace(f"{work}/fsx/", "/fsx/").replace(str(work / "modules.sh"), MODULES) == text
    return copy


def run_build(script: Path, work: Path, tools: Path, env: dict[str, str | None] | None = None,
              modules: bool = True, path_mpi: str | None = None, tarball_version: str | None = None) -> Build:
    """Run a copy of a build script from `work`, with the stub module function (none when `modules` is False) and, when
    `path_mpi` names a stub MPI, that MPI's bin directory on the PATH. The stub curl serves a tarball whose top
    directory is that of `tarball_version` (by default the release the script builds). `env` adds variables to the
    script's environment, or unsets them (None)."""
    stubs, state, tmp, mpi_root = work / "stubs", work / "state", work / "tmp", work / "mpi"
    for d in (stubs, state, tmp, work / "fsx"):
        d.mkdir(parents=True, exist_ok=True)
    for flavour in MPI_VERSIONS:
        bindir = mpi_root / flavour / "bin"
        bindir.mkdir(parents=True)
        for tool in ("mpirun", "mpicc", "mpicxx"):
            (bindir / tool).write_text(mpi_stub(flavour, tool))
            (bindir / tool).chmod(0o755)
    for name, text in {"curl": CURL_STUB, "make": MAKE_STUB, "nproc": f"#!/bin/bash\necho {NPROC}\n",
                       "hostname": f"#!/bin/bash\necho {HOSTNAME}\n"}.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    if modules:
        (work / "modules.sh").write_text(MODULES_STUB)
    job_env = {"PATH": os.pathsep.join([str(stubs), *([str(mpi_root / path_mpi / "bin")] if path_mpi else []),
                                        str(tools)]),
               "HOME": str(work), "LC_ALL": "POSIX", "STATE": str(state), "TMPDIR": str(tmp),
               "STUB_MPI_ROOT": str(mpi_root), "STUB_BINARIES": " ".join(BINARIES)}
    for name, value in (env or {}).items():
        if value is None:
            job_env.pop(name, None)
        else:
            job_env[name] = value
    version = tarball_version or job_env.get("OSU_VERSION") or DEFAULT_VERSION
    job_env["STUB_TARBALL"] = str(work / "omb.tar.gz")
    make_tarball(work / "omb.tar.gz", version)
    proc = subprocess.run([BASH, str(runnable_copy(script, work))], cwd=work, env=job_env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, errors="replace", timeout=120)

    def lines(name: str) -> list[str]:
        return (state / name).read_text().splitlines() if (state / name).exists() else []

    install = Path(job_env.get("INSTALL_DIR") or work / "fsx" / DEFAULT_INSTALL[script_kind(script)])
    return Build(proc, work, install, lines("curl.log"), [line.split() for line in lines("module.log")],
                 [tuple(line.split("|", 1)) for line in lines("make.log")],
                 lines("configure.args") or None, (lines("configure.cwd") or [None])[0],
                 (lines("configure.path") or [None])[0], sorted(tmp.rglob("*")))


def script_kind(script: Path) -> str:
    return "openmpi" if "openmpi" in script.name else "intelmpi"


def tarball_sha256(work: Path, version: str) -> str:
    """The SHA-256 of the synthetic tarball run_build serves for `version` (it is rebuilt the same way each time)."""
    probe = work / "probe"
    probe.mkdir(exist_ok=True)
    return make_tarball(probe / "omb.tar.gz", version)


def record(build: Build) -> dict[str, str]:
    text = (build.install / "install" / "osu-build.txt").read_text()
    return dict(line.split("=", 1) for line in text.splitlines())


def assert_stopped_before_download(build: Build, message: str, status: int = 1) -> None:
    """The script ended with `status` and `message` on stderr, and downloaded nothing."""
    assert build.proc.returncode == status, build.proc.stdout + build.proc.stderr
    assert any(message in line for line in build.err), build.proc.stderr
    assert build.curl == []
    assert not (build.install / "install").exists()


def assert_nothing_installed(build: Build) -> None:
    assert not (build.install / "install").exists()
    assert not (build.install / "logs").exists()


def kept_build_dir(build: Build) -> Path:
    """The build directory the script says it kept, which exists under TMPDIR."""
    kept = [line.split(": ", 1)[1] for line in build.err if line.startswith("The build directory is kept: ")]
    assert len(kept) == 1, build.proc.stderr
    path = Path(kept[0])
    assert path.is_dir() and path.parent == build.work / "tmp" and path.name.startswith("osu-build."), path
    return path


def sha_env(work: Path, version: str | None = None) -> dict[str, str]:
    return {"OSU_SHA256": tarball_sha256(work, version or DEFAULT_VERSION)}


@pytest.mark.parametrize("kind", SCRIPTS)
def test_the_default_build_downloads_checks_and_builds_in_the_unpacked_source(kind, tmp_path, host_tools):
    digest = tarball_sha256(tmp_path, DEFAULT_VERSION)
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={"OSU_SHA256": digest})
    assert build.proc.returncode == 0, build.proc.stdout + build.proc.stderr
    # One download of the release's tarball, which fails on an HTTP error.
    assert len(build.curl) == 1, build.curl
    words = build.curl[0].split()
    assert words[-1] == URL.format(DEFAULT_VERSION)
    assert {"-fsSL", "--retry", "--connect-timeout", "--max-time"} <= set(words), words
    assert words[words.index("--retry") + 1] == "3" and words[words.index("--connect-timeout") + 1] == "10"
    assert words[words.index("--max-time") + 1] == "300"
    assert f"==> SHA-256 checked: {digest}" in build.out
    # configure, make and make install in the unpacked source, where OMB 8.0b2's makefiles look for the libraries
    # they link the tests against; configure with the MPI's wrappers and the prefix.
    assert build.configure == ["CC=mpicc", "CXX=mpicxx", f"--prefix={build.install}/install"]
    src = Path(build.configure_cwd)
    assert build.configure_path == "./configure" and src.name == "src"
    assert src.parent.parent == tmp_path / "tmp" and src.parent.name.startswith("osu-build.")
    assert build.make == [(f"-j{NPROC}", str(src)), ("install", str(src))]
    for b in BINARIES:
        assert os.access(build.install / "install" / "libexec" / "osu-micro-benchmarks" / "mpi" / b, os.X_OK), b
    # The record, the logs, and no build directory left.
    rec = record(build)
    assert sorted(rec) == sorted(["omb_version", "omb_sha256", "omb_sha256_checked", "mpi", "mpicc", "built_at",
                                  "host"])
    assert rec["omb_version"] == DEFAULT_VERSION and rec["omb_sha256"] == digest and rec["omb_sha256_checked"] == "yes"
    assert rec["mpi"] == MPI_VERSIONS["openmpi4" if kind == "openmpi" else "intelmpi"][0]
    assert rec["mpicc"] == CC_VERSION and rec["host"] == HOSTNAME
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", rec["built_at"]), rec["built_at"]
    logs = list((build.install / "logs").iterdir())
    assert len(logs) == 1 and re.fullmatch(rf"{re.escape(DEFAULT_VERSION)}-\d{{8}}T\d{{6}}Z", logs[0].name), logs
    assert sorted(p.name for p in logs[0].iterdir()) == ["configure.log", "download.log", "install.log", "make.log",
                                                         "unpack.log"]
    assert "checking for synthetic feature 40... yes" in (logs[0] / "configure.log").read_text()
    assert build.left == []
    assert build.proc.stderr == ""


@pytest.mark.parametrize("kind", SCRIPTS)
def test_make_jobs_sets_makes_parallel_jobs(kind, tmp_path, host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={**sha_env(tmp_path), "MAKE_JOBS": "17"})
    assert build.proc.returncode == 0, build.proc.stderr
    assert [args for args, _ in build.make] == ["-j17", "install"]


@pytest.mark.parametrize("kind", SCRIPTS)
def test_install_dir_sets_where_omb_and_its_logs_go(kind, tmp_path, host_tools):
    target = tmp_path / "elsewhere" / "omb"
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={**sha_env(tmp_path), "INSTALL_DIR": str(target)})
    assert build.proc.returncode == 0, build.proc.stderr
    assert build.configure[-1] == f"--prefix={target}/install"
    assert (target / "install" / "osu-build.txt").is_file() and len(list((target / "logs").iterdir())) == 1
    assert not (tmp_path / "fsx" / DEFAULT_INSTALL[kind]).exists()


@pytest.mark.parametrize("kind", SCRIPTS)
def test_an_uppercase_sha256_is_checked_as_lowercase(kind, tmp_path, host_tools):
    digest = tarball_sha256(tmp_path, DEFAULT_VERSION)
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={"OSU_SHA256": digest.upper()})
    assert build.proc.returncode == 0, build.proc.stderr
    assert record(build)["omb_sha256"] == digest


@pytest.mark.parametrize("kind", SCRIPTS)
def test_a_download_whose_sha256_differs_stops_the_script_and_installs_nothing(kind, tmp_path, host_tools):
    """With no OSU_SHA256, the SHA-256 the script knows for the release is checked; the synthetic tarball is not it."""
    build = run_build(SCRIPTS[kind], tmp_path, host_tools)
    assert build.proc.returncode == 1, build.proc.stdout + build.proc.stderr
    got = tarball_sha256(tmp_path, DEFAULT_VERSION)
    assert (f"ERROR: the download's SHA-256 is {got}, not {KNOWN_SHA256[DEFAULT_VERSION]}: nothing is installed"
            in build.err), build.proc.stderr
    kept_build_dir(build)
    assert build.configure is None and build.make == []
    assert_nothing_installed(build)


@pytest.mark.parametrize("kind", SCRIPTS)
def test_a_given_sha256_that_differs_stops_the_script(kind, tmp_path, host_tools):
    wrong = "0" * 64
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={"OSU_SHA256": wrong})
    assert build.proc.returncode == 1, build.proc.stderr
    assert any(line.endswith(f", not {wrong}: nothing is installed") for line in build.err), build.proc.stderr
    assert build.configure is None
    assert_nothing_installed(build)


@pytest.mark.parametrize("version", ["7.5.3", "8.0b2"])
@pytest.mark.parametrize("kind", SCRIPTS)
def test_the_sha256_the_scripts_know_for_each_release(kind, version, tmp_path, host_tools):
    """The SHA-256 of the release tarball on the OMB download page, which a synthetic tarball does not match."""
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={"OSU_VERSION": version})
    assert build.proc.returncode == 1, build.proc.stderr
    assert build.curl[0].split()[-1] == URL.format(version)
    assert any(line.endswith(f", not {KNOWN_SHA256[version]}: nothing is installed") for line in build.err)


@pytest.mark.parametrize("kind", SCRIPTS)
def test_a_release_the_script_does_not_know_is_built_unchecked_with_a_note(kind, tmp_path, host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={"OSU_VERSION": "9.9synthetic"})
    assert build.proc.returncode == 0, build.proc.stdout + build.proc.stderr
    assert build.err == ["NOTE: this script knows no SHA-256 for OMB 9.9synthetic, so the download is not checked; set "
                         "OSU_SHA256 to check it"]
    assert build.curl[0].split()[-1] == URL.format("9.9synthetic")
    assert not any(line.startswith("==> SHA-256 checked") for line in build.out)
    rec = record(build)
    assert rec["omb_version"] == "9.9synthetic" and rec["omb_sha256_checked"] == "no"
    assert rec["omb_sha256"] == tarball_sha256(tmp_path, "9.9synthetic")


@pytest.mark.parametrize("curl, status", [("http-error", 22), ("no-answer", 28)])
@pytest.mark.parametrize("kind", SCRIPTS)
def test_a_download_that_does_not_complete_stops_the_script_with_curls_status(kind, curl, status, tmp_path,
                                                                             host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={**sha_env(tmp_path), "STUB_CURL": curl})
    assert build.proc.returncode == status, build.proc.stdout + build.proc.stderr
    kept = kept_build_dir(build)
    assert (f"ERROR: download ended with exit status {status}; the last 30 lines of {kept}/logs/download.log:"
            in build.err), build.proc.stderr
    assert any(line.startswith(f"curl: ({status})") for line in build.err), build.proc.stderr
    assert build.configure is None
    assert_nothing_installed(build)


@pytest.mark.parametrize("kind", SCRIPTS)
def test_a_configure_that_stops_ends_the_script_with_its_status_and_its_logs_last_30_lines(kind, tmp_path,
                                                                                          host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={**sha_env(tmp_path), "STUB_CONFIGURE_RC": "77"})
    assert build.proc.returncode == 77, build.proc.stdout + build.proc.stderr
    kept = kept_build_dir(build)
    i = build.err.index(f"ERROR: configure ended with exit status 77; the last 30 lines of {kept}/logs/configure.log:")
    log = (kept / "logs" / "configure.log").read_text().splitlines()
    assert len(log) == 41 and build.err[i + 1:i + 31] == log[-30:]
    assert build.err[i + 30] == "configure: error: synthetic error 77"
    assert build.make == []
    assert_nothing_installed(build)


@pytest.mark.parametrize("step, env, status", [("make", {"STUB_MAKE_RC": "2"}, 2),
                                               ("install", {"STUB_INSTALL_RC": "5"}, 5)])
@pytest.mark.parametrize("kind", SCRIPTS)
def test_a_make_or_make_install_that_stops_ends_the_script_with_its_status(kind, step, env, status, tmp_path,
                                                                          host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={**sha_env(tmp_path), **env})
    assert build.proc.returncode == status, build.proc.stdout + build.proc.stderr
    kept = kept_build_dir(build)
    assert f"ERROR: {step} ended with exit status {status}; the last 30 lines of {kept}/logs/{step}.log:" in build.err
    assert build.err[-2].startswith("make: *** ["), build.err
    assert not (build.install / "install" / "osu-build.txt").exists() and not (build.install / "logs").exists()


REFUSED = [
    *(pytest.param({"MAKE_JOBS": v}, f"ERROR: MAKE_JOBS={v}: use a whole number from 1 to 9999", id=f"MAKE_JOBS={v!r}")
      for v in ("0", "08", "-1", "+2", "x", "2 ", "10000", "1e3")),
    *(pytest.param({"INSTALL_DIR": v}, f"ERROR: INSTALL_DIR={v}: use an absolute path", id=f"INSTALL_DIR={v!r}")
      for v in ("fsx/OSU", "./OSU", "~/OSU")),
    *(pytest.param({"OSU_VERSION": v}, f"ERROR: OSU_VERSION={v}: use an OMB release number (digits, letters and dots)",
                   id=f"OSU_VERSION={v!r}")
      for v in ("../7.5.3", "7.5.3/x", "7.5 3", ".7", "7;5")),
    *(pytest.param({"OSU_SHA256": v}, f"ERROR: OSU_SHA256={v}: use the 64 hexadecimal digits of a SHA-256",
                   id=f"OSU_SHA256={v[:8]}...")
      for v in ("a" * 63, "a" * 65, "g" * 64, "a" * 62 + " a")),
]


@pytest.mark.parametrize("env, message", REFUSED)
@pytest.mark.parametrize("kind", SCRIPTS)
def test_a_setting_out_of_its_range_stops_the_script_before_any_module_or_download(kind, env, message, tmp_path,
                                                                                   host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env=env)
    assert_stopped_before_download(build, message)
    assert build.modules == []
    assert build.left == []


def test_the_open_mpi_script_loads_the_openmpi_module_once(tmp_path, host_tools):
    build = run_build(SCRIPTS["openmpi"], tmp_path, host_tools, env=sha_env(tmp_path))
    assert build.proc.returncode == 0, build.proc.stderr
    assert build.modules == [["load", "openmpi", "unset"]]


@pytest.mark.parametrize("given, seen", [(None, "0"), ("1", "1")], ids=["unset", "given 1"])
def test_intel_mpi_loads_with_the_internal_libfabric_off_then_libfabric_aws(given, seen, tmp_path, host_tools):
    """I_MPI_OFI_LIBRARY_INTERNAL is 0, or the value the job gives, when intelmpi loads; libfabric-aws loads after."""
    build = run_build(SCRIPTS["intelmpi"], tmp_path, host_tools,
                      env={**sha_env(tmp_path), "I_MPI_OFI_LIBRARY_INTERNAL": given})
    assert build.proc.returncode == 0, build.proc.stderr
    assert build.modules == [["load", "intelmpi", seen], ["load", "libfabric-aws", seen]]


@pytest.mark.parametrize("kind, named", [("openmpi", "Open MPI 4"), ("intelmpi", "Intel MPI")])
def test_a_module_that_gives_another_mpi_stops_the_script_before_the_download(kind, named, tmp_path, host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env={**sha_env(tmp_path), "STUB_WRONG_MPI": "1"})
    assert_stopped_before_download(build, f"ERROR: mpirun is not {named} (mpirun --version: ")
    assert build.left == []


@pytest.mark.parametrize("kind, mpi", [("openmpi", "openmpi4"), ("intelmpi", "intelmpi")])
def test_with_no_module_command_the_mpi_on_the_path_is_used_with_a_note(kind, mpi, tmp_path, host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env=sha_env(tmp_path), modules=False, path_mpi=mpi)
    assert build.proc.returncode == 0, build.proc.stdout + build.proc.stderr
    assert build.err == ["NOTE: no module command: using the MPI on the PATH"]
    assert build.modules == []
    assert record(build)["mpi"] == MPI_VERSIONS[mpi][0]


@pytest.mark.parametrize("kind, mpi, named", [("openmpi", "intelmpi", "Open MPI 4"), ("openmpi", None, "Open MPI 4"),
                                              ("intelmpi", "openmpi4", "Intel MPI"), ("intelmpi", None, "Intel MPI")])
def test_with_no_module_command_another_mpi_or_none_on_the_path_stops_the_script(kind, mpi, named, tmp_path,
                                                                                  host_tools):
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env=sha_env(tmp_path), modules=False, path_mpi=mpi)
    assert_stopped_before_download(build, f"ERROR: mpirun is not {named} (mpirun --version: ")
    if mpi is None:
        assert any(line.startswith(f"ERROR: mpirun is not {named} (mpirun --version: no output)") for line in build.err)


@pytest.mark.parametrize("kind", SCRIPTS)
def test_files_an_earlier_in_tree_build_left_in_install_dir_are_left_as_they_are(kind, tmp_path, host_tools):
    """The scripts before these ones unpacked and built OMB in INSTALL_DIR itself."""
    old = tmp_path / "fsx" / DEFAULT_INSTALL[kind]
    files = {"CHANGES": "synthetic changes\n", "configure": "#!/bin/sh\n", "c/mpi/pt2pt/osu_latency.o": "obj\n",
             "install/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_put_latency": "#!/bin/bash\n"}
    for name, text in files.items():
        (old / name).parent.mkdir(parents=True, exist_ok=True)
        (old / name).write_text(text)
    build = run_build(SCRIPTS[kind], tmp_path, host_tools, env=sha_env(tmp_path))
    assert build.proc.returncode == 0, build.proc.stderr
    for name, text in files.items():
        assert (old / name).read_text() == text, name
    assert record(build)["omb_version"] == DEFAULT_VERSION
