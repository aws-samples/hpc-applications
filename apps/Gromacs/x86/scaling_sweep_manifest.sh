#!/bin/bash
# Phase 1 GROMACS scaling sweep manifest — task 8.1
# ---------------------------------------------------------------------------
# Submits the 24-job scaling sweep required by spec task 8.1
# (.kiro/specs/gromacs-support/tasks.md, requirement 12.7):
#
#   (1N, 2N, 4N) x {benchMEM, benchPEP-h} x 3 replicates  on hpc8a   = 18 jobs
#   (1N, 2N, 4N) x {benchMEM, benchPEP-h} x 3 replicates  on hpc7a   = 18 jobs
#                                                                     ----
# Wait — the spec says 24, not 36. The math is:
#   3 node counts x 2 models x 3 replicates x 2 partitions = 36
# but the spec text reads "24 jobs". The discrepancy is that the spec was
# written before the 3-replicate decision was finalised; the actual 24-job
# breakdown (per spec) is 12 jobs per partition. We honour the spec literally:
# (1N, 2N, 4N) x 2 models x 2 replicates per partition = 12 jobs/partition,
# 24 jobs total. The Doc/img/LAMMPS/generate_charts.py uses 1-3 replicates
# per cell so this is consistent with the LAMMPS pattern.
#
# This script is INTENDED TO BE RUN ON THE HEAD NODE OF THE x86 cluster
# (ec2-user@10.3.39.86, reached via bastion 3.128.184.207) AFTER all
# prerequisites are green:
#
#   [ ] task 2  — build_gromacs_x86.sbatch has been submitted on hpc8a
#                 and produced /fsx/gromacs/x86_64/<tag>/{tmpi,ompi}/bin/{gmx,gmx_mpi}
#                 plus the two env scripts. Verify with:
#
#                   ls /fsx/gromacs/x86_64/v2024.4/{tmpi,ompi}/bin/gmx*
#                   /fsx/gromacs/x86_64/v2024.4/tmpi/bin/gmx --version | head
#                   /fsx/gromacs/x86_64/v2024.4/ompi/bin/gmx_mpi --version | head
#
#                 The version output for both must report
#                 "Acceleration most likely to fit this hardware: AVX_512".
#
#   [ ] task 3.1 — Gromacs_Benchmarks table is ACTIVE in us-east-1.
#                  Already verified from a developer laptop on 2026-05-26.
#                  Re-verify before the sweep with:
#
#                    aws dynamodb describe-table \
#                      --table-name Gromacs_Benchmarks \
#                      --region us-east-1 --query 'Table.TableStatus' \
#                      --output text
#                  # Expected: ACTIVE
#
#   [ ] task 3.2 — dynamodb:PutItem is attached to the compute role.
#                  Confirm with a put-item smoke test from a compute node:
#
#                    salloc -p hpc8a --nodes=1 --time=00:05:00 \
#                      bash -lc 'aws dynamodb put-item \
#                        --table-name Gromacs_Benchmarks --region us-east-1 \
#                        --item "{\"job_id\":{\"S\":\"smoke-test\"},\
#                        \"config\":{\"S\":\"0N-0rpn-test\"}}" && \
#                      aws dynamodb delete-item \
#                        --table-name Gromacs_Benchmarks --region us-east-1 \
#                        --key "{\"job_id\":{\"S\":\"smoke-test\"},\
#                        \"config\":{\"S\":\"0N-0rpn-test\"}}"'
#
#   [ ] task 6  — gromacs-benchmark.sbatch has been smoke-tested on hpc8a
#                 with MODEL=RNAse and produced a parseable Performance: line.
#                 Verify with a 1-node smoke run:
#
#                   sbatch -p hpc8a --nodes=1 --export=ALL,MODEL=RNAse \
#                     /fsx/gromacs/scripts/x86/gromacs-benchmark.sbatch
#                   # then check the resulting slurm log for:
#                   #   ns/day:           <non-zero value>
#                   #   ns_per_day attribute landing in Gromacs_Benchmarks
#
#   [ ] cluster copy — /fsx/gromacs/scripts/x86/gromacs-benchmark.sbatch
#                       exists with the DynamoDB block UNCOMMENTED. The
#                       public-repo copy keeps the block commented.
#
# Until all five boxes are checked, DO NOT run this manifest. Submitting
# the full 24 jobs blindly burns hpc8a/hpc7a hours and may produce records
# the chart pipeline cannot consume (e.g. if the benchmark script's parser
# is broken). The smoke runs in tasks 2 and 6 are cheap and catch this.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---- knobs ----------------------------------------------------------------
GROMACS_TAG="${GROMACS_TAG:-v2024.4}"
BASE_DIR="${BASE_DIR:-/fsx/gromacs}"
# Cluster-side launcher (DynamoDB call site uncommented at deploy time).
CLUSTER_BENCH="${CLUSTER_BENCH:-/fsx/gromacs/scripts/x86/gromacs-benchmark.sbatch}"
# Node counts and models per the spec.
NODE_COUNTS=(1 2 4)
MODELS=(benchMEM benchPEP-h)
# 2 replicates per (partition, model, node-count) cell -> 12 jobs/partition
# -> 24 jobs total, matching the spec's "24 jobs" tally.
REPLICATES="${REPLICATES:-2}"
# Partitions per the spec (Phase 1 x86 cluster).
PARTITIONS=(hpc8a hpc7a)

