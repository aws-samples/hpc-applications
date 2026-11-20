"""How apps/NAMD/x86/namd-benchmark.sbatch checks its settings, fetches a deck and starts a NAMD benchmark run.

These tests pin:
- the settings it refuses before mpirun starts (MODEL, TIMESTEPS, PPN, BASE_DIR);
- the deck: fetched from the NAMD utilities page (DHFR's from NAMD's benchmark page) into BASE_DIR/benchmarks/<MODEL>/
  when the cache lacks it, reused with no download when it holds it, and copied into a run directory of its own;
- the run's config: numsteps (and a run line) from TIMESTEPS, by default 1000, and for DHFR's GPU-offload config its
  num_steps_run, with doBenchmark and skipFFTWconfig set to 0; an outputTiming line when the deck has none, and the
  deck's output name without its directory, so NAMD writes its output files in the run directory; and the deck's
  downloaded archive kept out of the cache and the run directory;
- mpirun's command line, on one node and on two (where the job first checks EFA with fi_info), and NAMD's PEs;
- the result: days/ns from the last "Benchmark time:" line, ns/day = 1 / days/ns, and the NAMDRESULT line;
- the job's exit status: NAMD's when it fails; when NAMD exits 0, a result only from a complete run (NAMD's closing
  WallClock: line, and a positive days/ns on the last Benchmark time line), and otherwise status 1 with no result,
  and a NOTE that the run is not recorded;
- the contribution recorder: called once after a complete run, from its run directory, with the case, days/ns,
  NAMD's WallClock time, the nodes, the cores the run used (PROCS_PER_NODE x (PPN + 1) per node, at most the node's)
  and the instance type, and --metric procs_per_node, --metric pes_per_proc and --char avx512_tiles; found from the
  submit directory when DYNAMODB_RECORDER is unset; never called after a failed or incomplete run; a failing or
  missing recorder leaves the job's exit status 0, with a NOTE; and the repository's recorder, in --dry-run, records
  the run with each attribute once;
- the instance type from the instance metadata (IMDSv2): each request fails on an HTTP error and gives up after a few
  seconds, and an answer cut off at that limit, or one that is not an instance type name (tested in the C locale),
  counts as none. The banner, the run directory and NAMDRESULT then say "unknown", and the run goes on;
- the build: with NAMD_ENV unset, the build of the node's instance family under BASE_DIR/x86_64/<version>-<family>/
  (the highest version), else the only build there, with a NOTE, else a stop that asks for NAMD_ENV; and an AVX-512
  build on a CPU without AVX-512, refused before anything runs;
- cores per node on hpc8a.96xlarge and hpc7a.96xlarge, with one process per node: PPN 23, 47, 71, 95, 119, 143 and
  167 pin the communication thread to the first core of the flexible-cores list of PPN + 1 cores in
  Utils/flexible-cores/hello-cpu.openmpi.explicit.sbatch and the PEs to the rest, which puts (PPN + 1) / 24 threads on
  every CCD, on every node; PPN 191 and 192 fill the node; any other PPN stops the job before anything runs. With no
  instance type, lscpu decides (in the C locale), and only where the type changes what the job does: a 192-core AMD
  node gets the same check and lists, any other node none, each with a NOTE. Other types get no list and no check;
- processes per node (PROCS_PER_NODE, P): mpirun's -np and --map-by, and on a full node each process on G = cores / P
  consecutive cores, its communication thread on the first (+commap 0-<C-1>:G) and its G - 1 PEs on the others
  (+pemap 1-<C-1>:G.<G-1>), which these tests expand as Charm++ does and check core by core; the P values refused
  (on hpc8a.96xlarge and hpc7a.96xlarge, groups that are not whole CCDs); NAMD_EXTRA_ARGS; and the mpirun command line
  the job log prints.

They run the script with stubs of curl (the instance metadata and the deck downloads), srun, fi_info, nproc, lscpu,
mpirun and the contribution recorder (DYNAMODB_RECORDER), from a temporary directory, with a clean environment and a
PATH that holds no other MPI, Slurm, ssh, curl, aws or sudo command: no NAMD, MPI, Slurm, AWS or network is needed.
The stub mpirun notes its arguments and prints a synthetic namd.out, and the stub recorder notes its arguments and
environment. The script reads /proc/cpuinfo, so these tests run a copy of it that reads a synthetic cpuinfo instead
and differs from the script in that path alone (checked here). Every value is synthetic.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_namd_launcher.py -q
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "apps" / "NAMD" / "x86" / "namd-benchmark.sbatch"
FLEXIBLE_CORES = REPO / "Utils" / "flexible-cores" / "hello-cpu.openmpi.explicit.sbatch"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="needs bash")

JOB_ID = "4242"
UTILITIES = "https://www.ks.uiuc.edu/Research/namd/utilities/"
BENCHMARKS = "https://www.ks.uiuc.edu/Research/namd/benchmarks/systems/"
# Host commands the script must not find: the stubs stand in for some of them, and it runs none of the others.
HIDDEN = frozenset({"curl", "srun", "sbatch", "scontrol", "squeue", "sinfo", "mpirun", "mpiexec", "module", "lscpu",
                    "nproc", "fi_info", "namd3", "ssh", "aws", "sudo"})

# Each deck: its tarball's name, its top directory, its config, and the lines of its config (keywords as in the
# decks on the NAMD utilities page, values synthetic).
DECKS = {
    "ApoA1": ("apoa1.tar.gz", "apoa1", "apoa1.namd",
              ["structure            apoa1.psf", "coordinates          apoa1.pdb", "timestep             1.0",
               "stepspercycle        20", "numsteps             500", "outputtiming         20",
               "outputname           /usr/tmp/apoa1-out"]),
    "STMV": ("stmv.tar.gz", "stmv", "stmv.namd",
             ["structure           stmv.psf", "coordinates         stmv.pdb", "timestep            1.0",
              "stepspercycle       20", "outputName          /usr/tmp/stmv-output", "outputTiming        20",
              "numsteps 500"]),
    "ATPase": ("f1atpase.tar.gz", "f1atpase", "f1atpase.namd",
               ["coordinates             f1atpase.pdb", "structure               f1atpase.psf",
                "outputname              /usr/tmp/f1atpase", "timestep                1.0",
                "numsteps                500", "stepspercycle           20", "outputTiming\t\t20"]),
    # NAMD's GPU benchmark config, which sets its run length and switches in Tcl variables.
    "DHFR": ("dhfr_gpu.tar.gz", "dhfr_gpu", "dhfr_gpuoff_nve.namd",
             ["set doBenchmark  1    ;# a synthetic comment", "set benchtime    60", "set doGPUres     0",
              "set skipFFTWconfig 1", "set doMTS        1", "set num_steps_run   5000  ;# a synthetic comment",
              "structure           dhfr_gpu.psf", "coordinates         dhfr_gpu.pdb", "outputName          out_dhfr",
              "outputTiming        2500", "if { $doBenchmark } {", "  benchmarkTime        $benchtime", "}",
              "run                  $num_steps_run"]),
}
# The page each deck comes from, when it is not the utilities page.
DECK_PAGES = {"DHFR": BENCHMARKS}


def deck_url(model: str) -> str:
    return DECK_PAGES.get(model, UTILITIES) + DECKS[model][0]
DECK_DATA = ("psf", "pdb")   # the other files of a deck, named <top>.<ext>

# The stub curl. It logs each call's arguments to STATE/curl.log. The instance metadata answers as STUB_IMDS says:
# ok (a token, then STUB_INSTANCE_TYPE), none (no answer: exit 28, no output), error (an HTTP error: exit 22 and no
# output under -f, an HTML page and exit 0 without it), text (STUB_IMDS_TEXT for the type), cut-off (the type less
# its last five characters, then exit 28). A deck URL (NAMD's utilities or benchmark page) copies STUB_DECKS/<tarball>
# to the -o path. Anything else: exit 22.
CURL_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/curl.log"
url="" out="" fail=0 prev=""
for a in "$@"; do
    case "${prev}" in -o|--output) out="${a}" ;; esac
    case "${a}" in
        http://*|https://*) url="${a}" ;;
        --fail) fail=1 ;;
        --*) ;;
        -*f*) fail=1 ;;
    esac
    prev="${a}"
done
page='<html><head><title>404 Not Found</title></head>
<body><h1>Not Found</h1><p>The requested URL /latest/meta-data/ was not found on this server.</p></body></html>'
ks=https://www.ks.uiuc.edu/Research/namd
case "${url}" in
    http://169.254.169.254/latest/api/token)
        case "${STUB_IMDS}" in
            none) exit 28 ;;
            error) [ "${fail}" = 1 ] && exit 22; printf '%s' "${page}"; exit 0 ;;
            *) printf 'stub-token'; exit 0 ;;
        esac ;;
    http://169.254.169.254/latest/meta-data/instance-type)
        case "${STUB_IMDS}" in
            ok) printf '%s' "${STUB_INSTANCE_TYPE}"; exit 0 ;;
            none) exit 28 ;;
            error) [ "${fail}" = 1 ] && exit 22; printf '%s' "${page}"; exit 0 ;;
            text) printf '%s' "${STUB_IMDS_TEXT}"; exit 0 ;;
            cut-off) printf '%s' "${STUB_INSTANCE_TYPE%?????}"; exit 28 ;;
        esac ;;
    "${ks}"/utilities/*.tar.gz|"${ks}"/benchmarks/systems/*.tar.gz)
        name="${url##*/}"
        [ -n "${out}" ] && [ -f "${STUB_DECKS}/${name}" ] || exit 22
        cp "${STUB_DECKS}/${name}" "${out}"
        exit 0 ;;
esac
exit 22
"""
# srun: logs its arguments and does nothing else.
SRUN_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/srun.log"
"""
# fi_info: an EFA provider listing, then exit STUB_FI_RC.
FI_INFO_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "${STATE}/fi_info.log"
echo "provider: efa"
echo "    fabric: efa"
echo "    domain: rdmap0s0-rdm"
echo "    version: 122.0"
exit "${STUB_FI_RC:-0}"
"""
NPROC_STUB = r"""#!/bin/bash
echo 192
"""
# lscpu, as LC_ALL=C lscpu prints its summary: STUB_LSCPU is amd-192 (AuthenticAMD, 2 sockets of 96 cores), intel-192
# (GenuineIntel, 2 x 96), amd-96 (AuthenticAMD, 2 x 48) or fail (exit 1). It logs the LC_ALL it was given ("unset"
# when none).
LSCPU_STUB = r"""#!/bin/bash
printf '%s\n' "${LC_ALL-unset}" >> "${STATE}/lscpu.log"
case "${STUB_LSCPU:-amd-192}" in
    amd-192) vendor=AuthenticAMD per=96 ;;
    intel-192) vendor=GenuineIntel per=96 ;;
    amd-96) vendor=AuthenticAMD per=48 ;;
    *) exit 1 ;;
esac
echo "Architecture:                    x86_64"
echo "CPU(s):                          $(( 2 * per ))"
echo "Vendor ID:                       ${vendor}"
echo "  Thread(s) per core:            1"
echo "  Core(s) per socket:            ${per}"
echo "  Socket(s):                     2"
"""
# mpirun: `mpirun --version` prints an Open MPI version line. For any other call it notes, in its own directory, its
# arguments (one per line), its working directory, FI_PROVIDER ("unset" when none) and a copy of the run config (its
# last argument); then it prints a synthetic namd.out (STUB_NAMD_OUT: complete, no-wallclock, zero-days, no-bench or
# sci-days) and ends with STUB_RC. Like NAMD, it prints three "Initial time:" lines and then one "Benchmark time:" line
# per 100 steps from step 400 to 900 of the config's run length (its numsteps, or DHFR's "set num_steps_run"); the
# last one gives STUB_DAYS days/ns, the others 0.5. With STUB_TILES set, it
# prints NAMD's line on the AVX-512 tile kernels with that word (ENABLED or DISABLED).
MPIRUN_STUB = r"""#!/bin/bash
if [ "${1:-}" = --version ]; then echo "mpirun (Open MPI) 4.1.7"; exit 0; fi
n=1
while [ -e "${STATE}/mpirun-call-${n}" ]; do n=$((n + 1)); done
d="${STATE}/mpirun-call-${n}"
mkdir "${d}"
printf '%s\n' "$@" > "${d}/args"
pwd > "${d}/cwd"
printf '%s' "${FI_PROVIDER-unset}" > "${d}/fi_provider"
conf="${!#}"
[ -f "${conf}" ] && cp "${conf}" "${d}/config"
steps="$(awk 'tolower($1) == "numsteps" { s = $2 } $1 == "set" && $2 == "num_steps_run" { s = $3 }
              END { print s + 0 }' "${conf}" 2>/dev/null)"
phases=$(( steps / 100 )); [ "${phases}" -gt 9 ] && phases=9
bench=$(( phases > 3 ? phases - 3 : 0 ))
days="${STUB_DAYS:-0.25}"
case "${STUB_NAMD_OUT:-complete}" in
    zero-days) days=0 ;;
    sci-days) days=1.5e-05 ;;
    no-bench) bench=0 ;;
esac
echo "Charm++> cpu affinity enabled. "
echo "Info: NAMD 3.0.2 for Linux-x86_64-MPI-smp"
echo "Info: TIMESTEP               1"
echo "Info: NUMBER OF STEPS        ${steps}"
echo "Info: 123456 ATOMS"
[ -n "${STUB_TILES:-}" ] && echo "Info: MIXED PRECISION AVX-512 TILES OPTIMIZATIONS: ${STUB_TILES}"
for i in 1 2 3; do echo "Info: Initial time: 191 CPUs 0.05 s/step 0.6 days/ns 1000 MB memory"; done
for (( i = 1; i <= bench; i++ )); do
    if [ "${i}" -eq "${bench}" ]; then v="${days}"; else v=0.5; fi
    echo "Info: Benchmark time: 191 CPUs 0.04 s/step ${v} days/ns 1000 MB memory"
done
if [ "${STUB_NAMD_OUT:-complete}" != no-wallclock ]; then
    echo "WallClock: 12.500000  CPUTime: 12.000000  Memory: 1000.000000 MB"
    echo "[Partition 0][Node 0] End of program"
fi
exit "${STUB_RC:-0}"
"""
# namd3, from the synthetic build: the stub mpirun never runs it.
NAMD3_STUB = "#!/bin/bash\necho 'namd3 stub: not to be run' >&2\nexit 99\n"
# The variables the launcher may hand the contribution recorder.
RECORDER_VARS = ("BENCHMARK_CASE", "DAYS_PER_NS", "NS_PER_DAY", "TIME_TO_SOLUTION", "NUM_INSTANCES", "NUM_CORES",
                 "CORES_PER_NODE", "INSTANCE_TYPE", "RUN_DIR", "SOURCE", "ATOMS_MILLION", "NAMD_VERSION")
