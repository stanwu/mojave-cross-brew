#!/bin/bash
# Install cross-compiled tmux on macOS Mojave (10.14)
# Run on the Mojave machine, not WSL2
set -e

TMUX_BIN="${1:-./tmux}"

log() { echo -e "\033[1;32m==> $1\033[0m"; }
err() { echo -e "\033[1;31m==> ERROR: $1\033[0m"; exit 1; }

# Check binary exists
[ -f "$TMUX_BIN" ] || err "tmux binary not found: $TMUX_BIN"
file "$TMUX_BIN" | grep -q "Mach-O" || err "Not a Mach-O binary"

# 1. Install tmux binary
log "Installing tmux to /usr/local/bin/"
chmod +x "$TMUX_BIN"
if [ -w /usr/local/bin ]; then
    cp "$TMUX_BIN" /usr/local/bin/tmux
else
    sudo cp "$TMUX_BIN" /usr/local/bin/tmux
fi
echo "   $(tmux -V)"

# 2. Fix terminfo: cross-compiled ncurses looks for letter-named dirs (x/)
#    but macOS uses hex-named dirs (78/)
log "Setting up terminfo symlinks in ~/.terminfo/"
if [ -d /usr/share/terminfo ]; then
    cd /usr/share/terminfo
    for hexdir in */; do
        hexdir=${hexdir%/}
        letter=$(printf "\\x$hexdir" 2>/dev/null) || continue
        if [ -n "$letter" ] && [ "$letter" != "$hexdir" ]; then
            mkdir -p ~/.terminfo/"$letter"
            for f in "$hexdir"/*; do
                name=$(basename "$f")
                ln -sf "../$hexdir/$name" ~/.terminfo/"$letter"/"$name" 2>/dev/null
            done
        fi
    done
    echo "   $(find ~/.terminfo -type l | wc -l | tr -d ' ') symlinks created"
fi

# 3. Add TERM to shell profile if not set
log "Checking shell profile..."
PROFILE="$HOME/.bash_profile"
[ -f "$HOME/.zshrc" ] && PROFILE="$HOME/.zshrc"

if ! grep -q 'TERM=xterm-256color' "$PROFILE" 2>/dev/null; then
    echo 'export TERM=xterm-256color' >> "$PROFILE"
    echo "   Added TERM=xterm-256color to $PROFILE"
else
    echo "   TERM already set in $PROFILE"
fi

# 4. Remove quarantine attribute (Gatekeeper)
log "Removing quarantine attribute..."
xattr -cr /usr/local/bin/tmux 2>/dev/null || true

# 5. Test
log "Testing tmux..."
export TERM=xterm-256color
tmux new-session -d -s install-test 2>&1 && {
    tmux list-sessions
    tmux kill-session -t install-test
    echo "   Test: OK"
} || err "tmux failed to start"

log "Installation complete!"
echo ""
echo "  Usage: tmux new -s main"
echo ""
