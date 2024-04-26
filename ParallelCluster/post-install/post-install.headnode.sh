#!/bin/bash

curl -sL -O https://raw.githubusercontent.com/spack/spack-configs/main/AWS/parallelcluster/postinstall.sh
sudo bash postinstall.sh

#git clone https://github.com/aws-samples/hpc-applications.git