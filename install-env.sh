#!/bin/bash
# Setup build environment and download all dependencies for
# cross-compiling tmux for macOS Mojave (10.14 x86_64)
# Run on WSL2 Ubuntu 24.04 before running build.sh
set -e

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

log() { echo -e "\n\033[1;32m==> $1\033[0m"; }
err() { echo -e "\n\033[1;31m==> ERROR: $1\033[0m"; exit 1; }
warn() { echo -e "\033[1;33m    WARNING: $1\033[0m"; }

# ============================================================
# 0. Check build environment
# ============================================================
log "0/6 Checking build environment..."

# Must be Linux
[ "$(uname -s)" = "Linux" ] || err "This script must run on Linux (detected: $(uname -s))"

# Check Ubuntu version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "   OS: $PRETTY_NAME"
    if [ "$ID" != "ubuntu" ]; then
        warn "Expected Ubuntu, detected $ID — packages may differ"
    elif [ "${VERSION_ID}" != "24.04" ]; then
        warn "Expected Ubuntu 24.04, detected ${VERSION_ID} — libc++ package version may differ"
    fi
else
    warn "/etc/os-release not found, cannot verify OS"
fi

# Check architecture
ARCH=$(uname -m)
echo "   Arch: $ARCH"
[ "$ARCH" = "x86_64" ] || warn "Expected x86_64, detected $ARCH"

# Check resources
echo "   CPU cores: $(nproc)"
echo "   RAM: $(free -h | awk '/^Mem:/{print $2}') total, $(free -h | awk '/^Mem:/{print $7}') available"
echo "   Disk: $(df -h "$WORKDIR" | awk 'NR==2{print $4}') available"

# ============================================================
# 1. Install apt packages
# ============================================================
log "1/6 Installing apt build dependencies..."

# Detect clang version for libc++ package
CLANG_VER=""
if command -v clang &>/dev/null; then
    CLANG_VER=$(clang --version | grep -oP '\d+' | head -1)
fi

PACKAGES=(
    # Build system tools
    build-essential
    cmake
    autoconf
    automake
    pkg-config
    libtool
    bison

    # osxcross: compiler toolchain
    clang
    lld
    llvm-dev

    # osxcross: SDK packaging tools
    libssl-dev
    liblzma-dev
    libxml2-dev
    zlib1g-dev
    libbz2-dev
    cpio

    # osxcross: libc++ headers (needed to fix SDK)
    # Version determined after clang is installed

    # General build utilities
    patch
    python3
    curl
    wget
    xz-utils
    git
)

# Install base packages first (to get clang version)
sudo apt-get update -qq
sudo apt-get install -y -qq "${PACKAGES[@]}"

# Now install version-matched libc++ headers
if [ -z "$CLANG_VER" ]; then
    CLANG_VER=$(clang --version | grep -oP '\d+' | head -1)
fi
LIBCXX_PKG="libc++-${CLANG_VER}-dev"
echo "   Installing ${LIBCXX_PKG} (matching clang-${CLANG_VER})..."
sudo apt-get install -y -qq "$LIBCXX_PKG"

# Verify critical tools
echo ""
echo "   Installed tools:"
for cmd in gcc clang cmake autoconf automake pkg-config bison git wget; do
    if command -v "$cmd" &>/dev/null; then
        echo "     ✓ $cmd"
    else
        err "$cmd not found after install"
    fi
done

# Verify libc++ headers
LIBCXX_HEADERS="/usr/lib/llvm-${CLANG_VER}/include/c++/v1"
if [ -d "$LIBCXX_HEADERS" ]; then
    echo "     ✓ libc++ headers (llvm-${CLANG_VER})"
else
    err "libc++ headers not found at $LIBCXX_HEADERS"
fi

log "1/6 Done — all apt packages installed"

# ============================================================
# 2. Clone osxcross toolchain
# ============================================================
log "2/6 Cloning osxcross..."
if [ ! -d osxcross/.git ]; then
    git clone https://github.com/tpoechtrager/osxcross.git
else
    echo "   already exists, skipping"
fi

# ============================================================
# 3. Download macOS 10.14 SDK
# ============================================================
log "3/6 Downloading macOS 10.14 SDK..."
SDK_TAR="osxcross/tarballs/MacOSX10.14.sdk.tar.xz"
if [ ! -f "$SDK_TAR" ]; then
    mkdir -p osxcross/tarballs
    wget -q --show-progress -O "$SDK_TAR" \
        "https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX10.14.sdk.tar.xz"
else
    echo "   already exists, skipping"
fi

# ============================================================
# 4. Download libevent source
# ============================================================
LIBEVENT_VER="2.1.12-stable"
log "4/6 Downloading libevent ${LIBEVENT_VER}..."
if [ ! -f "libevent-${LIBEVENT_VER}.tar.gz" ]; then
    wget -q --show-progress \
        "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VER}/libevent-${LIBEVENT_VER}.tar.gz"
else
    echo "   already exists, skipping"
fi

# ============================================================
# 5. Download ncurses source
# ============================================================
NCURSES_VER="6.4"
log "5/6 Downloading ncurses ${NCURSES_VER}..."
if [ ! -f "ncurses-${NCURSES_VER}.tar.gz" ]; then
    wget -q --show-progress \
        "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"
else
    echo "   already exists, skipping"
fi

# ============================================================
# 6. Clone tmux source
# ============================================================
log "6/6 Cloning tmux..."
if [ ! -d tmux/.git ]; then
    git clone https://github.com/tmux/tmux.git
else
    echo "   already exists, skipping"
fi

# ============================================================
# Summary
# ============================================================
log "Environment ready!"
echo ""
echo "  Build environment:"
echo "    OS:      $(. /etc/os-release && echo $PRETTY_NAME)"
echo "    Clang:   $(clang --version | head -1)"
echo "    libc++:  $LIBCXX_PKG"
echo ""
echo "  Downloaded:"
echo "    osxcross/                          — cross-compilation toolchain"
echo "    osxcross/tarballs/*.tar.xz         — macOS 10.14 SDK"
echo "    libevent-${LIBEVENT_VER}.tar.gz"
echo "    ncurses-${NCURSES_VER}.tar.gz"
echo "    tmux/                              — tmux source"
echo ""
echo "  Next step: ./build.sh"
echo ""