# The contribution recorder: for each call it notes, in its own directory, its arguments (one per line), its working
# directory and each of RECORDER_VARS that is set (name=value), then ends with STUB_RECORDER_RC.
RECORDER_STUB = r"""#!/bin/bash
n=1
while [ -e "${STATE}/recorder-call-${n}" ]; do n=$((n + 1)); done
d="${STATE}/recorder-call-${n}"
mkdir "${d}"
printf '%s\n' "$@" > "${d}/args"
pwd > "${d}/cwd"
for v in """ + " ".join(RECORDER_VARS) + r"""; do
    if [ -n "${!v+set}" ]; then printf '%s=%s\n' "${v}" "${!v}"; fi
done > "${d}/env"
exit "${STUB_RECORDER_RC:-0}"
"""
# The flags line of /proc/cpuinfo on a CPU with AVX-512 and on one without.
CPUINFO_AVX512 = "processor\t: 0\nflags\t\t: fpu sse2 avx avx2 fma avx512f avx512dq avx512bw avx512vl\n"
CPUINFO_AVX2 = "processor\t: 0\nflags\t\t: fpu sse2 avx avx2 fma\n"
# The build the launcher picks on an hpc8a node.
HPC8A_BUILD = ("3.0.2-hpc8a", {"NAMD_TARGET_CPU": "hpc8a", "NAMD_ISA": "avx512"})


@dataclass
class Job:
    proc: subprocess.CompletedProcess
    calls: list[dict]     # mpirun's calls, as the stub noted them
    curl: list[str]       # each curl call's arguments
    srun: list[str]       # each srun call's arguments
    fi_info: list[str]    # each fi_info call's arguments
    lscpu: list[str]      # each lscpu call's LC_ALL
    base: Path            # BASE_DIR
    state: Path
    recorder: list[dict]  # the stub recorder's calls: args, cwd and env ({name: value})

    @property
    def out(self) -> list[str]:
        return self.proc.stdout.splitlines()

    @property
    def err(self) -> list[str]:
        return self.proc.stderr.splitlines()

    def run_dirs(self) -> list[Path]:
        run = self.base / "Run"
        return sorted(run.iterdir()) if run.is_dir() else []


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


def deck_tarball(model: str, lines: list[str] | None = None) -> bytes:
    """The deck's tarball: its top directory, its config and its data files."""
    name, top, conf, default = DECKS[model]
    files = {conf: "\n".join(default if lines is None else lines) + "\n"}
    files.update({f"{top}.{ext}": f"synthetic {ext}\n" for ext in DECK_DATA})
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for fname, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(f"{top}/{fname}")
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def make_build(base: Path, dirname: str = "3.0.2", exports: dict[str, str] | None = None) -> Path:
    """A synthetic build under base/x86_64/<dirname> (<version>[-<target>]): a stub namd3 and the env script that puts
    it on PATH."""
    root = base / "x86_64" / dirname
    version = dirname.split("-")[0]
    (root / "bin").mkdir(parents=True)
    (root / "bin" / "namd3").write_text(NAMD3_STUB)
    (root / "bin" / "namd3").chmod(0o755)
    env = {"NAMD_ROOT": str(root), "NAMD_VERSION": version, "CHARM_ARCH": "mpi-linux-x86_64-smp", **(exports or {})}
    script = root / f"namd-{version}-x86-env.sh"
    script.write_text("#!/bin/bash\n" + "".join(f'export {k}="{v}"\n' for k, v in env.items())
                      + 'export PATH="${NAMD_ROOT}/bin:${PATH}"\n')
    return script


def runnable_copy(work: Path, cpuinfo: str) -> Path:
    """The script, reading `cpuinfo` (written in `work`) instead of /proc/cpuinfo: the copy differs from the script in
    that path alone."""
    text = SCRIPT.read_text()
    assert text.count("/proc/cpuinfo") == 1, "the script names /proc/cpuinfo in other places"
    stub = work / "cpuinfo"
    stub.write_text(cpuinfo)
    copy = work / SCRIPT.name
    copy.write_text(text.replace("/proc/cpuinfo", str(stub)))
    assert copy.read_text().replace(str(stub), "/proc/cpuinfo") == text
    return copy


