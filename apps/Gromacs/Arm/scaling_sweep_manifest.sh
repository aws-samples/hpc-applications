#!/bin/bash
# Phase 2 GROMACS scaling sweep manifest
# ---------------------------------------------------------------------------
# Submits the 24-job aarch64 scaling sweep:
#
#   (1N, 2N, 4N) x {benchMEM, benchPEP-h} x N replicates  on hpc7g  = 12 jobs
#   (1N, 2N, 4N) x {benchMEM, benchPEP-h} x N replicates  on m8g    = 12 jobs
#                                                                     ----
# The spec text reads "3 replicates" and "24 jobs" — the same wording-vs-math
# discrepancy noted for the x86 sweep. We honour the explicit "24 jobs" tally:
#   3 node counts x 2 models x 2 replicates per partition x 2 partitions = 24
# REPLICATES defaults to 2 to land on the spec's 24 figure; pass
# REPLICATES=3 if you want 36 jobs for tighter error bars (the chart
# pipeline at Doc/img/Gromacs/generate_charts.py consumes either shape).
#
# This script is INTENDED TO BE RUN ON THE HEAD NODE OF THE Arm cluster
# (ec2-user@10.3.51.188, reached via bastion 3.128.184.207) AFTER all
# prerequisites are green:
#
#   [ ] — build_gromacs_arm.sbatch has been submitted on hpc7g
#                  (default OpenMPI 5) AND m8g (OpenMPI 5 forced) and
#                  produced the matching tmpi + ompi5 install trees:
#
#                    ls /fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/{tmpi,ompi}/bin/gmx*
#                    ls /fsx/gromacs/aarch64-graviton4-ompi5/v2024.4/{tmpi,ompi}/bin/gmx*
#                    /fsx/gromacs/aarch64-graviton3-ompi5/v2024.4/tmpi/bin/gmx --version | head
#                    /fsx/gromacs/aarch64-graviton4-ompi5/v2024.4/tmpi/bin/gmx --version | head
#
#                  The version output for both must report
#                  "Acceleration most likely to fit this hardware: ARM_SVE".
#                  If the Graviton4 build is missing, jobs on the m8g half
#                  of this manifest will fail at GROMACS_ENV auto-discovery.
#
#   [ ] — Gromacs_Benchmarks table is ACTIVE in us-east-1 (already
#                  provisioned during Phase 1; verify before re-running):
#
#                    aws dynamodb describe-table \
#                      --table-name Gromacs_Benchmarks \
#                      --region us-east-1 --query 'Table.TableStatus' \
#                      --output text
#                    # Expected: ACTIVE
#
#   [ ] — dynamodb:PutItem is attached to the Arm cluster compute
#                  role. The Phase 1 IAM policy targeted the x86 cluster
#                  role; re-confirm the Arm role has the same scoped
#                  inline policy attached. Smoke-test with a put-item
#                  from a compute node:
#
#                    salloc -p hpc7g --nodes=1 --time=00:05:00 \
#                      bash -lc 'aws dynamodb put-item \
#                        --table-name Gromacs_Benchmarks --region us-east-1 \
#                        --item "{\"job_id\":{\"S\":\"smoke-test-arm\"},\
#                        \"config\":{\"S\":\"0N-0rpn-test\"}}" && \
#                      aws dynamodb delete-item \
#                        --table-name Gromacs_Benchmarks --region us-east-1 \
#                        --key "{\"job_id\":{\"S\":\"smoke-test-arm\"},\
#                        \"config\":{\"S\":\"0N-0rpn-test\"}}"'
#
#   [ ] — gromacs-benchmark.sbatch has been smoke-tested on hpc7g
#                  (1N, MODEL=RNAse) AND m8g (1N, MODEL=benchMEM) and a
#                  4N benchPEP-h job on m8g at --ntasks-per-node=192 has
#                  produced a parseable Performance: line. Verify with:
#
#                    sbatch -p hpc7g --nodes=1 --export=ALL,MODEL=RNAse \
#                      /fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch
#                    sbatch -p m8g --nodes=1 --ntasks-per-node=192 \
#                      --export=ALL,MODEL=benchMEM \
#                      /fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch
#                    # then check resulting slurm logs for non-zero ns/day
#                    # values and corresponding rows in Gromacs_Benchmarks.
#
#   [ ] cluster copy — /fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch
#                       exists with the DynamoDB call site UNCOMMENTED. The
#                       public-repo copy keeps the block commented (every
#                       line of the trailing block prefixed with `# `).
#
# Until all five boxes are checked, DO NOT run this manifest. Submitting
# the full 24 jobs blindly burns hpc7g/m8g hours and may produce records
# the chart pipeline cannot consume (e.g. if the Arm benchmark script's
# parser is broken or m8g jobs land at 64 ranks/node instead of 192).
# The smoke runs in tasks 11 and 13 are cheap and catch this.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---- knobs ----------------------------------------------------------------
GROMACS_TAG="${GROMACS_TAG:-v2024.4}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
# Cluster-side launcher (DynamoDB call site uncommented at deploy time).
CLUSTER_BENCH="${CLUSTER_BENCH:-/fsx/gromacs/scripts/Arm/gromacs-benchmark.sbatch}"
# Node counts and models per the spec.
NODE_COUNTS=(1 2 4)
MODELS=(benchMEM benchPEP-h)
# 2 replicates per (partition, model, node-count) cell -> 12 jobs/partition
# -> 24 jobs total, matching the spec's "24 jobs" tally. Override with
# REPLICATES=3 to land on the alternative 36-job interpretation.
REPLICATES="${REPLICATES:-2}"
# Partitions per the spec (Phase 2 Arm cluster).
PARTITIONS=(hpc7g m8g)
# ntasks-per-node per partition: hpc7g is 64 vCPUs / Graviton3E (Neoverse V1),
# m8g is 192 vCPUs / Graviton4 (Neoverse V2) — both single-socket. The
# launcher's default is 64 (hpc7g-shaped); we override per-partition here
# so a 4N m8g benchPEP-h job lands at 768 ranks total.
declare -A RPN
RPN[hpc7g]=64
RPN[m8g]=192

