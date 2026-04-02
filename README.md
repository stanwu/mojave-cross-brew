# mojave-cross-brew

**Ubuntu 24.04 上交叉編譯 macOS Mojave (10.14) CLI 工具**

在 Ubuntu 24.04（WSL2 / Codespace / native）上使用 [osxcross](https://github.com/tpoechtrager/osxcross) 交叉編譯工具鏈，將 Homebrew formulae 的原始碼編譯成 macOS Mojave x86_64 可執行的 Mach-O binary。

適用場景：老舊 Mac（RAM/磁碟不足以本機編譯）、Homebrew 已不支援 Mojave pre-built bottle。

Source code is automatically fetched from [Homebrew formulae](https://github.com/Homebrew/homebrew-core) — no brew installation needed on the build machine.

## Requirements

- **Ubuntu 24.04** (WSL2, GitHub Codespace, or native)
- ~3 GB disk, ~2 GB RAM peak
- Internet connection (for downloading sources)

## Quick Start

```bash
# 1. Setup build environment (installs apt packages + downloads toolchain)
make setup

# 2. Build a single tool
make tmux

# 3. Or build everything
make all

# 4. Deploy to Mojave machine
make deploy
```

## Available Tools

| Tool | Type | Dependencies |
|------|------|-------------|
| tmux | cross-compile | libevent + ncurses |
| tree | cross-compile | none |
| htop | cross-compile | ncurses |
| bash | cross-compile | ncurses |
| nano | cross-compile | ncurses |
| vim | cross-compile | ncurses |
| screen | cross-compile | ncurses |
| rsync | cross-compile | none |
| socat | cross-compile | none |
| jq | pre-built download | — |
| nvim | pre-built download | — |

## How It Works

```
install-env.sh          Setup Ubuntu build env + download osxcross/SDK
        │
   build.sh <tool>      Fetch source from brew formula → cross-compile
        │
     output/             Mach-O x86_64 binaries ready to deploy
        │
install-tmux-macos-     Fix terminfo + install on Mojave
  mojave.sh
```

### Toolchain

- **osxcross** — provides `x86_64-apple-darwin18-clang` cross-compiler
- **macOS 10.14 SDK** — from [phracker/MacOSX-SDKs](https://github.com/phracker/MacOSX-SDKs)
- **Source URLs** — parsed from Homebrew formulae on GitHub (no brew installation needed)

### Static Linking

Dependencies (libevent, ncurses) are statically linked. Output binaries only depend on macOS system libraries (`libSystem`, `libresolv`), so nothing needs to be installed on the target Mac.

## Files

```
├── Makefile                       # Make targets
├── build.sh                       # Main build script
├── install-env.sh                 # Ubuntu env setup (apt + downloads)
├── install-tmux-macos-mojave.sh   # Mojave install helper (terminfo fix)
├── test-tmux.sh                   # tmux functionality test
└── output/                        # Built binaries (git-ignored)
```

## Known Issues

### Mojave Compatibility

- **jq 1.7+** and **nvim 0.10+** use `LC_BUILD_VERSION` load command unsupported by Mojave's dyld. Older pre-built versions are used instead.
- **terminfo**: Cross-compiled ncurses looks for letter-named dirs (`x/`) but Mojave uses hex-named dirs (`78/`). The install script creates symlinks to fix this.

### osxcross SDK

The macOS 10.14 SDK from phracker is missing libc++ headers. `install-env.sh` installs `libc++-XX-dev` and `build.sh` copies the headers into the SDK automatically.
