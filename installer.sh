#!/usr/bin/env bash
# ============================================================================
#  TYXEN CLOUD SYSTEM | MEGA SERVER INSTALLER — VIP ELITE LAUNCHER
#  DATE: 2026-08-14 | UI-TYPE: SEMA-HYPER-VISUAL -> VIP ELITE
#
#  This is the public entry point. It connects to the TYXEN uplink,
#  downloads the core payload and executes it with elevated privileges.
# ============================================================================
set -euo pipefail

# --- VIP ELITE THEME ---
R='\033[1;38;5;196m'     # Crimson Red
G='\033[1;38;5;82m'      # Emerald Green
Y='\033[1;38;5;220m'     # Gold
C='\033[1;38;5;51m'      # Cyan
P='\033[1;38;5;201m'     # Hot Pink (VIP)
VIOLET='\033[1;38;5;135m' # Deep Violet
NEON='\033[1;38;5;198m'  # Neon Pink
W='\033[1;38;5;255m'     # Pure White
DG='\033[0;38;5;244m'    # Steel Gray
NC='\033[0m'             # Reset

# --- CONFIG (credentials are base64-encoded, not human-readable) ---
CORE_URL="https://tyxen-installer.sgsatyam27.workers.dev"
CORE_AUTH_B64="dHl4ZW46dHhuLTIwMjYtdXBsaW5r"
CORE_FILE="/tmp/tyxen-core.sh"

# --- VIP HEADER ---
render_vip_header() {
  clear
  echo -e "${P}"
  cat << "EOF"
 ████████╗   ██╗   ██╗   ██╗  ██╗   ███████╗   ███╗   ██╗
 ╚══██╔══╝   ╚██╗ ██╔╝   ╚██╗██╔╝   ██╔════╝   ████╗  ██║
    ██║       ╚████╔╝     ╚███╔╝    █████╗     ██╔██╗ ██║
    ██║        ╚██╔╝      ██╔██╗    ██╔══╝     ██║╚██╗██║
    ██║         ██║      ██╔╝ ██╗   ███████╗   ██║ ╚████║
    ╚═╝         ╚═╝      ╚═╝  ╚═╝   ╚══════╝   ╚═╝  ╚═══╝
EOF
  echo -e "${NC}"
  echo -e "${VIOLET}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${VIOLET}║${NC}              ${P}☢ TYXEN MEGA SERVER INSTALLER ${NEON}— ${Y}VIP ELITE ACCESS${NC}              ${VIOLET}║${NC}"
  echo -e "${VIOLET}║${NC}               ${DG}v14.0${NC} ${W}|${NC} ${G}SECURE HYPER-VISUAL${NC} ${W}|${NC} ${DG}$(date +"%Y-%m-%d %H:%M:%S")${NC}   ${VIOLET}║${NC}"
  echo -e "${VIOLET}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

  echo -e "\n${Y}                  ★★★ VIP ACCESS PROTOCOL ACTIVATED ★★★${NC}\n"
}

render_vip_header

# --- SYSTEM DIAGNOSTICS ---
ENV_LABEL="Ubuntu/Debian VPS"
if grep -qi microsoft /proc/version 2>/dev/null; then
  ENV_LABEL="WSL2"
  grep -qi microsoft-standard-WSL2 /proc/version 2>/dev/null || ENV_LABEL="WSL1"
elif [ -f /.dockerenv ] || grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
  ENV_LABEL="Container (Docker/LXC)"
fi
HAS_SYSTEMD=0; [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && HAS_SYSTEMD=1
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

echo -e " ${C}◉ SYSTEM DIAGNOSTICS${NC}"
echo -e " ${DG}├─ Platform       :${NC} ${W}${ENV_LABEL}${NC}"
echo -e " ${DG}├─ Kernel         :${NC} ${W}$(uname -sr)${NC}"
echo -e " ${DG}├─ Architecture   :${NC} ${W}$(uname -m)${NC}"
echo -e " ${DG}├─ systemd        :${NC} $([ "$HAS_SYSTEMD" = "1" ] && echo "${G}ACTIVE${NC}" || echo "${R}NOT ACTIVE${NC}")"
echo -e " ${DG}├─ Security Level :${NC} ${G}ROOT ${P}★ VIP${NC}"
echo -e " ${DG}└─ Encryption     :${NC} ${NEON}TLS-1.3 UPLINK${NC}"
echo -e "${DG}──────────────────────────────────────────────────────────────────────────────${NC}"

# --- SECURITY SEQUENCE ---
echo -e "\n ${Y}[1/2] SECURITY SEQUENCE${NC}"
echo -ne " ${DG}├─ Verifying privileges...${NC} "
sleep 0.4
if [ "$IS_ROOT" = "1" ]; then
  echo -e "${G}VERIFIED${NC} ${P}✓${NC}"
else
  echo -e "${Y}REQUIRED${NC} ${P}✓${NC}"
fi

# --- UPLINK CONNECTION ---
echo -e "\n ${Y}[2/2] TYXEN UPLINK PROTOCOL${NC}"
echo -ne " ${DG}├─ Establishing secure link...${NC} "
if curl -fsSL -A "TYXEN-VIP-Agent" -H "Authorization: Basic ${CORE_AUTH_B64}" --connect-timeout 15 -o "$CORE_FILE" "$CORE_URL"; then
  echo -e "${G}CONNECTED${NC} ${P}★${NC}"
  echo -e " ${DG}└─ Agent Status   :${NC} ${G}AUTHORIZED — VIP TIER${NC}"

  echo -e "\n${DG}──────────────────────────────────────────────────────────────────────────────${NC}"
  echo -e " ${P}★★★ VIP UPLINK ESTABLISHED — EXECUTING CORE PAYLOAD ★★★${NC}\n"
  echo -ne " ${W}Initiating in ${R}1${NC} ${R}●${NC}"
  sleep 1
  echo -e "\n"

  chmod 755 "$CORE_FILE"
  sed -i 's/\r$//' "$CORE_FILE" 2>/dev/null
  if [ "$IS_ROOT" = "1" ]; then
    exec bash "$CORE_FILE" "$@"
  else
    exec sudo -E bash "$CORE_FILE" "$@"
  fi
else
  echo -e "${R}FAILED${NC}"
  echo -e " ${DG}└─ Error Detail :${NC} ${R}Uplink terminated — check internet${NC}"
  echo -e "\n ${R}[!] CRITICAL:${NC} TYXEN uplink handshake failed."
  exit 1
fi