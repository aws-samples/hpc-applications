#!/bin/bash
set -e

AOCC_VERSION="5.1.0"
AOCC_URL="https://download.amd.com/developer/eula/aocc/aocc-5-1/aocc-compiler-${AOCC_VERSION}.tar"
AOCC_INSTALL="/fsx/aocc/aocc-compiler-${AOCC_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install AOCC compiler
if [ ! -d "${AOCC_INSTALL}" ]; then
    echo "==> Downloading AOCC ${AOCC_VERSION}..."
    mkdir -p /fsx/aocc
    cd /fsx/aocc
    wget -q "${AOCC_URL}"
    tar -xf "aocc-compiler-${AOCC_VERSION}.tar"
    cd "aocc-compiler-${AOCC_VERSION}"
    bash install.sh
    cd "${SCRIPT_DIR}"
    rm -f "/fsx/aocc/aocc-compiler-${AOCC_VERSION}.tar"
fi

# Set up AOCC environment
export PATH="${AOCC_INSTALL}/bin:${AOCC_INSTALL}/share/opt-viewer:${PATH}"
export LIBRARY_PATH="${AOCC_INSTALL}/lib:${AOCC_INSTALL}/lib32:/usr/lib64:/usr/lib:${LIBRARY_PATH}"
export LD_LIBRARY_PATH="${AOCC_INSTALL}/ompd:${AOCC_INSTALL}/lib:${AOCC_INSTALL}/lib32:/usr/lib64:/usr/lib:${LD_LIBRARY_PATH}"
export C_INCLUDE_PATH="${AOCC_INSTALL}/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
export CPLUS_INCLUDE_PATH="${AOCC_INSTALL}/include${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"

# Download STREAM source
cd "${SCRIPT_DIR}"
if test -f "stream.c"; then
    rm stream.c
fi
wget -q https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c

# Compile with AOCC optimizations for AMD EPYC 5th Gen (znver5)
echo "==> Compiling STREAM with AOCC ${AOCC_VERSION}..."
clang stream.c \
    -fopenmp \
    -mcmodel=large \
    -DSTREAM_TYPE=double \
    -DSTREAM_ARRAY_SIZE=560000000 \
    -DNTIMES=100 \
    -ffp-contract=fast \
    -fnt-store \
    -O3 -Ofast -ffast-math \
    -ffinite-loops \
    -march=znver5 \
    -zopt \
    -fremap-arrays \
    -mllvm -enable-strided-vectorization \
    -fvector-transform \
    -o stream

echo "==> Done. Run with: sbatch stream.sbatch"

