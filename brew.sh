#!/bin/bash
set -e

# ============================================================
# brew.sh — Homebrew-compatible cross-compiler for macOS Mojave
#
# Fetches source from Homebrew formulae on GitHub,
# cross-compiles on Ubuntu for macOS Mojave (10.14 x86_64).
#
# Usage:
#   ./brew.sh install <formula>    Download + cross-compile
#   ./brew.sh info <formula>       Show formula info
#   ./brew.sh search <keyword>     Search formulae
#   ./brew.sh list                 Show installed packages
#   ./brew.sh doctor               Check build environment
# ============================================================

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
OSXCROSS_DIR="$WORKDIR/osxcross"
CROSS_PREFIX="$WORKDIR/cross-sysroot"
CELLAR="$WORKDIR/cellar"       # like /usr/local/Cellar
SRCDIR="$WORKDIR/sources"
DARWIN_TARGET="x86_64-apple-darwin18"
MIN_MACOS="10.14"
NPROC=$(nproc)

export PATH="$OSXCROSS_DIR/target/bin:$PATH"

CC="${DARWIN_TARGET}-clang"
CXX="${DARWIN_TARGET}-clang++"
STRIP="${DARWIN_TARGET}-strip"
COMMON_CFLAGS="-mmacosx-version-min=${MIN_MACOS} -I${CROSS_PREFIX}/include"
COMMON_LDFLAGS="-mmacosx-version-min=${MIN_MACOS} -L${CROSS_PREFIX}/lib"
COMMON_CPPFLAGS="-I${CROSS_PREFIX}/include"

BREW_RAW="https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula"
BREW_API="https://formulae.brew.sh/api/formula"

# --- Colors ---
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}==> $1${NC}"; }
err()  { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}Warning: $1${NC}"; }
info() { echo -e "${CYAN}$1${NC}"; }

# ============================================================
# Formula parser (reads from Homebrew GitHub, no brew needed)
# ============================================================

# Get formula Ruby source
_formula_rb() {
    local name="$1"
    local url="${BREW_RAW}/${name:0:1}/${name}.rb"
    curl -sfL "$url"
}

# Extract source URL from formula
_formula_url() {
    _formula_rb "$1" | grep -m1 'url "' | sed 's/.*url "//;s/".*//'
}

# Extract version from formula
_formula_version() {
    local rb ver url filename
    rb=$(_formula_rb "$1")
    ver=$(echo "$rb" | grep -m1 'version "' | sed 's/.*version "//;s/".*//')
    if [ -z "$ver" ]; then
        url=$(echo "$rb" | grep -m1 'url "' | sed 's/.*url "//;s/".*//')
        filename=$(basename "$url" | sed 's/\.tar.*//;s/\.zip$//')
        ver=$(echo "$filename" | grep -oP '[\d]+\.[\d]+[\.\d]*[a-z]?' | tail -1)
    fi
    echo "${ver:-unknown}"
}

# Extract description
_formula_desc() {
    _formula_rb "$1" | grep -m1 'desc "' | sed 's/.*desc "//;s/".*//'
}

# Extract dependencies
_formula_deps() {
    _formula_rb "$1" | grep 'depends_on "' | sed 's/.*depends_on "//;s/".*//' | tr '\n' ' '
}

# Check if formula exists
_formula_exists() {
    curl -sfL "${BREW_RAW}/${1:0:1}/${1}.rb" -o /dev/null 2>/dev/null
}

# Download + extract formula source
_fetch() {
    local name="$1"
    local url
    url=$(_formula_url "$name")
    [ -z "$url" ] && err "Cannot find source URL for: $name"

    local tarball
    tarball=$(basename "$url")
    mkdir -p "$SRCDIR"; cd "$SRCDIR"

    if [ ! -f "$tarball" ]; then
        log "Downloading $name..."
        info "  $url"
        wget -q --show-progress "$url"
    fi

    local dir
    dir=$(tar tf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1)
    rm -rf "$dir"; tar xf "$tarball"; cd "$dir"
}

