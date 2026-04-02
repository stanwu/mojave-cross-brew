#!/bin/bash
set -e

echo "==> Setting up macOS Mojave cross-compile environment..."

# 1. Install apt packages + download sources
./install-env.sh

# 2. Build osxcross toolchain (takes ~5-15 min)
echo ""
echo "==> Building osxcross toolchain..."
./brew.sh doctor

echo ""
echo "==> Environment ready!"
echo ""
echo "  Usage:"
echo "    ./brew.sh install tmux"
echo "    ./brew.sh install tree"
echo "    ./brew.sh list"
echo ""
