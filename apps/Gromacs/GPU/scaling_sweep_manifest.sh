#!/bin/bash
# Phase 3 GROMACS scaling sweep manifest
# ---------------------------------------------------------------------------
# Submits the 32-job GPU scaling sweep:
#
#   (1, 2, 4, 8 GPUs) x {benchMEM, benchPEP-h} x N replicates  on g6e = 16 jobs
#   (1, 2, 4, 8 GPUs) x {benchMEM, benchPEP-h} x N replicates  on p5  = 16 jobs
#                                                                       ----
# Same wording-vs-math convention as tasks 8.1 and 14.2: the spec text says
# "Phase 3 chart sweep (1, 2, 4, 8 GPUs on g6e and p5; benchMEM and
# benchPEP-h)". 4 GPU counts x 2 models x 2 replicates per partition x 2
# partitions = 32 jobs at REPLICATES=2; pass REPLICATES=3 if you'd rather
# collect 48 jobs up front for tighter error bars (the chart pipeline at
# Doc/img/Gromacs/generate_charts.py consumes either shape).
#
# All jobs are SINGLE NODE on g6e and p5 — both instance families ship up to
# 8 GPUs in one chassis, and the launcher's GPU_COUNT validation tops out at
# min(8, nvidia-smi -L count). Multi-node GPU runs (Library_MPI under
# mpirun) are out of Phase 3 scope and are not part of
# this manifest. The launcher still supports them when GPU_COUNT exceeds
# GPUs/node — see apps/Gromacs/GPU/gromacs-benchmark.sbatch for the path.
#
# This script is INTENDED TO BE RUN ON THE HEAD NODE OF A GPU CLUSTER
# (reached via the same bastion as the CPU clusters) AFTER all
# prerequisites are green:
#
#   [ ] — build_gromacs_gpu.sbatch has been submitted on g6e (L40S)
#                  AND p5 (H100) and produced the matching tmpi + ompi
#                  install trees:
#
#                    ls /fsx/gromacs/x86_64-cuda12-l40s/v2024.4/{tmpi,ompi}/bin/gmx*
#                    ls /fsx/gromacs/x86_64-cuda12-h100/v2024.4/{tmpi,ompi}/bin/gmx*
#                    /fsx/gromacs/x86_64-cuda12-l40s/v2024.4/tmpi/bin/gmx --version | head
#                    /fsx/gromacs/x86_64-cuda12-h100/v2024.4/tmpi/bin/gmx --version | head
#
#                  The version output for both must report
#                  "GPU support: CUDA" and the host SIMD line must include
#                  AVX_512 — Phase 3 preserves the AVX-512 host code path.
#                  If the H100 build is missing, jobs on the p5 half of
#                  this manifest will fail at GROMACS_ENV auto-discovery.
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
#   [ ] — dynamodb:PutItem is attached to the GPU cluster compute
#                  role. The Phase 1 IAM policy targeted the x86 cluster
#                  role and Phase 2 added the Arm cluster role; Phase 3
#                  needs the same scoped inline policy on the GPU
#                  cluster's compute role too. Smoke-test from a compute
#                  node:
#
#                    salloc -p g6e --nodes=1 --gres=gpu:1 --time=00:05:00 \
#                      bash -lc 'aws dynamodb put-item \
#                        --table-name Gromacs_Benchmarks --region us-east-1 \
#                        --item "{\"job_id\":{\"S\":\"smoke-test-gpu\"},\
#                        \"config\":{\"S\":\"0N-0rpn-test\"}}" && \
#                      aws dynamodb delete-item \
#                        --table-name Gromacs_Benchmarks --region us-east-1 \
#                        --key "{\"job_id\":{\"S\":\"smoke-test-gpu\"},\
#                        \"config\":{\"S\":\"0N-0rpn-test\"}}"'
#
#   [ ] — gromacs-benchmark.sbatch has been smoke-tested on g6e
#                  (1 GPU, MODEL=RNAse) AND p5 (1 GPU, MODEL=benchMEM) AND
#                  multi-GPU (4-GPU benchMEM on g6e and 8-GPU benchMEM on
#                  p5) and each produced a parseable Performance: line.
#                  GPU_COUNT validation must reject out-of-range values
#                  (GPU_COUNT=0, GPU_COUNT=9, GPU_COUNT=GPUs+1) before
#                  launching the sweep:
#
#                    sbatch -p g6e --nodes=1 --gres=gpu:1 \
#                      --export=ALL,MODEL=RNAse,GPU_COUNT=1 \
#                      /fsx/gromacs/scripts/GPU/gromacs-benchmark.sbatch
#                    sbatch -p p5 --nodes=1 --gres=gpu:8 \
#                      --export=ALL,MODEL=benchMEM,GPU_COUNT=8 \
#                      /fsx/gromacs/scripts/GPU/gromacs-benchmark.sbatch
#                    # then check resulting slurm logs for non-zero ns/day
#                    # values, the "GPU topology:" classification line, and
#                    # corresponding rows in Gromacs_Benchmarks with
#                    # gpu_count and cuda_version attributes populated.
#
#   [ ] cluster copy — /fsx/gromacs/scripts/GPU/gromacs-benchmark.sbatch
#                       exists with the DynamoDB call site UNCOMMENTED. The
#                       public-repo copy keeps the block commented (every
#                       line of the trailing block prefixed with `# `).
#                       Phase 3 records additionally export GPU_COUNT and
#                       CUDA_VERSION so the recorder appends those fields
#                       to the DynamoDB record.
#
# Until all five boxes are checked, DO NOT run this manifest. Submitting
# the full 32 jobs blindly burns g6e/p5 hours (p5 in particular is
# expensive) and may produce records the chart pipeline cannot consume
# (e.g. if GPU_COUNT validation is broken or topology classification is
# misreporting NVSwitch as PCIe). The smoke runs in tasks 17 and 18 are
# cheap relative to the sweep and catch this.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---- knobs ----------------------------------------------------------------
GROMACS_TAG="${GROMACS_TAG:-v2024.4}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
# Cluster-side launcher (DynamoDB call site uncommented at deploy time).
CLUSTER_BENCH="${CLUSTER_BENCH:-/fsx/gromacs/scripts/GPU/gromacs-benchmark.sbatch}"
# GPU counts and models per the spec.
GPU_COUNTS=(1 2 4 8)
MODELS=(benchMEM benchPEP-h)
# 2 replicates per (partition, model, gpu-count) cell -> 16 jobs/partition
# -> 32 jobs total. Override with REPLICATES=3 for 48 jobs.
REPLICATES="${REPLICATES:-2}"
# Partitions per the spec (Phase 3 GPU cluster).
PARTITIONS=(g6e p5)
# GPUs available per partition. Both g6e and p5 SKUs in this sweep ship
# 8 GPUs/node (g6e.48xlarge / p5.48xlarge); --gres=gpu:N is set to the
# requested GPU_COUNT so the scheduler reserves exactly N GPUs per job.

