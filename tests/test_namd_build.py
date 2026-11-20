"""How apps/NAMD/x86/build_namd_x86.sbatch builds NAMD: its checks, FFTW, Charm++, NAMD's configure and the install.

These tests pin:
- the checks before anything is built: the licence-gated source must be staged (or NAMD_SRC_URL name a mirror), an
  existing install is never overwritten, and TARGET_CPU must be one of the seven targets;
- each target's flags: its -march and -mtune for Charm++'s build and for NAMD's ./config --cxx-opts and --cc-opts,
  with the options of its NAMD arch file (Linux-AVX512-g++ for the AVX-512 targets, Linux-x86_64-g++ for hpc6a), and
  its install directory, BASE_DIR/x86_64/<version>-<target>/;
- FFTW: a static single-precision build, from the staged tarball or else from fftw.org, its build tree removed
  afterwards, and no FFTW step at all when the install already holds libfftw3f.a. The tarball, downloaded or staged,
  must have the SHA-256 FFTW_SHA256 names (by default FFTW's published one for 3.3.10) before it is extracted; with
  none for another version, the build prints the tarball's SHA-256 and goes on;
- Charm++'s build and NAMD's ./config command lines;
- the install: bin/namd3, bin/psfgen (NAMD's, for the launcher's 20STMV benchmark; a psfgen that does not build
  leaves namd3 installed, with a NOTE), and the env script, whose lines load the MPI modules and put namd3 on PATH.

They run the script with stubs of sudo, curl, mpicxx and make, on a synthetic NAMD source tarball (a stub config and a
bundled Charm++ tarball with a stub build) and a synthetic FFTW tarball (a stub configure), from a temporary directory,
with a clean environment and a PATH that holds no other compiler driver, MPI, Slurm, ssh, curl, aws or sudo command:
no compiler, MPI, network or NAMD source is needed. Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_namd_build.py -q
"""
from __future__ import annotations

import gzip
import hashlib
import io
import os
import shutil
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "apps" / "NAMD" / "x86" / "build_namd_x86.sbatch"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

JOB_ID = "4242"
FFTW_URL = "https://www.fftw.org/fftw-3.3.10.tar.gz"
# The SHA-256 FFTW publishes for its 3.3.10 tarball, which the synthetic tarball does not have.
FFTW_3_3_10_SHA256 = "56c932549852cddcfafdab3820b0200c7742675be92179e59e6215b340e26467"
MIRROR_URL = "https://mirror.example.com/NAMD_3.0.2_Source.tar.gz"
# Host commands the script must not find: the stubs stand in for some of them, and it runs none of the others.
HIDDEN = frozenset({"curl", "sudo", "dnf", "make", "mpicxx", "mpicc", "mpirun", "mpiexec", "module", "srun", "sbatch",
                    "scontrol", "squeue", "sinfo", "ssh", "aws"})

