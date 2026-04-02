#!/bin/bash
set -e

# ============================================================
# Cross-compile tools for macOS Mojave (10.14 x86_64) from WSL2
# Usage: ./build.sh <tool_name>
#        ./build.sh list
#        ./build.sh all
# ============================================================

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
OSXCROSS_DIR="$WORKDIR/osxcross"
CROSS_PREFIX="$WORKDIR/cross-sysroot"
DARWIN_TARGET="x86_64-apple-darwin18"
MIN_MACOS="10.14"
NPROC=$(nproc)
SRCDIR="$WORKDIR/sources"
OUTDIR="$WORKDIR/output"

export PATH="$OSXCROSS_DIR/target/bin:$PATH"

CC="${DARWIN_TARGET}-clang"
STRIP="${DARWIN_TARGET}-strip"
COMMON_CFLAGS="-mmacosx-version-min=${MIN_MACOS} -I${CROSS_PREFIX}/include"
COMMON_LDFLAGS="-mmacosx-version-min=${MIN_MACOS} -L${CROSS_PREFIX}/lib"

log()  { echo -e "\n\033[1;32m==> $1\033[0m"; }
err()  { echo -e "\n\033[1;31m==> ERROR: $1\033[0m"; exit 1; }
warn() { echo -e "\033[1;33m    WARNING: $1\033[0m"; }

# ============================================================
# Brew formula parser: get source URL + version from GitHub
# No brew installation needed — reads formula directly from
# https://github.com/Homebrew/homebrew-core
# ============================================================
BREW_RAW="https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula"

# Fetch source URL from a brew formula
# Usage: brew_source_url <formula_name>
brew_source_url() {
    local name="$1"
    local formula_url="${BREW_RAW}/${name:0:1}/${name}.rb"
    curl -sL "$formula_url" | grep -m1 'url "' | sed 's/.*url "//;s/".*//'
}

# Fetch + extract source from brew formula
# Usage: brew_fetch <formula_name> [expected_dir_pattern]
brew_fetch() {
    local name="$1"
    local url
    url=$(brew_source_url "$name")
    [ -z "$url" ] && err "Cannot resolve brew formula URL for: $name"

    local tarball
    tarball=$(basename "$url")
    mkdir -p "$SRCDIR"; cd "$SRCDIR"

    if [ ! -f "$tarball" ]; then
        log "Downloading $name from brew formula..."
        echo "   $url"
        wget -q --show-progress "$url"
    fi

    # Detect extracted directory name
    local dir
    dir=$(tar tf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1)
    rm -rf "$dir"
    tar xf "$tarball"
    cd "$dir"
    log "$name source ready: $dir"
}

# ============================================================
# Tool registry: name | description | dependencies
# ============================================================
declare -A TOOL_DESC=(
    [tmux]="terminal multiplexer (needs libevent+ncurses)"
    [tree]="directory listing in tree format (zero deps)"
    [htop]="interactive process viewer (needs ncurses)"
    [bash]="Bash 5.x shell (pure C)"
    [nano]="simple text editor (needs ncurses)"
    [vim]="Vi IMproved editor (needs ncurses)"
    [screen]="terminal multiplexer (needs ncurses)"
    [rsync]="fast file sync (low deps)"
    [socat]="multipurpose relay (low deps)"
    [jq]="JSON processor (download pre-built)"
    [nvim]="Neovim editor (download pre-built)"
)

show_list() {
    echo ""
    echo "Available tools for macOS Mojave cross-compilation:"
    echo ""
    printf "  %-10s %s\n" "NAME" "DESCRIPTION"
    printf "  %-10s %s\n" "----" "-----------"
    for tool in tmux tree htop bash nano vim screen rsync socat jq nvim; do
        printf "  %-10s %s\n" "$tool" "${TOOL_DESC[$tool]}"
    done
    echo ""
    echo "Usage:"
    echo "  ./build.sh <tool>     Build a single tool"
    echo "  ./build.sh all        Build all tools"
    echo "  ./build.sh list       Show this list"
    echo ""
}

