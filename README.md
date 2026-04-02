# mojave-cross-brew

[![Build macOS Mojave Tools](https://github.com/stanwu/mojave-cross-brew/actions/workflows/build.yml/badge.svg)](https://github.com/stanwu/mojave-cross-brew/actions/workflows/build.yml)
[![GitHub Release](https://img.shields.io/github/v/release/stanwu/mojave-cross-brew)](https://github.com/stanwu/mojave-cross-brew/releases/latest)

**Cross-compile Homebrew CLI tools for macOS Mojave (10.14 x86_64) on Ubuntu 24.04**

> **Download pre-built binaries:** [Latest Release](https://github.com/stanwu/mojave-cross-brew/releases/latest)

Use [osxcross](https://github.com/tpoechtrager/osxcross) on Ubuntu 24.04 (WSL2 / GitHub Codespace / native) to cross-compile Homebrew formulae source code into Mach-O binaries that run on macOS Mojave.

Built for old Macs where RAM/disk is too limited to compile locally, and Homebrew no longer provides pre-built bottles for Mojave.

Source URLs are automatically parsed from [Homebrew formulae on GitHub](https://github.com/Homebrew/homebrew-core) — no brew installation needed on the build machine.

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

Or use the brew-like interface:

```bash
./brew.sh install tmux
./brew.sh install tree
./brew.sh search editor
./brew.sh list
./brew.sh doctor
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

Other Homebrew formulae can also be built using the generic autotools/cmake/make recipe.

## How It Works

```
install-env.sh          Setup Ubuntu 24.04 build env + download osxcross/SDK
        |
   brew.sh install      Parse brew formula -> fetch source -> cross-compile
        |
     cellar/             Mach-O x86_64 binaries ready to deploy
        |
   scp to Mac            Transfer binaries to macOS Mojave target
```

### Toolchain

- **osxcross** — provides `x86_64-apple-darwin18-clang` cross-compiler
- **macOS 10.14 SDK** — from [phracker/MacOSX-SDKs](https://github.com/phracker/MacOSX-SDKs)
- **Source URLs** — parsed from Homebrew formulae on GitHub (no brew installation needed)

### Static Linking

Dependencies (libevent, ncurses) are statically linked. Output binaries only depend on macOS system libraries (`libSystem`, `libresolv`), so nothing extra needs to be installed on the target Mac.

## Files

```
├── brew.sh                        # Brew-like CLI (install/search/info/list/doctor)
├── build.sh                       # Low-level build script with per-tool recipes
├── install-env.sh                 # Ubuntu 24.04 environment setup (apt + downloads)
├── install-tmux-macos-mojave.sh   # Mojave-side install helper (terminfo fix)
├── test-tmux.sh                   # tmux functionality test
├── Makefile                       # Make targets (setup/build/deploy/clean)
├── scripts/
│   └── check-pii.sh              # Pre-commit hook: block personal path leaks
├── .devcontainer/                 # GitHub Codespace auto-setup
│   ├── devcontainer.json
│   └── post-create.sh
└── .pre-commit-config.yaml        # Security + lint hooks
```

## GitHub Codespace

This repo includes a `.devcontainer` configuration. Opening it in GitHub Codespace will automatically:

1. Provision an Ubuntu 24.04 container
2. Install all build dependencies via `install-env.sh`
3. Download osxcross toolchain and macOS 10.14 SDK

After setup completes, run `./brew.sh install <tool>` to start building.

## Known Issues

### Mojave Compatibility

- **jq 1.7+** and **nvim 0.10+** use `LC_BUILD_VERSION` load command unsupported by Mojave's dyld. Older pre-built versions are used instead.
- **terminfo**: Cross-compiled ncurses looks for letter-named dirs (`x/`) but Mojave uses hex-named dirs (`78/`). The install script creates symlinks to fix this.

### osxcross SDK

The macOS 10.14 SDK from phracker is missing libc++ headers. `install-env.sh` installs `libc++-XX-dev` and `build.sh` copies the headers into the SDK automatically.

## License

MIT