SUDO_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/sudo.log"
"""
# curl: logs its arguments; copies the synthetic FFTW tarball for fftw.org's URL and the synthetic NAMD source for
# the mirror's, to the -o path. Anything else: exit 22.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/curl.log"
url="" out="" prev=""
for a in "$@"; do
    case "${prev}" in -o|--output) out="${a}" ;; esac
    case "${a}" in http://*|https://*) url="${a}" ;; esac
    prev="${a}"
done
case "${url}" in
    https://www.fftw.org/fftw-*.tar.gz) src="${STUB_SRC}/${url##*/}" ;;
    "${STUB_MIRROR_URL}") src="${STUB_SRC}/mirror/${url##*/}" ;;
    *) exit 22 ;;
esac
[ -n "${out}" ] && [ -f "${src}" ] || exit 22
cp "${src}" "${out}"
"""
MPICXX_STUB = r"""#!/bin/bash
[ "$1" = --showme:version ] && echo "mpicxx: Open MPI 4.1.7 (Language: C++)"
"""
# make: logs its working directory and arguments. In the FFTW tree (where the stub configure left .stub-prefix),
# "install" creates <prefix>/lib/libfftw3f.a; in NAMD's Linux-* build directory, it creates an executable namd3, or
# for the psfgen target an executable psfgen (with STUB_PSFGEN_FAIL=1, it exits 2 instead).
MAKE_STUB = r"""#!/bin/bash
printf '%s | %s\n' "$(pwd)" "$*" >> "${STATE}/make.log"
if [ -f .stub-prefix ]; then
    if [ "$1" = install ]; then p="$(cat .stub-prefix)"; mkdir -p "${p}/lib"; echo synthetic > "${p}/lib/libfftw3f.a"; fi
elif [[ "$(basename "$(pwd)")" == Linux-* ]]; then
    if [ "${!#}" = psfgen ]; then
        [ "${STUB_PSFGEN_FAIL:-0}" = 1 ] && exit 2
        printf '#!/bin/bash\necho "psfgen stub"\n' > psfgen
        chmod 755 psfgen
    else
        printf '#!/bin/bash\necho "NAMD stub 3.0.2"\n' > namd3
        chmod 755 namd3
    fi
fi
"""
# NAMD's config (in the source tarball): logs its arguments, one per line, and makes the directory its first one
# names, as NAMD's does.
CONFIG_STUB = r"""#!/bin/bash
printf '%s\n' "$@" > "${STATE}/config.args"
mkdir -p "$1"
"""
# Charm++'s build (in the bundled Charm++ tarball): logs its arguments, one per line.
CHARM_BUILD_STUB = r"""#!/bin/bash
printf '%s\n' "$@" > "${STATE}/charm-build.args"
"""
# FFTW's configure: logs its arguments, one per line, and notes its --prefix for the stub make.
FFTW_CONFIGURE_STUB = r"""#!/bin/bash
printf '%s\n' "$@" > "${STATE}/fftw-configure.args"
for a in "$@"; do case "${a}" in --prefix=*) printf '%s' "${a#--prefix=}" > .stub-prefix ;; esac; done
"""


