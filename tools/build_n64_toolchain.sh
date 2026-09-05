#!/usr/bin/env bash
# Build the mips64-elf cross toolchain the libdragon path actually compiles
# with, so a gate can check what a user's `make` would do.
#
# tcl/tools/libdragon_api_test.tcl compiles Pak's generated C against real
# libdragon headers, which closes the whole signature-mismatch class. It
# cannot speak to anything the TARGET decides: type sizes (a 32-bit long, not
# the host's 64-bit one), struct layout, alignment, or endianness. Nor can it
# link. This builds the real compiler so those questions can be asked.
#
#   tools/build_n64_toolchain.sh [prefix]
#
# Versions are libdragon's own, from its tools/build-toolchain.sh at the
# revision tools/fetch_libdragon.sh pins -- a toolchain that is not the one
# libdragon expects would produce failures that say nothing about Pak.
#
# C and C++ are both built, because libdragon needs them: src/debugcpp.cpp is
# part of libdragon.a, and n64.mk links every ROM with $(CXX) deliberately, for
# the global ctor/dtor handling its __do_global_ctors wrapper depends on. A
# C-only toolchain gets as far as "mips64-elf-g++: not found".
#
# Skips cleanly (exit 0, nothing installed) without a compiler or network, so
# a gate can report SKIP rather than fail for a reason that is not the code.
# Expect 30-60 minutes on 4 cores. The result is self-contained under the
# prefix and can be cached.
set -u

PREFIX="${1:-${TMPDIR:-/tmp}/pak-n64-toolchain}"
TARGET=mips64-elf
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

BINUTILS_V=2.45
GCC_V=16.2.0
NEWLIB_V=4.4.0.20231231

BUILD="$PREFIX/build"
DL="$PREFIX/download"

# Already built?
if [ -x "$PREFIX/bin/$TARGET-gcc" ] && [ -x "$PREFIX/bin/$TARGET-g++" ] \
   && [ -f "$PREFIX/$TARGET/lib/libc.a" ]; then
    echo "n64 toolchain: already built at $PREFIX"
    exit 0
fi

for t in gcc make curl tar; do
    command -v "$t" >/dev/null 2>&1 || { echo "n64 toolchain: SKIP (no $t)"; exit 0; }
done

mkdir -p "$BUILD" "$DL" || { echo "n64 toolchain: cannot create $PREFIX"; exit 0; }

fetch() {  # fetch URL FILE
    [ -f "$DL/$2" ] && return 0
    echo "  fetching $2"
    curl -fsSL --retry 3 -o "$DL/$2.part" "$1" || return 1
    mv "$DL/$2.part" "$DL/$2"
}

fetch "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_V.tar.gz" "binutils-$BINUTILS_V.tar.gz" \
    || { echo "n64 toolchain: SKIP (cannot download binutils)"; exit 0; }
fetch "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_V/gcc-$GCC_V.tar.gz" "gcc-$GCC_V.tar.gz" \
    || { echo "n64 toolchain: SKIP (cannot download gcc)"; exit 0; }
fetch "https://sourceware.org/pub/newlib/newlib-$NEWLIB_V.tar.gz" "newlib-$NEWLIB_V.tar.gz" \
    || { echo "n64 toolchain: SKIP (cannot download newlib)"; exit 0; }

set -e
cd "$BUILD"
[ -d "binutils-$BINUTILS_V" ] || tar -xzf "$DL/binutils-$BINUTILS_V.tar.gz"
[ -d "gcc-$GCC_V" ]           || tar -xzf "$DL/gcc-$GCC_V.tar.gz"
[ -d "newlib-$NEWLIB_V" ]     || tar -xzf "$DL/newlib-$NEWLIB_V.tar.gz"

export PATH="$PREFIX/bin:$PATH"

# ── binutils ────────────────────────────────────────────────────────────────
if [ ! -x "$PREFIX/bin/$TARGET-ld" ]; then
    echo "== binutils $BINUTILS_V =="
    mkdir -p build-binutils && cd build-binutils
    ../"binutils-$BINUTILS_V"/configure \
        --prefix="$PREFIX" --target="$TARGET" \
        --with-cpu=mips64vr4300 --disable-werror --disable-nls --with-system-zlib
    make -j "$JOBS"
    make install-strip
    cd "$BUILD"
fi

# ── gcc: compiler + libgcc, no libc yet ─────────────────────────────────────
if [ ! -x "$PREFIX/bin/$TARGET-gcc" ]; then
    echo "== gcc $GCC_V (compiler + libgcc) =="
    mkdir -p build-gcc && cd build-gcc
    ../"gcc-$GCC_V"/configure \
        --prefix="$PREFIX" --target="$TARGET" \
        --with-arch=vr4300 --with-tune=vr4300 \
        --enable-languages=c,c++ \
        --without-headers --disable-libssp --enable-multilib \
        --disable-shared --with-gcc --with-newlib \
        --disable-win32-registry --disable-nls --disable-werror --with-system-zlib
    make all-gcc -j "$JOBS"
    make install-gcc
    make all-target-libgcc -j "$JOBS"
    make install-target-libgcc
    cd "$BUILD"
fi

# ── newlib ──────────────────────────────────────────────────────────────────
if [ ! -f "$PREFIX/$TARGET/lib/libc.a" ]; then
    echo "== newlib $NEWLIB_V =="
    mkdir -p build-newlib && cd build-newlib
    CC_FOR_TARGET="$TARGET-gcc" \
    CFLAGS_FOR_TARGET="-DHAVE_ASSERT_FUNC -O2 -fpermissive" \
    ../"newlib-$NEWLIB_V"/configure \
        --prefix="$PREFIX" --target="$TARGET" \
        --with-cpu=mips64vr4300 --disable-libssp --disable-werror \
        --enable-newlib-multithread --enable-newlib-retargetable-locking
    make -j "$JOBS"
    make install
    cd "$BUILD"
fi

# ── target libraries (libstdc++), now that newlib provides a libc ───────────
# libdragon links with $(CXX), so these have to exist.
if [ ! -x "$PREFIX/bin/$TARGET-g++" ] || [ ! -f "$PREFIX/$TARGET/lib/libstdc++.a" ]; then
    echo "== gcc target libraries =="
    cd build-gcc
    make all -j "$JOBS"
    make install-strip
    cd "$BUILD"
fi

echo "n64 toolchain: $PREFIX/bin/$TARGET-gcc"
"$PREFIX/bin/$TARGET-gcc" --version | head -1