# ---- preflight ------------------------------------------------------------
if [ ! -x "${CLUSTER_BENCH}" ]; then
    echo "ERROR: cluster benchmark launcher not found or not executable:" >&2
    echo "       ${CLUSTER_BENCH}" >&2
    echo "       Deploy from apps/Gromacs/Arm/gromacs-benchmark.sbatch and" >&2
    echo "       uncomment the DynamoDB record block before continuing." >&2
    exit 1
fi
for partition in "${PARTITIONS[@]}"; do
    if ! sinfo -h -p "${partition}" -o '%P' 2>/dev/null | grep -q "${partition}"; then
        echo "ERROR: partition '${partition}' not visible to sinfo" >&2
        echo "       Are you on the Arm cluster head node?" >&2
        exit 1
    fi
done
# Quick sanity: at least one OpenMPI 5 env script exists for the pinned tag
# under each per-architecture install root. Phase 2 default is OpenMPI 5
# on both Graviton3E and Graviton4; we don't preflight the legacy
# Graviton3E + OpenMPI 4 path because the manifest doesn't submit jobs
# that need it.
for ARCH_DIR in \
        "${BASE_DIR}/aarch64-graviton3-ompi5/${GROMACS_TAG}" \
        "${BASE_DIR}/aarch64-graviton4-ompi5/${GROMACS_TAG}"; do
    if ! ls "${ARCH_DIR}"/gromacs-*-ompi5-env.sh >/dev/null 2>&1; then
        echo "ERROR: no GROMACS OpenMPI 5 env scripts found under" >&2
        echo "       ${ARCH_DIR}/" >&2
        echo "       Run build_gromacs_arm.sbatch first on the" >&2
        echo "       matching partition." >&2
        exit 1
    fi
done

mkdir -p "${BASE_DIR}/logs"

# ---- submission loop ------------------------------------------------------
SUBMITTED=()
echo "=== Phase 2 GROMACS scaling sweep submission plan ==="
echo "Tag:        ${GROMACS_TAG}"
echo "Launcher:   ${CLUSTER_BENCH}"
echo "Partitions: ${PARTITIONS[*]}"
echo "Node sweep: ${NODE_COUNTS[*]}"
echo "Models:     ${MODELS[*]}"
echo "Replicates: ${REPLICATES}"
echo "Ranks/node: hpc7g=${RPN[hpc7g]}, m8g=${RPN[m8g]}"
echo
echo "Total jobs to submit: $(( ${#PARTITIONS[@]} * ${#NODE_COUNTS[@]} * ${#MODELS[@]} * REPLICATES )) (spec target: 24)"
echo
read -r -p "Proceed with submission? [y/N] " ans
case "${ans}" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac

for partition in "${PARTITIONS[@]}"; do
    rpn="${RPN[${partition}]}"
    for nodes in "${NODE_COUNTS[@]}"; do
        for model in "${MODELS[@]}"; do
            for ((r=1; r<=REPLICATES; r++)); do
                name="gmx-${partition}-${model}-${nodes}N-r${r}"
                jid=$(sbatch \
                    -p "${partition}" \
                    --nodes="${nodes}" \
                    --ntasks-per-node="${rpn}" \
                    --job-name="${name}" \
                    --export="ALL,MODEL=${model},GROMACS_TAG=${GROMACS_TAG}" \
                    --parsable \
                    "${CLUSTER_BENCH}")
                printf '  submitted %-40s -> jobid %s\n' "${name}" "${jid}"
                SUBMITTED+=("${jid}")
            done
        done
    done
done

echo
echo "=== ${#SUBMITTED[@]} jobs submitted ==="
echo "Tail with: squeue -u \"\${USER}\" | head"
echo "Or watch:  watch -n 10 'squeue -u \"\${USER}\"'"
echo
echo "Once all jobs reach state CD (completed), confirm DynamoDB has the"
echo "records with apps/Gromacs/dynamodb/scan_sweep.sh — see that script's"
echo "comment header for what to do with the output."

# ---------------------------------------------------------------------------
# Inline submission table (also valid for manual one-shot submission, e.g.
# if you'd rather paste lines into a terminal than run this whole script):
#
#   # hpc7g (Graviton3E, 64 ranks/node, OpenMPI 5)
#   sbatch -p hpc7g --nodes=1 --ntasks-per-node=64 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x2
#   sbatch -p hpc7g --nodes=1 --ntasks-per-node=64 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x2
#   sbatch -p hpc7g --nodes=2 --ntasks-per-node=64 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x2
#   sbatch -p hpc7g --nodes=2 --ntasks-per-node=64 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x2
#   sbatch -p hpc7g --nodes=4 --ntasks-per-node=64 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x2
#   sbatch -p hpc7g --nodes=4 --ntasks-per-node=64 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x2
#
#   # m8g (Graviton4, 192 ranks/node, OpenMPI 5 — required)
#   sbatch -p m8g --nodes=1 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x2
#   sbatch -p m8g --nodes=1 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x2
#   sbatch -p m8g --nodes=2 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x2
#   sbatch -p m8g --nodes=2 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x2
#   sbatch -p m8g --nodes=4 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x2
#   sbatch -p m8g --nodes=4 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x2
# ---------------------------------------------------------------------------