def tar_bytes(files: dict[str, tuple[bytes, int]], gz: bool = True) -> bytes:
    """A tarball of `files` ({name: (data, mode)}), the same bytes on every call."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name, (data, mode) in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            tar.addfile(info, io.BytesIO(data))
    return gzip.compress(buf.getvalue(), mtime=0) if gz else buf.getvalue()


def namd_source() -> bytes:
    """A synthetic NAMD_3.0.2_Source.tar.gz: a stub config, and the bundled Charm++ tarball with a stub build."""
    charm = tar_bytes({"charm-8.0.0/build": (CHARM_BUILD_STUB.encode(), 0o755)}, gz=False)
    return tar_bytes({"NAMD_3.0.2_Source/config": (CONFIG_STUB.encode(), 0o755),
                      "NAMD_3.0.2_Source/charm-8.0.0.tar": (charm, 0o644),
                      "NAMD_3.0.2_Source/notes.txt": (b"synthetic notes\n", 0o644)})


def fftw_source(version: str = "3.3.10") -> bytes:
    """A synthetic fftw-<version>.tar.gz: a stub configure."""
    return tar_bytes({f"fftw-{version}/configure": (FFTW_CONFIGURE_STUB.encode(), 0o755),
                      f"fftw-{version}/README": (b"synthetic\n", 0o644)})


FFTW_SYNTHETIC_SHA256 = hashlib.sha256(fftw_source()).hexdigest()


# Each target: its -march and -mtune, its NAMD arch file, and its instruction set.
TARGETS = {
    "hpc8a": (["-march=x86-64-v4", "-mtune=znver4"], "Linux-AVX512-g++", "avx512"),
    "hpc7a": (["-march=x86-64-v4", "-mtune=znver4"], "Linux-AVX512-g++", "avx512"),
    "m8a": (["-march=x86-64-v4", "-mtune=znver4"], "Linux-AVX512-g++", "avx512"),
    "c8i": (["-march=x86-64-v4", "-mtune=sapphirerapids"], "Linux-AVX512-g++", "avx512"),
    "r8i": (["-march=x86-64-v4", "-mtune=sapphirerapids"], "Linux-AVX512-g++", "avx512"),
    "hpc6id": (["-march=x86-64-v4", "-mtune=icelake-server"], "Linux-AVX512-g++", "avx512"),
    "hpc6a": (["-march=x86-64-v3", "-mtune=znver3"], "Linux-x86_64-g++", "avx2"),
}
# The options of NAMD's two arch files, as NAMD 3.0.2 ships them.
ARCH_OPTS = {"Linux-AVX512-g++": "-O3 -fexpensive-optimizations -ffast-math -mavx512f -mavx512dq -DNAMD_AVXTILES",
             "Linux-x86_64-g++": "-O3 -fexpensive-optimizations -ffast-math"}


@dataclass
class Build:
    proc: subprocess.CompletedProcess
    base: Path
    state: Path
    target: str = "hpc8a"

    def args(self, name: str) -> list[str] | None:
        path = self.state / name
        return path.read_text().splitlines() if path.exists() else None

    def log(self, name: str) -> list[str]:
        path = self.state / name
        return path.read_text().splitlines() if path.exists() else []

    @property
    def install(self) -> Path:
        return self.base / "x86_64" / f"3.0.2-{self.target}"


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


def build(work: Path, tools: Path, env: dict[str, str | None] | None = None, staged_source: bool = True,
          staged_fftw: bool = False) -> Build:
    """Run the build script in `work`/submit, with BASE_DIR `work`/base and NAMD_SRC `work`/src/<tarball>.

    `staged_source` stages the synthetic NAMD source at NAMD_SRC; `staged_fftw` stages the synthetic FFTW tarball at
    BASE_DIR/src/ (otherwise the stub curl serves it). `env` adds variables, or unsets them (None)."""
    stubs, state, submit, base, src, served, tmp = (work / d for d in ("stubs", "state", "submit", "base", "src",
                                                                       "served", "tmp"))
    for d in (stubs, state, submit, base, src, served / "mirror", tmp):
        d.mkdir(parents=True, exist_ok=True)
    for name, text in {"sudo": SUDO_STUB, "curl": CURL_STUB, "mpicxx": MPICXX_STUB, "make": MAKE_STUB}.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    for version in ("3.3.10", "3.3.9"):
        (served / f"fftw-{version}.tar.gz").write_bytes(fftw_source(version))
    (served / "mirror" / "NAMD_3.0.2_Source.tar.gz").write_bytes(namd_source())
    if staged_source:
        (src / "NAMD_3.0.2_Source.tar.gz").write_bytes(namd_source())
    if staged_fftw:
        (base / "src").mkdir()
        (base / "src" / "fftw-3.3.10.tar.gz").write_bytes(fftw_source())
    job_env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": "POSIX", "TMPDIR": str(tmp),
               "STATE": str(state), "STUB_SRC": str(served), "STUB_MIRROR_URL": MIRROR_URL, "SLURM_JOB_ID": JOB_ID,
               "BASE_DIR": str(base), "NAMD_SRC": str(src / "NAMD_3.0.2_Source.tar.gz"), "COMPILE_CORES": "4",
               "FFTW_SHA256": FFTW_SYNTHETIC_SHA256}
    for name, value in (env or {}).items():
        if value is None:
            job_env.pop(name, None)
        else:
            job_env[name] = value
    proc = subprocess.run([BASH, str(SCRIPT)], cwd=submit, env=job_env, capture_output=True, text=True,
                          errors="replace", timeout=120)
    return Build(proc, base, state, job_env.get("TARGET_CPU", "hpc8a"))


def built(b: Build) -> Build:
    assert b.proc.returncode == 0, b.proc.stdout + b.proc.stderr
    return b


def namd_makes(b: Build) -> list[str]:
    """make's calls in NAMD's Linux-* build directory that build namd3 (not the psfgen target)."""
    return [line for line in b.log("make.log") if "/Linux-" in line and not line.endswith(" psfgen")]


def assert_nothing_built(b: Build) -> None:
    """Exit status 1, and no FFTW, Charm++ or NAMD build step ran."""
    assert b.proc.returncode == 1, b.proc.stdout + b.proc.stderr
    for name in ("fftw-configure.args", "charm-build.args", "config.args"):
        assert b.args(name) is None, name
    assert b.log("make.log") == []


def test_a_missing_source_stops_the_build_with_the_licence_message(tmp_path, host_tools):
    b = build(tmp_path, host_tools, staged_source=False)
    assert_nothing_built(b)
    assert "NAMD source tarball not found at" in b.proc.stderr
    assert "https://www.ks.uiuc.edu/Research/namd/" in b.proc.stderr
    assert not (b.base / "x86_64").exists()


def test_a_missing_source_is_fetched_from_namd_src_url(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools, staged_source=False, env={"NAMD_SRC_URL": MIRROR_URL}))
    assert any(line.endswith(MIRROR_URL) for line in b.log("curl.log")), b.log("curl.log")
    assert (b.install / "bin" / "namd3").exists()


def test_an_existing_install_is_never_overwritten(tmp_path, host_tools):
    install = tmp_path / "base" / "x86_64" / "3.0.2-hpc8a" / "bin"
    install.mkdir(parents=True)
    b = build(tmp_path, host_tools)
    assert_nothing_built(b)
    assert "install directory already exists" in b.proc.stderr
    assert sorted(p.name for p in install.iterdir()) == []


@pytest.mark.parametrize("target", ["x", "hpc8a.96xlarge", "HPC8A", "hpc7g"])
def test_an_unknown_target_stops_the_build_before_anything_is_extracted(target, tmp_path, host_tools):
    b = build(tmp_path, host_tools, env={"TARGET_CPU": target})
    assert_nothing_built(b)
    assert f"unsupported TARGET_CPU '{target}' (expected hpc8a, hpc7a, m8a, c8i, r8i, hpc6id or hpc6a)" \
        in b.proc.stderr, b.proc.stderr
    assert not (b.base / "build").exists() and not (b.base / "x86_64").exists()


def test_charm_is_built_with_the_mpi_smp_layer_and_the_hosts_flags(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools))
    assert b.args("charm-build.args") == ["charm++", "mpi-linux-x86_64", "smp", "--with-production", "-j4", "-O3",
                                          "-march=x86-64-v4", "-mtune=znver4"]


def test_namd_is_configured_against_that_charm_tcl_and_the_static_fftw(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools))
    config = b.args("config.args")
    opts = f"{ARCH_OPTS['Linux-AVX512-g++']} -march=x86-64-v4 -mtune=znver4"
    assert config == ["Linux-AVX512-g++", "--charm-arch", "mpi-linux-x86_64-smp", "--with-tcl", "--tcl-prefix",
                      "/usr", "--with-fftw3", "--fftw-prefix", str(b.install / "fftw"), "--cc", "gcc", "--cxx", "g++",
                      "--cc-opts", opts, "--cxx-opts", opts]
    assert any(line.endswith(f"/{config[0]} | -j4") for line in b.log("make.log")), b.log("make.log")


def test_namd_is_compiled_with_its_avx512_arch_and_the_env_script_says_so(tmp_path, host_tools):
    """NAMD's Linux-AVX512-g++ arch (AVX-512 and the tile-list kernels): ./config's first argument, make's build
    directory, and the env script's comment line, which is the env script's only line that names the arch."""
    b = built(build(tmp_path, host_tools))
    assert b.args("config.args")[0] == "Linux-AVX512-g++"
    (namd_make,) = namd_makes(b)
    assert namd_make.split(" | ")[0].endswith("/Linux-AVX512-g++"), namd_make
    assert (b.install / "namd-3.0.2-x86-env.sh").read_text() == env_text(b, "Linux-AVX512-g++", "avx512")


def env_text(b: Build, arch: str, isa: str) -> str:
    """The env script the build should write for its target."""
    return ("#!/bin/bash\n"
            f"# NAMD 3.0.2 — x86_64, target {b.target} (Charm++ mpi-linux-x86_64-smp over OpenMPI/EFA, NAMD arch "
            f"{arch})\n"
            "module load openmpi/4.1.7 libfabric-aws 2>/dev/null || true\n"
            f'export NAMD_ROOT="{b.install}"\n'
            'export PATH="${NAMD_ROOT}/bin:${PATH}"\n'
            'export LD_LIBRARY_PATH="${NAMD_ROOT}/lib:${LD_LIBRARY_PATH:-}"\n'
            'export NAMD_VERSION="3.0.2"\n'
            'export CHARM_ARCH="mpi-linux-x86_64-smp"\n'
            f'export NAMD_TARGET_CPU="{b.target}"\n'
            f'export NAMD_ISA="{isa}"\n')


@pytest.mark.parametrize("target", list(TARGETS))
def test_each_target_builds_with_its_flags_and_arch_into_its_own_install(target, tmp_path, host_tools):
    flags, arch, isa = TARGETS[target]
    b = built(build(tmp_path, host_tools, env={"TARGET_CPU": target}))
    assert b.args("charm-build.args") == ["charm++", "mpi-linux-x86_64", "smp", "--with-production", "-j4", "-O3",
                                          *flags]
    config = b.args("config.args")
    opts = " ".join([ARCH_OPTS[arch], *flags])
    assert config[0] == arch
    assert config[config.index("--cc-opts") + 1] == opts and config[config.index("--cxx-opts") + 1] == opts
    assert config[config.index("--fftw-prefix") + 1] == str(b.install / "fftw")
    (namd_make,) = namd_makes(b)
    assert namd_make.split(" | ")[0].endswith(f"/{arch}"), namd_make
    assert sorted(p.name for p in (b.base / "x86_64").iterdir()) == [f"3.0.2-{target}"]
    assert os.access(b.install / "bin" / "namd3", os.X_OK)
    assert (b.install / "namd-3.0.2-x86-env.sh").read_text() == env_text(b, arch, isa)


def test_fftw_is_fetched_built_static_into_the_install_and_its_build_tree_removed(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools))
    assert any(line.endswith(FFTW_URL) for line in b.log("curl.log")), b.log("curl.log")
    assert (b.base / "src" / "fftw-3.3.10.tar.gz").read_bytes() == fftw_source()
    assert b.args("fftw-configure.args") == [f"--prefix={b.install / 'fftw'}", "--enable-float", "--enable-static",
                                             "--disable-shared", "--enable-sse2", "--enable-avx", "--enable-avx2",
                                             "--enable-avx512", "CFLAGS=-O3 -fPIC"]
    assert (b.install / "fftw" / "lib" / "libfftw3f.a").exists()
    assert not list((b.base / "build").glob("*-fftw"))


def test_a_staged_fftw_tarball_is_used_with_no_download(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools, staged_fftw=True))
    assert b.log("curl.log") == []
    assert b.args("fftw-configure.args") is not None


def test_an_installed_fftw_is_reused_with_no_fftw_step(tmp_path, host_tools):
    lib = tmp_path / "base" / "x86_64" / "3.0.2-hpc8a" / "fftw" / "lib"
    lib.mkdir(parents=True)
    (lib / "libfftw3f.a").write_text("synthetic\n")
    b = built(build(tmp_path, host_tools))
    assert b.log("curl.log") == []
    assert b.args("fftw-configure.args") is None


def test_the_build_installs_namd3_and_an_env_script_that_loads_the_mpi_modules(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools))
    assert os.access(b.install / "bin" / "namd3", os.X_OK)
    lines = (b.install / "namd-3.0.2-x86-env.sh").read_text().splitlines()
    for line in ("module load openmpi/4.1.7 libfabric-aws 2>/dev/null || true",
                 f'export NAMD_ROOT="{b.install}"', 'export PATH="${NAMD_ROOT}/bin:${PATH}"',
                 'export LD_LIBRARY_PATH="${NAMD_ROOT}/lib:${LD_LIBRARY_PATH:-}"', 'export NAMD_VERSION="3.0.2"',
                 'export CHARM_ARCH="mpi-linux-x86_64-smp"'):
        assert line in lines, line
    assert b.log("sudo.log") == ["dnf install -y gcc gcc-c++ gcc-gfortran make tar gzip tcl-devel"]


def assert_fftw_refused(b: Build, expected: str) -> None:
    """The build stopped on the FFTW tarball's SHA-256 before it extracted it: exit 1, both values named."""
    assert b.proc.returncode == 1, b.proc.stdout + b.proc.stderr
    assert f"has SHA-256 {FFTW_SYNTHETIC_SHA256}, not the expected {expected}" in b.proc.stderr, b.proc.stderr
    assert b.args("fftw-configure.args") is None
    assert not list((b.base / "build").glob("*-fftw"))
    assert b.args("charm-build.args") is None and b.args("config.args") is None


