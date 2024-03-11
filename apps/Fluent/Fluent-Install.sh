#!/bin/bash

##how to use it: ./Fluent-Install.sh /fsx s3://your_bucket/FLUIDSTRUCTURES_2022R1_LINX64.tgz

root_dir=${1:-"/fsx"}
fluent_s3_path=${2:-"s3://your_bucket/Ansys/FLUIDSTRUCTURES_2023R1_LINX64.tgz"}

#check the installation directory
if [ ! -d "${root_dir}" -o -z "${root_dir}" ]; then
    echo "Error: please check the install dir"
    exit 1
fi

#check s3 path
if [ -z "${fluent_s3_path}" ]; then
    echo "Error: please check the s3 path"
    exit 1
fi

check=$(aws s3 ls "${fluent_s3_path}")
if [ -z "${check}" ]; then
    echo "Error: please check your file on S3"
    exit 1
fi

tmpInstallDir="${root_dir}/ansys_tmp"
ansysDir="${root_dir}/ansys_inc"

mkdir -p "${tmpInstallDir}"
cd "${tmpInstallDir}"

echo "Downloading file from ${fluent_s3_path} ..."
aws s3 cp "${fluent_s3_path}" .

tar -xzvf *.tgz

# INSTALL Ansys WB
echo "Installing Ansys"
"./INSTALL" -silent -install_dir "${ansysDir}"

echo "Ansys installed"

rm -rf ${tmpInstallDir}

echo "Installation process completed!"
