#!/bin/bash
set -e

#############################################################
# Build HPL 2.3 with OpenMPI + AMD AOCL BLIS + AOCC
# Target: hpc8a.96xlarge — AMD EPYC 9R14 (Zen 5 / znver5)
#
# Compiler: AOCC 5.1.0 (clang-17, supports -march=znver5)
# BLAS:     AOCL 5.1.0 BLIS (tuned for AMD EPYC)
#
# We set OMPI_CC=clang so OpenMPI's mpicc wrapper uses AOCC.
#############################################################

HPL_VERSION="2.3"
HPL_URL="https://www.netlib.org/benchmark/hpl/hpl-${HPL_VERSION}.tar.gz"
INSTALL_DIR="/fsx/HPL-OpenMPI"
TARBALL="/tmp/hpl-${HPL_VERSION}.tar.gz"

# AOCC compiler
AOCC_DIR="/fsx/aocc/aocc-compiler-5.1.0"
export PATH="${AOCC_DIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${AOCC_DIR}/lib:${LD_LIBRARY_PATH}"

# Tell OpenMPI's mpicc to use AOCC clang
export OMPI_CC=clang

module load openmpi
module load libfabric-aws

# AOCL BLIS
AOCL_DIR="/fsx/aocl/5.1.0"
BLIS_LIB="${AOCL_DIR}/lib"
BLIS_INC="/opt/AMD/aocl/aocl-linux-gcc-5.1.0/gcc/include/blis"

if [ ! -f "${BLIS_LIB}/libblis.so" ]; then
    echo "ERROR: AOCL BLIS not found at ${BLIS_LIB}"
    echo "       Install: sudo rpm -ivh /fsx/aocl-linux-gcc-5.1.0-1.x86_64.rpm"
    exit 1
fi

echo "==> Compiler: $(clang --version | head -1)"
echo "==> BLAS: AOCL BLIS at ${BLIS_LIB}"

echo "==> Downloading HPL ${HPL_VERSION}..."
wget -q -O "$TARBALL" "$HPL_URL"

echo "==> Extracting to ${INSTALL_DIR}..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1

cd "$INSTALL_DIR"

ARCH="Linux_AMD_OpenMPI"
cat > "Make.${ARCH}" <<EOF
SHELL        = /bin/sh
CD           = cd
CP           = cp
LN_S         = ln -s
MKDIR        = mkdir
RM           = /bin/rm -f
TOUCH        = touch

ARCH         = ${ARCH}
TOPdir       = ${INSTALL_DIR}

INCdir       = \$(TOPdir)/include
BINdir       = \$(TOPdir)/bin/\$(ARCH)
LIBdir       = \$(TOPdir)/lib/\$(ARCH)

HPLlib       = \$(LIBdir)/libhpl.a

LAinc        = -I${BLIS_INC}
LAlib        = -L${BLIS_LIB} -lblis-mt -lflame -lm -lpthread -lgomp

F2CDEFS      =

HPL_INCLUDES = -I\$(INCdir) -I\$(INCdir)/\$(ARCH) \$(LAinc)
HPL_LIBS     = \$(HPLlib) \$(LAlib)

HPL_OPTS     = -DHPL_CALL_CBLAS
HPL_DEFS     = \$(F2CDEFS) \$(HPL_OPTS) \$(HPL_INCLUDES)

CC           = mpicc
CCNOOPT      = \$(HPL_DEFS)
CCFLAGS      = \$(HPL_DEFS) -O3 -march=znver5 -mtune=znver5 \
               -funroll-loops -fomit-frame-pointer \
               -ffp-contract=fast -ffast-math
LINKER       = mpicc
LINKFLAGS    = \$(CCFLAGS) -Wl,-rpath,${BLIS_LIB} -Wl,-rpath,${AOCC_DIR}/lib

ARCHIVER     = ar
ARFLAGS      = r
RANLIB       = ranlib
EOF

echo "==> Compiling HPL (arch=${ARCH}, march=znver5, BLAS=AOCL BLIS-mt)..."
make arch="${ARCH}" 2>&1

echo "==> Done. HPL binary: ${INSTALL_DIR}/bin/${ARCH}/xhpl"