def test_by_default_the_fftw_tarball_must_have_fftws_published_sha256(tmp_path, host_tools):
    """FFTW_SHA256 unset and FFTW 3.3.10: the synthetic tarball is not FFTW's, so the build stops before it is
    extracted."""
    assert_fftw_refused(build(tmp_path, host_tools, env={"FFTW_SHA256": None}), FFTW_3_3_10_SHA256)


def test_a_wrong_fftw_sha256_stops_the_build(tmp_path, host_tools):
    assert_fftw_refused(build(tmp_path, host_tools, env={"FFTW_SHA256": "0" * 64}), "0" * 64)


def test_the_tarballs_own_sha256_lets_the_build_go_on(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools))
    assert f"FFTW 3.3.10 tarball: SHA-256 {FFTW_SYNTHETIC_SHA256}, as expected" in b.proc.stdout
    assert b.args("fftw-configure.args") is not None


def test_a_staged_fftw_tarball_is_checked_as_a_downloaded_one(tmp_path, host_tools):
    assert_fftw_refused(build(tmp_path, host_tools, staged_fftw=True, env={"FFTW_SHA256": None}),
                        FFTW_3_3_10_SHA256)


def test_another_fftw_version_with_no_sha256_prints_the_tarballs_and_goes_on(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools, env={"FFTW_VERSION": "3.3.9", "FFTW_SHA256": None}))
    got = hashlib.sha256(fftw_source("3.3.9")).hexdigest()
    assert f"NOTE: no SHA-256 to check for FFTW 3.3.9 (set FFTW_SHA256); {b.base / 'src' / 'fftw-3.3.9.tar.gz'} " \
           f"has SHA-256 {got}" in b.proc.stderr.splitlines(), b.proc.stderr
    assert b.args("fftw-configure.args") is not None


