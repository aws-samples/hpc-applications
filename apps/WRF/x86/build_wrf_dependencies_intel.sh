#!/bin/bash
#
# Build WRF dependencies with GCC + Intel MPI on AWS HPC instances.
# Intel classic compilers (icc/ifort) are not required — uses GCC with
# Intel MPI wrappers (mpigcc/mpifc).
#
set -xe

arch=$(uname -m)
prefix=${1:-/sw/$arch}
mods=$prefix/modulefiles

## Compiler
compiler() {

  pkg=intel
  version=2023.2.4

  check_install $prefix/$pkg && return

  sudo rm -rf /var/intel
  ./l_dpcpp-cpp-compiler_p_2023.2.4.24_offline.sh -a -s --eula accept --install-dir $prefix/intel
  ./l_mpi_oneapi_p_2021.12.0.538_offline.sh -a -s --eula accept --install-dir $prefix/intel
  #./l_onemkl_p_2024.1.0.695_offline.sh -a -s --eula accept --install-dir $prefix/intel
  ./l_fortran-compiler_p_2023.2.4.31_offline.sh -a -s --eula accept --install-dir $prefix/intel
  echo '-diag-disable=10441' | sudo tee -a $prefix/intel/compiler/2023.2.4/linux/bin/intel64/icc.cfg
  echo '-diag-disable=10441' | sudo tee -a $prefix/intel/compiler/2023.2.4/linux/bin/intel64/icpc.cfg

}

# Cmake
cmake3() {
  (
  pkg=cmake
  version=3.25.1

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge
  curl -OL https://cmake.org/files/v${version%.*}/${pkg}-${version}.tar.gz
  tar xf ${pkg}-${version}.tar.gz
  cd ${pkg}-${version}
  ./bootstrap --prefix=$prefix/$pkg/$version
  make -j $(nproc) install
  gen_mod $pkg $version
  )
}

# ZLib-ng
zlib-ng() {
  (
  pkg=zlib-ng
  version=2.1.6

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge
  curl -OL https://github.com/${pkg}/${pkg}/archive/refs/tags/${version}.tar.gz
  tar xf ${version}.tar.gz
  cd ${pkg}-${version}
  ./configure --prefix=$prefix/$pkg/$version --zlib-compat
  make -j $(nproc)
  make install
  gen_mod $pkg $version
  )
}


# Libaec
libaec() {
  (
  pkg=libaec
  version=1.0.6

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge
  module load cmake

  curl -OL https://gitlab.dkrz.de/k202009/${pkg}/-/archive/v${version}/${pkg}-v${version}.tar.gz
  tar xf ${pkg}-v${version}.tar.gz
  cd ${pkg}-v${version}
  mkdir -p build && cd $_
  export CFLAGS="-O2 -fPIC"
  export CXXFLAGS="-O2 -fPIC"
  export FFLAGS="-fPIC"
  export FCFLAGS="-fPIC"
  export FLDFLAGS="-fPIC"
  export F90LDFLAGS="-fPIC"
  export LDFLAGS="-fPIC"
  cmake -DCMAKE_INSTALL_PREFIX=$prefix/$pkg/$version -DCMAKE_C_COMPILER=$CC ..
  make -j $(nproc)
  make install
  module purge
  gen_mod $pkg $version
  )
}