def run(work: Path, tools: Path, nodes: int = 1, env: dict[str, str | None] | None = None, imds: str = "ok",
        itype: str = "hpc8a.96xlarge", namd_out: str = "complete", rc: int = 0, cached: dict | None = None,
        decks: dict | None = None, builds: tuple = (HPC8A_BUILD,), cpuinfo: str = CPUINFO_AVX512) -> Job:
    """Run the script as a job on `nodes` nodes, from `work`/submit, with BASE_DIR `work`/base.

    `imds` and `itype` set the stub instance metadata, `namd_out` and `rc` the stub mpirun's output and exit status.
    `cached` puts decks in the cache ({MODEL: config lines or None for the default}), `decks` changes the tarballs the
    stub curl serves ({MODEL: config lines}). `builds` are the synthetic builds ((dirname, exports), ...), `cpuinfo`
    the node's /proc/cpuinfo. DYNAMODB_RECORDER is the stub recorder. `env` adds variables to the job's environment,
    or unsets them (None)."""
    stubs, state, submit, base, served, tmp = (work / d for d in ("stubs", "state", "submit", "base", "decks", "tmp"))
    for d in (stubs, state, submit, base, served, tmp):
        d.mkdir(parents=True, exist_ok=True)
    for name, text in {"curl": CURL_STUB, "srun": SRUN_STUB, "fi_info": FI_INFO_STUB, "nproc": NPROC_STUB,
                       "lscpu": LSCPU_STUB, "mpirun": MPIRUN_STUB, "recorder-stub": RECORDER_STUB}.items():
        (stubs / name).write_text(text)
        (stubs / name).chmod(0o755)
    for model in DECKS:
        lines = (decks or {}).get(model)
        (served / DECKS[model][0]).write_bytes(deck_tarball(model, lines))
    for model, lines in (cached or {}).items():
        _, top, conf, default = DECKS[model]
        cache = base / "benchmarks" / model
        cache.mkdir(parents=True)
        (cache / conf).write_text("\n".join(default if lines is None else lines) + "\n")
        for ext in DECK_DATA:
            (cache / f"{top}.{ext}").write_text(f"synthetic cached {ext}\n")
    for dirname, exports in builds:
        make_build(base, dirname, exports)
    job_env = {"PATH": f"{stubs}{os.pathsep}{tools}", "HOME": str(work), "LC_ALL": "POSIX", "TMPDIR": str(tmp),
               "STATE": str(state), "STUB_IMDS": imds, "STUB_INSTANCE_TYPE": itype, "STUB_NAMD_OUT": namd_out,
               "STUB_RC": str(rc), "STUB_DECKS": str(served), "SLURM_JOB_ID": JOB_ID,
               "SLURM_JOB_NUM_NODES": str(nodes), "SLURM_CPUS_ON_NODE": "192", "SLURM_CLUSTER_NAME": "test",
               "SLURM_SUBMIT_DIR": str(submit), "BASE_DIR": str(base),
               "DYNAMODB_RECORDER": str(stubs / "recorder-stub")}
    for name, value in (env or {}).items():
        if value is None:
            job_env.pop(name, None)
        else:
            job_env[name] = value
    proc = subprocess.run([BASH, str(runnable_copy(work, cpuinfo))], cwd=submit, env=job_env, capture_output=True,
                          text=True, errors="replace", timeout=120)
    calls = []
    for d in sorted(state.glob("mpirun-call-*"), key=lambda p: int(p.name.rsplit("-", 1)[1])):
        calls.append({"args": (d / "args").read_text().splitlines(), "cwd": (d / "cwd").read_text().strip(),
                      "fi_provider": (d / "fi_provider").read_text(),
                      "config": (d / "config").read_text().splitlines() if (d / "config").exists() else None})

    def log(name: str) -> list[str]:
        return (state / name).read_text().splitlines() if (state / name).exists() else []

    recorder = []
    for d in sorted(state.glob("recorder-call-*"), key=lambda p: int(p.name.rsplit("-", 1)[1])):
        recorder.append({"args": (d / "args").read_text().splitlines(), "cwd": (d / "cwd").read_text().strip(),
                         "env": dict(line.split("=", 1) for line in (d / "env").read_text().splitlines())})
    return Job(proc, calls, log("curl.log"), log("srun.log"), log("fi_info.log"), log("lscpu.log"), base, state,
               recorder)


def started(job: Job) -> dict:
    """The job called mpirun once and ended with exit status 0: that call."""
    assert job.proc.returncode == 0, job.proc.stdout + job.proc.stderr
    assert len(job.calls) == 1, job.calls
    return job.calls[0]


def namd_words(call: dict) -> list[str]:
    """mpirun's arguments from namd3 on: the binary, its options and the config."""
    args = call["args"]
    i = next(i for i, a in enumerate(args) if a.endswith("/namd3"))
    return args[i:]


def mpi_words(call: dict) -> list[str]:
    """mpirun's own arguments, before namd3."""
    args = call["args"]
    return args[:next(i for i, a in enumerate(args) if a.endswith("/namd3"))]


def deck_downloads(job: Job) -> list[str]:
    return [line for line in job.curl if "https://www.ks.uiuc.edu/Research/namd/" in line]


def assert_refused(job: Job, message: str) -> None:
    """The job stopped with exit status 1 and `message` on stderr, before mpirun and before it made a run directory."""
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert message in job.proc.stderr, job.proc.stderr
    assert job.calls == []
    assert job.run_dirs() == []


def test_one_node_runs_one_process_with_191_pes_and_reports_the_last_benchmark_line(tmp_path, host_tools):
    job = run(tmp_path, host_tools)
    call = started(job)
    namd3 = str(tmp_path / "base" / "x86_64" / "3.0.2-hpc8a" / "bin" / "namd3")
    assert mpi_words(call) == ["-np", "1", "--map-by", "ppr:1:node", "--bind-to", "none"]
    assert namd_words(call) == [namd3, "+ppn", "191", "+setcpuaffinity", "+commap", "0-191:192", "+pemap",
                                "1-191:192.191", "run-ApoA1.namd"]
    assert call["fi_provider"] == "unset"
    assert "NAMDRESULT model=ApoA1 nodes=1 ppn=191 instance=hpc8a.96xlarge days_per_ns=0.25 ns_per_day=4.0000 " \
           "wallclock=12.500000 procs_per_node=1" in job.out
    assert any(re.fullmatch(r"\s*model=ApoA1\s+nodes=1 x hpc8a\.96xlarge\s+procs/node=1\s+ppn=191\s+"
                            r"cores/node=192", line) for line in job.out), job.out


def test_two_nodes_check_efa_and_send_mpis_traffic_over_it(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"MODEL": "STMV"})
    call = started(job)
    assert mpi_words(call) == ["-np", "2", "--map-by", "ppr:1:node", "--bind-to", "none", "--mca", "pml", "cm",
                               "--mca", "mtl", "ofi", "-x", "FI_PROVIDER", "-x", "FI_EFA_USE_DEVICE_RDMA", "-x",
                               "RDMAV_FORK_SAFE"]
    assert call["fi_provider"] == "efa"
    assert job.fi_info == ["-p efa -t FI_EP_RDM"]
    assert "NAMDRESULT model=STMV nodes=2 ppn=191 instance=hpc8a.96xlarge days_per_ns=0.25 ns_per_day=4.0000 " \
           "wallclock=12.500000 procs_per_node=1" in job.out


def test_no_efa_on_two_nodes_stops_the_job_before_mpirun(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"STUB_FI_RC": "1"})
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    assert "fi_info -p efa failed" in job.proc.stderr
    assert job.calls == []


REFUSED = [
    pytest.param({"MODEL": "apoa1"}, "MODEL='apoa1' invalid", id="MODEL=apoa1"),
    pytest.param({"MODEL": "JAC"}, "MODEL='JAC' invalid (supported: ApoA1, ATPase, STMV, DHFR)", id="MODEL=JAC"),
    pytest.param({"MODEL": "dhfr"}, "MODEL='dhfr' invalid", id="MODEL=dhfr"),
    pytest.param({"MODEL": "F1-ATPase"}, "MODEL='F1-ATPase' invalid", id="MODEL=F1-ATPase"),
    *(pytest.param({"TIMESTEPS": v}, f"TIMESTEPS='{v}' invalid", id=f"TIMESTEPS={v}")
      for v in ("0", "10000001", "1e3")),
    *(pytest.param({"PPN": v}, f"PPN='{v}' invalid", id=f"PPN={v}") for v in ("0", "193", "abc")),
    pytest.param({"BASE_DIR": "relative/dir"}, "BASE_DIR must be an absolute path", id="relative BASE_DIR"),
]


@pytest.mark.parametrize("env, message", REFUSED)
def test_a_setting_out_of_its_range_stops_the_job_before_mpirun(env, message, tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, env=env), message)


def test_timesteps_rewrites_numsteps_in_the_run_config_only(tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"TIMESTEPS": "2000"})
    config = started(job)["config"]
    assert [line for line in config if line.lower().startswith("numsteps")] == ["numsteps 2000"]
    cached = (job.base / "benchmarks" / "ApoA1" / "apoa1.namd").read_text().splitlines()
    assert "numsteps             500" in cached