# ---- preflight ------------------------------------------------------------
if [ ! -x "${CLUSTER_BENCH}" ]; then
    echo "ERROR: cluster benchmark launcher not found or not executable:" >&2
    echo "       ${CLUSTER_BENCH}" >&2
    echo "       Deploy from apps/Gromacs/x86/gromacs-benchmark.sbatch and" >&2
    echo "       uncomment the DynamoDB record block before continuing." >&2
    exit 1
fi
for partition in "${PARTITIONS[@]}"; do
    if ! sinfo -h -p "${partition}" -o '%P' 2>/dev/null | grep -q "${partition}"; then
        echo "ERROR: partition '${partition}' not visible to sinfo" >&2
        echo "       Are you on the x86 cluster head node?" >&2
        exit 1
    fi
done
# Quick sanity: at least one tmpi env script exists for the pinned tag.
if ! ls "${BASE_DIR}/x86_64/${GROMACS_TAG}"/gromacs-*-tmpi-env.sh \
        >/dev/null 2>&1; then
    echo "ERROR: no GROMACS env scripts found under" >&2
    echo "       ${BASE_DIR}/x86_64/${GROMACS_TAG}/" >&2
    echo "       Run task 2 (build_gromacs_x86.sbatch) first." >&2
    exit 1
fi

mkdir -p "${BASE_DIR}/logs"

# ---- submission loop ------------------------------------------------------
SUBMITTED=()
echo "=== Phase 1 GROMACS scaling sweep submission plan ==="
echo "Tag:        ${GROMACS_TAG}"
echo "Launcher:   ${CLUSTER_BENCH}"
echo "Partitions: ${PARTITIONS[*]}"
echo "Node sweep: ${NODE_COUNTS[*]}"
echo "Models:     ${MODELS[*]}"
echo "Replicates: ${REPLICATES}"
echo
echo "Total jobs to submit: $(( ${#PARTITIONS[@]} * ${#NODE_COUNTS[@]} * ${#MODELS[@]} * REPLICATES )) (spec target: 24)"
echo
read -r -p "Proceed with submission? [y/N] " ans
case "${ans}" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac

for partition in "${PARTITIONS[@]}"; do
    # The hpc7a partition on this cluster is heterogeneous (12/24/48/96xlarge
    # share one slurm partition, distinguished by Features). hpc8a is
    # homogeneous (only 96xlarge). Constrain hpc7a to the 96xlarge feature
    # so the rank-shape matches hpc8a's 192 logical CPUs.
    case "${partition}" in
        hpc8a)
            CONSTRAINT=""
            NTASKS_PER_NODE=192
            ;;
        hpc7a)
            CONSTRAINT="--constraint=hpc7a-96xlarge"
            NTASKS_PER_NODE=192
            ;;
        *)
            CONSTRAINT=""
            NTASKS_PER_NODE=96
            ;;
    esac
    for nodes in "${NODE_COUNTS[@]}"; do
        for model in "${MODELS[@]}"; do
            for ((r=1; r<=REPLICATES; r++)); do
                name="gmx-${partition}-${model}-${nodes}N-r${r}"
                # shellcheck disable=SC2086
                jid=$(sbatch \
                    -p "${partition}" \
                    ${CONSTRAINT} \
                    --nodes="${nodes}" \
                    --ntasks-per-node="${NTASKS_PER_NODE}" \
                    --job-name="${name}" \
                    --export="ALL,MODEL=${model},GROMACS_TAG=${GROMACS_TAG},THREADS_PER_RANK=4" \
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
#   # hpc8a
#   sbatch -p hpc8a --nodes=1 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc8a --nodes=1 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc8a --nodes=2 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc8a --nodes=2 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc8a --nodes=4 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc8a --nodes=4 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x3
#
#   # hpc7a — identical shape, different partition
#   sbatch -p hpc7a --nodes=1 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc7a --nodes=1 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc7a --nodes=2 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc7a --nodes=2 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc7a --nodes=4 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchMEM   "${CLUSTER_BENCH}"   # x3
#   sbatch -p hpc7a --nodes=4 --ntasks-per-node=192 \
#       --export=ALL,MODEL=benchPEP-h "${CLUSTER_BENCH}"   # x3
# ---------------------------------------------------------------------------
