#!/bin/bash
# =============================================================================
# End-to-end test of the LAMMPS benchmark scripts as ASSEMBLED.
# =============================================================================
# Runs x86/lammps-benchmark.sbatch and Arm/lammps-benchmark.sbatch with stub
# commands, so the whole script executes. tests/README.md lists the stubs and
# what is checked.
#
# The stub lmp handles the input the way LAMMPS does for what is tested here:
# a "run N" line runs N steps, "run ${name}" runs the value given with
# -var name, and a variable nobody defined is an error; the atom count is
# 32,000 x x*y*z for a deck that defines x, y and z, and 32,000 otherwise. The
# benchmark cache is filled with synthetic decks of the bench/ decks' shape,
# so nothing is downloaded. Every time in the stub's log is synthetic.
#
# No Slurm, no EC2, no LAMMPS, no MPI, no AWS credentials, no network. The
# stubs never run a command on the host: the cache drops and THP settings the
# scripts launch through srun are swallowed, and sudo does nothing.
#
#   apps/LAMMPS/tests/test-sbatch-e2e.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMMPS_APP="$(cd "${HERE}/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

SCRIPTS=(x86/lammps-benchmark.sbatch Arm/lammps-benchmark.sbatch)

STUBS="$(mktemp -d)"
trap 'rm -rf "${STUBS}"' EXIT

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
mkdir -p "${STUBS}/bin" "${STUBS}/lmp-bin" "${STUBS}/decks"

cat > "${STUBS}/bin/curl" <<'EOF'
#!/bin/bash
# IMDS stub (token, instance type, Region), each call logged with its options.
# STUB_IMDS sets how the metadata service answers:
#   (unset)     the token, STUB_INSTANCE_TYPE (default stub.96xlarge), a Region;
#   no-answer   nothing: every call ends as curl does past --max-time (exit 28);
#   error-page  the instance type is an HTTP 404: curl -f fails (exit 22), and
#               curl without -f prints the error page and exits 0;
#   not-a-type  the instance type is answered with a page that is not one.
# Any other URL is a download, which this test never expects: logged, and
# refused as curl -f refuses an HTTP error.
case "$*" in
  *169.254.169.254*)
    echo "curl $*" >> "${IMDS_LOG}"
    fail_opt=0
    for a in "$@"; do
      case "${a}" in --fail|-f*|-[!-]*f*) fail_opt=1;; esac
    done
    [ "${STUB_IMDS:-}" = no-answer ] && exit 28
    case "$*" in
      *api/token*) echo "stub-token"; exit 0;;
      *instance-type*)
        case "${STUB_IMDS:-}" in
          error-page)
            [ "${fail_opt}" = 1 ] && exit 22
            printf '<?xml version="1.0" encoding="iso-8859-1"?>\n<html>\n <head>\n  <title>404 - Not Found</title>\n </head>\n</html>\n'
            exit 0;;
          not-a-type)
            echo "<html><body>Instance metadata is not available here</body></html>"
            exit 0;;
        esac
        echo "${STUB_INSTANCE_TYPE:-stub.96xlarge}"; exit 0;;
      *placement/region*) echo "stub-region-1"; exit 0;;
    esac
    exit 22;;
esac
echo "curl $*" >> "${CURL_LOG}"
exit 22
EOF

cat > "${STUBS}/bin/lscpu" <<'EOF'
#!/bin/bash
# lscpu stub, each call logged: the fields the x86 script reads, for the node
# STUB_LSCPU names (amd192, amd192-indented, amd96, amd96-smt: the same CPU
# with two threads per core, so 192 CPUs; amd96-1s: 96 cores on one socket;
# amd256: 2 x 128 cores; intel192), in the flat layout or, for
# amd192-indented, the indented one of newer util-linux. Anything else fails,
# as on a node without lscpu.
echo "lscpu $*" >> "${LSCPU_LOG}"
threads=1
case "${STUB_LSCPU:-}" in
  amd192|amd192-indented) vendor=AuthenticAMD; model="AMD EPYC 9R45"; per_socket=96; sockets=2;;
  amd96)                  vendor=AuthenticAMD; model="AMD EPYC 7R13 Processor"; per_socket=48; sockets=2;;
  amd96-smt)              vendor=AuthenticAMD; model="AMD EPYC 7R13 Processor"; per_socket=48; sockets=2; threads=2;;
  amd96-1s)               vendor=AuthenticAMD; model="AMD EPYC"; per_socket=96; sockets=1;;
  amd256)                 vendor=AuthenticAMD; model="AMD EPYC"; per_socket=128; sockets=2;;
  intel192)               vendor=GenuineIntel; model="Intel(R) Xeon(R) CPU"; per_socket=96; sockets=2;;
  *)                      exit 1;;