def test_an_outputtiming_line_is_added_when_the_deck_has_none(tmp_path, host_tools):
    lines = [line for line in DECKS["ApoA1"][3] if not line.lower().startswith("outputtiming")]
    job = run(tmp_path, host_tools, decks={"ApoA1": lines})
    config = started(job)["config"]
    assert config[-1] == "outputTiming 20"
    assert sum(line.lower().startswith("outputtiming") for line in config) == 1


def test_a_deck_with_an_outputtiming_line_keeps_it(tmp_path, host_tools):
    config = started(run(tmp_path, host_tools))["config"]
    assert [line for line in config if line.lower().startswith("outputtiming")] == ["outputtiming         20"]


@pytest.mark.parametrize("model", list(DECKS))
def test_a_deck_missing_from_the_cache_is_downloaded_and_copied_into_the_run_directory(model, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"MODEL": model})
    call = started(job)
    name, top, conf, _ = DECKS[model]
    downloads = deck_downloads(job)
    assert len(downloads) == 1 and downloads[0].endswith(deck_url(model)), downloads
    cache = job.base / "benchmarks" / model
    assert (cache / conf).read_text().splitlines() == DECKS[model][3]
    (run_dir,) = job.run_dirs()
    assert call["cwd"] == str(run_dir)
    for fname in (conf, *(f"{top}.{ext}" for ext in DECK_DATA)):
        assert (run_dir / fname).read_text() == (cache / fname).read_text(), fname
    assert namd_words(call)[-1] == f"run-{model}.namd"


def test_a_cached_deck_is_reused_with_no_download(tmp_path, host_tools):
    job = run(tmp_path, host_tools, cached={"ApoA1": None})
    started(job)
    assert deck_downloads(job) == []
    (run_dir,) = job.run_dirs()
    assert (run_dir / "apoa1.psf").read_text() == "synthetic cached psf\n"


def test_the_run_directory_names_the_job_model_cluster_nodes_type_and_pes(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"MODEL": "STMV"})
    started(job)
    (run_dir,) = job.run_dirs()
    assert re.fullmatch(rf"{JOB_ID}-STMV-test-2xhpc8a\.96xlarge-191ppn-\d{{8}}T\d{{6}}Z", run_dir.name), run_dir.name
    assert (run_dir / "namd.out").read_text().splitlines()[-1] == "[Partition 0][Node 0] End of program"


def test_the_last_benchmark_time_line_gives_the_result(tmp_path, host_tools):
    """Six Benchmark time lines in a 1,000-step run: the last one's days/ns is the result."""
    job = run(tmp_path, host_tools, env={"TIMESTEPS": "1000", "STUB_DAYS": "0.125"})
    started(job)
    (run_dir,) = job.run_dirs()
    bench = [line for line in (run_dir / "namd.out").read_text().splitlines() if "Benchmark time:" in line]
    assert len(bench) == 6
    assert any(line.startswith("NAMDRESULT ") and " days_per_ns=0.125 ns_per_day=8.0000 " in line for line in job.out)


def test_the_cache_drop_runs_once_on_every_node(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2)
    started(job)
    assert len(job.srun) == 1 and job.srun[0].startswith("--ntasks=2 --ntasks-per-node=1 bash -c "), job.srun


NOT_A_TYPE = {
    "a proxy's page": "<html><head><title>Proxy</title></head>\n<body>Request denied by proxy.example.com</body></html>",
    "a type-shaped word at the end": "Request denied by proxy.example.com",
    "capitals": "HPC8A.96XLARGE",
    "a type, then other text": "hpc8a.96xlarge: not found",
    "a type, then a second line": "hpc8a.96xlarge\n<p>Request checked by proxy.example.com",
}
NO_TYPE = [pytest.param("none", None, id="no answer"), pytest.param("error", None, id="an HTTP error"),
           pytest.param("cut-off", None, id="an answer cut off at the time limit"),
           *(pytest.param("text", text, id=name) for name, text in NOT_A_TYPE.items())]


@pytest.mark.parametrize("imds, text", NO_TYPE)
def test_no_instance_type_from_the_metadata_names_it_unknown_and_the_run_goes_on(imds, text, tmp_path, host_tools):
    env = {"STUB_IMDS_TEXT": text} if text is not None else {}
    job = run(tmp_path, host_tools, imds=imds, env=env)
    started(job)
    (run_dir,) = job.run_dirs()
    assert re.fullmatch(rf"{JOB_ID}-ApoA1-test-1xunknown-191ppn-\d{{8}}T\d{{6}}Z", run_dir.name), run_dir.name
    assert any(re.fullmatch(r"\s*model=ApoA1\s+nodes=1 x unknown\s+procs/node=1\s+ppn=191\s+cores/node=192", line)
               for line in job.out), job.out
    (result,) = [line for line in job.out if line.startswith("NAMDRESULT ")]
    assert " instance=unknown " in result, result
    for word in ("proxy", "html", "HPC8A", "hpc8a.96x"):
        assert word not in job.proc.stdout, word


