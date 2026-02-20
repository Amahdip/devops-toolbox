#!/usr/bin/env bash
# ==============================================================================
# Script: connection-manager.sh (v2.2 - Fixed & Robust)
# Description: Network Audit, Auto-Dependency, Subscription Decode, Benchmark & Xray Runner
# Supports:
#   1) Subscription URL (Base64 list of links)
#   2) Single share link (vless://, vmess://, trojan:// - vless fully supported here)
#   3) Full V2Ray/Xray JSON config (installs directly)
# ==============================================================================

set -euo pipefail

TTY_IN="/dev/tty"
if [[ ! -r "$TTY_IN" ]]; then
  echo "[x] No TTY available for interactive input. Run without piping, or add non-interactive flags." >&2
  exit 1
fi

# --- STYLING ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"; echo -e "\n${GREEN}[✓] Temp files cleaned.${NC}"' EXIT

PARALLELISM=20

die() {
  echo -e "${RED}[x] $*${NC}" >&2
  exit 1
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (recommended: curl ... | sudo bash)"
  fi
}

url_decode() {
  # decodes %xx and plus to space
  python3 - <<'PY'
import sys, urllib.parse
print(urllib.parse.unquote_plus(sys.stdin.read().strip()))
PY
}

prepare_system() {
  echo -e "${BLUE}=== [1/4] Preparing System ===${NC}"

  # host comes from dnsutils on ubuntu
  local deps=("fzf" "curl" "jq" "python3" "dnsutils" "iputils-ping" "ca-certificates")
  export DEBIAN_FRONTEND=noninteractive

  for tool in "${deps[@]}"; do
    # packages vs commands: best-effort check by command for the common tools
    case "$tool" in
      dnsutils|iputils-ping|ca-certificates) ;;
      *)
        if command -v "$tool" &>/dev/null; then
          continue
        fi
        ;;
    esac
    echo -e "${YELLOW}[!] Installing: $tool ...${NC}"
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq "$tool" >/dev/null 2>&1 || true
  done

  if ! command -v xray &>/dev/null; then
    echo -e "${YELLOW}[!] Xray-core missing. Installing...${NC}"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || \
      die "Failed to install xray-core."
  fi

  mkdir -p /usr/local/etc/xray
  echo -e "${GREEN}[✓] System is ready.${NC}\n"
}

run_audit() {
  echo -e "${BLUE}=== [2/4] Network Audit ===${NC}"

  local DNS=""
  DNS="$(grep -m1 "nameserver" /etc/resolv.conf | awk '{print $2}' || true)"

  if host google.com &>/dev/null; then
    echo -e "DNS (${DNS:-unknown}): ${GREEN}WORKING${NC}"
  else
    echo -e "DNS (${DNS:-unknown}): ${RED}FAILED${NC}"
  fi

  if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    echo -e "Global WAN: ${GREEN}ONLINE${NC}"
  else
    echo -e "Global WAN: ${RED}OFFLINE (or ICMP blocked)${NC}"
  fi

  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 https://hub.docker.com || true)"
  if [[ "$code" == "403" ]]; then
    echo -e "Docker Hub: ${RED}BLOCKED (403)${NC}"
  else
    echo -e "Docker Hub: ${GREEN}OK${NC} (HTTP $code)"
  fi

  echo ""
}

# ---- Parsing helpers ----
extract_vless_host_port() {
  # input: vless://uuid@host:port?....#name
  local link="$1"
  local host port

  host="$(echo "$link" | grep -oP '@\K[^:?#]+' || true)"
  port="$(echo "$link" | grep -oP '@[^:]+:\K[0-9]+' || true)"

  [[ -z "$host" || -z "$port" ]] && return 1
  echo "$host:$port"
}

extract_display_name() {
  local link="$1"
  local name
  name="$(echo "$link" | sed -n 's/.*#//p' || true)"
  if [[ -n "$name" && "$name" != "$link" ]]; then
    printf "%s" "$name" | url_decode
  else
    # fallback: host
    if echo "$link" | grep -q '^vless://'; then
      echo "$(echo "$link" | grep -oP '@\K[^:?#]+' || echo "Unnamed")"
    else
      echo "Unnamed"
    fi
  fi
}