# ---- preflight ------------------------------------------------------------
if [ ! -x "${CLUSTER_BENCH}" ]; then
    echo "ERROR: cluster benchmark launcher not found or not executable:" >&2
    echo "       ${CLUSTER_BENCH}" >&2
    echo "       Deploy from apps/Gromacs/GPU/gromacs-benchmark.sbatch and" >&2
    echo "       uncomment the DynamoDB record block before continuing." >&2
    exit 1
fi
for partition in "${PARTITIONS[@]}"; do
    if ! sinfo -h -p "${partition}" -o '%P' 2>/dev/null | grep -q "${partition}"; then
        echo "ERROR: partition '${partition}' not visible to sinfo" >&2
        echo "       Are you on the GPU cluster head node?" >&2
        exit 1
    fi
done
# Quick sanity: at least one tmpi env script exists for the pinned tag
# under each per-GPU install root. Phase 3 single-node multi-GPU runs use
# the Thread_MPI variant exclusively.
for ARCH_DIR in \
        "${BASE_DIR}/x86_64-cuda12-l40s/${GROMACS_TAG}" \
        "${BASE_DIR}/x86_64-cuda12-h100/${GROMACS_TAG}"; do
    if ! ls "${ARCH_DIR}"/gromacs-*-tmpi-env.sh >/dev/null 2>&1; then
        echo "ERROR: no GROMACS Thread_MPI env scripts found under" >&2
        echo "       ${ARCH_DIR}/" >&2
        echo "       Run build_gromacs_gpu.sbatch first on the" >&2
        echo "       matching partition." >&2
        exit 1
    fi
done