def test_every_metadata_request_fails_on_an_http_error_and_has_a_time_limit(tmp_path, host_tools):
    job = run(tmp_path, host_tools)
    started(job)
    requests = [line for line in job.curl if "169.254.169.254" in line]
    assert len(requests) == 2, requests
    assert "latest/api/token" in requests[0] and "meta-data/instance-type" in requests[1], requests
    for request in requests:
        words = request.split()
        assert any(w == "--fail" or re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", w) for w in words), request
        assert re.search(r"(^| )--connect-timeout 2( |$)", request), request
        assert re.search(r"(^| )--max-time 5( |$)", request), request


def test_a_type_name_with_an_i_reads_in_a_turkish_locale(tmp_path, host_tools):
    """In a Turkish locale [a-z] leaves out i, so the type name is tested in the C locale."""
    if "tr_TR.utf8" not in subprocess.run(["locale", "-a"], capture_output=True, text=True).stdout.split():
        pytest.skip("the tr_TR.UTF-8 locale is not installed")
    job = run(tmp_path, host_tools, itype="c8i.96xlarge", env={"LC_ALL": "tr_TR.UTF-8"})
    started(job)
    (result,) = [line for line in job.out if line.startswith("NAMDRESULT ")]
    assert " instance=c8i.96xlarge " in result, result


def build_bin(job: Job, dirname: str) -> str:
    return str(job.base / "x86_64" / dirname / "bin" / "namd3")


ALL_TARGETS = tuple((f"3.0.2-{target}", {"NAMD_TARGET_CPU": target, "NAMD_ISA": "avx2" if target == "hpc6a" else
                                          "avx512"}) for target in ("hpc8a", "hpc7a", "m8a", "c8i", "r8i", "hpc6id",
                                                                    "hpc6a"))


@pytest.mark.parametrize("itype, dirname", [("hpc8a.96xlarge", "3.0.2-hpc8a"), ("hpc7a.96xlarge", "3.0.2-hpc7a"),
                                            ("hpc7a.48xlarge", "3.0.2-hpc7a"), ("c8i.96xlarge", "3.0.2-c8i"),
                                            ("r8i.96xlarge", "3.0.2-r8i"), ("m8a.48xlarge", "3.0.2-m8a"),
                                            ("hpc6id.32xlarge", "3.0.2-hpc6id")])
def test_the_build_of_the_nodes_instance_family_is_picked(itype, dirname, tmp_path, host_tools):
    job = run(tmp_path, host_tools, itype=itype, builds=ALL_TARGETS)
    call = started(job)
    assert namd_words(call)[0] == build_bin(job, dirname)
    target = dirname.split("-")[1]
    assert any(line.endswith(f"target={target}   isa=avx512") for line in job.out), job.out
    assert "NOTE:" not in job.proc.stderr, job.proc.stderr


def test_hpc6a_gets_its_avx2_build(tmp_path, host_tools):
    job = run(tmp_path, host_tools, itype="hpc6a.48xlarge", builds=ALL_TARGETS, cpuinfo=CPUINFO_AVX2,
              env={"SLURM_CPUS_ON_NODE": "96"})
    call = started(job)
    assert namd_words(call)[0] == build_bin(job, "3.0.2-hpc6a")
    assert any(line.endswith("target=hpc6a   isa=avx2") for line in job.out), job.out


def test_the_highest_version_of_the_familys_builds_is_picked(tmp_path, host_tools):
    builds = (("3.0.2-hpc8a", None), ("3.0.10-hpc8a", None), ("3.0.9-hpc8a", None), ("3.0.11-hpc7a", None))
    job = run(tmp_path, host_tools, builds=builds)
    assert namd_words(started(job))[0] == build_bin(job, "3.0.10-hpc8a")


@pytest.mark.parametrize("builds, imds", [((("3.0.2", None),), "ok"), ((HPC8A_BUILD,), "none"),
                                          ((("3.0.2-c8i", None),), "ok")],
                         ids=["a build from before the targets", "no instance type", "another family's build"])
def test_with_no_build_for_the_family_the_only_build_is_used_with_a_note(builds, imds, tmp_path, host_tools):
    job = run(tmp_path, host_tools, builds=builds, imds=imds)
    dirname = builds[0][0]
    assert namd_words(started(job))[0] == build_bin(job, dirname)
    family = "hpc8a" if imds == "ok" else "an unknown instance type"
    assert f"NOTE: no build for {family} under {job.base / 'x86_64'}/; using the only build there, " \
           f"{job.base / 'x86_64' / dirname}" in job.err, job.err


@pytest.mark.parametrize("imds", ["ok", "none"])
def test_several_builds_and_none_for_the_family_stop_the_job_and_ask_for_namd_env(imds, tmp_path, host_tools):
    builds = (("3.0.2-c8i", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, builds=builds, imds=imds)
    family = "hpc8a" if imds == "ok" else "an unknown instance type"
    root = job.base / "x86_64"
    assert_refused(job, f"ERROR: no build for {family} under {root}/, which holds 2 others ({root / '3.0.2-c8i'} "
                        f"{root / '3.0.2-hpc7a'}): set NAMD_ENV to the env script of one of them")


def test_no_build_at_all_stops_the_job(tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, builds=()), "ERROR: no NAMD env script found under")


def test_namd_env_set_by_hand_is_used_as_given(tmp_path, host_tools):
    env_script = tmp_path / "base" / "x86_64" / "3.0.2-c8i" / "namd-3.0.2-x86-env.sh"
    job = run(tmp_path, host_tools, builds=ALL_TARGETS, env={"NAMD_ENV": str(env_script)})
    assert namd_words(started(job))[0] == build_bin(job, "3.0.2-c8i")


@pytest.mark.parametrize("imds", ["ok", "none"])
def test_an_avx512_build_on_a_cpu_without_avx512_stops_the_job_before_anything_runs(imds, tmp_path, host_tools):
    env_script = tmp_path / "base" / "x86_64" / "3.0.2-hpc8a" / "namd-3.0.2-x86-env.sh"
    job = run(tmp_path, host_tools, nodes=2, itype="hpc6a.48xlarge", imds=imds, cpuinfo=CPUINFO_AVX2,
              env={"NAMD_ENV": str(env_script), "SLURM_CPUS_ON_NODE": "96"})
    assert_refused(job, f"ERROR: {env_script} is an AVX-512 build (NAMD_ISA=avx512), and this node's CPU has no "
                        "AVX-512: build TARGET_CPU=hpc6a for it, or set NAMD_ENV to that build's env script")
    assert job.fi_info == [] and deck_downloads(job) == []


def test_an_avx2_build_runs_on_a_cpu_with_avx512_too(tmp_path, host_tools):
    job = run(tmp_path, host_tools, builds=(("3.0.2-hpc6a", {"NAMD_TARGET_CPU": "hpc6a", "NAMD_ISA": "avx2"}),),
              env={"NAMD_ENV": str(tmp_path / "base" / "x86_64" / "3.0.2-hpc6a" / "namd-3.0.2-x86-env.sh")})
    started(job)


# The PPN of each flexible-cores count below a full node, and the counts.
LISTED_PPN = (23, 47, 71, 95, 119, 143, 167)
FLEX_TYPES = ("hpc8a.96xlarge", "hpc7a.96xlarge")


def flexible_cores_lists() -> dict[int, list[int]]:
    """The OPEN_MPI_PROCESSOR_LIST of each cores-per-node count in hello-cpu.openmpi.explicit.sbatch's case."""
    lists: dict[int, list[int]] = {}
    count = None
    for line in FLEXIBLE_CORES.read_text().splitlines():
        if m := re.fullmatch(r"\s*(\d+)\)", line):
            count = int(m.group(1))
        elif (m := re.fullmatch(r'\s*OPEN_MPI_PROCESSOR_LIST="([0-9,]+)"', line)) and count is not None:
            lists[count] = [int(c) for c in m.group(1).split(",")]
            count = None
    assert sorted(lists) == [24, 48, 72, 96, 120, 144, 168, 192], sorted(lists)
    return lists


def maps(call: dict) -> tuple[str | None, str | None]:
    """namd3's +commap and +pemap values (None when absent)."""
    words = namd_words(call)
    value = lambda opt: words[words.index(opt) + 1] if opt in words else None  # noqa: E731
    return value("+commap"), value("+pemap")


def assert_no_maps(call: dict) -> None:
    assert maps(call) == (None, None), namd_words(call)
    assert "+setcpuaffinity" in namd_words(call)


@pytest.mark.parametrize("ppn", LISTED_PPN)
@pytest.mark.parametrize("itype", FLEX_TYPES)
def test_below_a_full_node_the_threads_are_pinned_to_the_flexible_cores_list(itype, ppn, tmp_path, host_tools):
    """The communication thread on the list's first core, the PEs on the rest: every core once, and (PPN + 1) / 24
    threads on every CCD."""
    builds = (("3.0.2-hpc8a", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, itype=itype, builds=builds, env={"PPN": str(ppn)})
    call = started(job)
    commap, pemap = maps(call)
    listed = flexible_cores_lists()[ppn + 1]
    assert [int(commap)] + [int(c) for c in pemap.split(",")] == listed
    cores = [int(commap)] + [int(c) for c in pemap.split(",")]
    assert len(cores) == len(set(cores)) == ppn + 1
    assert {ccd: sum(c // 8 == ccd for c in cores) for ccd in range(24)} == dict.fromkeys(range(24), (ppn + 1) // 24)
    assert namd_words(call)[1:4] == ["+ppn", str(ppn), "+setcpuaffinity"]
    assert namd_words(call)[-1] == "run-ApoA1.namd"
    assert f"Flexible cores: the communication thread on core {commap} and the {ppn} PEs on the rest of the " \
           f"{ppn + 1}-core list (Utils/flexible-cores/)" in job.out
    assert job.lscpu == []


def test_two_nodes_use_the_same_node_local_list(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"PPN": "95", "MODEL": "STMV"})
    commap, pemap = maps(started(job))
    listed = flexible_cores_lists()[96]
    assert commap == str(listed[0]) and pemap == ",".join(map(str, listed[1:]))


@pytest.mark.parametrize("itype", FLEX_TYPES)
def test_a_full_node_gets_no_flexible_cores_list(itype, tmp_path, host_tools):
    builds = (("3.0.2-hpc8a", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, itype=itype, builds=builds, env={"PPN": "191"})
    assert maps(started(job)) == ("0-191:192", "1-191:192.191")
    assert not any(line.startswith("Flexible cores:") for line in job.out)


@pytest.mark.parametrize("itype", [*FLEX_TYPES, "c8i.96xlarge"])
def test_ppn_equal_to_the_nodes_cores_gets_no_maps_and_a_note(itype, tmp_path, host_tools):
    job = run(tmp_path, host_tools, itype=itype, builds=ALL_TARGETS, env={"PPN": "192"})
    assert_no_maps(started(job))
    assert "NOTE: PPN=192 on a node of 192 cores leaves no core for the communication thread; Charm++ places the " \
           "threads" in job.err


def flex_error(ppn: int, node: str, on: str) -> str:
    return (f"ERROR: PPN={ppn} worker threads and the communication thread use {ppn + 1} cores per node, which would "
            f"load the 24 CCDs of {node} unevenly; on {on} use PPN=23, 47, 71, 95, 119, 143, 167, 191 or 192 (see "
            "Utils/flexible-cores/)")


@pytest.mark.parametrize("ppn", [63, 100, 1])
@pytest.mark.parametrize("itype", FLEX_TYPES)
def test_another_ppn_on_hpc8a_and_hpc7a_stops_the_job_before_anything_runs(itype, ppn, tmp_path, host_tools):
    builds = (("3.0.2-hpc8a", None), ("3.0.2-hpc7a", None))
    job = run(tmp_path, host_tools, itype=itype, builds=builds, env={"PPN": str(ppn)})
    assert_refused(job, flex_error(ppn, itype, "this type"))
    assert deck_downloads(job) == [] and job.srun == []


@pytest.mark.parametrize("itype, cpus", [("hpc6a.48xlarge", 96), ("c8i.96xlarge", 192), ("hpc7a.48xlarge", 96)])
def test_other_types_and_sizes_get_no_list_and_no_check(itype, cpus, tmp_path, host_tools):
    cpuinfo = CPUINFO_AVX2 if itype.startswith("hpc6a") else CPUINFO_AVX512
    job = run(tmp_path, host_tools, itype=itype, builds=ALL_TARGETS, cpuinfo=cpuinfo,
              env={"PPN": "63", "SLURM_CPUS_ON_NODE": str(cpus)})
    assert_no_maps(started(job))
    assert job.lscpu == []
    assert "NOTE:" not in job.proc.stderr, job.proc.stderr


NOTE_APPLY = ("NOTE: no instance type from the instance metadata; lscpu shows a 192-core AMD node, which could be an "
              "hpc8a.96xlarge or hpc7a.96xlarge, so their cores-per-node check and flexible-cores lists apply")
NOTE_SKIP = ("NOTE: no instance type from the instance metadata, and lscpu does not show a 192-core AMD node, so the "
             "flexible-cores check and lists for hpc8a.96xlarge and hpc7a.96xlarge are skipped")


def test_with_no_type_a_192_core_amd_node_gets_the_check(tmp_path, host_tools):
    job = run(tmp_path / "63", host_tools, imds="none", env={"PPN": "63", "STUB_LSCPU": "amd-192"})
    assert_refused(job, flex_error(63, "this 192-core AMD node", "this node"))
    assert NOTE_APPLY in job.err


def test_with_no_type_a_192_core_amd_node_gets_the_lists(tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": "95", "STUB_LSCPU": "amd-192"})
    commap, pemap = maps(started(job))
    listed = flexible_cores_lists()[96]
    assert commap == str(listed[0]) and pemap == ",".join(map(str, listed[1:]))
    assert NOTE_APPLY in job.err
    (run_dir,) = job.run_dirs()
    assert "-1xunknown-95ppn-" in run_dir.name


@pytest.mark.parametrize("ppn", [63, 95])
@pytest.mark.parametrize("node", ["intel-192", "amd-96", "fail"])
def test_with_no_type_any_other_node_runs_with_no_list_and_a_note(node, ppn, tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": str(ppn), "STUB_LSCPU": node})
    assert_no_maps(started(job))
    assert NOTE_SKIP in job.err


@pytest.mark.parametrize("ppn", [191, 192])
def test_with_no_type_a_full_node_asks_lscpu_nothing(ppn, tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": str(ppn)})
    started(job)
    assert job.lscpu == []
    assert "lscpu" not in job.proc.stderr


def test_lscpu_is_read_in_the_c_locale(tmp_path, host_tools):
    job = run(tmp_path, host_tools, imds="none", env={"PPN": "95", "LC_ALL": "de_DE.UTF-8"})
    started(job)
    assert job.lscpu == ["C"]


def expand_map(spec: str) -> list[int]:
    """A Charm++ +pemap or +commap value as Charm++'s search_pemap expands it: comma-separated entries, each a core,
    a range a-b, or a-b:stride or a-b:stride.block (block cores from every stride-th core from a up to b)."""
    cores: list[int] = []
    for token in spec.split(","):
        m = re.fullmatch(r"(\d+)(?:-(\d+)(?::(\d+)(?:\.(\d+))?)?)?", token)
        assert m, token
        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else start
        stride, block = int(m.group(3) or 1), int(m.group(4) or 1)
        assert block <= stride, token
        for i in range(start, end + 1, stride):
            cores.extend(i + j for j in range(block) if i + j <= end)
    return cores


def process_cores(call: dict, procs: int, ppn: int) -> list[tuple[int, list[int]]]:
    """Each of a node's processes, in rank order: its communication thread's core and its PEs' cores. Charm++ binds
    PE p to the pemap entry p mod (the entries), and the communication thread of process k to commap entry k mod (the
    entries)."""
    commap, pemap = (expand_map(v) for v in maps(call))
    return [(commap[k % len(commap)], [pemap[(k * ppn + i) % len(pemap)] for i in range(ppn)]) for k in range(procs)]


def assert_whole_groups(call: dict, cores: int, procs: int) -> None:
    """Every core once, and process k on group k of cores / procs consecutive cores, its communication thread on the
    group's first core."""
    g = cores // procs
    placed = process_cores(call, procs, g - 1)
    used = [c for comm, pes in placed for c in (comm, *pes)]
    assert sorted(used) == list(range(cores)), placed
    for k, (comm, pes) in enumerate(placed):
        assert comm == k * g, (k, comm)
        assert sorted(pes) == list(range(k * g + 1, (k + 1) * g)), (k, pes)


@pytest.mark.parametrize("procs", [1, 2, 3, 4, 6, 8, 12, 24])
def test_on_hpc8a_each_process_takes_whole_ccds_with_its_communication_thread_on_the_first_core(procs, tmp_path,
                                                                                               host_tools):
    job = run(tmp_path, host_tools, env={"PROCS_PER_NODE": str(procs), "MODEL": "STMV"})
    call = started(job)
    g = 192 // procs
    assert mpi_words(call)[:6] == ["-np", str(procs), "--map-by", f"ppr:{procs}:node", "--bind-to", "none"]
    assert namd_words(call)[1:3] == ["+ppn", str(g - 1)]
    assert maps(call) == (f"0-191:{g}", f"1-191:{g}.{g - 1}")
    assert_whole_groups(call, 192, procs)
    placed = process_cores(call, procs, g - 1)
    ccds = [sum(c // 8 == ccd for comm, pes in placed for c in (comm, *pes)) for ccd in range(24)]
    assert ccds == [8] * 24
    assert all(len({c // 8 for c in (comm, *pes)}) == g // 8 for comm, pes in placed)
    (run_dir,) = job.run_dirs()
    layout = "191ppn" if procs == 1 else f"{procs}x{g - 1}ppn"
    assert f"-1xhpc8a.96xlarge-{layout}-" in run_dir.name
    (result,) = [line for line in job.out if line.startswith("NAMDRESULT ")]
    assert f" ppn={g - 1} " in result and result.endswith(f" procs_per_node={procs}")


@pytest.mark.parametrize("itype, cores, procs", [("c8i.96xlarge", 192, 6), ("hpc6id.32xlarge", 64, 2),
                                                 ("hpc6id.32xlarge", 64, 8), ("hpc6a.48xlarge", 96, 12),
                                                 ("c8i.96xlarge", 192, 16)])
def test_on_other_types_each_process_takes_its_group(itype, cores, procs, tmp_path, host_tools):
    cpuinfo = CPUINFO_AVX2 if itype.startswith("hpc6a") else CPUINFO_AVX512
    job = run(tmp_path, host_tools, itype=itype, builds=ALL_TARGETS, cpuinfo=cpuinfo,
              env={"PROCS_PER_NODE": str(procs), "SLURM_CPUS_ON_NODE": str(cores)})
    call = started(job)
    assert mpi_words(call)[:4] == ["-np", str(procs), "--map-by", f"ppr:{procs}:node"]
    assert_whole_groups(call, cores, procs)
    assert job.lscpu == []


def test_two_nodes_run_p_processes_on_each_with_the_same_node_local_maps(tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=2, env={"PROCS_PER_NODE": "24", "MODEL": "STMV"})
    call = started(job)
    assert mpi_words(call)[:4] == ["-np", "48", "--map-by", "ppr:24:node"]
    assert "--mca" in mpi_words(call)
    assert_whole_groups(call, 192, 24)
    # Node 1's processes are ranks 24-47: PEs 24*7 ... and node indices 24-47 map to the same entries.
    commap, pemap = (expand_map(v) for v in maps(call))
    assert [commap[k % len(commap)] for k in range(24, 48)] == [commap[k] for k in range(24)]
    assert [pemap[p % len(pemap)] for p in range(24 * 7, 48 * 7)] == pemap


PROCS_REFUSED = ["0", "abc", "5", "97", "192", "-2", "+2", "02"]


@pytest.mark.parametrize("value", PROCS_REFUSED)
def test_a_procs_per_node_that_does_not_divide_the_node_stops_the_job(value, tmp_path, host_tools):
    job = run(tmp_path, host_tools, itype="c8i.96xlarge", builds=ALL_TARGETS, env={"PROCS_PER_NODE": value})
    assert_refused(job, f"ERROR: PROCS_PER_NODE='{value}' invalid (an integer that divides the node's 192 cores and "
                        "leaves each process at least 2)")


def test_more_than_one_process_takes_ppn_g_minus_1_only(tmp_path, host_tools):
    assert_refused(run(tmp_path / "63", host_tools, env={"PROCS_PER_NODE": "2", "PPN": "63"}),
                   "ERROR: PPN=63 with PROCS_PER_NODE=2: each process has 96 cores, so PPN is 95 (a core for its "
                   "communication thread); leave PPN unset")
    started(run(tmp_path / "95", host_tools, env={"PROCS_PER_NODE": "2", "PPN": "95"}))


def procs_error(procs: int, node: str, on: str) -> str:
    return (f"ERROR: PROCS_PER_NODE={procs} gives each process {192 // procs} cores, which would load the 24 CCDs of "
            f"{node} unevenly; on {on} use PROCS_PER_NODE=1, 2, 3, 4, 6, 8, 12 or 24 (see Utils/flexible-cores/)")


@pytest.mark.parametrize("procs", [16, 32, 48, 64, 96])
@pytest.mark.parametrize("itype", FLEX_TYPES)
def test_on_hpc8a_and_hpc7a_groups_that_are_not_whole_ccds_stop_the_job(itype, procs, tmp_path, host_tools):
    job = run(tmp_path, host_tools, itype=itype, builds=ALL_TARGETS, env={"PROCS_PER_NODE": str(procs)})
    assert_refused(job, procs_error(procs, itype, "this type"))


def test_with_no_type_lscpu_decides_for_groups_that_are_not_whole_ccds(tmp_path, host_tools):
    job = run(tmp_path / "amd", host_tools, imds="none", env={"PROCS_PER_NODE": "16", "STUB_LSCPU": "amd-192"})
    assert_refused(job, procs_error(16, "this 192-core AMD node", "this node"))
    assert NOTE_APPLY in job.err
    job = run(tmp_path / "intel", host_tools, imds="none", env={"PROCS_PER_NODE": "16", "STUB_LSCPU": "intel-192"})
    assert_whole_groups(started(job), 192, 16)
    assert NOTE_SKIP in job.err
    job = run(tmp_path / "whole", host_tools, imds="none", env={"PROCS_PER_NODE": "4"})
    assert_whole_groups(started(job), 192, 4)
    assert job.lscpu == []


@pytest.mark.parametrize("extra", ["+notiles", "+notiles +stdout_flush_1"])
def test_namd_extra_args_go_before_the_config(extra, tmp_path, host_tools):
    call = started(run(tmp_path, host_tools, env={"NAMD_EXTRA_ARGS": extra}))
    words = namd_words(call)
    assert words[-1 - len(extra.split()):-1] == extra.split()


@pytest.mark.parametrize("word", ["notiles", "+1x", "+notiles;rm", "-notiles", "+no-tiles", "+no/tiles"])
def test_a_namd_extra_args_word_that_is_not_a_plus_option_stops_the_job(word, tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, env={"NAMD_EXTRA_ARGS": f"+notiles {word}"}),
                   f"ERROR: NAMD_EXTRA_ARGS: '{word}' is not a namd3 option word (a + and a name of letters, digits "
                   "and _)")


@pytest.mark.parametrize("word", ["+ppn", "+setcpuaffinity", "+pemap", "+commap"])
def test_namd_extra_args_cannot_set_what_the_launcher_sets(word, tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, env={"NAMD_EXTRA_ARGS": word}),
                   f"ERROR: NAMD_EXTRA_ARGS: {word} is set by the launcher")


@pytest.mark.parametrize("value", ["095", "+95", " 95"])
def test_a_ppn_with_a_sign_a_space_or_a_leading_zero_stops_the_job(value, tmp_path, host_tools):
    assert_refused(run(tmp_path, host_tools, env={"PPN": value}), f"PPN='{value}' invalid")


@pytest.mark.parametrize("nodes, env", [(1, {}), (2, {"PROCS_PER_NODE": "8", "NAMD_EXTRA_ARGS": "+notiles"})])
def test_the_job_log_prints_the_mpirun_command_line(nodes, env, tmp_path, host_tools):
    job = run(tmp_path, host_tools, nodes=nodes, env=env)
    call = started(job)
    assert f"==> mpirun {' '.join(call['args'])}" in job.out


def assert_no_result(job: Job) -> None:
    """No results block, no NAMDRESULT line, and no call of the recorder."""
    assert not any(line.startswith("NAMDRESULT") for line in job.out), job.out
    assert "NAMD benchmark results" not in job.proc.stdout
    assert job.recorder == []


@pytest.mark.parametrize("rc", [3, 139])
def test_a_failing_namd_ends_the_job_with_its_exit_status(rc, tmp_path, host_tools):
    job = run(tmp_path, host_tools, rc=rc)
    assert job.proc.returncode == rc, job.proc.stdout + job.proc.stderr
    (run_dir,) = job.run_dirs()
    assert f"ERROR: NAMD exited with status {rc}; see {run_dir}/namd.out" in job.err
    assert_no_result(job)


@pytest.mark.parametrize("out, message", [
    ("no-wallclock", "ERROR: namd.out has no closing 'WallClock:' line, so NAMD did not end normally"),
    ("zero-days", "ERROR: the last 'Benchmark time:' line gives no positive days/ns ('0')"),
    ("no-bench", "ERROR: could not parse 'days/ns' from NAMD output"),
])
def test_namd_exiting_0_without_a_complete_result_ends_the_job_with_status_1(out, message, tmp_path, host_tools):
    """An ERROR that says what is missing, and a NOTE that the run is not recorded: the recorder is not called."""
    job = run(tmp_path, host_tools, namd_out=out)
    assert job.proc.returncode == 1, job.proc.stdout + job.proc.stderr
    (run_dir,) = job.run_dirs()
    assert any(line.startswith(message) and line.endswith(f"({run_dir}/namd.out)") for line in job.err), job.err
    assert f"NOTE: not recorded: {message.removeprefix('ERROR: ')}" in job.err, job.err
    assert_no_result(job)


def test_a_days_per_ns_in_scientific_notation_is_a_result(tmp_path, host_tools):
    job = run(tmp_path, host_tools, namd_out="sci-days")
    started(job)
    (result,) = [line for line in job.out if line.startswith("NAMDRESULT ")]
    assert " days_per_ns=1.5e-05 ns_per_day=66666.6667 " in result, result


def output_names(config: list[str]) -> list[str]:
    return [line for line in config if line.split()[:1] and line.split()[0].lower() == "outputname"]


@pytest.mark.parametrize("model, name", [("ApoA1", "outputname           apoa1-out"),
                                         ("ATPase", "outputname              f1atpase"),
                                         ("STMV", "outputName          stmv-output")])
def test_the_run_config_names_its_output_without_the_decks_directory(model, name, tmp_path, host_tools):
    config = started(run(tmp_path, host_tools, env={"MODEL": model}))["config"]
    assert output_names(config) == [name]


@pytest.mark.parametrize("line, expected", [("OUTPUTNAME /usr/tmp/x", "OUTPUTNAME x"),
                                            ("outputname   x-out", "outputname   x-out"),
                                            ("  outputName /a/b/c-1 ;# a comment", "  outputName c-1 ;# a comment")])
def test_any_case_and_spacing_of_outputname_keeps_the_name_only(line, expected, tmp_path, host_tools):
    lines = [x for x in DECKS["ApoA1"][3] if not x.lower().startswith("outputname")] + [line]
    config = started(run(tmp_path, host_tools, decks={"ApoA1": lines}))["config"]
    assert output_names(config) == [expected]


def test_a_deck_without_an_output_name_is_left_as_it_is(tmp_path, host_tools):
    lines = [x for x in DECKS["ApoA1"][3] if not x.lower().startswith("outputname")]
    config = started(run(tmp_path, host_tools, decks={"ApoA1": lines}))["config"]
    assert output_names(config) == []
    keep = lambda ls: [x for x in ls if not x.startswith("numsteps")]  # noqa: E731
    assert keep(config[:len(lines)]) == keep(lines)


@pytest.mark.parametrize("model", list(DECKS))
def test_the_downloaded_archive_stays_out_of_the_cache_and_the_run_directory(model, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"MODEL": model})
    started(job)
    _, top, conf, _ = DECKS[model]
    files = sorted([conf, *(f"{top}.{ext}" for ext in DECK_DATA)])
    assert sorted(p.name for p in (job.base / "benchmarks" / model).iterdir()) == files
    (run_dir,) = job.run_dirs()
    names = {p.name for p in run_dir.iterdir()}
    assert set(files) <= names and not any(n.endswith(".tar.gz") for n in names), names


def test_f1_atpase_comes_from_its_tarball_and_runs_its_config(tmp_path, host_tools):
    """MODEL=ATPase: f1atpase.tar.gz from the NAMD utilities page and f1atpase.namd, whose outputTiming line (after a
    tab) is kept, with no second one added."""
    job = run(tmp_path, host_tools, env={"MODEL": "ATPase"})
    call = started(job)
    assert deck_downloads(job)[0].endswith(UTILITIES + "f1atpase.tar.gz")
    assert namd_words(call)[-1] == "run-ATPase.namd"
    assert [line for line in call["config"] if line.lower().startswith("outputtiming")] == ["outputTiming\t\t20"]
    assert any(line.startswith("NAMDRESULT model=ATPase ") for line in job.out), job.out


def test_dhfr_comes_from_namds_benchmark_page_and_runs_its_gpu_offload_config_on_the_cpu(tmp_path, host_tools):
    """MODEL=DHFR: dhfr_gpu.tar.gz from NAMD's benchmark page and dhfr_gpuoff_nve.namd, with doBenchmark and
    skipFFTWconfig set to 0 and its run length to TIMESTEPS; every other line as the deck has it."""
    job = run(tmp_path, host_tools, env={"MODEL": "DHFR"})
    call = started(job)
    assert deck_downloads(job)[0].endswith(BENCHMARKS + "dhfr_gpu.tar.gz")
    assert namd_words(call)[-1] == "run-DHFR.namd"
    changed = {"set doBenchmark  1    ;# a synthetic comment": "set doBenchmark  0    ;# a synthetic comment",
               "set skipFFTWconfig 1": "set skipFFTWconfig 0",
               "set num_steps_run   5000  ;# a synthetic comment": "set num_steps_run   1000  ;# a synthetic comment"}
    assert call["config"] == [changed.get(line, line) for line in DECKS["DHFR"][3]]
    (run_dir,) = job.run_dirs()
    assert sum("Benchmark time:" in line for line in (run_dir / "namd.out").read_text().splitlines()) == 6
    assert any(line.startswith("NAMDRESULT model=DHFR ") for line in job.out), job.out


@pytest.mark.parametrize("steps", ["500", "20000"])
def test_timesteps_sets_dhfrs_run_length(steps, tmp_path, host_tools):
    config = started(run(tmp_path, host_tools, env={"MODEL": "DHFR", "TIMESTEPS": steps}))["config"]
    assert run_length(config) == [f"set num_steps_run   {steps}  ;# a synthetic comment"]
    assert "run                  $num_steps_run" in config


def run_length(config: list[str]) -> list[str]:
    """The lines that set the run config's length: numsteps, or DHFR's num_steps_run."""
    return [line for line in config if line.lower().startswith("numsteps") or line.startswith("set num_steps_run")]


@pytest.mark.parametrize("model", list(DECKS))
def test_by_default_the_run_is_1000_steps(model, tmp_path, host_tools):
    """The run config's numsteps (DHFR's num_steps_run) is 1000, the cached deck keeps its own, and NAMD prints six
    Benchmark time lines."""
    job = run(tmp_path, host_tools, env={"MODEL": model})
    config = started(job)["config"]
    expected = ["set num_steps_run   1000  ;# a synthetic comment"] if model == "DHFR" else ["numsteps 1000"]
    assert run_length(config) == expected
    _, _, conf, lines = DECKS[model]
    cached = (job.base / "benchmarks" / model / conf).read_text().splitlines()
    assert cached == lines
    (run_dir,) = job.run_dirs()
    assert sum("Benchmark time:" in line for line in (run_dir / "namd.out").read_text().splitlines()) == 6


@pytest.mark.parametrize("steps", ["500", "20000"])
def test_timesteps_sets_numsteps_and_a_run_line(steps, tmp_path, host_tools):
    lines = [*DECKS["ApoA1"][3], "RUN 500"]
    config = started(run(tmp_path, host_tools, decks={"ApoA1": lines}, env={"TIMESTEPS": steps}))["config"]
    assert [line for line in config if line.lower().startswith(("numsteps", "run "))] == [f"numsteps {steps}",
                                                                                         f"run {steps}"]


def test_the_job_asks_slurm_for_a_time_limit_of_two_hours():
    header = [line for line in SCRIPT.read_text().splitlines() if line.startswith("#SBATCH")]
    assert [line for line in header if line.startswith("#SBATCH --time")] == ["#SBATCH --time=02:00:00"], header


NOTE_NOT_FOUND = "NOTE: benchmark recorder not found; set DYNAMODB_RECORDER=/path/to/record-benchmark.sh to record."
NOTE_FAILED = "NOTE: benchmark recorder failed (non-fatal); the solve was unaffected."


def recorded(job: Job) -> dict:
    """The job called mpirun once, the recorder once, and ended with exit status 0: the recorder's call."""
    started(job)
    assert len(job.recorder) == 1, job.recorder
    return job.recorder[0]


def test_a_complete_run_is_recorded_from_its_run_directory(tmp_path, host_tools):
    """The recorder runs in the run directory, with the case, days/ns (it computes ns/day itself), NAMD's WallClock
    time, the nodes, the cores the run used and the instance type, and the layout and kernels as a metric and a char."""
    job = run(tmp_path, host_tools)
    call = recorded(job)
    (run_dir,) = job.run_dirs()
    assert call["cwd"] == str(run_dir)
    assert call["args"] == ["--metric", "procs_per_node=1", "--metric", "pes_per_proc=191", "--char",
                            "avx512_tiles=off"]
    env = call["env"]
    assert {k: env.get(k) for k in ("BENCHMARK_CASE", "DAYS_PER_NS", "TIME_TO_SOLUTION", "NUM_INSTANCES",
                                    "NUM_CORES", "CORES_PER_NODE", "INSTANCE_TYPE", "RUN_DIR")} == {
        "BENCHMARK_CASE": "ApoA1", "DAYS_PER_NS": "0.25", "TIME_TO_SOLUTION": "12.500000", "NUM_INSTANCES": "1",
        "NUM_CORES": "192", "CORES_PER_NODE": "192", "INSTANCE_TYPE": "hpc8a.96xlarge", "RUN_DIR": str(run_dir)}
    assert "NS_PER_DAY" not in env, env
    assert env["NAMD_VERSION"] == "3.0.2"   # from the build's env script
    assert "NOTE:" not in job.proc.stderr, job.proc.stderr


@pytest.mark.parametrize("nodes, itype, cores, env, procs, pes, per_node", [
    pytest.param(2, "hpc8a.96xlarge", 192, {"MODEL": "STMV", "PROCS_PER_NODE": "4"}, 4, 47, 192, id="2 nodes x 4"),
    pytest.param(1, "hpc8a.96xlarge", 192, {"PPN": "95"}, 1, 95, 96, id="the 96-core list"),
    pytest.param(1, "hpc8a.96xlarge", 192, {"PPN": "192"}, 1, 192, 192, id="PPN 192: the node's cores"),
    pytest.param(1, "c8i.96xlarge", 192, {"PPN": "63"}, 1, 63, 64, id="c8i at 64 cores"),
    pytest.param(4, "hpc6a.48xlarge", 96, {"PROCS_PER_NODE": "12"}, 12, 7, 96, id="4 hpc6a nodes x 12"),
])
def test_the_record_counts_the_cores_the_run_used(nodes, itype, cores, env, procs, pes, per_node, tmp_path,
                                                  host_tools):
    """PROCS_PER_NODE x (PPN + 1) cores per node, at most the node's, and the nodes' cores in all."""
    cpuinfo = CPUINFO_AVX2 if itype.startswith("hpc6a") else CPUINFO_AVX512
    job = run(tmp_path, host_tools, nodes=nodes, itype=itype, builds=ALL_TARGETS, cpuinfo=cpuinfo,
              env={**env, "SLURM_CPUS_ON_NODE": str(cores)})
    call = recorded(job)
    assert call["env"]["NUM_INSTANCES"] == str(nodes)
    assert call["env"]["CORES_PER_NODE"] == str(per_node)
    assert call["env"]["NUM_CORES"] == str(nodes * per_node)
    assert call["args"][:4] == ["--metric", f"procs_per_node={procs}", "--metric", f"pes_per_proc={pes}"]


@pytest.mark.parametrize("tiles, value", [("ENABLED", "on"), ("DISABLED", "off"), (None, "off")],
                         ids=["enabled", "disabled (+notiles)", "no line (an AVX2 build)"])
def test_the_record_says_whether_the_avx512_tile_kernels_ran(tiles, value, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"STUB_TILES": tiles})
    assert recorded(job)["args"][-2:] == ["--char", f"avx512_tiles={value}"]


@pytest.mark.parametrize("rc", [1, 3])
def test_a_failing_recorder_leaves_the_jobs_exit_status_0_with_a_note(rc, tmp_path, host_tools):
    job = run(tmp_path, host_tools, env={"STUB_RECORDER_RC": str(rc)})
    recorded(job)
    assert NOTE_FAILED in job.err, job.err
    assert any(line.startswith("NAMDRESULT ") for line in job.out), job.out


@pytest.mark.parametrize("value", [None, "", "missing", "not-executable"])
def test_with_no_recorder_found_the_job_says_so_and_ends_with_status_0(value, tmp_path, host_tools):
    path = {"missing": str(tmp_path / "no-such-recorder.sh"), "not-executable": str(tmp_path / "recorder.sh")}
    (tmp_path / "recorder.sh").write_text(RECORDER_STUB)
    job = run(tmp_path, host_tools, env={"DYNAMODB_RECORDER": path.get(value, value)})
    started(job)
    assert job.recorder == []
    assert NOTE_NOT_FOUND in job.err, job.err


@pytest.mark.parametrize("where", ["../dynamodb", "dynamodb", "apps/NAMD/dynamodb"])
def test_the_recorder_is_found_from_the_submit_directory(where, tmp_path, host_tools):
    """With DYNAMODB_RECORDER unset, the recorder next to x86/ when the job is submitted from x86/, inside the
    submit directory, or under apps/NAMD/ when it is submitted from a clone's root."""
    found = tmp_path / "submit" / where / "record-benchmark.sh"
    found.parent.mkdir(parents=True, exist_ok=True)
    found.write_text(RECORDER_STUB)
    found.chmod(0o755)
    job = run(tmp_path, host_tools, env={"DYNAMODB_RECORDER": None})
    recorded(job)
    assert NOTE_NOT_FOUND not in job.err


def dynamo_item(text: str) -> dict:
    """The record a dry run printed, each value as its string (a list of strings for libraries); a key twice fails."""
    def unique(pairs):
        keys = [k for k, _ in pairs]
        assert len(keys) == len(set(keys)), keys
        return dict(pairs)
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("# DRY RUN"))
    data = json.loads("\n".join(lines[start + 1:]), object_pairs_hook=unique)
    return {k: [x["S"] for x in v["L"]] if "L" in v else v.get("S", v.get("N")) for k, v in data.items()}


def test_the_contribution_recorder_records_the_run_in_a_dry_run(tmp_path, host_tools):
    """The repository's recorder, in --dry-run as the real-node checks run it: the launcher's values and namd.out's,
    each attribute once, no WARN, no file and no AWS."""
    wrapper = tmp_path / "record-dryrun.sh"
    recorder_script = REPO / "apps" / "NAMD" / "dynamodb" / "record-benchmark.sh"
    wrapper.write_text(f'#!/bin/bash\nexec bash "{recorder_script}" --dry-run "$@"\n')
    wrapper.chmod(0o755)
    job = run(tmp_path, host_tools, env={"DYNAMODB_RECORDER": str(wrapper), "STUB_TILES": "ENABLED",
                                         "SOURCE": "TestOrg", "OPERATING_SYSTEM": "Synthetic OS 1"})
    started(job)
    table = " would write to table 'External_TestOrg_Namd' (region us-east-1); no file, no AWS."
    assert any(line.startswith("# DRY RUN") and line.endswith(table) for line in job.out), job.out
    item = dynamo_item(job.proc.stdout)
    assert re.fullmatch(rf"namd-TestOrg-hpc8a\.96xlarge-192c-ApoA1-\d{{8}}T\d{{6}}Z-{JOB_ID}", item.pop("record_id"))
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", item.pop("recorded_at"))
    assert item == {
        "application": "namd", "benchmark_case": "ApoA1", "instance_type": "hpc8a.96xlarge",
        "operating_system": "Synthetic OS 1", "num_cores": "192", "num_instances": "1", "cores_per_node": "192",
        "mpi_implementation": "openmpi", "libraries": ["mpi:openmpi", "mpi-version:4.1.7", "efa:122.0", "namd:3.0.2"],
        "time_to_solution_seconds": "12.500000", "ns_per_day": "4", "days_per_ns": "0.25", "nsteps": "1000",
        "timestep_fs": "1", "discipline": "MD", "atoms_million": "0.123456", "namd_version": "3.0.2",
        "namd_platform": "Linux-x86_64-MPI-smp", "provenance_origin": "external", "provenance_source_id": "TestOrg",
        "procs_per_node": "1", "pes_per_proc": "191", "avx512_tiles": "on"}
    assert "WARN" not in job.proc.stderr and "NOTE:" not in job.proc.stderr, job.proc.stderr
    (run_dir,) = job.run_dirs()
    assert not list(run_dir.glob("*.json"))