# HDF5
hdf5() {
  (
  pkg=hdf5
  version=1.12.0

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge
  module load zlib-ng
  module load libaec

  curl -OL https://github.com/HDFGroup/hdf5/archive/refs/tags/${pkg}-${version//\./_}.tar.gz
  tar xf ${pkg}-${version//\./_}.tar.gz
  cd ${pkg}-${pkg}-${version//\./_}
  ./configure --prefix=$prefix/$pkg/$version \
    --enable-parallel \
    --enable-shared \
    --enable-hl \
    --enable-fortran \
    --with-szlib=$LIBAEC_DIR \
    --with-zlib=$ZLIB_NG_DIR \
    CFLAGS="-fPIC" \
    CXXFLAGS="-fPIC" \
    FFLAGS="-fPIC" \
    FCFLAGS="-fPIC" \
    FLDFLAGS="-fPIC" \
    F90LDFLAGS="-fPIC" \
    LDFLAGS="-fPIC"
  make -j $(nproc)
  make install

  gen_mod $pkg $version
  )
}

#PnetCDF
pnetcdf() {
  (
  pkg=pnetcdf
  version=1.12.2

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge

  curl -OL https://parallel-netcdf.github.io/Release/${pkg}-${version}.tar.gz
  tar xf ${pkg}-${version}.tar.gz
  cd ${pkg}-${version}
  ./configure --prefix=$prefix/$pkg/$version \
    --enable-shared \
    --enable-fortran \
    CFLAGS="-fPIC" \
    CXXFLAGS="-fPIC" \
    FFLAGS="-fPIC" \
    FCFLAGS="-fPIC" \
    FLDFLAGS="-fPIC" \
    F90LDFLAGS="-fPIC" \
    LDFLAGS="-fPIC"
  make -j $(nproc)
  make install

  gen_mod $pkg $version
  )
}

#netCDF-C
netcdf-c() {

  (
  pkg=netcdf-c
  version=4.8.1

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge
  module load libaec
  module load zlib-ng
  module load hdf5
  module load pnetcdf
 
  curl -OL https://github.com/Unidata/${pkg}/archive/refs/tags/v${version}.tar.gz
  mv v${version}.tar.gz ${pkg}-${version}.tar.gz
  tar xf ${pkg}-${version}.tar.gz
  cd ${pkg}-${version}
  ./configure --prefix=$prefix/$pkg/$version \
    --enable-pnetcdf \
    --enable-largefile \
    --enable-parallel-tests \
    --enable-shared \
    --enable-netcdf-4 \
    --with-pic \
    --disable-doxygen \
    --disable-dap \
    CFLAGS="-fPIC" \
    CXXFLAGS="-fPIC" \
    FFLAGS="-fPIC" \
    FCFLAGS="-fPIC" \
    FLDFLAGS="-fPIC" \
    F90LDFLAGS="-fPIC" \
    LDFLAGS="-fPIC -I$HDF5_DIR/include -L$HDF5_DIR/lib -I$PNETCDF_DIR/include -L$PNETCDF_DIR/lib -I$ZLIB_NG_DIR/include -L$ZLIB_NG_DIR/lib"
  make -j $(nproc)
  make install

  gen_mod $pkg $version
  )
}

#netCDF-FORTRAN
netcdf-fortran() {
  (
  pkg=netcdf-fortran
  version=4.5.3

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge
  module load libaec
  module load zlib-ng
  module load hdf5
  module load pnetcdf
  module load netcdf-c

  curl -OL https://github.com/Unidata/${pkg}/archive/refs/tags/v${version}.tar.gz
  mv v${version}.tar.gz ${pkg}-${version}.tar.gz
  tar xf ${pkg}-${version}.tar.gz
  cd ${pkg}-${version}
  ./configure --prefix=$prefix/$pkg/$version \
    --enable-largefile \
    --enable-parallel-tests \
    --enable-shared \
    --with-pic \
    --disable-doxygen \
    CFLAGS="-fPIC" \
    CXXFLAGS="-fPIC" \
    FFLAGS="-fPIC" \
    FCFLAGS="-fPIC" \
    FLDFLAGS="-fPIC" \
    F90LDFLAGS="-fPIC" \
    LDFLAGS="-fPIC -I$HDF5_DIR/include -L$HDF5_DIR/lib -I$PNETCDF_DIR/include -L$PNETCDF_DIR/lib -I$NETCDF_C_DIR/include -L$NETCDF_C_DIR/lib -I$LIBAEC_DIR/include -L$LIBAEC_DIR/lib"
  make -j $(nproc)
  make install

  gen_mod $pkg $version
  )
}

# PIO
pio() {
  (
  pkg=pio
  version=2.5.9

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge
  module load cmake
  module load libaec
  module load zlib-ng
  module load hdf5
  module load pnetcdf
  module load netcdf-c
  module load netcdf-fortran

  curl -OL https://github.com/NCAR/ParallelIO/archive/refs/tags/${pkg}${version//\./_}.tar.gz
  tar xf ${pkg}${version//\./_}.tar.gz
  cd ParallelIO-${pkg}${version//\./_}
  mkdir -p build && cd $_
  cmake -DCMAKE_INSTALL_PREFIX=$prefix/$pkg/$version \
        -DPIO_ENABLE_TIMING=OFF \
        -DPIO_ENABLE_DOC=OFF \
        -DPIO_ENABLE_EXAMPLES=OFF \
        -DNetCDF_C_INCLUDE_DIR=$NETCDF_C_DIR/include \
        -DNetCDF_C_LIBRARY=$NETCDF_C_DIR/lib/libnetcdf.so \
        -DNetCDF_Fortran_INCLUDE_DIR=$NETCDF_FORTRAN_DIR/include \
        -DNetCDF_Fortran_LIBRARY=$NETCDF_FORTRAN_DIR/lib/libnetcdff.so \
        -DPnetCDF_C_INCLUDE_DIR=$PNETCDF_DIR/include \
        -DPnetCDF_C_LIBRARY=$PNETCDF_DIR/lib/libpnetcdf.so \
        ..
  make -j $(nproc)
  make install

  gen_mod $pkg $version
  )
}

# Metis
metis() {
  (
  pkg=metis
  version=5.1.1

  check_install $prefix/$pkg/$version && return
  cd $prefix/src
  module purge

  curl -OL https://github.com/KarypisLab/GKlib/archive/refs/tags/METIS-v5.1.1-DistDGL-0.5.tar.gz
  tar xf METIS-v5.1.1-DistDGL-0.5.tar.gz
  cd GKlib-METIS-v5.1.1-DistDGL-0.5
  make config shared=1 cc=gcc prefix=$prefix/$pkg/$version
  make install
  cd ..
  
  curl -OL https://github.com/KarypisLab/METIS/archive/refs/tags/v5.1.1-DistDGL-v0.5.tar.gz
  tar xf v5.1.1-DistDGL-v0.5.tar.gz
  cd METIS-5.1.1-DistDGL-v0.5
  make config shared=1 cc=gcc prefix=$prefix/$pkg/$version gklib_path=../GKlib-METIS-v5.1.1-DistDGL-0.5/
  make install

  gen_mod $pkg $version
  )
}

gen_mod() {

  pkg=$1
  version=$2

  if [ $LOADEDMODULES  ] ; then
    echo "LOADEDMODULES: $LOADEDMODULES"
    echo "len: ${#LOADEDMODULES}"
    loaded=$(echo $LOADEDMODULES | sed 's/:/ /g')
    prereq="prereq $loaded"
  else
    prereq=""
  fi

  mkdir -p $mods/$pkg/
  cat > $mods/$pkg/$version <<EOF
#%Module

set VERSION $version
set PROG $pkg
set HOME "$prefix/\$PROG/\$VERSION"
set PROG_ROOT [regsub -all -- {-} [string toupper \$PROG] {_}]
append PROG_ROOT "_DIR"

module-whatis "Sets up \$PROG \$VERSION in your environment"

proc ModulesHelp { } {
   puts stderr "This module adds \$PROG \$VERSION to various paths"
}
$prereq

setenv \$PROG_ROOT "\$HOME"

prepend-path PATH \$HOME/bin
prepend-path CPATH \$HOME/include
prepend-path MANPATH \$HOME/share/man
EOF
  if [ -d $prefix/$pkg/$version/lib ]; then
    echo "prepend-path LD_LIBRARY_PATH \$HOME/lib" >> $mods/$pkg/$version
    echo "prepend-path LIBRARY_PATH \$HOME/lib" >> $mods/$pkg/$version
  fi
  if [ -d $prefix/$pkg/$version/lib64 ]; then
    echo "prepend-path LD_LIBRARY_PATH \$HOME/lib64" >> $mods/$pkg/$version
    echo "prepend-path LIBRARY_PATH \$HOME/lib64" >> $mods/$pkg/$version
  fi
  if [ -d $prefix/$pkg/$version/lib/pkgconfig ]; then
    echo "prepend-path PKG_CONFIG_PATH \$HOME/lib/pkgconfig" >> $mods/$pkg/$version
  fi
  if [ -d $prefix/$pkg/$version/lib64/pkgconfig ]; then
    echo "prepend-path PKG_CONFIG_PATH \$HOME/lib64/pkgconfig" >> $mods/$pkg/$version
  fi
}

check_install() {
  if [ -d $1 ] ; then
    return 0
  fi
  return 1
}

main() {

  mkdir -p $prefix $mods $prefix/src
  module use $mods

  # Load Intel MPI environment
  source /opt/intel/mpi/latest/env/vars.sh 2>/dev/null || true

  # Use GCC for serial builds (cmake, zlib-ng, libaec)
  export CC=gcc \
         FC=gfortran \
         CXX=g++ \
         CFLAGS="-O2 -fPIC" \
         CXXFLAGS="-O2 -fPIC" \
         FFLAGS="-O2 -fPIC" \
         FCFLAGS="-O2 -fPIC" \
         FLDFLAGS="-fPIC" \
         F90LDFLAGS="-fPIC" \
         LDFLAGS="-fPIC"

  cmake3
  zlib-ng
  libaec

  # Switch to Intel MPI wrappers (backed by GCC) for parallel libs
  export CC=mpigcc \
         FC=mpifc \
         CXX=mpigxx \
         I_MPI_CC=gcc \
         I_MPI_FC=gfortran \
         I_MPI_CXX=g++

  hdf5
  pnetcdf
  netcdf-c
  netcdf-fortran
  pio
  metis
}

main $@