# ---- Benchmark: TCP connect timing (more reliable than ping) ----
tcp_latency_ms() {
  # prints ms or 9999 if fails
  python3 - <<'PY'
import socket, sys, time
hp = sys.argv[1]
host, port = hp.rsplit(":", 1)
port = int(port)
s = socket.socket()
s.settimeout(1.5)
t0 = time.time()
try:
    s.connect((host, port))
    dt = (time.time() - t0) * 1000
    print(int(dt))
except Exception:
    print(9999)
finally:
    try: s.close()
    except: pass
PY
}

decode_subscription_to_lines() {
  # Reads downloaded subscription file and outputs decoded lines to stdout
  local in_file="$1"
  python3 - <<PY
import base64, re, sys
p = "$in_file"
try:
    raw = open(p, "r", encoding="utf-8", errors="ignore").read().strip()
    raw = raw.replace(" ", "").replace("\\n", "").replace("\\r", "")
    # sanitize to base64 alphabet
    raw = re.sub(r'[^a-zA-Z0-9+/=]', '', raw)
    if not raw:
        sys.exit(2)
    missing = len(raw) % 4
    if missing:
        raw += "=" * (4 - missing)
    dec = base64.b64decode(raw).decode("utf-8", "ignore")
    print(dec)
except Exception:
    sys.exit(3)
PY
}

install_json_config() {
  # Validates and installs JSON directly
  local json_file="$1"

  jq -e . "$json_file" >/dev/null 2>&1 || die "Invalid JSON config (jq parse failed)."

  cp -f "$json_file" /usr/local/etc/xray/config.json
  systemctl restart xray || die "Failed to restart xray service."
  echo -e "${GREEN}[✓] Installed JSON config and restarted Xray.${NC}"
}