esac
row() {  # row <indent> <field> <value>
  local indent=0
  [ "${STUB_LSCPU}" = amd192-indented ] && indent="$1"
  printf '%*s%-*s%s\n' "${indent}" '' $(( 41 - indent )) "$2" "$3"
}
row 0 "Architecture:" x86_64
row 0 "CPU(s):" $(( per_socket * sockets * threads ))
row 0 "Vendor ID:" "${vendor}"
row 2 "Model name:" "${model}"
row 4 "Thread(s) per core:" "${threads}"
row 4 "Core(s) per socket:" "${per_socket}"
row 4 "Socket(s):" "${sockets}"
row 0 "NUMA node(s):" 4
EOF

cat > "${STUBS}/bin/scontrol" <<'EOF'
#!/bin/bash
# scontrol show nodes <list>: two node records, as Slurm prints them.
for n in node1 node2; do
  echo "NodeName=${n} Arch=x86_64 CoresPerSocket=2"
  echo "   NodeAddr=${n} NodeHostName=${n} Version=25.05.0"
done
EOF

cat > "${STUBS}/bin/srun" <<'EOF'
#!/bin/bash
# The scripts only srun the cache drop and THP setting: swallow them.
exit 0
EOF

cat > "${STUBS}/bin/sudo" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "${STUBS}/bin/fi_info" <<'EOF'
#!/bin/bash
echo "provider: efa"
echo "    fabric: efa"
EOF

cat > "${STUBS}/bin/mpirun" <<'EOF'
#!/bin/bash
# --version answers as Open MPI. A launch is logged; when lmp is among its
# arguments, lmp runs with the arguments that follow it (and -np's value).
[ "${1:-}" = "--version" ] && { echo "mpirun (Open MPI) 4.1.7"; exit 0; }
echo "$*" >> "${MPIRUN_LOG}"
np=1
while [ $# -gt 0 ]; do
  case "$1" in
    -np) np="$2"; shift 2;;
    */lmp) bin="$1"; shift; STUB_NP="${np}" exec "${bin}" "$@";;
    *) shift;;
  esac
done
exit 0
EOF

cat > "${STUBS}/lmp-bin/lmp" <<'EOF'
#!/bin/bash
# Stub lmp: -in <deck>, -var <name> <value>. Writes log.lammps (and stdout) the
# way LAMMPS reports a run, with synthetic times.
echo "$*" >> "${LMP_LOG}"
deck=""; declare -A var=()
while [ $# -gt 0 ]; do
  case "$1" in
    -in)  deck="$2"; shift 2;;
    -var) var["$2"]="$3"; shift 3;;
    *)    echo "ERROR: stub lmp: unexpected argument '$1'"; exit 1;;
  esac
done
[ -f "${deck}" ] || { echo "ERROR: Cannot open input script ${deck}"; exit 1; }
atoms=32000
if grep -qE '^variable[[:space:]]+x[[:space:]]+index' "${deck}"; then
  atoms=$(( 32000 * ${var[x]:-1} * ${var[y]:-1} * ${var[z]:-1} ))
fi
{
  echo "LAMMPS (stub)"
  while read -r cmd arg rest; do
    [ "${cmd}" = "run" ] || continue
    case "${arg}" in
      '${'*'}') name="${arg#\$\{}"; name="${name%\}}"
                if [ -z "${var[${name}]+set}" ]; then
                  echo "ERROR: Substitution for illegal variable ${name}"; exit 1
                fi
                steps="${var[${name}]}";;
      *)        steps="${arg}";;
    esac
    echo "Setting up Verlet run ..."
    echo "Loop time of 12.5 on ${STUB_NP:-1} procs for ${steps} steps with ${atoms} atoms"
  done < "${deck}"
  echo "Total wall time: 0:00:13"
} | tee log.lammps
exit "${PIPESTATUS[0]}"
EOF