def test_the_job_asks_slurm_for_a_time_limit_of_two_hours():
    header = [line for line in SCRIPT.read_text().splitlines() if line.startswith("#SBATCH")]
    assert [line for line in header if line.startswith("#SBATCH --time")] == ["#SBATCH --time=02:00:00"], header


def test_psfgen_is_built_in_namds_build_directory_and_installed_beside_namd3(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools))
    psfgen_makes = [line for line in b.log("make.log") if line.endswith(" psfgen")]
    assert len(psfgen_makes) == 1 and psfgen_makes[0] == f"{namd_makes(b)[0].split(' | ')[0]} | -j4 psfgen", \
        b.log("make.log")
    assert os.access(b.install / "bin" / "psfgen", os.X_OK)
    assert sorted(p.name for p in (b.install / "bin").iterdir()) == ["namd3", "psfgen"]
    assert f"installed psfgen -> {b.install / 'bin' / 'psfgen'}" in b.proc.stdout
    assert "NOTE: psfgen" not in b.proc.stderr


def test_a_psfgen_that_does_not_build_leaves_namd3_installed_with_a_note(tmp_path, host_tools):
    b = built(build(tmp_path, host_tools, env={"STUB_PSFGEN_FAIL": "1"}))
    assert sorted(p.name for p in (b.install / "bin").iterdir()) == ["namd3"]
    assert "NOTE: psfgen did not build; namd3 is installed without it, and only the 20STMV benchmark " \
           "(MODEL=20STMV) needs it" in b.proc.stderr.splitlines(), b.proc.stderr
    assert (b.install / "namd-3.0.2-x86-env.sh").exists()
