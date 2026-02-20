#!/usr/bin/env bash
set -euo pipefail

# --- styling ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

timeout_s=4
ua="Mozilla/5.0 (network-audit)"

have() { command -v "$1" >/dev/null 2>&1; }

# Prefer dig/host/getent. We degrade gracefully.
dns_resolve() {
  local name="$1"
  if have dig; then
    dig +time=2 +tries=1 +short A "$name" | head -n1
  elif have host; then
    host -W 2 "$name" 2>/dev/null | awk '/has address/ {print $NF; exit}'
  elif have getent; then
    getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}'
  else
    echo ""
  fi
}

http_code() {
  local url="$1"
  curl -A "$ua" -sS -o /dev/null --max-time "$timeout_s" \
    -w "%{http_code}" "$url" 2>/dev/null || echo "000"
}

probe_url() {
  local label="$1"
  local url="$2"
  local code
  code="$(http_code "$url")"
  if [[ "$code" =~ ^2|3 ]]; then
    echo -e "${label}: ${GREEN}OK${NC} (HTTP $code)"
    return 0
  fi
  echo -e "${label}: ${RED}FAIL${NC} (HTTP $code)"
  return 1
}

echo -e "${BLUE}=== Network Audit (DNS + Domestic vs Global Reachability) ===${NC}"

# --- DNS server ---
dns_server="$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || true)"
echo -e "Resolver: ${CYAN}${dns_server:-unknown}${NC}"

# --- DNS test ---
g_ip="$(dns_resolve google.com || true)"
if [[ -n "$g_ip" ]]; then
  echo -e "DNS Resolution: ${GREEN}WORKING${NC} (google.com -> $g_ip)"
  dns_ok=1
else
  echo -e "DNS Resolution: ${RED}FAILED${NC} (could not resolve google.com)"
  dns_ok=0
fi
echo ""

# --- Reachability probes ---
# Use multiple global endpoints (less likely all blocked) and multiple domestic endpoints.
# Adjust domestic targets to what you consider reliably “Iran-hosted”.
global_ok=0
domestic_ok=0

echo -e "${BLUE}Global probes:${NC}"
probe_url "  Cloudflare" "https://1.1.1.1/cdn-cgi/trace" && global_ok=$((global_ok+1)) || true
probe_url "  Google"     "https://www.google.com/generate_204" && global_ok=$((global_ok+1)) || true
probe_url "  GitHub"     "https://github.com" && global_ok=$((global_ok+1)) || true
echo ""

echo -e "${BLUE}Domestic probes:${NC}"
# NOTE: replace these with your own known domestic endpoints if needed.
probe_url "  Aparat"     "https://www.aparat.com" && domestic_ok=$((domestic_ok+1)) || true
probe_url "  Divar"      "https://divar.ir" && domestic_ok=$((domestic_ok+1)) || true
probe_url "  Snapp"      "https://snapp.ir" && domestic_ok=$((domestic_ok+1)) || true
echo ""

# --- Verdict logic ---
echo -e "${BLUE}=== Verdict ===${NC}"

if [[ "$dns_ok" -eq 0 ]]; then
  echo -e "${RED}[x] DNS is broken.${NC} Fix resolver first (resolv.conf / systemd-resolved / upstream DNS)."
  exit 2
fi

# Interpret results
# - If global probes mostly fail but domestic succeed -> likely “domestic-only / filtered” network
# - If both fail -> broader connectivity issue
# - If global succeed -> global internet is reachable
if [[ "$global_ok" -ge 1 ]]; then
  echo -e "${GREEN}[✓] Global internet reachable.${NC} (global_ok=$global_ok/3, domestic_ok=$domestic_ok/3)"
  exit 0
fi

if [[ "$domestic_ok" -ge 1 && "$global_ok" -eq 0 ]]; then
  echo -e "${YELLOW}[!] Domestic reachable, global blocked/unreachable.${NC} (global_ok=0/3, domestic_ok=$domestic_ok/3)"
  echo -e "${YELLOW}    Likely filtered / domestic-only routing or upstream restriction.${NC}"
  exit 1
fi

echo -e "${RED}[x] Neither global nor domestic endpoints are reachable reliably.${NC} (global_ok=0/3, domestic_ok=0/3)"
echo -e "${RED}    This looks like general outbound HTTPS failure (routing / firewall / proxy / gateway).${NC}"
exit 3
