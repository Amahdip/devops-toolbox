#!/bin/bash

# --- مرحله ۱: نصب پیش‌نیازها در صورت نبودن ---
REQUIRED_PKGS=(tmux htop ccze)
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v $pkg &> /dev/null; then
        echo "Installing $pkg..."
        sudo apt update && sudo apt install -y $pkg
    fi
done

SESSION="monitor"
tmux kill-session -t $SESSION 2>/dev/null
sleep 0.5

# --- مرحله ۲: ایجاد سشن و تنظیمات ---
tmux new-session -d -s $SESSION -n 'Dashboard'
tmux set -g mouse on
tmux set -g pane-border-status top

# پنل ۰: امنیت (در همه لینوکس‌ها مشترک است)
tmux select-pane -t $SESSION:0.0 -T " 🛡️ SECURITY "
tmux send-keys "journalctl -p 3 -f | ccze -A" C-m

# پنل ۱: تشخیص هوشمند لاگ اپلیکیشن
tmux split-window -h -p 50 -t $SESSION:0
if [ -f "/var/log/bbb-apps-akka/bbb-apps-akka.log" ]; then
    tmux select-pane -t $SESSION:0.1 -T " 📢 BBB LIVE (AKKA) "
    tmux send-keys "tail -f /var/log/bbb-apps-akka/bbb-apps-akka.log | ccze -A" C-m
elif [ -f "/var/log/nginx/error.log" ]; then
    tmux select-pane -t $SESSION:0.1 -T " 🌐 NGINX ERRORS "
    tmux send-keys "tail -f /var/log/nginx/error.log | ccze -A" C-m
else
    tmux select-pane -t $SESSION:0.1 -T " 📄 SYSTEM LOG "
    tmux send-keys "tail -f /var/log/syslog | ccze -A" C-m
fi

# پنل ۲: تشخیص داکر یا دیسک
tmux select-pane -t $SESSION:0.0
tmux split-window -v -p 50 -t $SESSION:0
if command -v docker &> /dev/null; then
    tmux select-pane -t $SESSION:0.2 -T " 🐳 DOCKER STATS "
    tmux send-keys "docker stats --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'" C-m
else
    tmux select-pane -t $SESSION:0.2 -T " 💾 DISK USAGE "
    tmux send-keys "watch -n 5 df -h" C-m
fi

# پنل ۳: سلامت سیستم (همیشه htop)
tmux select-pane -t $SESSION:0.1
tmux split-window -v -p 50 -t $SESSION:0
tmux select-pane -t $SESSION:0.3 -T " 📊 RESOURCES "
tmux send-keys "htop" C-m

# جابجایی به پنجره اول و اتصال
tmux new-window -t $SESSION -n 'Work'
tmux select-window -t $SESSION:0
tmux attach-session -t $SESSION