# ============================================================
# Common: verify environment
# ============================================================
verify_env() {
    for cmd in clang cmake autoconf automake pkg-config bison git wget; do
        command -v "$cmd" &>/dev/null || err "$cmd not found — run ./install-env.sh first"
    done
}

# ============================================================
# Common: setup osxcross toolchain
# ============================================================
setup_osxcross() {
    if [ -x "$OSXCROSS_DIR/target/bin/${DARWIN_TARGET}-clang" ]; then
        if echo 'int main(){return 0;}' | \
           ${CC} -x c - -o /dev/null 2>/dev/null; then
            return 0
        fi
    fi

    if [ ! -d "$OSXCROSS_DIR/.git" ]; then
        git clone https://github.com/tpoechtrager/osxcross.git "$OSXCROSS_DIR"
    fi

    local SDK_TAR="$OSXCROSS_DIR/tarballs/MacOSX10.14.sdk.tar.xz"
    if [ ! -f "$SDK_TAR" ]; then
        log "Downloading macOS 10.14 SDK..."
        mkdir -p "$OSXCROSS_DIR/tarballs"
        wget -q --show-progress -O "$SDK_TAR" \
            "https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX10.14.sdk.tar.xz"
    fi

    cd "$OSXCROSS_DIR"
    UNATTENDED=1 TARGET_DIR="$OSXCROSS_DIR/target" ./build.sh || true

    # Fix: copy libc++ headers into SDK
    local SDK_INCLUDE="$OSXCROSS_DIR/target/SDK/MacOSX10.14.sdk/usr/include"
    if [ ! -d "$SDK_INCLUDE/c++/v1" ]; then
        log "Fixing: installing libc++ headers into SDK..."
        local CLANG_VER
        CLANG_VER=$(clang --version | grep -oP '\d+' | head -1)
        local HOST_CXX_HEADERS="/usr/lib/llvm-${CLANG_VER}/include/c++/v1"
        [ -d "$HOST_CXX_HEADERS" ] || err "libc++ headers not found — run ./install-env.sh first"
        mkdir -p "$SDK_INCLUDE/c++/v1"
        cp -a "$HOST_CXX_HEADERS/"* "$SDK_INCLUDE/c++/v1/"
    fi

    echo 'int main(){return 0;}' | ${CC} -x c - -o /tmp/test_darwin 2>/dev/null || err "osxcross C compiler test failed"
    file /tmp/test_darwin | grep -q "Mach-O" || err "Output is not Mach-O binary"
    rm -f /tmp/test_darwin
    log "osxcross toolchain ready"
}

# ============================================================
# Common: build static libevent (needed by tmux)
# ============================================================
build_libevent() {
    [ -f "$CROSS_PREFIX/lib/libevent.a" ] && return 0
    log "Building libevent (static dependency)..."
    mkdir -p "$CROSS_PREFIX"/{lib,include}
    brew_fetch libevent

    ./configure --host="${DARWIN_TARGET}" --prefix="$CROSS_PREFIX" \
        --enable-static --disable-shared --disable-openssl \
        --disable-samples --disable-libevent-regress \
        CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1 && make install > /dev/null 2>&1
    [ -f "$CROSS_PREFIX/lib/libevent.a" ] || err "libevent build failed"
}

# ============================================================
# Common: build static ncurses (needed by tmux, htop, nano, vim, screen, bash)
# ============================================================
build_ncurses() {
    [ -f "$CROSS_PREFIX/lib/libncursesw.a" ] && return 0
    log "Building ncurses (static dependency)..."
    mkdir -p "$CROSS_PREFIX"/{lib,include}
    brew_fetch ncurses

    ./configure --host="${DARWIN_TARGET}" --prefix="$CROSS_PREFIX" \
        --with-default-terminfo-dir=/usr/share/terminfo \
        --without-shared --with-normal --without-debug --without-ada \
        --without-cxx-binding --without-manpages --without-tests --without-progs \
        --enable-widec --enable-pc-files \
        --with-pkg-config-libdir="$CROSS_PREFIX/lib/pkgconfig" \
        CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
        cf_cv_working_poll=yes ac_cv_func_getpwnam=yes ac_cv_func_getpwuid=yes \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1 && make install > /dev/null 2>&1

    ln -sf "$CROSS_PREFIX/lib/libncursesw.a" "$CROSS_PREFIX/lib/libncurses.a"
    ln -sf "$CROSS_PREFIX/lib/pkgconfig/ncursesw.pc" "$CROSS_PREFIX/lib/pkgconfig/ncurses.pc" 2>/dev/null || true
    cp -n "$CROSS_PREFIX/include/ncursesw/"* "$CROSS_PREFIX/include/" 2>/dev/null || true
    [ -f "$CROSS_PREFIX/lib/libncursesw.a" ] || err "ncurses build failed"
}