mkdir -p "${BASE_DIR}/logs"

# ---- submission loop ------------------------------------------------------
SUBMITTED=()
echo "=== Phase 3 GROMACS GPU scaling sweep submission plan ==="
echo "Tag:        ${GROMACS_TAG}"
echo "Launcher:   ${CLUSTER_BENCH}"
echo "Partitions: ${PARTITIONS[*]}"
echo "GPU sweep:  ${GPU_COUNTS[*]}"
echo "Models:     ${MODELS[*]}"
echo "Replicates: ${REPLICATES}"
echo
echo "Total jobs to submit: $(( ${#PARTITIONS[@]} * ${#GPU_COUNTS[@]} * ${#MODELS[@]} * REPLICATES )) (spec target: 32 at REPLICATES=2)"
echo
read -r -p "Proceed with submission? [y/N] " ans
case "${ans}" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac

for partition in "${PARTITIONS[@]}"; do
    for gpus in "${GPU_COUNTS[@]}"; do
        for model in "${MODELS[@]}"; do
            for ((r=1; r<=REPLICATES; r++)); do
                name="gmx-${partition}-${model}-${gpus}G-r${r}"
                jid=$(sbatch \
                    -p "${partition}" \
                    --nodes=1 \
                    --gres="gpu:${gpus}" \
                    --job-name="${name}" \
                    --export="ALL,MODEL=${model},GPU_COUNT=${gpus},GROMACS_TAG=${GROMACS_TAG}" \
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
echo "comment header for what to do with the output. Phase 3 records"
echo "additionally carry gpu_count and cuda_version attributes so the chart"
echo "pipeline can disambiguate g6e (sm_89) from p5 (sm_90)."

# ---------------------------------------------------------------------------
# Inline submission table (also valid for manual one-shot submission, e.g.
# if you'd rather paste lines into a terminal than run this whole script):
#
#   # g6e (L40S, sm_89) — single-node multi-GPU Thread_MPI
#   sbatch -p g6e --nodes=1 --gres=gpu:1 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=1   "${CLUSTER_BENCH}"   # x2
#   sbatch -p g6e --nodes=1 --gres=gpu:1 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=1 "${CLUSTER_BENCH}"   # x2
#   sbatch -p g6e --nodes=1 --gres=gpu:2 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=2   "${CLUSTER_BENCH}"   # x2
#   sbatch -p g6e --nodes=1 --gres=gpu:2 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=2 "${CLUSTER_BENCH}"   # x2
#   sbatch -p g6e --nodes=1 --gres=gpu:4 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=4   "${CLUSTER_BENCH}"   # x2
#   sbatch -p g6e --nodes=1 --gres=gpu:4 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=4 "${CLUSTER_BENCH}"   # x2
#   sbatch -p g6e --nodes=1 --gres=gpu:8 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=8   "${CLUSTER_BENCH}"   # x2
#   sbatch -p g6e --nodes=1 --gres=gpu:8 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=8 "${CLUSTER_BENCH}"   # x2
#
#   # p5 (H100, sm_90) — same shape, NVSwitch all-to-all topology
#   sbatch -p p5 --nodes=1 --gres=gpu:1 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=1   "${CLUSTER_BENCH}"   # x2
#   sbatch -p p5 --nodes=1 --gres=gpu:1 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=1 "${CLUSTER_BENCH}"   # x2
#   sbatch -p p5 --nodes=1 --gres=gpu:2 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=2   "${CLUSTER_BENCH}"   # x2
#   sbatch -p p5 --nodes=1 --gres=gpu:2 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=2 "${CLUSTER_BENCH}"   # x2
#   sbatch -p p5 --nodes=1 --gres=gpu:4 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=4   "${CLUSTER_BENCH}"   # x2
#   sbatch -p p5 --nodes=1 --gres=gpu:4 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=4 "${CLUSTER_BENCH}"   # x2
#   sbatch -p p5 --nodes=1 --gres=gpu:8 \
#       --export=ALL,MODEL=benchMEM,GPU_COUNT=8   "${CLUSTER_BENCH}"   # x2
#   sbatch -p p5 --nodes=1 --gres=gpu:8 \
#       --export=ALL,MODEL=benchPEP-h,GPU_COUNT=8 "${CLUSTER_BENCH}"   # x2
# ---------------------------------------------------------------------------