# --- 3. MANAGE CONFIGS (Fixed) ---
manage_configs() {
  echo -e "${BLUE}=== [3/4] Config Input & Benchmark ===${NC}"
  echo -e "${CYAN}Choose input type:${NC}"
  echo "  1) Subscription URL (Base64)"
  echo "  2) Paste a single share link (vless://...)"
  echo "  3) Paste full V2Ray/Xray JSON config"
  echo ""

  read -r -p "Select [1-3]: " mode < "$TTY_IN"
  mode="${mode:-1}"

  case "$mode" in
    1)
      read -r -p "Paste Subscription URL: " SUB_URL < "$TTY_IN"
      [[ -z "${SUB_URL:-}" ]] && die "Empty subscription URL."

      echo -e "${CYAN}Downloading subscription...${NC}"
      curl -fsSL -A "Mozilla/5.0" --max-time 20 "$SUB_URL" > "$WORK_DIR/sub.tmp" || \
        die "Failed to download subscription."

      echo -e "${CYAN}Decoding subscription...${NC}"
      if ! decode_subscription_to_lines "$WORK_DIR/sub.tmp" > "$WORK_DIR/raw_configs.txt"; then
        die "Decoding failed. The URL content is probably not valid Base64 subscription."
      fi
      ;;
    2)
      read -r -p "Paste share link: " SINGLE_LINK < "$TTY_IN"
      [[ -z "${SINGLE_LINK:-}" ]] && die "Empty link."
      printf "%s\n" "$SINGLE_LINK" > "$WORK_DIR/raw_configs.txt"
      ;;
    3)
      echo -e "${CYAN}Paste JSON config now. End with Ctrl-D on a new line.${NC}"
      cat > "$WORK_DIR/pasted.json"
      [[ ! -s "$WORK_DIR/pasted.json" ]] && die "Empty JSON."
      install_json_config "$WORK_DIR/pasted.json"
      # When JSON is installed, we don't need selection; set SELECTED empty and return
      SELECTED=""
      return 0
      ;;
    *)
      die "Invalid mode."
      ;;
  esac

  # Filter supported links (focus: vless)
  grep -E '^(vless|vmess|trojan)://' "$WORK_DIR/raw_configs.txt" > "$WORK_DIR/links.txt" || true
  [[ ! -s "$WORK_DIR/links.txt" ]] && die "No supported links found in input."

  # Build candidate list for benchmarking (only vless fully benchmarked/used in start_connection here)
  awk '/^vless:\/\//' "$WORK_DIR/links.txt" > "$WORK_DIR/vless.txt" || true
  [[ ! -s "$WORK_DIR/vless.txt" ]] && die "No vless:// links found. (This script version activates vless.)"

  echo -e "${CYAN}Benchmarking (TCP connect) in parallel...${NC}"

  # Create a CSV: ms,name,link
  # We benchmark host:port extracted from the vless link.
  export WORK_DIR
  while IFS= read -r link; do
    hp="$(extract_vless_host_port "$link" || true)"
    name="$(extract_display_name "$link" || true)"
    [[ -z "$hp" ]] && continue
    echo "$hp|$name|$link"
  done < "$WORK_DIR/vless.txt" > "$WORK_DIR/candidates.pipe"

  [[ ! -s "$WORK_DIR/candidates.pipe" ]] && die "Could not parse any usable vless host:port entries."

  # Parallel benchmark via xargs
  cat "$WORK_DIR/candidates.pipe" | \
    xargs -P "$PARALLELISM" -I{} bash -c '
      set -euo pipefail
      IFS="|" read -r hp name link <<< "{}"
      ms=$(python3 - <<PY
import socket, time
hp = "'"$hp"'"
host, port = hp.rsplit(":", 1)
port = int(port)
s = socket.socket()
s.settimeout(1.5)
t0 = time.time()
try:
    s.connect((host, port))
    dt = int((time.time() - t0) * 1000)
    print(dt)
except Exception:
    print(9999)
finally:
    try: s.close()
    except: pass
PY
)
      printf "%s,%s,%s\n" "$ms" "$name" "$link"
    ' > "$WORK_DIR/bench.csv"

  # Sort and present with fzf
  sort -t, -k1,1n "$WORK_DIR/bench.csv" > "$WORK_DIR/bench.sorted.csv"

  # Pretty list for fzf: "  42 ms | name | vless://..."
  awk -F, '{
      ms=$1; name=$2;
      link="";
      for(i=3;i<=NF;i++){ link = link (i==3? "" : ",") $i }
      printf "%5s ms | %s | %s\n", ms, name, link
  }' "$WORK_DIR/bench.sorted.csv" > "$WORK_DIR/fzf.list"

  echo -e "${CYAN}Select a connection:${NC}"
  SELECTED="$(cat "$WORK_DIR/fzf.list" | fzf --height 60% --reverse --prompt="Pick > " || true)"

  [[ -z "${SELECTED:-}" ]] && die "No selection made."
}


verify_connection() {
  echo -e "${BLUE}=== Verifying Connection ===${NC}"

  local DIRECT_IP PROXY_IP

  DIRECT_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "N/A")
  PROXY_IP=$(curl -s --max-time 8 --proxy socks5h://127.0.0.1:10808 https://api.ipify.org || echo "N/A")

  echo -e "Direct IP : ${YELLOW}${DIRECT_IP}${NC}"
  echo -e "Proxy  IP : ${CYAN}${PROXY_IP}${NC}"

  if [[ "$PROXY_IP" == "N/A" || -z "$PROXY_IP" ]]; then
    echo -e "${RED}[x] Proxy test failed. Connection NOT established.${NC}"
    return 1
  fi

  if [[ "$DIRECT_IP" == "$PROXY_IP" ]]; then
    echo -e "${YELLOW}[!] Proxy IP matches direct IP. Likely NOT tunneled.${NC}"
    return 1
  fi

  echo -e "${GREEN}[✓] Connection successful. Traffic is routed through Xray.${NC}"
  return 0
}