# ============================================================
# Dependency builder (static libs for cross-sysroot)
# ============================================================

_ensure_osxcross() {
    if echo 'int main(){return 0;}' | ${CC} -x c - -o /dev/null 2>/dev/null; then
        return 0
    fi
    err "osxcross not ready — run ./install-env.sh && ./build.sh tmux first"
}

_ensure_ncurses() {
    [ -f "$CROSS_PREFIX/lib/libncursesw.a" ] && return 0
    log "Building dependency: ncurses (static)..."
    mkdir -p "$CROSS_PREFIX"/{lib,include}
    _fetch ncurses
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

_ensure_libevent() {
    [ -f "$CROSS_PREFIX/lib/libevent.a" ] && return 0
    log "Building dependency: libevent (static)..."
    mkdir -p "$CROSS_PREFIX"/{lib,include}
    _fetch libevent
    ./configure --host="${DARWIN_TARGET}" --prefix="$CROSS_PREFIX" \
        --enable-static --disable-shared --disable-openssl \
        --disable-samples --disable-libevent-regress \
        CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1 && make install > /dev/null 2>&1
    [ -f "$CROSS_PREFIX/lib/libevent.a" ] || err "libevent build failed"
}

# ncurses flags for tools that need it
_ncurses_flags() {
    echo "CFLAGS=\"${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw\" \
          CPPFLAGS=\"${COMMON_CPPFLAGS} -I${CROSS_PREFIX}/include/ncursesw\" \
          PKG_CONFIG_PATH=\"${CROSS_PREFIX}/lib/pkgconfig\""
}

# ============================================================
# Install result: copy to cellar, show summary
# ============================================================

_install_bin() {
    local name="$1" binary="$2" version="$3"
    [ -f "$binary" ] || err "Build failed: $binary not found"

    $STRIP "$binary" 2>/dev/null || true

    local dest="$CELLAR/$name/$version"
    mkdir -p "$dest/bin"
    cp "$binary" "$dest/bin/$name"
    chmod +x "$dest/bin/$name"

    echo ""
    info "  ${name} ${version}"
    echo "  $(file "$dest/bin/$name")"
    echo "  Size: $(du -h "$dest/bin/$name" | cut -f1)"
    echo ""
    echo "  Installed to: $dest/bin/$name"
    echo "  Deploy:       scp $dest/bin/$name <mojave-host>:/usr/local/bin/"
}

# ============================================================
# Recipe registry — custom configure flags per formula
# ============================================================

_recipe_tmux() {
    _ensure_libevent; _ensure_ncurses; _fetch tmux
    ./configure --host="${DARWIN_TARGET}" --disable-utf8proc \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="${COMMON_CPPFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        PKG_CONFIG_PATH="${CROSS_PREFIX}/lib/pkgconfig" \
        PKG_CONFIG_LIBDIR="${CROSS_PREFIX}/lib/pkgconfig" \
        LIBEVENT_CFLAGS="-I${CROSS_PREFIX}/include" \
        LIBEVENT_LIBS="-L${CROSS_PREFIX}/lib -levent" \
        ac_cv_func_prog_cc_c99=yes > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin tmux tmux "$(_formula_version tmux)"
}

_recipe_tree() {
    _fetch tree
    make CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
        -j"$NPROC" > /dev/null 2>&1
    _install_bin tree tree "$(_formula_version tree)"
}

_recipe_htop() {
    _ensure_ncurses; _fetch htop
    ./autogen.sh > /dev/null 2>&1 || true
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local --disable-unicode \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="${COMMON_CPPFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        ac_cv_lib_ncursesw_addnwstr=yes > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin htop htop "$(_formula_version htop)"
}

_recipe_bash() {
    _ensure_ncurses; _fetch bash
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --without-bash-malloc --disable-nls \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS}" \
        LDFLAGS="${COMMON_LDFLAGS} -lncursesw" \
        CPPFLAGS="${COMMON_CPPFLAGS}" > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin bash bash "$(_formula_version bash)"
}

