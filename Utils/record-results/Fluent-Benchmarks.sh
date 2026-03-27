#!/bin/bash

output=$(mpirun -V 2>&1)
if echo "$output" | grep -q "Open MPI"; then
    mpi_ver=$(echo "$output" | grep -oP 'Open MPI\) \K[\d.]+')
elif echo "$output" | grep -q "Intel"; then
    mpi_ver=$(echo "$output" | grep -oP 'Version \K[\d.]+')
else
    mpi_ver="Unknown MPI: $output"
fi

libfabric_version=${libfabric_version:-$(cat *.log | grep "libfabric version:" | awk '{print $6}' |  head -1)}

if [ -z "$libfabric_version" ] ; then
  libfabric_version=$(fi_info --version | grep libfabric: | awk '{print $2}')
fi

execDate=$(date -Is)
region=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
pc_version=$(cat /opt/parallelcluster/.bootstrapped | sed "s/aws-parallelcluster-cookbook-//g")

read_case=$(cat ${benchmark_name}*.out      | grep "Read case time" | awk '{print $5}' | head -1)
read_data=$(cat ${benchmark_name}*.out      | grep "Read data time" | awk '{print $5}' | head -1)
time_iteration=$(cat ${benchmark_name}*.out | grep "Solver wall time per iteration" | awk '{print $7}' | head -1)
solver_speed=$(cat ${benchmark_name}*.out   | grep "Solver speed" | awk '{print $4}' | head -1)
solver_rating=$(cat ${benchmark_name}*.out  | grep "Solver rating" | awk '{print $4}' | head -1)    

kernel_version=$(uname -a)
. /etc/os-release

efa_version=$(fi_info -p efa -t FI_EP_RDM | grep version | awk '{print $2}'| tail -1)

node=$(cat hostfile | head -1)
cores_x_node=$(((SLURM_NPROCS / SLURM_JOB_NUM_NODES ) + ( SLURM_NPROCS % SLURM_JOB_NUM_NODES > 0 )))


dynamo_file="${benchmark_name}.json"
dynamodb_table_name="Fluent_Benchmarks"

cat > ${dynamo_file} <<EOF
{   
    "working_dir": {"S": "${workdir}"},
    "jobid": {"S": "${SLURM_JOB_ID}"},
    "Instance_type": {"S": "${instanceType}"},
    "Architecture": {"S": "${FLUENT_ARCH}"},
    "dataset": {"S": "${benchmark_name}"},
    "date": {"S": "${execDate}"},
    "read_case": {"N": "${read_case:-0}"},
    "read_data": {"N": "${read_data:-0}"},
    "time_iteration": {"N": "${time_iteration:-0}"},
    "solver_speed": {"N": "${solver_speed:-0}"},
    "solver_rating": {"N": "${solver_rating:-0}"},
    "mpi": {"S": "${mpi_ver}"},
    "vectorization": {"S": "-platform=intel"},
    "num_cores": {"N": "${SLURM_NPROCS}"},
    "num_nodes": {"N": "${SLURM_JOB_NUM_NODES}"},
    "cores_x_node": {"N": "${cores_x_node}"},
    "HyperThread": {"S": "NO"},
    "aws_region": {"S": "${region}"},
    "fluent_version": {"S": "${fluentversion}"},
    "pc_version": {"S": "${pc_version}"},
    "libfabric_version": {"S": "${libfabric_version}"},
    "s3": {"S": ""},
    "kernel_version": {"S": "${kernel_version}"},
    "os_version": {"S": "${PRETTY_NAME}"},
    "efa_version": {"S": "${efa_version}"}
}
EOF

aws dynamodb --region us-east-1 put-item --table-name "${dynamodb_table_name}" --item file://${dynamo_file}
