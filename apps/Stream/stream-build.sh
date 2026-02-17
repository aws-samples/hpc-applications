#! /bin/bash

if test -f "stream.c"; then
    rm stream.c
fi

wget https://download.amd.com/developer/eula/aocc-compiler/aocc-compiler-4.0.0.tar
tar -xf aocc-compiler-4.0.0.tar
cd aocc-compiler-4.0.0
./install.sh
cd ../
source ./setenv_AOCC.sh

wget https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c

clang stream.c -fopenmp -mcmodel=large -DSTREAM_TYPE=double -DSTREAM_ARRAY_SIZE=560000000 -DNTIMES=100 -ffp-contract=fast -fnt-store -O3 -Ofast -ffast-math -ffinite-loops -march=native -zopt -fremap-arrays -mllvm -enable-strided-vectorization -fvector-transform  -o stream