_recipe_nano() {
    _ensure_ncurses; _fetch nano
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-nls --disable-browser --disable-speller \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="${COMMON_CPPFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        NCURSESW_CFLAGS="-I${CROSS_PREFIX}/include/ncursesw" \
        NCURSESW_LIBS="-L${CROSS_PREFIX}/lib -lncursesw" > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin nano src/nano "$(_formula_version nano)"
}

_recipe_vim() {
    _ensure_ncurses; _fetch vim
    vim_cv_toupper_broken=no vim_cv_terminfo=yes vim_cv_tgetent=zero \
    vim_cv_getcwd_broken=no vim_cv_stat_ignores_slash=yes \
    vim_cv_memmove_handles_overlap=yes ac_cv_sizeof_int=4 \
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --with-features=huge --disable-gui --without-x --enable-multibyte \
        --disable-nls --disable-netbeans --disable-gpm --with-tlib=ncursesw \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="${COMMON_CPPFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin vim src/vim "$(_formula_version vim)"
}

_recipe_screen() {
    _ensure_ncurses; _fetch screen
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local --disable-pam \
        CC="${CC}" \
        CFLAGS="${COMMON_CFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        LDFLAGS="${COMMON_LDFLAGS}" \
        CPPFLAGS="${COMMON_CPPFLAGS} -I${CROSS_PREFIX}/include/ncursesw" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin screen screen "$(_formula_version screen)"
}

_recipe_rsync() {
    _fetch rsync
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-lz4 --disable-zstd --disable-xxhash \
        --disable-openssl --disable-md2man \
        CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin rsync rsync "$(_formula_version rsync)"
}

_recipe_socat() {
    _fetch socat
    sc_cv_termios_ispeed=yes ac_cv_have_z_modifier=yes \
    sc_cv_sys_crdly_shift=9 sc_cv_sys_tabdly_shift=11 sc_cv_sys_csize_shift=8 \
    ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
        --disable-openssl --disable-readline \
        CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
        > /dev/null 2>&1
    make -j"$NPROC" > /dev/null 2>&1
    _install_bin socat socat "$(_formula_version socat)"
}

_recipe_jq() {
    local ver="1.6"
    log "Downloading pre-built jq ${ver} (1.7+ incompatible with Mojave)..."
    mkdir -p "$CELLAR/jq/$ver/bin"
    wget -q --show-progress -O "$CELLAR/jq/$ver/bin/jq" \
        "https://github.com/jqlang/jq/releases/download/jq-${ver}/jq-osx-amd64"
    chmod +x "$CELLAR/jq/$ver/bin/jq"
    info "  jq ${ver}"
    echo "  Size: $(du -h "$CELLAR/jq/$ver/bin/jq" | cut -f1)"
    echo "  Installed to: $CELLAR/jq/$ver/bin/jq"
    warn "jq 1.7+ uses LC_BUILD_VERSION unsupported by Mojave"
}

