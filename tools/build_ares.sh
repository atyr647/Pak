#!/usr/bin/env bash
# tools/build_ares.sh — build ares, headless-capable, for tcl/tools/ares_test.tcl.
#
# ares is the emulator Pak's standalone ROMs are verified on. mupen64plus is
# not an option: its RDRAM emulation cannot run libdragon's IPL3 at all (see
# runtime/standalone/ipl3_compat.README.md), and its PIF does not implement the
# boot timeout that caught a real bug in Pak's crt0.
#
# The distro package is not an option either: Debian and Ubuntu ship ares with
# the Nintendo 64 core removed.
#
# Everything runs under Xvfb with Mesa's software rasterisers -- llvmpipe for
# the window, lavapipe for paraLLEl-RDP -- so no GPU is required.
#
#   tools/build_ares.sh [prefix]      default /opt/pak-ares
set -euo pipefail

PREFIX="${1:-/opt/pak-ares}"
ARES_REV="${ARES_REV:-master}"
SDL_VER="${SDL_VER:-3.2.24}"
JOBS="${JOBS:-$(nproc)}"

echo "==> apt dependencies"
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build git curl ca-certificates \
    libgtk-3-dev libgl-dev libglx-dev libasound2-dev libudev-dev \
    libpulse-dev libao-dev libopenal-dev libxrandr-dev libxinerama-dev \
    libvulkan-dev mesa-vulkan-drivers libgl1-mesa-dri \
    xvfb imagemagick

# ares needs SDL3, which Ubuntu 24.04 does not package.
if ! [ -f /usr/local/include/SDL3/SDL.h ]; then
    echo "==> SDL $SDL_VER"
    mkdir -p "$PREFIX/src" && cd "$PREFIX/src"
    curl -sSL -o "SDL3-$SDL_VER.tar.gz" \
        "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VER/SDL3-$SDL_VER.tar.gz"
    tar xf "SDL3-$SDL_VER.tar.gz"
    cd "SDL3-$SDL_VER"
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local -DSDL_STATIC=OFF
    cmake --build build -j"$JOBS"
    cmake --install build
    ldconfig
fi

echo "==> ares ($ARES_REV)"
mkdir -p "$PREFIX/src" && cd "$PREFIX/src"
if [ ! -d ares/.git ]; then
    git clone --depth 1 --branch "$ARES_REV" https://github.com/ares-emulator/ares ares
fi
cd ares
# ARES_BUILD_LOCAL=OFF keeps -march=native out of it, so the binary is portable
# across the machines a CI cache is shared with.
cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DARES_BUILD_LOCAL=OFF \
    -DARES_BUILD_OPTIONAL_TARGETS=OFF \
    -DENABLE_CCACHE=OFF
cmake --build build -j"$JOBS"

install -Dm755 build/desktop-ui/ares "$PREFIX/bin/ares"
echo "==> installed $PREFIX/bin/ares"
"$PREFIX/bin/ares" --version 2>/dev/null || true