cat > "${STUBS}/bin/recorder-stub.sh" <<'EOF'
#!/bin/bash
{
  echo "ARGS: $*"
  echo "BENCHMARK_CASE=${BENCHMARK_CASE:-}"
} >> "${RECORDER_LOG}"
exit 0
EOF
chmod +x "${STUBS}"/bin/* "${STUBS}/lmp-bin/lmp"

cat > "${STUBS}/lammps-env.sh" <<EOF
export PATH="${STUBS}/lmp-bin:\${PATH}"
export LAMMPS_TAG="stub_tag"
EOF

# Synthetic decks with the bench/ decks' shape: x, y and z index variables
# where the real deck has them (in.rhodo has none), and one "run 100" line,
# aligned with spaces as in the bench/ decks.
replicated_deck() {
  printf '# synthetic %s\n\nvariable        x index 1\nvariable        y index 1\nvariable        z index 1\n\n' "$1"
  printf 'region          box block 0 ${x} 0 ${y} 0 ${z}\n# run 100 is not a run line, nor is the next one\nrerun           dump.synthetic\n\n'
  printf 'run             100\n'
}
replicated_deck in.lj > "${STUBS}/decks/in.lj"
replicated_deck in.eam > "${STUBS}/decks/in.eam"
replicated_deck in.rhodo.scaled > "${STUBS}/decks/in.rhodo.scaled"
printf '# synthetic in.rhodo\n\nread_data       data.rhodo\n\nthermo          50\nrun             100\n' > "${STUBS}/decks/in.rhodo"
echo "synthetic data" > "${STUBS}/decks/data.rhodo"
echo "synthetic potential" > "${STUBS}/decks/Cu_u3.eam"

declare -A DECK=([lj]=in.lj [rhodo]=in.rhodo [rhodo_scaled]=in.rhodo.scaled [eam]=in.eam)
declare -A EXTRA=([lj]="" [rhodo]=data.rhodo [rhodo_scaled]=data.rhodo [eam]=Cu_u3.eam)
# The defaults: SCALE, TIMESTEPS and the atom count they give
declare -A WANT_SCALE=([lj]=8 [rhodo]=1 [rhodo_scaled]=4 [eam]=4)
declare -A WANT_STEPS=([lj]=15000 [rhodo]=6000 [rhodo_scaled]=6000 [eam]=30000)
declare -A WANT_ATOMS=([lj]=16384000 [rhodo]=32000 [rhodo_scaled]=2048000 [eam]=2048000)

# run_script <script> <model> [<deck file to cache instead of the synthetic one>] [NAME=value...]
# Runs one benchmark script in a clean environment, with the model's files in
# the benchmark cache. Sets OUT (stdout and stderr), RC, BASE (BASE_DIR),
# CACHED (the cached deck), RUNDECK (the run directory's deck, if any),
# LMPLOG, MPILOG, CURLLOG, IMDSLOG, LSCPULOG, RECLOG and ERRLOG (the script's
# stderr alone).
run_script() {
  local script="$1" model="$2" deck_src="$3"; shift 3
  BASE="$(mktemp -d "${STUBS}/case.XXXXXX")"
  local cache="${BASE}/benchmarks/${model}" f
  mkdir -p "${cache}"
  cp "${deck_src:-${STUBS}/decks/${DECK[${model}]}}" "${cache}/${DECK[${model}]}"
  for f in ${EXTRA[${model}]}; do cp "${STUBS}/decks/${f}" "${cache}/${f}"; done
  CACHED="${cache}/${DECK[${model}]}"
  LMPLOG="${BASE}/lmp.log"; MPILOG="${BASE}/mpirun.log"; CURLLOG="${BASE}/curl.log"; RECLOG="${BASE}/recorder.log"
  IMDSLOG="${BASE}/imds.log"; LSCPULOG="${BASE}/lscpu.log"; ERRLOG="${BASE}/stderr.log"
  : > "${LMPLOG}"; : > "${MPILOG}"; : > "${CURLLOG}"; : > "${RECLOG}"; : > "${IMDSLOG}"; : > "${LSCPULOG}"
  : > "${ERRLOG}"
  OUT="$(cd "${BASE}" && env -i \
      PATH="${STUBS}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${BASE}" LANG=C \
      LAMMPS_ENV="${STUBS}/lammps-env.sh" BASE_DIR="${BASE}" MODEL="${model}" \
      LMP_LOG="${LMPLOG}" MPIRUN_LOG="${MPILOG}" CURL_LOG="${CURLLOG}" RECORDER_LOG="${RECLOG}" \
      IMDS_LOG="${IMDSLOG}" LSCPU_LOG="${LSCPULOG}" \
      CONTRIB_RECORDER="${STUBS}/bin/recorder-stub.sh" \
      SLURM_JOB_ID=4242 SLURM_JOB_NAME=lammps SLURM_CLUSTER_NAME=test \
      SLURM_JOB_NUM_NODES=2 SLURM_NTASKS_PER_NODE=4 SLURM_NTASKS=8 SLURM_NODELIST="node[1-2]" \
      SLURM_SUBMIT_DIR="${BASE}" \
      "$@" \
      bash "${LAMMPS_APP}/${script}" 2> >(tee "${ERRLOG}"))"
  RC=$?
  RUNDECK="$(find "${BASE}/Run" -name "${DECK[${model}]}" -type f 2>/dev/null | head -1)"
}

# has <label> <exact line>: the output holds that line
has() {
  if grep -qxF -- "$2" <<<"${OUT}"; then ok "$1"
  else bad "$1" "$2" "$(grep -E 'Timesteps|Atoms|Scale|ERROR|Run length' <<<"${OUT}" | head -6 | tr '\n' '|')"; fi
}

# lmp_args_have <label> <word...>: lmp was called once, with these words in its arguments
lmp_args_have() {
  local label="$1" args; shift
  args="$(cat "${LMPLOG}")"
  if [ "$(grep -c . "${LMPLOG}")" != 1 ]; then bad "${label}" "one lmp launch" "$(grep -c . "${LMPLOG}") launches"; return; fi
  if grep -qF -- " $* " <<<" ${args} "; then ok "${label}"; else bad "${label}" "... $* ..." "${args}"; fi
}

# The one line of the run directory's deck that differs from the cached deck
changed_lines() { diff "${CACHED}" "${RUNDECK}" | grep -E '^[<>]' | tr '\n' '|'; }

for s in "${SCRIPTS[@]}"; do
  echo "== ${s} =="

  for model in lj rhodo rhodo_scaled eam; do
    steps="${WANT_STEPS[${model}]}"; scale="${WANT_SCALE[${model}]}"; atoms="${WANT_ATOMS[${model}]}"
    run_script "${s}" "${model}" ""
    sum_before="$(sha256sum < "${STUBS}/decks/${DECK[${model}]}")"
    [ "${RC}" -eq 0 ] && ok "${model}: completes (exit 0)" || bad "${model}: completes" "exit 0" "exit ${RC}: $(tail -3 <<<"${OUT}" | tr '\n' '|')"
    lmp_args_have "${model}: lmp gets the default scale" -var x "${scale}" -var y "${scale}" -var z "${scale}"
    lmp_args_have "${model}: lmp gets the default run length" -var nsteps "${steps}"
    grep -qE '(^| )-var t ' "${LMPLOG}" && bad "${model}: no -var t" "no -var t" "$(cat "${LMPLOG}")" \
      || ok "${model}: lmp gets no -var t"
    if [ -n "${RUNDECK}" ]; then
      got="$(changed_lines)"
      want='< run             100|> run             ${nsteps}|'
      [ "${got}" = "${want}" ] && ok "${model}: the run directory's deck differs in its run line only" \
        || bad "${model}: the run directory's deck differs in its run line only" "${want}" "${got}"
    else
      bad "${model}: the deck is staged in the run directory" "a deck under Run/" "none"
    fi
    [ "$(sha256sum < "${CACHED}")" = "${sum_before}" ] && ok "${model}: the cached deck is unchanged" \
      || bad "${model}: the cached deck is unchanged" "${sum_before}" "$(sha256sum < "${CACHED}")"
    has "${model}: the results give the run length" "Timesteps run:    ${steps}"
    has "${model}: the results give the atom count" "Atoms:            ${atoms}"
    has "${model}: the results give the scale" "Scale factor:     ${scale}"
    has "${model}: the job log says how the run length is set" \
        "Run length:    ${steps} timesteps (${DECK[${model}]} runs \${nsteps})"
    grep -qxF "BENCHMARK_CASE=${model}" "${RECLOG}" && grep -qF -- "--char scale=${scale} " "${RECLOG}" \
      && ok "${model}: the recorder gets the model and its scale" \
      || bad "${model}: the recorder gets the model and its scale" "BENCHMARK_CASE=${model}, --char scale=${scale}" \
             "$(tr '\n' '|' < "${RECLOG}")"
    grep -qF -- "--char timesteps=${steps} " "${RECLOG}" \
      && ok "${model}: the recorder gets the run length" \
      || bad "${model}: the recorder gets the run length" "--char timesteps=${steps}" "$(tr '\n' '|' < "${RECLOG}")"
    [ -s "${CURLLOG}" ] && bad "${model}: nothing downloaded" "no download" "$(head -1 "${CURLLOG}")" \
      || ok "${model}: nothing downloaded (the cache holds the files)"
  done

  # Explicit overrides
  run_script "${s}" lj "" TIMESTEPS=500
  lmp_args_have "TIMESTEPS=500: lmp gets -var nsteps 500" -var nsteps 500
  has "TIMESTEPS=500: the results give 500 timesteps" "Timesteps run:    500"
  grep -qF -- "--char timesteps=500 " "${RECLOG}" && ok "TIMESTEPS=500: the recorder gets 500 timesteps" \
    || bad "TIMESTEPS=500: the recorder gets 500 timesteps" "--char timesteps=500" "$(tr '\n' '|' < "${RECLOG}")"
  run_script "${s}" lj "" TIMESTEPS=10000000
  lmp_args_have "TIMESTEPS=10000000 (the largest allowed): lmp gets it" -var nsteps 10000000
  run_script "${s}" lj "" SCALE=2
  lmp_args_have "SCALE=2: lmp gets -var x 2" -var x 2 -var y 2 -var z 2
  has "SCALE=2: the atom count follows" "Atoms:            256000"
  has "SCALE=2: the default run length stays" "Timesteps run:    15000"
  run_script "${s}" eam "" SCALE=6 TIMESTEPS=9000
  lmp_args_have "SCALE=6 TIMESTEPS=9000 together" -var x 6 -var y 6 -var z 6 -var nsteps 9000
  run_script "${s}" rhodo "" SCALE=4
  has "MODEL=rhodo, SCALE=4: still 32,000 atoms (in.rhodo has no replicate)" "Atoms:            32000"

  # A run length that is not a whole number from 1 to 10,000,000 stops the job before any launch.
  for t in 0 -5 abc 1e4 10.5 "1 000" 007 10000001 99999999999999999999; do
    run_script "${s}" lj "" TIMESTEPS="${t}"
    if [ "${RC}" -ne 0 ] && grep -qF "ERROR: TIMESTEPS must be a whole number from 1 to 10000000, such as 15000 (got '${t}')" <<<"${OUT}" \
        && [ ! -s "${LMPLOG}" ] && ! grep -q 'LAMMPS benchmark results' <<<"${OUT}"; then
      ok "TIMESTEPS='${t}': refused before any launch"
    else
      bad "TIMESTEPS='${t}': refused before any launch" "exit != 0, the ERROR line, no lmp, no results" \
          "exit ${RC}; lmp launches $(grep -c . "${LMPLOG}"); $(grep -E 'ERROR' <<<"${OUT}" | head -1)"
    fi
  done

  # A deck whose run line cannot be set stops the job before any launch, with
  # an ERROR line that says why (the count, or the one run line itself), and
  # the cached deck is left as it was.
  bad_decks=("no-run" "two-runs" "run-with-keywords" "run-variable" "run-nsteps")
  declare -A bad_reason=(
    [no-run]="in.lj has 0 run lines; exactly one plain 'run <steps>' line is needed to set the run length"
    [two-runs]="in.lj has 2 run lines; exactly one plain 'run <steps>' line is needed to set the run length"
    [run-with-keywords]="in.lj: its run line is 'run 100 post no'; a plain 'run <steps>' line is needed to set the run length"
    [run-variable]="in.lj: its run line is 'run \${t}'; a plain 'run <steps>' line is needed to set the run length"
    [run-nsteps]="in.lj: its run line is 'run \${nsteps}'; a plain 'run <steps>' line is needed to set the run length"
  )
  printf 'variable        x index 1\nvariable        y index 1\nvariable        z index 1\nthermo 50\n' \
    > "${STUBS}/decks/no-run"
  printf 'variable        x index 1\nvariable        y index 1\nvariable        z index 1\nrun 100\nrun 100\n' \
    > "${STUBS}/decks/two-runs"
  printf 'variable        x index 1\nvariable        y index 1\nvariable        z index 1\nrun 100 post no\n' \
    > "${STUBS}/decks/run-with-keywords"
  printf 'variable        x index 1\nvariable        y index 1\nvariable        z index 1\nrun ${t}\n' \
    > "${STUBS}/decks/run-variable"
  printf 'variable        x index 1\nvariable        y index 1\nvariable        z index 1\nrun ${nsteps}\n' \
    > "${STUBS}/decks/run-nsteps"
  for d in "${bad_decks[@]}"; do
    run_script "${s}" lj "${STUBS}/decks/${d}"
    if [ "${RC}" -ne 0 ] && grep -qxF "ERROR: ${bad_reason[${d}]}" <<<"${OUT}" \
        && [ ! -s "${LMPLOG}" ] && ! grep -q 'LAMMPS benchmark results' <<<"${OUT}" \
        && cmp -s "${STUBS}/decks/${d}" "${CACHED}"; then
      ok "deck '${d}': refused before any launch, saying why; the cached deck unchanged"
    else
      bad "deck '${d}': refused before any launch, saying why; the cached deck unchanged" \
          "exit != 0, 'ERROR: ${bad_reason[${d}]}', no lmp, no results" \
          "exit ${RC}; lmp launches $(grep -c . "${LMPLOG}"); $(grep -E 'ERROR' <<<"${OUT}" | head -1)"
    fi
  done

  # Any plain run length in the cached deck is replaced, with its whitespace.
  printf 'variable x index 1\nvariable y index 1\nvariable z index 1\n\t run \t 250 \t\n' > "${STUBS}/decks/tabs-250"
  run_script "${s}" lj "${STUBS}/decks/tabs-250"
  got="$(changed_lines)"
  want="$(printf '< \t run \t 250 \t|> \t run \t ${nsteps} \t|')"
  [ "${got}" = "${want}" ] && ok "a 'run 250' line with tabs: replaced, whitespace kept" \
    || bad "a 'run 250' line with tabs: replaced, whitespace kept" "${want}" "${got}"
  has "a 'run 250' line with tabs: the default run length runs" "Timesteps run:    15000"
done

# ---------------------------------------------------------------------------
# Rank placement (x86 only: the Arm script has no flexible-cores lists). The
# lists and the cores-per-node check apply on hpc8a.96xlarge and
# hpc7a.96xlarge only; every other instance type and size maps ranks by slot.
# ---------------------------------------------------------------------------
echo "== x86/lammps-benchmark.sbatch: rank placement =="
X86=x86/lammps-benchmark.sbatch
LIST48="$(seq -s, 0 4 188)"   # the flexible-cores list for 48 ranks per node
LIST96="$(seq -s, 0 2 190)"   # and for 96

# on_node <instance type> <cores per node> <cores the node has> [NAME=value...]:
# run the x86 script with MODEL=lj on 2 nodes of that layout
on_node() {
  local itype="$1" cpn="$2" cpus="$3"; shift 3
  run_script "${X86}" lj "" STUB_INSTANCE_TYPE="${itype}" SLURM_NTASKS_PER_NODE="${cpn}" \
      SLURM_NTASKS=$(( 2 * cpn )) SLURM_CPUS_ON_NODE="${cpus}" "$@"
}

# binds <label> <expected placement flags> [<NOTE line>]: the run completed, and mpirun got exactly these
# placement flags (and stderr holds the NOTE line, when one is given)
binds() {
  local got
  got="$(grep -oE -- '--bind-to [^ ]+( --map-by [^ ]+| --cpu-list [0-9,]+)' "${MPILOG}" | head -1)"
  if [ "${RC}" -eq 0 ] && [ "$(grep -c . "${MPILOG}")" = 1 ] && [ "${got}" = "$2" ] \
      && { [ -z "${3:-}" ] || grep -qxF -- "$3" "${ERRLOG}"; }; then ok "$1"
  else bad "$1" "exit 0 and mpirun ${2:0:80}${3:+, and the NOTE}" \
           "exit ${RC}; mpirun ${got:0:80}; $(grep -E 'ERROR|NOTE: the instance' <<<"${OUT}" | head -1)"; fi
}

# refused <label> <node> <cores per node> [<on>] [<NOTE line>]: stopped before the run directory, naming the
# supported counts on stderr ("on <on> use ...", by default "on this type"; and stderr holds the NOTE line, when one
# is given)
refused() {
  local want="ERROR: $3 cores per node would load the 24 CCDs of $2 unevenly; on ${4:-this type} use 24, 48, 72, 96, 120, 144, 168 or 192 (--ntasks-per-node; see Utils/flexible-cores/)"
  if [ "${RC}" -ne 0 ] && grep -qxF "${want}" "${ERRLOG}" && [ ! -s "${MPILOG}" ] && [ ! -s "${LMPLOG}" ] \
      && [ ! -e "${BASE}/Run" ] && { [ -z "${5:-}" ] || grep -qxF -- "$5" "${ERRLOG}"; }; then ok "$1"
  else bad "$1" "exit != 0, '${want:0:60}...', no launch, no run directory${5:+, and the NOTE}" \
           "exit ${RC}; mpirun launches $(grep -c . "${MPILOG}"); $(grep -E 'ERROR|NOTE: the instance' <<<"${OUT}" | head -2 | tr '\n' '|')"; fi
}

on_node hpc8a.96xlarge 48 192
binds "hpc8a.96xlarge, 48 ranks per node: the flexible-cores list" "--bind-to cpu-list:ordered --cpu-list ${LIST48}"
on_node hpc7a.96xlarge 96 192
binds "hpc7a.96xlarge, 96 ranks per node: the flexible-cores list" "--bind-to cpu-list:ordered --cpu-list ${LIST96}"
on_node hpc8a.96xlarge 192 192
binds "hpc8a.96xlarge, a full node: by slot" "--bind-to core --map-by slot"
on_node hpc8a.96xlarge 96 192 THREADS_PER_RANK=2
binds "hpc8a.96xlarge, 48 ranks x 2 threads (96 cores): hybrid placement" "--bind-to core --map-by ppr:48:node:PE=2"

# Other instance types and sizes get no list, whatever the count: 48 ranks on a
# 96-core node must not name cores above 95.
for layout in "hpc6a.48xlarge 48 96" "hpc7a.48xlarge 48 96" "hpc6a.48xlarge 64 96" "c7a.48xlarge 48 192"; do
  read -r itype cpn cpus <<<"${layout}"
  on_node "${itype}" "${cpn}" "${cpus}"
  binds "${itype}, ${cpn} ranks per node on ${cpus} cores: no list, by slot" "--bind-to core --map-by slot"
done

# On hpc8a.96xlarge and hpc7a.96xlarge any other count stops the job before anything starts.
for layout in "hpc8a.96xlarge 64" "hpc8a.96xlarge 16" "hpc7a.96xlarge 32" "hpc7a.96xlarge 128" "hpc8a.96xlarge 384"; do
  read -r itype cpn <<<"${layout}"
  on_node "${itype}" "${cpn}" 192
  refused "${itype}, ${cpn} cores per node: refused before the run directory, naming the counts" "${itype}" "${cpn}"
done
on_node hpc8a.96xlarge 64 192 THREADS_PER_RANK=2
refused "hpc8a.96xlarge, 32 ranks x 2 threads (64 cores): refused, the count is cores per node" hpc8a.96xlarge 64

# When IMDS gives no instance type (no answer, an HTTP error, or an answer that
# is not an instance type name, capitals included), lscpu decides: a node with
# a 192-core AMD CPU could be an hpc8a or hpc7a.96xlarge, so it gets their
# check and lists; any other node runs by slot. Either way a NOTE says which,
# wherever the type would change what the job does (a count outside the list,
# or a pure-MPI count below 192); a full node, or a hybrid layout at a
# supported count, gets neither lscpu nor a NOTE. No run is refused only
# because IMDS did not answer. (The instance type on_node sets is the node's,
# which IMDS does not give here.)
NOTE_AMD="NOTE: the instance type could not be read from the instance metadata, and lscpu shows a 192-core AMD CPU, as on hpc8a.96xlarge and hpc7a.96xlarge, so their flexible-cores check and lists apply"
NOTE_SKIP="NOTE: the instance type could not be read from the instance metadata and lscpu shows no 192-core AMD CPU, so the flexible-cores check for hpc8a.96xlarge and hpc7a.96xlarge is skipped"
for imds in no-answer error-page not-a-type; do
  on_node hpc8a.96xlarge 64 192 STUB_IMDS="${imds}" STUB_LSCPU=amd192
  refused "IMDS ${imds}, a 192-core AMD node, 64 cores per node: refused before the run directory, naming the counts" \
      "this 192-core AMD node" 64 "this node" "${NOTE_AMD}"
  on_node hpc8a.96xlarge 96 192 STUB_IMDS="${imds}" STUB_LSCPU=amd192
  binds "IMDS ${imds}, a 192-core AMD node, 96 ranks per node: the flexible-cores list" \
      "--bind-to cpu-list:ordered --cpu-list ${LIST96}" "${NOTE_AMD}"
  on_node c8i.96xlarge 64 192 STUB_IMDS="${imds}" STUB_LSCPU=intel192
  binds "IMDS ${imds}, a 192-core Intel node, 64 cores per node: runs by slot, with a NOTE" \
      "--bind-to core --map-by slot" "${NOTE_SKIP}"
  on_node hpc6a.48xlarge 48 96 STUB_IMDS="${imds}" STUB_LSCPU=amd96
  binds "IMDS ${imds}, a 96-core AMD node, 48 ranks per node: runs by slot, with a NOTE" \
      "--bind-to core --map-by slot" "${NOTE_SKIP}"
  # 192 CPUs from 96 cores with two threads each: the check counts cores.
  on_node m6a.48xlarge 64 192 STUB_IMDS="${imds}" STUB_LSCPU=amd96-smt
  binds "IMDS ${imds}, a 96-core AMD node with SMT on (192 CPUs), 64 cores per node: runs by slot, with a NOTE" \
      "--bind-to core --map-by slot" "${NOTE_SKIP}"
done
on_node hpc8a.96xlarge 64 192 STUB_IMDS=no-answer STUB_LSCPU=amd192-indented
refused "IMDS no-answer, lscpu's indented layout, a 192-core AMD node, 64 cores per node: refused" \
    "this 192-core AMD node" 64 "this node" "${NOTE_AMD}"
on_node hpc8a.96xlarge 64 192 STUB_IMDS=no-answer STUB_LSCPU=fail
binds "IMDS no-answer, lscpu fails: runs by slot, with a NOTE" "--bind-to core --map-by slot" "${NOTE_SKIP}"
# Exactly 192 AMD cores, sockets x cores per socket: 96 on one socket, and 2 x 128, are other nodes.
on_node hpc8a.96xlarge 64 96 STUB_IMDS=no-answer STUB_LSCPU=amd96-1s
binds "IMDS no-answer, an AMD node with 96 cores on one socket, 64 cores per node: runs by slot, with a NOTE" \
    "--bind-to core --map-by slot" "${NOTE_SKIP}"
on_node hpc8a.96xlarge 64 256 STUB_IMDS=no-answer STUB_LSCPU=amd256
binds "IMDS no-answer, an AMD node with 2 x 128 cores, 64 cores per node: runs by slot, with a NOTE" \
    "--bind-to core --map-by slot" "${NOTE_SKIP}"
# An answer in capitals is not an instance type name, in any locale.
on_node HPC8A.96XLARGE 64 192 STUB_LSCPU=amd192
refused "the answer HPC8A.96XLARGE, a 192-core AMD node, 64 cores per node: refused before the run directory" \
    "this 192-core AMD node" 64 "this node" "${NOTE_AMD}"
# A type name inside other text is not a type name: the test's ^ and $ (a page naming a host, a type and more).
for answer in "Request denied by proxy.example.com" "hpc8a.96xlarge: not found"; do
  on_node "${answer}" 64 192 STUB_LSCPU=amd192
  refused "the answer '${answer}', a 192-core AMD node, 64 cores per node: refused before the run directory" \
      "this 192-core AMD node" 64 "this node" "${NOTE_AMD}"
done
# quiet <label> <expected placement flags>: binds, and no NOTE about the instance type, and no lscpu call
quiet() {
  if ! grep -q '^NOTE: the instance type' "${ERRLOG}" && [ ! -s "${LSCPULOG}" ]; then
    binds "$1" "$2"
  else
    bad "$1" "no NOTE, no lscpu call" \
        "exit ${RC}; $(grep -E '^NOTE: the instance' "${ERRLOG}" | head -1); lscpu calls $(grep -c . "${LSCPULOG}")"
  fi
}
# Where the type changes nothing, no lscpu and no NOTE: a full node, and a hybrid layout at a supported count.
on_node c8i.96xlarge 192 192 STUB_IMDS=no-answer STUB_LSCPU=intel192
quiet "IMDS no-answer, a 192-core Intel node, a full node: by slot, no NOTE, and lscpu is not run" \
    "--bind-to core --map-by slot"
on_node hpc8a.96xlarge 192 192 STUB_IMDS=no-answer STUB_LSCPU=amd192
quiet "IMDS no-answer, a 192-core AMD node, a full node: by slot, no NOTE, and lscpu is not run" \
    "--bind-to core --map-by slot"
on_node hpc8a.96xlarge 96 192 STUB_IMDS=no-answer STUB_LSCPU=amd192 THREADS_PER_RANK=2
quiet "IMDS no-answer, a 192-core AMD node, 48 ranks x 2 threads (96 cores): hybrid, no NOTE, and lscpu is not run" \
    "--bind-to core --map-by ppr:48:node:PE=2"
# A type name with an i reads as one in a Turkish locale too, where [a-z] leaves out i.
on_node c8i.96xlarge 64 192 STUB_LSCPU=intel192 LANG=tr_TR.UTF-8
quiet "c8i.96xlarge from IMDS, a Turkish locale, 64 cores per node: by slot, no NOTE, and lscpu is not run" \
    "--bind-to core --map-by slot"

# Every IMDS call gives up within a few seconds and fails on an HTTP error;
# and when IMDS gives the instance type, no NOTE is printed and lscpu is not run.
on_node hpc8a.96xlarge 48 192 STUB_LSCPU=amd192
timeout_re='(^| )--connect-timeout [1-9][0-9]?( |$)'
max_time_re='(^| )--max-time ([1-9]|10)( |$)'
fail_re='(^| )(--fail|-f[a-zA-Z]*|-[a-zA-Z]+f[a-zA-Z]*)( |$)'
untimed=0
while read -r call; do
  [[ "${call}" =~ ${timeout_re} ]] && [[ "${call}" =~ ${max_time_re} ]] && [[ "${call}" =~ ${fail_re} ]] \
    || untimed=$(( untimed + 1 ))
done < "${IMDSLOG}"
if [ "$(grep -c . "${IMDSLOG}")" -ge 2 ] && [ "${untimed}" = 0 ]; then
  ok "every IMDS call has a connect timeout, a total timeout of at most 10 s and -f"
else
  bad "every IMDS call has a connect timeout, a total timeout of at most 10 s and -f" \
      "--connect-timeout N --max-time M (M <= 10) and -f on each call" "$(tr '\n' '|' < "${IMDSLOG}")"
fi
if [ "${RC}" -eq 0 ] && ! grep -q '^NOTE: the instance type' <<<"${OUT}" && [ ! -s "${LSCPULOG}" ]; then
  ok "an instance type from IMDS: no NOTE, and lscpu is not run"
else
  bad "an instance type from IMDS: no NOTE, and lscpu is not run" "exit 0, no NOTE, no lscpu call" \
      "exit ${RC}; $(grep -E '^NOTE: the instance' <<<"${OUT}" | head -1); lscpu calls $(grep -c . "${LSCPULOG}")"
fi
# The same for another 192-core AMD type that IMDS names: no check and no
# list, even at a count the two types refuse.
on_node c7a.48xlarge 64 192 STUB_LSCPU=amd192
label="c7a.48xlarge from IMDS on a 192-core AMD CPU, 64 cores per node: by slot, no NOTE, and lscpu is not run"
if ! grep -q '^NOTE: the instance type' <<<"${OUT}" && [ ! -s "${LSCPULOG}" ]; then
  binds "${label}" "--bind-to core --map-by slot"
else
  bad "${label}" "no NOTE, no lscpu call" \
      "exit ${RC}; $(grep -E '^NOTE: the instance' <<<"${OUT}" | head -1); lscpu calls $(grep -c . "${LSCPULOG}")"
fi

echo
printf 'sbatch e2e tests: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