# Helper: finish build — strip, copy to output, show result
finish_build() {
    local name="$1" binary="$2"
    [ -f "$binary" ] || err "$name build failed"
    $STRIP "$binary" 2>/dev/null || true
    mkdir -p "$OUTDIR"
    cp "$binary" "$OUTDIR/$name"
    echo ""
    echo "  Binary: $OUTDIR/$name"
    echo "  Size:   $(du -h "$OUTDIR/$name" | cut -f1)"
    file "$OUTDIR/$name"
    log "$name build complete!"
    echo "  Deploy: scp $OUTDIR/$name <mojave-host>:~/"
}

# ============================================================
# Tool builders
# ============================================================

build_tmux() {
    log "Building tmux..."
    build_libevent
    build_ncurses
    brew_fetch tmux

    ./configure --host="${DARWIN_TARGET}" --disable-utf8proc \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="-I${CROSS_PREFIX}/include -I${CROSS_PREFIX}/include/ncursesw" \
        PKG_CONFIG_PATH="${CROSS_PREFIX}/lib/pkgconfig" \
        PKG_CONFIG_LIBDIR="${CROSS_PREFIX}/lib/pkgconfig" \
        LIBEVENT_CFLAGS="-I${CROSS_PREFIX}/include" \
        LIBEVENT_LIBS="-L${CROSS_PREFIX}/lib -levent" \
        ac_cv_func_prog_cc_c99=yes \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build tmux tmux
}

build_tree() {
    log "Building tree..."
    brew_fetch tree

    make CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
        -j"$NPROC" > /dev/null 2>&1
    finish_build tree tree
}

build_htop() {
    log "Building htop..."
    build_ncurses
    brew_fetch htop

    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-unicode \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="-I${CROSS_PREFIX}/include -I${CROSS_PREFIX}/include/ncursesw" \
        HTOP_NCURSES_CONFIG_SCRIPT="${CROSS_PREFIX}/bin/ncursesw6-config" \
        ac_cv_lib_ncursesw_addnwstr=yes \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build htop htop
}

build_bash() {
    log "Building bash..."
    build_ncurses
    brew_fetch bash

    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --without-bash-malloc \
        --disable-nls \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS}" \
        LDFLAGS="${COMMON_LDFLAGS} -lncursesw" \
        CPPFLAGS="-I${CROSS_PREFIX}/include" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build bash bash
}

build_nano() {
    log "Building nano..."
    build_ncurses
    brew_fetch nano

    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-nls --disable-browser --disable-speller \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="-I${CROSS_PREFIX}/include -I${CROSS_PREFIX}/include/ncursesw" \
        PKG_CONFIG_PATH="${CROSS_PREFIX}/lib/pkgconfig" \
        NCURSESW_CFLAGS="-I${CROSS_PREFIX}/include/ncursesw" \
        NCURSESW_LIBS="-L${CROSS_PREFIX}/lib -lncursesw" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build nano src/nano
}

build_vim() {
    log "Building vim..."
    build_ncurses
    brew_fetch vim

    vim_cv_toupper_broken=no \
    vim_cv_terminfo=yes \
    vim_cv_tgetent=zero \
    vim_cv_getcwd_broken=no \
    vim_cv_stat_ignores_slash=yes \
    vim_cv_memmove_handles_overlap=yes \
    ac_cv_sizeof_int=4 \
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --with-features=huge \
        --disable-gui --without-x --enable-multibyte \
        --disable-nls --disable-netbeans --disable-gpm \
        --with-tlib=ncursesw \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="-I${CROSS_PREFIX}/include -I${CROSS_PREFIX}/include/ncursesw" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build vim src/vim
}

