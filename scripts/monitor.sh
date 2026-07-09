#!/usr/bin/env bash
#
# devops-monitor — an interactive tmux dashboard that composes best-in-class
# monitoring tools (btop, lazydocker, nload, ncdu, ...) into one session.
#
# Usage: monitor.sh [--install] [--help] [--version]

set -euo pipefail

VERSION="0.2.0"
SESSION="monitor"
REQUIRED_PKGS=(tmux ccze btop whiptail nload ncdu)

# --- CLI ---------------------------------------------------------------------

usage() {
    cat <<EOF
devops-monitor $VERSION

Interactive tmux monitoring dashboard. Pick modules from a checklist;
light panes share one dashboard window, heavier tools get their own tabs.

Usage: ${0##*/} [OPTIONS]

Options:
  --install      Offer to install missing dependencies (uses sudo, asks first)
  -h, --help     Show this help and exit
  -V, --version  Print version and exit

Required tools: ${REQUIRED_PKGS[*]}
Optional:       docker + lazydocker (container dashboard), nginx (app logs)
EOF
}

DO_INSTALL=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)    DO_INSTALL=true ;;
        -h|--help)    usage; exit 0 ;;
        -V|--version) echo "$VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --- Dependencies ------------------------------------------------------------
# We never install anything without being asked (--install) and confirming.

detect_pkg_manager() {
    local pm
    for pm in apt-get dnf yum pacman zypper apk; do
        if command -v "$pm" &>/dev/null; then
            echo "$pm"
            return 0
        fi
    done
    return 1
}

install_pkgs() {
    local pm="$1"; shift
    case "$pm" in
        apt-get) sudo apt-get update && sudo apt-get install -y "$@" ;;
        dnf)     sudo dnf install -y "$@" ;;
        yum)     sudo yum install -y "$@" ;;
        pacman)  sudo pacman -S --needed "$@" ;;
        zypper)  sudo zypper install -y "$@" ;;
        apk)     sudo apk add "$@" ;;
    esac
}

MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    command -v "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if ((${#MISSING[@]} > 0)); then
    echo "Missing dependencies: ${MISSING[*]}" >&2
    if [[ "$DO_INSTALL" == true ]]; then
        if ! PM=$(detect_pkg_manager); then
            echo "No supported package manager found (apt/dnf/yum/pacman/zypper/apk)." >&2
            exit 1
        fi
        printf 'Install them now via %s (requires sudo)? [y/N] ' "$PM"
        read -r REPLY
        [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
        install_pkgs "$PM" "${MISSING[@]}"
    else
        echo "Install them with your package manager, or re-run with --install." >&2
        exit 1
    fi
fi

# --- Optional modules ---------------------------------------------------------

HAS_DOCKER="OFF"
if command -v docker &>/dev/null && docker info &>/dev/null; then
    if command -v lazydocker &>/dev/null; then
        HAS_DOCKER="ON"
    else
        echo "Note: Docker detected, but lazydocker is not installed — Docker module disabled."
        echo "      Install it: https://github.com/jesseduffield/lazydocker#installation"
    fi
fi

HAS_NGINX="OFF"
if [[ -f /var/log/nginx/error.log ]]; then
    HAS_NGINX="ON"
fi

# --- Module selection ----------------------------------------------------------

CHOICES=$(whiptail --title "DevOps Monitor v$VERSION" --checklist \
    "Select modules. Items marked (Tab) open in their own tmux window:" 22 78 8 \
    "SECURITY"   "Auth/SSH logs (Main Dash)" ON \
    "APP_LOGS"   "App/System logs (Main Dash)" ON \
    "LAZYDOCKER" "Docker Manager (Main Dash)" "$HAS_DOCKER" \
    "SYSTEM"     "CPU/RAM Visual - btop (Main Dash)" ON \
    "NETWORK"    "Live Bandwidth - nload (Tab)" ON \
    "PORTS"      "Listening Ports (Tab)" ON \
    "STORAGE"    "Disk Usage Analyzer - ncdu (Tab)" ON \
    "PING"       "Live Network Latency (Tab)" ON \
    3>&1 1>&2 2>&3) || exit 0

read -ra MODULES <<< "$(tr -d '"' <<< "$CHOICES")"
if ((${#MODULES[@]} == 0)); then
    exit 0
fi

# --- Tmux session ---------------------------------------------------------------
# Never silently destroy an existing session — offer to attach instead.

if tmux has-session -t "$SESSION" 2>/dev/null; then
    if whiptail --title "Session already running" --yesno \
        "A '$SESSION' tmux session already exists.\n\nAttach to it? (choosing 'No' replaces it)" 10 60; then
        exec tmux attach-session -t "$SESSION"
    fi
    tmux kill-session -t "$SESSION"
fi

tmux new-session -d -s "$SESSION" -n Dashboard
tmux set-option -t "$SESSION" mouse on
tmux set-window-option -t "$SESSION:0" pane-border-status top

# --- Layout ----------------------------------------------------------------------

DASH_IDX=0

add_dash_pane() {
    local title="$1" cmd="$2"
    if ((DASH_IDX > 0)); then
        tmux split-window -t "$SESSION:0"
    fi
    tmux select-pane -t "$SESSION:0.$DASH_IDX" -T "$title"
    tmux send-keys -t "$SESSION:0.$DASH_IDX" "$cmd" C-m
    DASH_IDX=$((DASH_IDX + 1))
}

add_tab() {
    local name="$1" cmd="$2"
    tmux new-window -t "$SESSION" -n "$name"
    tmux send-keys -t "$SESSION:$name" "$cmd" C-m
}

security_cmd() {
    # Actual auth/SSH activity, not just priority-3 errors.
    if command -v journalctl &>/dev/null; then
        echo "journalctl -f -u ssh -u sshd | ccze -A"
    else
        echo "tail -f /var/log/auth.log | ccze -A"
    fi
}

app_logs_cmd() {
    if [[ "$HAS_NGINX" == "ON" ]]; then
        echo "tail -f /var/log/nginx/error.log | ccze -A"
    elif [[ -f /var/log/syslog ]]; then
        echo "tail -f /var/log/syslog | ccze -A"
    elif command -v journalctl &>/dev/null; then
        echo "journalctl -f | ccze -A"
    else
        echo "tail -f /var/log/messages | ccze -A"
    fi
}

for MOD in "${MODULES[@]}"; do
    case "$MOD" in
        SECURITY)   add_dash_pane " 🛡️ SECURITY "   "$(security_cmd)" ;;
        APP_LOGS)   add_dash_pane " 📄 APP LOGS "   "$(app_logs_cmd)" ;;
        LAZYDOCKER) add_dash_pane " 🐳 LAZYDOCKER " "lazydocker" ;;
        SYSTEM)     add_dash_pane " 📊 RESOURCES "  "btop" ;;
        NETWORK)    add_tab Network "nload" ;;
        PORTS)      add_tab Ports "watch -n 5 'ss -tulpn | grep LISTEN'" ;;
        # -x: stay on this filesystem (don't descend into /proc, mounts, ...)
        STORAGE)    add_tab Storage "ncdu -x /" ;;
        PING)       add_tab Ping 'watch -n 2 "echo == IP: 8.8.8.8 ==; ping -c 1 -W 2 8.8.8.8 | grep time=; echo; echo == DNS: google.com ==; ping -c 1 -W 2 google.com | grep time="' ;;
    esac
done

if ((DASH_IDX > 0)); then
    tmux select-layout -t "$SESSION:0" tiled
fi

# A plain shell tab for ad-hoc work.
tmux new-window -t "$SESSION" -n Terminal
tmux select-window -t "$SESSION:0"
exec tmux attach-session -t "$SESSION"
