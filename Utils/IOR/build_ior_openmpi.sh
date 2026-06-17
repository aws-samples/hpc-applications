#!/bin/bash
# Build the IOR + mdtest parallel I/O benchmarks against OpenMPI.
#
# IOR (https://github.com/hpc/ior) measures parallel-filesystem throughput
# (POSIX and MPI-IO back-ends) and the bundled mdtest measures metadata
# performance (file/dir create, stat, remove rates). On AWS these are the
# standard tools for characterising Amazon FSx for Lustre.
#
# The official release tarball ships a pre-generated ./configure, so no
# autotools/bootstrap step is required.
set -e

IOR_VERSION="4.0.0"
IOR_URL="https://github.com/hpc/ior/releases/download/${IOR_VERSION}/ior-${IOR_VERSION}.tar.gz"
INSTALL_DIR="/fsx/IOR-OpenMPI"
TARBALL="/tmp/ior-${IOR_VERSION}.tar.gz"

module load openmpi
module load libfabric-aws

echo "==> Downloading IOR ${IOR_VERSION}..."
wget -q -O "$TARBALL" "$IOR_URL"

echo "==> Extracting to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
tar xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1

echo "==> Configuring (POSIX + MPI-IO back-ends via mpicc)..."
cd "$INSTALL_DIR"
./configure MPICC=mpicc --prefix="$INSTALL_DIR/install" > configure.log 2>&1

echo "==> Compiling..."
make -j"$(nproc)" > build.log 2>&1

echo "==> Installing..."
make install > install.log 2>&1

echo "==> Done. Binaries installed to ${INSTALL_DIR}/install/bin"
echo "    ior:    ${INSTALL_DIR}/install/bin/ior"
echo "    mdtest: ${INSTALL_DIR}/install/bin/mdtest"
echo "    Example: mpirun -np 16 ${INSTALL_DIR}/install/bin/ior -a POSIX -b 4g -t 1m -F -e -C -w -r -o /fsx/ior-test/f"
