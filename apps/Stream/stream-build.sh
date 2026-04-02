#!/bin/bash
set -e

# Install AOCC 5.0 compiler (AMD Optimizing C/C++ Compiler)
if ! command -v /opt/AMD/aocc-compiler-5.0.0/bin/clang &> /dev/null; then
    echo "==> Installing AOCC 5.0.0..."
    wget -q https://download.amd.com/developer/eula/aocc-compiler/aocc-compiler-5.0.0-1.x86_64.rpm
    sudo yum localinstall -y aocc-compiler-5.0.0-1.x86_64.rpm
    rm -f aocc-compiler-5.0.0-1.x86_64.rpm
fi

# Source AOCC environment
source /opt/AMD/aocc-compiler-5.0.0/setenv_AOCC.sh

# Download STREAM source
if test -f "stream.c"; then
    rm stream.c
fi
wget -q https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c

# Compile with AOCC-specific optimizations for AMD EPYC 5th Gen (znver5)
echo "==> Compiling STREAM..."
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
