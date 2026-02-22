#!/bin/bash

# --- Step 1: Install prerequisites ---
REQUIRED_PKGS=(tmux ccze btop whiptail nload curl)
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v $pkg &> /dev/null; then
        echo "Installing $pkg..."
        sudo apt update && sudo apt install -y $pkg
    fi
done

# --- Step 2: Auto-detect Docker & Install Lazydocker ---
HAS_DOCKER="OFF"
if command -v docker &> /dev/null && sudo docker info &> /dev/null; then
    HAS_DOCKER="ON"
    # Install lazydocker if it doesn't exist
    if ! command -v lazydocker &> /dev/null; then
        echo "Installing Lazydocker for pro container management..."
        curl -s https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
        sudo mv ~/.local/bin/lazydocker /usr/local/bin/ 2>/dev/null || true
    fi
fi

HAS_NGINX="OFF"
if [ -f "/var/log/nginx/error.log" ]; then
    HAS_NGINX="ON"
fi

# --- Step 3: Interactive Pro Menu ---
CHOICES=$(whiptail --title "DevOps Pro Monitor Setup" --checklist \
"Select the modules to display (Space to toggle, Enter to confirm):" 20 70 6 \
"SECURITY"   "Auth and SSH security logs" ON \
"APP_LOGS"   "Application or System logs" ON \
"LAZYDOCKER" "Interactive Docker Manager" $HAS_DOCKER \
"SYSTEM"     "Visual CPU/RAM/Disk (btop)" ON \
"NETWORK"    "Live Network Traffic (nload)" ON \
"PORTS"      "Listening Ports Monitor" OFF \
3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    echo "Dashboard setup cancelled."
    exit 0
fi

CHOICES=$(echo $CHOICES | tr -d '"')

if [ -z "$CHOICES" ]; then
    echo "No modules selected. Exiting."
    exit 0
fi

# --- Step 4: Setup Tmux Session ---
SESSION="monitor"
tmux kill-session -t $SESSION 2>/dev/null
sleep 0.5

tmux new-session -d -s $SESSION -n 'Dashboard'
tmux set -g mouse on
tmux set -g pane-border-status top

# --- Step 5: Create Dynamic Panes based on selection ---
read -a SELECTED_MODULES <<< "$CHOICES"
PANE_IDX=0

for MOD in "${SELECTED_MODULES[@]}"; do
    if [ $PANE_IDX -gt 0 ]; then
        tmux split-window -t $SESSION:0
    fi

    case $MOD in
        SECURITY)
            TITLE=" 🛡️ SECURITY "
            CMD="journalctl -p 3 -f | ccze -A"
            ;;
        APP_LOGS)
            TITLE=" 📄 APP LOGS "
            if [ "$HAS_NGINX" == "ON" ]; then
                CMD="tail -f /var/log/nginx/error.log | ccze -A"
            elif [ -f "/var/log/bbb-apps-akka/bbb-apps-akka.log" ]; then
                CMD="tail -f /var/log/bbb-apps-akka/bbb-apps-akka.log | ccze -A"
            else
                CMD="tail -f /var/log/syslog | ccze -A"
            fi
            ;;
        LAZYDOCKER)
            TITLE=" 🐳 LAZYDOCKER "
            if command -v lazydocker &> /dev/null; then
                CMD="lazydocker"
            else
                CMD="docker stats --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'"
            fi
            ;;
        SYSTEM)
            TITLE=" 📊 RESOURCES (BTOP) "
            CMD="btop"
            ;;
        NETWORK)
            TITLE=" 🌐 NETWORK (NLOAD) "
            CMD="nload"
            ;;
        PORTS)
            TITLE=" 🔌 LIVE PORTS "
            CMD="watch -n 5 'ss -tulpn | grep LISTEN'"
            ;;
    esac

    tmux select-pane -t $SESSION:0.$PANE_IDX -T "$TITLE"
    tmux send-keys -t $SESSION:0.$PANE_IDX "$CMD" C-m

    ((PANE_IDX++))
done

# Arrange panes neatly
tmux select-layout -t $SESSION:0 tiled

# --- Step 6: Create background workspace and Attach ---
tmux new-window -t $SESSION -n 'Terminal'
tmux select-window -t $SESSION:0
tmux attach-session -t $SESSION
