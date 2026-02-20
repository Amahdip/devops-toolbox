#!/bin/bash
# ==============================================================================
# Script: connection-manager.sh (v2.0 - National-Ready)
# Description: Network Audit, Auto-Dependency, Parallel Ping & Xray Runner
# ==============================================================================

# --- STYLING ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"; echo -e "\n${GREEN}[✓] Temp files cleaned.${NC}"' EXIT

# --- 1. DEPENDENCY & XRAY INSTALLER ---
# This ensures even if GitHub is filtered later, you have the binaries NOW.
prepare_system() {
    echo -e "${BLUE}=== [1/4] Preparing System ===${NC}"
    local deps=("fzf" "curl" "jq" "base64" "column")
    for tool in "${deps[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${YELLOW}[!] Installing $tool...${NC}"
            sudo apt-get update -qq && sudo apt-get install -y -qq $tool > /dev/null 2>&1
        fi
    done

    if ! command -v xray &> /dev/null; then
        echo -e "${YELLOW}[!] Xray-core missing. Installing...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
    fi
    echo -e "${GREEN}[✓] System is ready.${NC}\n"
}

# --- 2. NETWORK AUDIT ---
run_audit() {
    echo -e "${BLUE}=== [2/4] Network Audit ===${NC}"
    # DNS Check
    DNS=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | head -n 1)
    host google.com &>/dev/null && echo -e "DNS ($DNS): ${GREEN}WORKING${NC}" || echo -e "DNS: ${RED}FAILED${NC}"
    
    # Intranet vs Internet
    ping -c 1 -W 2 8.8.8.8 &>/dev/null && echo -e "Global WAN: ${GREEN}ONLINE${NC}" || echo -e "Global WAN: ${RED}OFFLINE (Melli)${NC}"
    
    # Sanction Check
    local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 https://hub.docker.com)
    [[ "$code" == "403" ]] && echo -e "Docker Hub: ${RED}SANCTIONED (403)${NC}" || echo -e "Docker Hub: ${GREEN}OK ($code)${NC}"
    echo ""
}

# --- 3. FETCH & PARALLEL PING ---
manage_configs() {
    echo -e "${BLUE}=== [3/4] Fetching & Benchmarking ===${NC}"
    read -p "Paste Subscription URL: " SUB_URL
    [[ -z "$SUB_URL" ]] && exit 1

    local raw_data=$(curl -sL --max-time 10 "$SUB_URL" | base64 -d 2>/dev/null)
    [[ -z "$raw_data" ]] && { echo -e "${RED}Error: Link invalid or network blocked.${NC}"; exit 1; }

    echo -e "${CYAN}Testing latencies in parallel...${NC}"
    > "$WORK_DIR/results.txt"

    while read -r line; do
        [[ -z "$line" ]] && continue
        (
            # Simple extraction for VLESS
            local ip=$(echo "$line" | grep -oP '@\K[^:]+(?=:)')
            local name=$(echo "$line" | grep -oP '#\K.*' | sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\x\1/g;s/\\x/%\x/g' | xargs -0 printf "%b" 2>/dev/null)
            [[ -z "$name" ]] && name="Unnamed_Node"
            
            if [ -n "$ip" ]; then
                local lat=$(ping -c 1 -W 1 "$ip" 2>/dev/null | grep -oP 'time=\K[0-9.]+')
                [[ -z "$lat" ]] && lat="999.9"
                echo "$lat|$ip|$name|$line" >> "$WORK_DIR/results.txt"
            fi
        ) &
    done <<< "$raw_data"
    wait

    # Sort and Display with FZF
    echo "LATENCY|IP|NAME|LINK" > "$WORK_DIR/table.txt"
    sort -n -t '|' -k 1 "$WORK_DIR/ping_results.txt" 2>/dev/null | awk -F'|' '{printf "%s ms|%s|%s|%s\n", $1, $2, $3, $4}' >> "$WORK_DIR/table.txt"

    SELECTED=$(column -t -s '|' "$WORK_DIR/table.txt" | fzf --header="Select the best node (Sorted by Ping)" --with-nth=1,2,3 --layout=reverse)
}

# --- 4. CONVERT TO JSON & START ---
start_connection() {
    [[ -z "$SELECTED" ]] && exit 1
    local link=$(echo "$SELECTED" | awk '{print $NF}')
    
    echo -e "${BLUE}=== [4/4] Activating Connection ===${NC}"
    
    # Extraction for JSON
    local uuid=$(echo "$link" | grep -oP 'vless://\K[^@]+')
    local remote=$(echo "$link" | grep -oP '@\K[^:]+')
    local port=$(echo "$link" | grep -oP ':[0-9]+' | head -n 1 | tr -d ':')
    local sni=$(echo "$link" | grep -oP 'sni=\K[^&]+')
    local path=$(echo "$link" | grep -oP 'path=\K[^&]+' | sed 's/%2F/\//g')

    # Minimal Xray Config
    cat <<EOF > /usr/local/etc/xray/config.json
{
    "inbounds": [{"port": 10808, "protocol": "socks", "settings": {"auth": "noauth"}}],
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": "$remote", "port": $port, "users": [{"id": "$uuid", "encryption": "none"}]}]},
        "streamSettings": {"network": "ws", "security": "tls", "tlsSettings": {"serverName": "$sni"}, "wsSettings": {"path": "$path"}}
    }]
}
EOF

    systemctl restart xray
    echo -e "${GREEN}[✓] Xray is running on SOCKS5 port 10808${NC}"
    echo -e "${YELLOW}Test it with: curl --proxy socks5h://127.0.0.1:10808 https://google.com${NC}"
}

# --- EXECUTION ---
clear
prepare_system
run_audit
manage_configs
start_connection