# --- 4. CONVERT TO XRAY JSON & START (VLESS only) ---
start_connection() {
  # If JSON mode was used, SELECTED is empty and we already restarted xray.
  if [[ -z "${SELECTED:-}" ]]; then
    echo -e "${BLUE}=== [4/4] Done ===${NC}"
    echo -e "${GREEN}[✓] Xray is active with the installed JSON config.${NC}"
    return 0
  fi

  local link
  link="$(echo "$SELECTED" | awk -F' \\| ' '{print $3}')"
  [[ -z "$link" ]] && die "Internal error: could not extract link from selection."

  echo -e "${BLUE}=== [4/4] Activating Connection (VLESS) ===${NC}"

  # Parse VLESS URL parts
  local uuid remote port query frag
  uuid="$(echo "$link" | sed -n 's#^vless://\([^@]*\)@.*#\1#p')"
  remote="$(echo "$link" | sed -n 's#^vless://[^@]*@\([^:/?#]*\).*#\1#p')"
  port="$(echo "$link" | sed -n 's#^vless://[^@]*@[^:]*:\([0-9]\+\).*#\1#p')"
  query="$(echo "$link" | sed -n 's/.*?\(.*\)#.*/\1/p; t; s/.*?\(.*\)$/\1/p')"
  frag="$(extract_display_name "$link" || true)"

  [[ -z "$uuid" || -z "$remote" || -z "$port" ]] && die "Failed to parse vless link."

  # Helper to get query param by key
  qp() {
    local key="$1"
    echo "$query" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n1
  }

  local sni security nettype path pbk sid fp flow
  sni="$(qp sni || true)"
  security="$(qp security || true)"
  nettype="$(qp type || true)"
  path="$(qp path || true)"
  pbk="$(qp pbk || true)"
  sid="$(qp sid || true)"
  fp="$(qp fp || true)"
  flow="$(qp flow || true)"

  # decode url-encoded path
  if [[ -n "$path" ]]; then
    path="$(printf "%s" "$path" | url_decode)"
  fi

  # defaults
  [[ -z "$nettype" ]] && nettype="tcp"
  [[ -z "$sni" ]] && sni="$remote"

  local outbound_json

  if [[ "$security" == "reality" ]]; then
    [[ -z "$pbk" || -z "$sid" ]] && die "Reality config missing pbk or sid."
    [[ -z "$fp" ]] && fp="chrome"
    [[ -z "$flow" ]] && flow="xtls-rprx-vision"

    outbound_json="$(cat <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$remote",
      "port": $port,
      "users": [{
        "id": "$uuid",
        "encryption": "none",
        "flow": "$flow"
      }]
    }]
  },
  "streamSettings": {
    "network": "$nettype",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "fingerprint": "$fp",
      "serverName": "$sni",
      "publicKey": "$pbk",
      "shortId": "$sid"
    }
  }
}
EOF
)"
  else
    # WS+TLS common case
    [[ -z "$path" ]] && path="/"
    outbound_json="$(cat <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$remote",
      "port": $port,
      "users": [{
        "id": "$uuid",
        "encryption": "none"
      }]
    }]
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "tlsSettings": { "serverName": "$sni" },
    "wsSettings": { "path": "$path" }
  }
}
EOF
)"
  fi

  # Write full config
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": 10808,
    "protocol": "socks",
    "settings": { "auth": "noauth", "udp": true }
  }],
  "outbounds": [
    $outbound_json
  ]
}
EOF

  # Validate JSON
  jq -e . /usr/local/etc/xray/config.json >/dev/null 2>&1 || die "Generated config.json is invalid JSON."

  systemctl restart xray || die "Failed to restart xray service."
  echo -e "${GREEN}[✓] Xray is active (SOCKS5 on 127.0.0.1:10808).${NC}"
  echo -e "${YELLOW}Test:${NC} curl --proxy socks5h://127.0.0.1:10808 https://google.com"
  echo -e "${CYAN}Selected:${NC} ${frag:-Unnamed}"
}

# --- EXECUTION ---
clear
need_root
prepare_system
run_audit
manage_configs
start_connection
