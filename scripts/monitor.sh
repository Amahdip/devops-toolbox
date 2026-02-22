#!/bin/bash

# --- Step 1: Install prerequisites ---
# We replaced htop with 'btop' for the graphical speedometer look
# 'whiptail' is used for the interactive menu
REQUIRED_PKGS=(tmux ccze btop whiptail)
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v $pkg &> /dev/null; then
        echo "Installing $pkg..."
        sudo apt update && sudo apt install -y $pkg
    fi
done

# --- Step 2: Auto-detect environment for default menu selections ---
HAS_DOCKER="OFF"
if command -v docker &> /dev/null && sudo docker info &> /dev/null; then
    HAS_DOCKER="ON"
fi

HAS_NGINX="OFF"
if [ -f "/var/log/nginx/error.log" ]; then
    HAS_NGINX="ON"
fi

# --- Step 3: Interactive Menu ---
# Displays a checklist prompt. Use SPACE to check/uncheck, ENTER to confirm.
CHOICES=$(whiptail --title "System Monitor Setup" --checklist \
"Select the modules you want to display (Space to toggle, Enter to confirm):" 15 65 4 \
"SECURITY" "Auth and SSH security logs" ON \
"APP_LOGS" "Application or System logs" ON \
"DOCKER"   "Docker containers status" $HAS_DOCKER \
"SYSTEM"   "Visual CPU/RAM/Disk (btop)" ON \
3>&1 1>&2 2>&3)

# Exit if user cancelled (ESC or Cancel button)
if [ $? -ne 0 ]; then
    echo "Dashboard setup cancelled."
    exit 0
fi

# Clean the whiptail output (removes quotes)
CHOICES=$(echo $CHOICES | tr -d '"')

# Exit if nothing was selected
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
    # Split window for every module after the first one
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
        DOCKER)
            TITLE=" 🐳 DOCKER "
            CMD="docker stats --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'"
            ;;
        SYSTEM)
            TITLE=" 📊 RESOURCES (BTOP) "
            CMD="btop"
            ;;
    esac

    # Set Pane Title and Execute Command
    tmux select-pane -t $SESSION:0.$PANE_IDX -T "$TITLE"
    tmux send-keys -t $SESSION:0.$PANE_IDX "$CMD" C-m

    ((PANE_IDX++))
done

# Let tmux automatically arrange the panes beautifully based on count
tmux select-layout -t $SESSION:0 tiled

# --- Step 6: Create a background workspace and Attach ---
tmux new-window -t $SESSION -n 'Terminal'
tmux select-window -t $SESSION:0
tmux attach-session -t $SESSION