_recipe_nvim() {
    local ver="0.9.0"
    log "Downloading pre-built nvim ${ver} (0.10+ may not work on Mojave)..."
    mkdir -p "$CELLAR/nvim/$ver"
    cd /tmp
    local tarball="nvim-macos.tar.gz"
    [ -f "$tarball" ] || wget -q --show-progress -O "$tarball" \
        "https://github.com/neovim/neovim/releases/download/v${ver}/nvim-macos.tar.gz"
    rm -rf nvim-macos; tar xf "$tarball"
    cp -a nvim-macos/* "$CELLAR/nvim/$ver/"
    info "  nvim ${ver}"
    echo "  Size: $(du -sh "$CELLAR/nvim/$ver" | cut -f1)"
    echo "  Installed to: $CELLAR/nvim/$ver/bin/nvim"
    warn "nvim 0.10+ may use LC_BUILD_VERSION unsupported by Mojave"
}

# Generic autotools recipe (fallback for unknown formulae)
_recipe_generic() {
    local name="$1"
    _fetch "$name"

    # Try autoreconf if configure doesn't exist
    if [ ! -f configure ] && [ -f configure.ac ]; then
        autoreconf -fi > /dev/null 2>&1 || true
    fi

    if [ -f configure ]; then
        ./configure --host="${DARWIN_TARGET}" --prefix=/usr/local \
            CC="${CC}" CXX="${CXX}" \
            CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
            CPPFLAGS="${COMMON_CPPFLAGS}" > /dev/null 2>&1
        make -j"$NPROC" > /dev/null 2>&1
    elif [ -f CMakeLists.txt ]; then
        mkdir -p _build && cd _build
        cmake .. \
            -DCMAKE_C_COMPILER="${CC}" \
            -DCMAKE_SYSTEM_NAME=Darwin \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_MACOS}" \
            -DCMAKE_INSTALL_PREFIX=/usr/local \
            > /dev/null 2>&1
        make -j"$NPROC" > /dev/null 2>&1
    elif [ -f Makefile ]; then
        make CC="${CC}" CFLAGS="${COMMON_CFLAGS}" LDFLAGS="${COMMON_LDFLAGS}" \
            -j"$NPROC" > /dev/null 2>&1
    else
        err "No configure, CMakeLists.txt, or Makefile found — cannot build $name"
    fi

    # Try to find the binary
    local bin
    bin=$(find . -maxdepth 3 -name "$name" -type f -perm -111 2>/dev/null | head -1)
    if [ -z "$bin" ]; then
        bin=$(find . -maxdepth 3 -type f -perm -111 2>/dev/null | \
              grep -v '\.o$\|\.a$\|config\.' | head -1)
    fi
    [ -z "$bin" ] && err "Cannot find built binary for $name"
    _install_bin "$name" "$bin" "$(_formula_version "$name")"
}

# ============================================================
# Commands
# ============================================================

cmd_install() {
    local name="$1"
    [ -z "$name" ] && err "Usage: $0 install <formula>"

    _ensure_osxcross

    log "Installing $name for macOS Mojave ($MIN_MACOS)..."

    if declare -f "_recipe_${name}" &>/dev/null; then
        "_recipe_${name}"
    elif _formula_exists "$name"; then
        warn "No custom recipe for '$name' — trying generic autotools build"
        _recipe_generic "$name"
    else
        err "Formula not found: $name"
    fi

    log "$name installed successfully!"
}

cmd_info() {
    local name="$1"
    [ -z "$name" ] && err "Usage: $0 info <formula>"

    if ! _formula_exists "$name"; then
        err "Formula not found: $name"
    fi

    local desc ver url deps
    desc=$(_formula_desc "$name")
    ver=$(_formula_version "$name")
    url=$(_formula_url "$name")
    deps=$(_formula_deps "$name")

    echo ""
    info "$name: stable $ver"
    echo "$desc"
    echo ""
    echo "Source:       $url"
    [ -n "$deps" ] && echo "Dependencies: $deps"

    if declare -f "_recipe_${name}" &>/dev/null; then
        echo "Recipe:       custom (optimized for Mojave)"
    else
        echo "Recipe:       generic (autotools/cmake/make)"
    fi

    # Check if installed
    if [ -d "$CELLAR/$name" ]; then
        local iver
        iver=$(ls "$CELLAR/$name" | sort -V | tail -1)
        echo "Installed:    $iver (in $CELLAR/$name/$iver/)"
    else
        echo "Installed:    no"
    fi
    echo ""
}

cmd_search() {
    local keyword="$1"
    [ -z "$keyword" ] && err "Usage: $0 search <keyword>"

    log "Searching Homebrew formulae for '$keyword'..."
    curl -sf "${BREW_API}.json" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
kw = '${keyword}'.lower()
for f in data:
    name = f.get('name','')
    desc = f.get('desc','')
    if kw in name.lower() or kw in desc.lower():
        ver = f.get('versions',{}).get('stable','?')
        print(f'  {name:20s} {ver:12s} {desc}')
" 2>/dev/null | head -30

    echo ""
}

cmd_list() {
    if [ ! -d "$CELLAR" ] || [ -z "$(ls -A "$CELLAR" 2>/dev/null)" ]; then
        echo "No packages installed."
        echo "Run: $0 install <formula>"
        return
    fi

    echo ""
    printf "  ${CYAN}%-15s %-12s %-8s %s${NC}\n" "NAME" "VERSION" "SIZE" "PATH"
    printf "  %-15s %-12s %-8s %s\n" "----" "-------" "----" "----"
    for pkg in "$CELLAR"/*/; do
        local name ver size bin
        name=$(basename "$pkg")
        ver=$(ls "$pkg" | sort -V | tail -1)
        bin=$(find "$pkg$ver" -type f -perm -111 2>/dev/null | head -1)
        size=$(du -sh "$pkg$ver" 2>/dev/null | cut -f1)
        printf "  %-15s %-12s %-8s %s\n" "$name" "$ver" "$size" "$bin"
    done
    echo ""
}

