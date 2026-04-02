#!/bin/bash
export PATH="/usr/local/bin:$PATH"
export TERM=xterm-256color
export TERMINFO=/usr/local/opt/ncurses/share/terminfo

echo "=== tmux 測試 ==="
echo ""

# 1. 版本
echo "1. 版本檢查:"
tmux -V
echo ""

# 2. 啟動 session
echo "2. 啟動 session 測試:"
tmux new-session -d -s test-session 2>&1 && echo "   建立 session: OK" || echo "   建立 session: FAIL"

# 3. 列出 sessions
echo "3. 列出 sessions:"
tmux list-sessions 2>&1
echo ""

# 4. 執行指令
echo "4. 執行指令測試:"
tmux send-keys -t test-session "echo hello-from-tmux" Enter
sleep 0.5
tmux capture-pane -t test-session -p | grep -q "hello-from-tmux" && echo "   send-keys + capture: OK" || echo "   send-keys + capture: FAIL"
echo ""

# 5. 分割視窗
echo "5. 分割視窗測試:"
tmux split-window -t test-session 2>&1 && echo "   split-window: OK" || echo "   split-window: FAIL"
echo "   panes: $(tmux list-panes -t test-session | wc -l | tr -d ' ')"
echo ""

# 6. 新 window
echo "6. 新 window 測試:"
tmux new-window -t test-session 2>&1 && echo "   new-window: OK" || echo "   new-window: FAIL"
echo "   windows: $(tmux list-windows -t test-session | wc -l | tr -d ' ')"
echo ""

# 7. 清理
echo "7. 清理:"
tmux kill-session -t test-session 2>&1 && echo "   kill-session: OK" || echo "   kill-session: FAIL"

echo ""
echo "=== 測試完成 ==="
