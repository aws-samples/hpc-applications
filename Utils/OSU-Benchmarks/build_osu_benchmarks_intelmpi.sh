#!/bin/bash
set -e

module load intelmpi
module load libfabric-aws

OSU_VERSION="8.0b2"
OSU_URL="https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz"
INSTALL_DIR="/fsx/OSU-Benchmark-IntelMPI"
TARBALL="/tmp/osu-micro-benchmarks-${OSU_VERSION}.tar.gz"

echo "==> Downloading OSU Micro-Benchmarks ${OSU_VERSION}..."
wget -q -O "$TARBALL" "$OSU_URL"

echo "==> Extracting to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
tar xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1

echo "==> Configuring..."
cd "$INSTALL_DIR"
./configure CC=mpicc CXX=mpicxx --prefix="$INSTALL_DIR/install" > /dev/null 2>&1

echo "==> Compiling..."
make -j"$(nproc)" > /dev/null 2>&1

echo "==> Installing..."
make install > /dev/null 2>&1

echo "==> Done. Benchmarks installed to ${INSTALL_DIR}/install"
