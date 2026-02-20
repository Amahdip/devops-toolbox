#!/bin/bash
# ==============================================================================
# Script: connection-manager.sh (v2.1 - Robust Edition)
# Description: Network Audit, Auto-Dependency, Parallel Ping & Xray Runner
# ==============================================================================

# --- STYLING ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"; echo -e "\n${GREEN}[✓] Temp files cleaned.${NC}"' EXIT

# --- 1. DEPENDENCY & XRAY INSTALLER ---
prepare_system() {
    echo -e "${BLUE}=== [1/4] Preparing System ===${NC}"
    local deps=("fzf" "curl" "jq" "base64" "column" "python3")
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
    DNS=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | head -n 1)
    host google.com &>/dev/null && echo -e "DNS ($DNS): ${GREEN}WORKING${NC}" || echo -e "DNS: ${RED}FAILED${NC}"
    ping -c 1 -W 2 8.8.8.8 &>/dev/null && echo -e "Global WAN: ${GREEN}ONLINE${NC}" || echo -e "Global WAN: ${RED}OFFLINE (Melli)${NC}"
    local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 https://hub.docker.com)
    [[ "$code" == "403" ]] && echo -e "Docker Hub: ${RED}SANCTIONED (403)${NC}" || echo -e "Docker Hub: ${GREEN}OK ($code)${NC}"
    echo ""
}

# --- 3. FETCH & PARALLEL PING (Anti-Fragile Version) ---
manage_configs() {
    echo -e "${BLUE}=== [3/4] Fetching & Benchmarking ===${NC}"
    read -p "Paste Subscription URL: " SUB_URL
    [[ -z "$SUB_URL" ]] && exit 1

    echo -e "${CYAN}Downloading and sanitizing subscription...${NC}"
    
    # دانلود مستقیم و ذخیره در یک فایل موقت
    curl -sL -A "Mozilla/5.0" --max-time 15 "$SUB_URL" > "$WORK_DIR/downloaded.tmp"

    # استفاده از پایتون برای دیکود کردن هوشمند (حتی با وجود کاراکترهای کثیف)
    python3 <<EOF > "$WORK_DIR/raw_configs.txt" 2>/dev/null
import base64
try:
    with open("$WORK_DIR/downloaded.tmp", "r") as f:
        content = f.read().strip().replace(" ", "").replace("\n", "").replace("\r", "")
        # پاکسازی کاراکترهای غیر Base64 مثل % در انتها
        import re
        content = re.sub(r'[^a-zA-Z0-9+/=]', '', content)
        # اضافه کردن Padding اگر لازم باشد
        missing_padding = len(content) % 4
        if missing_padding:
            content += '=' * (4 - missing_padding)
        decoded = base64.b64decode(content).decode('utf-8', 'ignore')
        print(decoded)
except Exception as e:
    pass
EOF

    if [[ ! -s "$WORK_DIR/raw_configs.txt" ]]; then
        echo -e "${RED}Error: Critical decoding failure.${NC}"
        echo -e "${YELLOW}Please check if the URL content is valid Base64.${NC}"
        exit 1
    fi

    # ادامه اسکریپت (بخش پینگ و جدول) ...
    echo -e "${CYAN}Testing latencies in parallel...${NC}"
    # ... بقیه کدهای قبلی ...


# --- 4. CONVERT TO JSON & START ---
start_connection() {
    [[ -z "$SELECTED" ]] && exit 1
    local link=$(echo "$SELECTED" | awk '{print $NF}')
    
    echo -e "${BLUE}=== [4/4] Activating Connection ===${NC}"
    
    # Advanced extraction for VLESS (WS or Reality)
    local uuid=$(echo "$link" | grep -oP 'vless://\K[^@]+')
    local remote=$(echo "$link" | grep -oP '@\K[^:]+')
    local port=$(echo "$link" | grep -oP ':[0-9]+' | head -n 1 | tr -d ':')
    local sni=$(echo "$link" | grep -oP 'sni=\K[^&]+')
    local security=$(echo "$link" | grep -oP 'security=\K[^&]+')
    local type=$(echo "$link" | grep -oP 'type=\K[^&]+')

    # Build Xray Outbound
    local outbound_json
    if [[ "$security" == "reality" ]]; then
        local pbk=$(echo "$link" | grep -oP 'pbk=\K[^&]+')
        local sid=$(echo "$link" | grep -oP 'sid=\K[^&]+')
        local fp=$(echo "$link" | grep -oP 'fp=\K[^&]+')
        outbound_json=$(cat <<EOF
        {
            "protocol": "vless",
            "settings": {"vnext": [{"address": "$remote", "port": $port, "users": [{"id": "$uuid", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
            "streamSettings": {
                "network": "$type", "security": "reality",
                "realitySettings": {"show": false, "fingerprint": "$fp", "serverName": "$sni", "publicKey": "$pbk", "shortId": "$sid"}
            }
        }
EOF
)
    else
        local path=$(echo "$link" | grep -oP 'path=\K[^&]+' | sed 's/%2F/\//g')
        outbound_json=$(cat <<EOF
        {
            "protocol": "vless",
            "settings": {"vnext": [{"address": "$remote", "port": $port, "users": [{"id": "$uuid", "encryption": "none"}]}]},
            "streamSettings": {"network": "ws", "security": "tls", "tlsSettings": {"serverName": "$sni"}, "wsSettings": {"path": "$path"}}
        }
EOF
)
    fi

    # Write Config
    cat <<EOF > /usr/local/etc/xray/config.json
{
    "log": {"loglevel": "warning"},
    "inbounds": [{"port": 10808, "protocol": "socks", "settings": {"auth": "noauth"}}],
    "outbounds": [$outbound_json]
}
EOF

    systemctl restart xray
    echo -e "${GREEN}[✓] Xray is active on SOCKS5 port 10808${NC}"
    echo -e "${YELLOW}Test: curl --proxy socks5h://127.0.0.1:10808 https://google.com${NC}"
}

# --- EXECUTION ---
clear
prepare_system
run_audit
manage_configs
start_connection