build_screen() {
    log "Building screen..."
    build_ncurses
    brew_fetch screen

    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-pam \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="-I${CROSS_PREFIX}/include -I${CROSS_PREFIX}/include/ncursesw" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build screen screen
}

build_rsync() {
    log "Building rsync..."
    brew_fetch rsync

    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-lz4 --disable-zstd --disable-xxhash \
        --disable-openssl --disable-md2man \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS}" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build rsync rsync
}

build_socat() {
    log "Building socat..."
    brew_fetch socat

    # socat cross-compile needs many cache overrides
    sc_cv_termios_ispeed=yes \
    ac_cv_have_z_modifier=yes \
    sc_cv_sys_crdly_shift=9 \
    sc_cv_sys_tabdly_shift=11 \
    sc_cv_sys_csize_shift=8 \
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-openssl --disable-readline \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS}" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    finish_build socat socat
}

build_jq() {
    log "Downloading pre-built jq for macOS..."
    mkdir -p "$OUTDIR"
    wget -q --show-progress -O "$OUTDIR/jq" \
        "https://github.com/jqlang/jq/releases/download/jq-1.6/jq-osx-amd64"
    chmod +x "$OUTDIR/jq"
    echo ""
    echo "  Binary: $OUTDIR/jq"
    echo "  Size:   $(du -h "$OUTDIR/jq" | cut -f1)"
    file "$OUTDIR/jq"
    warn "jq 1.6 is the latest version compatible with Mojave (1.7+ uses unsupported LC_BUILD_VERSION)"
    log "jq download complete!"
    echo "  Deploy: scp $OUTDIR/jq <mojave-host>:~/"
}

build_nvim() {
    log "Downloading pre-built nvim for macOS..."
    mkdir -p "$OUTDIR"
    cd /tmp
    local TARBALL="nvim-macos.tar.gz"
    [ -f "$TARBALL" ] || wget -q --show-progress -O "$TARBALL" \
        "https://github.com/neovim/neovim/releases/download/v0.9.0/nvim-macos.tar.gz"
    rm -rf nvim-macos; tar xf "$TARBALL"
    cp -a nvim-macos "$OUTDIR/nvim-macos"
    echo ""
    echo "  Directory: $OUTDIR/nvim-macos/"
    echo "  Binary:    $OUTDIR/nvim-macos/bin/nvim"
    echo "  Size:      $(du -sh "$OUTDIR/nvim-macos" | cut -f1)"
    warn "nvim 0.9.0 is the latest version confirmed working on Mojave (0.10+ may fail)"
    log "nvim download complete!"
    echo "  Deploy: scp -r $OUTDIR/nvim-macos <mojave-host>:~/"
}

# ============================================================
# Main
# ============================================================
TOOL="${1:-}"

if [ -z "$TOOL" ] || [ "$TOOL" = "help" ] || [ "$TOOL" = "--help" ] || [ "$TOOL" = "-h" ]; then
    show_list
    exit 0
fi

if [ "$TOOL" = "list" ]; then
    show_list
    exit 0
fi

# Setup common infrastructure
log "Cross-compile for macOS Mojave ($MIN_MACOS) x86_64"
echo "  Work dir:  $WORKDIR"
echo "  CPU cores: $NPROC"
echo "  Output:    $OUTDIR/"
verify_env

# Pre-built tools don't need osxcross
if [ "$TOOL" != "jq" ] && [ "$TOOL" != "nvim" ]; then
    setup_osxcross
fi

if [ "$TOOL" = "all" ]; then
    for t in tmux tree htop bash nano vim screen rsync socat jq nvim; do
        build_"$t"
    done
    log "All tools built!"
    echo ""
    ls -lh "$OUTDIR/"
else
    # Check tool exists
    if ! declare -f "build_${TOOL}" &>/dev/null; then
        err "Unknown tool: $TOOL (run ./build.sh list)"
    fi
    build_"$TOOL"
fi
