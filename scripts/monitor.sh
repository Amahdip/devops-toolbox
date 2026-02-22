#!/bin/bash

# --- Step 1: Install prerequisites ---
# Added 'ncdu' for disk usage analysis
REQUIRED_PKGS=(tmux ccze btop whiptail nload curl ncdu)
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v $pkg &> /dev/null; then
        echo "Installing $pkg..."
        sudo apt update && sudo apt install -y $pkg
    fi
done

# --- Step 2: Auto-detect Docker & Lazydocker ---
HAS_DOCKER="OFF"
if command -v docker &> /dev/null && sudo docker info &> /dev/null; then
    HAS_DOCKER="ON"
    if ! command -v lazydocker &> /dev/null; then
        echo "Installing Lazydocker..."
        curl -s https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
        sudo mv ~/.local/bin/lazydocker /usr/local/bin/ 2>/dev/null || true
    fi
fi

HAS_NGINX="OFF"
[ -f "/var/log/nginx/error.log" ] && HAS_NGINX="ON"

# --- Step 3: The Ultimate Interactive Menu ---
CHOICES=$(whiptail --title "Ultimate DevOps Monitor" --checklist \
"Select modules. Items marked (Tab) will open in a separate window:" 22 78 8 \
"SECURITY"   "Auth/SSH logs (Main Dash)" ON \
"APP_LOGS"   "App/System logs (Main Dash)" ON \
"LAZYDOCKER" "Docker Manager (Main Dash)" $HAS_DOCKER \
"SYSTEM"     "CPU/RAM Visual (Main Dash)" ON \
"NETWORK"    "Live Bandwidth - nload (Tab)" ON \
"PORTS"      "Listening Ports (Tab)" ON \
"STORAGE"    "Disk Usage Analyzer - ncdu (Tab)" ON \
"PING"       "Live Network Latency (Tab)" ON \
3>&1 1>&2 2>&3)

[ $? -ne 0 ] && exit 0
CHOICES=$(echo $CHOICES | tr -d '"')

# --- Step 4: Setup Tmux Session ---
SESSION="monitor"
tmux kill-session -t $SESSION 2>/dev/null
sleep 0.5
tmux new-session -d -s $SESSION -n 'Dashboard'
tmux set -g mouse on
tmux set -g pane-border-status top

# --- Step 5: Logical Distribution ---
DASH_IDX=0
for MOD in $CHOICES; do
    case $MOD in
        SECURITY|APP_LOGS|LAZYDOCKER|SYSTEM)
            # --- MAIN DASHBOARD WINDOW ---
            [ $DASH_IDX -gt 0 ] && tmux split-window -t $SESSION:0
            
            if [ "$MOD" == "SECURITY" ]; then
                TITLE=" 🛡️ SECURITY "; CMD="journalctl -p 3 -f | ccze -A"
            elif [ "$MOD" == "APP_LOGS" ]; then
                TITLE=" 📄 APP LOGS "
                [ "$HAS_NGINX" == "ON" ] && CMD="tail -f /var/log/nginx/error.log | ccze -A" || CMD="tail -f /var/log/syslog | ccze -A"
            elif [ "$MOD" == "LAZYDOCKER" ]; then
                TITLE=" 🐳 LAZYDOCKER "; CMD="lazydocker"
            elif [ "$MOD" == "SYSTEM" ]; then
                TITLE=" 📊 RESOURCES "; CMD="btop"
            fi
            
            tmux select-pane -t $SESSION:0.$DASH_IDX -T "$TITLE"
            tmux send-keys -t $SESSION:0.$DASH_IDX "$CMD" C-m
            ((DASH_IDX++))
            ;;
            
        NETWORK)
            # --- TABS (NEW WINDOWS) ---
            tmux new-window -t $SESSION -n 'Network'
            tmux send-keys -t $SESSION:'Network' "nload" C-m
            ;;
        PORTS)
            tmux new-window -t $SESSION -n 'Ports'
            tmux send-keys -t $SESSION:'Ports' "watch -n 5 'ss -tulpn | grep LISTEN'" C-m
            ;;
        STORAGE)
            tmux new-window -t $SESSION -n 'Storage'
            # Runs ncdu in the root directory to find large files
            tmux send-keys -t $SESSION:'Storage' "echo 'Scanning disk space, please wait...' && ncdu /" C-m
            ;;
        PING)
            tmux new-window -t $SESSION -n 'Ping'
            # Pings Google DNS to check internet health
            tmux send-keys -t $SESSION:'Ping' "watch -n 1 'echo \"🌍 INTERNET CONNECTIVITY:\" && echo \"\" && ping -c 1 8.8.8.8 | grep \"time=\" && echo \"\" && ping -c 1 google.com | grep \"time=\"'" C-m
            ;;
    esac
done

# Arrange Dashboard panes
tmux select-layout -t $SESSION:0 tiled

# Final Tab for standard terminal work
tmux new-window -t $SESSION -n 'Terminal'
tmux select-window -t $SESSION:0
tmux attach-session -t $SESSION