cmd_doctor() {
    echo ""
    log "Checking build environment..."

    # OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "  OS:        $PRETTY_NAME"
        [ "$ID" = "ubuntu" ] && [ "$VERSION_ID" = "24.04" ] && echo "             ✓ Supported" || warn "Expected Ubuntu 24.04"
    fi

    # Arch
    echo "  Arch:      $(uname -m)"

    # Resources
    echo "  CPU:       $(nproc) cores"
    echo "  RAM:       $(free -h | awk '/^Mem:/{print $7}') available"
    echo "  Disk:      $(df -h "$WORKDIR" | awk 'NR==2{print $4}') available"

    # Tools
    echo ""
    echo "  Build tools:"
    for cmd in clang cmake autoconf automake pkg-config bison git wget curl; do
        if command -v "$cmd" &>/dev/null; then
            printf "    %-12s ✓\n" "$cmd"
        else
            printf "    %-12s ✗ (missing)\n" "$cmd"
        fi
    done

    # osxcross
    echo ""
    echo "  Cross-compiler:"
    if echo 'int main(){return 0;}' | ${CC} -x c - -o /dev/null 2>/dev/null; then
        echo "    ${CC}  ✓"
    else
        echo "    ${CC}  ✗ (run ./install-env.sh)"
    fi

    # Static libs
    echo ""
    echo "  Static libraries:"
    [ -f "$CROSS_PREFIX/lib/libncursesw.a" ] && echo "    ncurses     ✓" || echo "    ncurses     ✗"
    [ -f "$CROSS_PREFIX/lib/libevent.a" ]    && echo "    libevent    ✓" || echo "    libevent    ✗"

    # Cellar
    echo ""
    local count
    count=$(find "$CELLAR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    echo "  Installed packages: $count"
    echo ""
}

# ============================================================
# Main
# ============================================================

CMD="${1:-}"
ARG="${2:-}"

case "$CMD" in
    install)  cmd_install "$ARG" ;;
    info)     cmd_info "$ARG" ;;
    search)   cmd_search "$ARG" ;;
    list)     cmd_list ;;
    doctor)   cmd_doctor ;;
    ""|help|-h|--help)
        echo ""
        info "brew.sh — Cross-compile Homebrew formulae for macOS Mojave"
        echo ""
        echo "  Usage:"
        echo "    $0 install <formula>    Download source + cross-compile"
        echo "    $0 info <formula>       Show formula details"
        echo "    $0 search <keyword>     Search Homebrew formulae"
        echo "    $0 list                 Show installed packages"
        echo "    $0 doctor               Check build environment"
        echo ""
        echo "  Custom recipes: tmux tree htop bash nano vim screen rsync socat jq nvim"
        echo "  Other formulae: tries generic autotools/cmake/make build"
        echo ""
        ;;
    *)
        err "Unknown command: $CMD (run $0 help)"
        ;;
esac
