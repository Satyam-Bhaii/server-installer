#!/usr/bin/env bash
# ============================================================================
#  TYXEN MEGA SERVER INSTALLER  —  CORE PAYLOAD  (VIP ELITE EDITION)
#
#  This is the core engine. It is launched by the TYXEN launcher
#  (installer.sh), which downloads this file and executes it.
#
#  Includes:
#    Core:        Cloudflare Zero Trust, xrdp, Docker, LEMP, Node.js,
#                 Security (UFW+Fail2ban), Monitoring, Cockpit
#    Containers:  Portainer, CasaOS
#    Web panels:  HestiaCP, CyberPanel, aaPanel
#    Network:     Uptime Kuma, Pi-hole, AdGuard Home, Nginx Proxy Manager
#    Cloud/Media: Nextcloud, Jellyfin, Plex
#    Game panels: PufferPanel, Pelican, FeatherPanel, Pterodactyl, Crafty,
#                 MineOS, Open Game Panel, GameAP, LinuxGSM
#    Daemons:     Pterodactyl Wings, Pelican Wings, FeatherWings
#    SSL:         Let's Encrypt (Certbot, auto-renew)
#
#  Auto-detects where it runs: VPS | WSL1/WSL2 | Docker/LXC container
#
#  Usage:
#    sudo bash installer.sh                    -> interactive menu
#    sudo bash installer.sh xrdp               -> one tool by name
#    sudo bash installer.sh 1,3,6              -> multiple by numbers
#    sudo bash installer.sh all                -> install everything
#    sudo bash installer.sh --list             -> show available tools
#    sudo bash installer.sh -d example.com -t <TOKEN>   -> tunnel only (non-interactive)
#    sudo bash installer.sh ... --yes          -> skip all confirmations
#    sudo bash installer.sh --uninstall        -> interactive uninstaller menu
#    sudo bash installer.sh --uninstall 1,16   -> uninstall specific tools
#    sudo bash installer.sh --uninstall all    -> remove everything
#
#  Security: tokens are never echoed or logged; configs are mode 600.
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
#  Online bootstrap: allow 'curl | bash' / 'bash <(curl ...)' execution.
#  Materializes the core payload to /tmp and re-runs it with sudo (if needed),
#  so the interactive menu, root tools and --help all work normally.
# ----------------------------------------------------------------------------
if [ "$0" = "bash" ] || [ "$0" = "-bash" ] || [[ "$0" == /dev/fd/* ]] || [ ! -f "$0" ]; then
  BOOTSTRAP_URL="https://raw.githubusercontent.com/Satyam-Bhaii/server-installer/main/core.sh"
  BOOTSTRAP_FILE="/tmp/tyxen-core.sh"
  echo "Downloading TYXEN core from GitHub..."
  curl -fsSL "$BOOTSTRAP_URL" -o "$BOOTSTRAP_FILE" || {
    echo "Download failed. Check your internet connection."
    exit 1
  }
  chmod 755 "$BOOTSTRAP_FILE"
  if [ "$(id -u)" -eq 0 ]; then
    exec bash "$BOOTSTRAP_FILE" "$@"
  else
    exec sudo -E bash "$BOOTSTRAP_FILE" "$@"
  fi
fi

# --- VIP ELITE THEME (256-color) ---
GREEN='\033[1;38;5;82m'      # Emerald Green
YELLOW='\033[1;38;5;220m'    # Gold
RED='\033[1;38;5;196m'       # Crimson Red
CYAN='\033[1;38;5;51m'       # Cyan
BOLD='\033[1m'
DIM='\033[2m'
VIOLET='\033[1;38;5;135m'    # Deep Violet
NEON='\033[1;38;5;198m'      # Neon Pink
WHITE='\033[1;38;5;255m'     # Pure White
GRAY='\033[0;38;5;244m'      # Steel Gray
NC='\033[0m'

TS() { date +%H:%M:%S; }
info()  { echo -e "${YELLOW}[INFO${DIM} $(TS)${NC}${YELLOW}]${NC} $*"; }
ok()    { echo -e "${GREEN}[SUCCESS${DIM} $(TS)${NC}${GREEN}]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN${DIM} $(TS)${NC}${YELLOW}]${NC} $*"; }
error() { echo -e "${RED}[ERROR${DIM} $(TS)${NC}${RED}]${NC} $*" >&2; }
title() { echo; echo -e "${BOLD}${CYAN}────────── $* ──────────${NC}"; }

# ----------------------------------------------------------------------------
#  Global state
# ----------------------------------------------------------------------------
CFD_DIR_HOME="$HOME/.cloudflared"
CFD_CFG_HOME="$CFD_DIR_HOME/config.yml"
CFD_PID_HOME="$CFD_DIR_HOME/cloudflared.pid"
CFD_LOG_HOME="$CFD_DIR_HOME/cloudflared.log"
CFD_CTRL_HOME="$CFD_DIR_HOME/cloudflared.sh"
CFD_SYS_DIR="/etc/cloudflared"
SERVICE_UNIT_HOME="$HOME/.config/systemd/user/cloudflared.service"

BIN_CREATED=0; CFG_CREATED=0; SYS_SERVICE_INSTALLED=0
UNIT_CREATED=0; PROC_STARTED=0
DOMAIN=""; TOKEN=""; SUMMARIES=()

cleanup() {
  local code=$?
  trap - EXIT
  stty echo 2>/dev/null || true
  rm -f /tmp/get-docker.sh /tmp/node_setup.sh 2>/dev/null || true
  if [ "$code" -ne 0 ]; then
    echo
    error "Aborted (exit code ${code})."
  fi
  exit "$code"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
#  Helpers
# ----------------------------------------------------------------------------
spinner() {
  local pid=$1 i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s' "${spinner_chars:$((i % 4)):1}"
    i=$((i + 1)); sleep 0.1
  done
  printf '\r '
}

is_online() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o /dev/null --connect-timeout 8 https://github.com
  else
    wget -q --spider --timeout=8 https://github.com
  fi
}

require_root() {
  if [ "$IS_ROOT" = "1" ]; then return 0; fi
  error "This tool requires root privileges."
  echo -e "${YELLOW}Re-run with:${NC} sudo bash installer.sh $*"
  return 1
}

confirm() {
  [ "$ASK_CONFIRM" = "0" ] && return 0
  local ans
  echo -n -e "${CYAN}  ? $1 [y/N]: ${NC}"
  read -r ans
  case "${ans,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>/dev/null || warn "apt-get update failed — continuing with existing lists."
  apt-get install -y -qq "$@" >/dev/null 2>&1 || {
    apt-get install -y "$@" 2>&1 || { error "Failed to install: $*"; return 1; }
  }
}

validate_domain() {
  local d="$1"
  [ -n "$d" ] || return 1
  echo "$d" | grep -qE '^([a-z0-9](-?[a-z0-9])*\.)+[a-z]{2,}$'
}

# ----------------------------------------------------------------------------
#  Environment detection
# ----------------------------------------------------------------------------
detect_environment() {
  ENV_TYPE="vps"; ENV_LABEL="Ubuntu/Debian VPS"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    if grep -qi microsoft-standard-WSL2 /proc/version 2>/dev/null; then
      ENV_TYPE="wsl2"; ENV_LABEL="WSL2"
    else
      ENV_TYPE="wsl1"; ENV_LABEL="WSL1"
    fi
  elif [ -f /.dockerenv ] || grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
    ENV_TYPE="container"; ENV_LABEL="Container (Docker/LXC)"
  fi
  [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && HAS_SYSTEMD=1 || HAS_SYSTEMD=0
  [ "$(id -u)" -eq 0 ] && IS_ROOT=1 || IS_ROOT=0
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="${PRETTY_NAME:-${ID:-unknown}}"
  else
    DISTRO="unknown"
  fi
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armhf)  ARCH="arm" ;;
    i686|i386)     ARCH="386" ;;
    *) error "Unsupported CPU architecture: $(uname -m)"; exit 1 ;;
  esac
}

# ============================================================================
#  TOOL 1 — Cloudflare Zero Trust Tunnel
# ============================================================================
install_tunnel() {
  title "Cloudflare Zero Trust Tunnel"

  if [ "$ENV_TYPE" = "wsl1" ]; then
    EXTRA_FLAGS=" --protocol http2"
    warn "WSL1 detected — using HTTP/2 protocol (QUIC is unreliable on WSL1)."
  else
    EXTRA_FLAGS=""
  fi

  # mode selection
  if [ "$HAS_SYSTEMD" = "1" ]; then
    if [ "$IS_ROOT" = "1" ] && [ "$ENV_TYPE" = "vps" ]; then MODE="system-service"; else MODE="user-service"; fi
  else
    MODE="background"
  fi
  info "Install mode: ${MODE}"

  # domain
  while :; do
    if [ -n "${CFD_DOMAIN:-}" ]; then
      DOMAIN="$CFD_DOMAIN"
    else
      echo -n -e "${CYAN}  ? Target domain (e.g. server.example.com): ${NC}"
      if ! read -r DOMAIN; then
        echo
        info "No input received — skipping tunnel setup."
        return 1
      fi
    fi
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    validate_domain "$DOMAIN" && break
    error "Invalid or empty domain. Format: 'server.example.com'"
    [ -n "${CFD_DOMAIN:-}" ] && return 1
  done
  ok "Domain accepted: ${BOLD}${DOMAIN}${NC}"

  # token (masked)
  while :; do
    if [ -n "${CFD_TOKEN:-}" ]; then
      TOKEN="$CFD_TOKEN"
    else
      echo -n -e "${CYAN}  ? Cloudflare Zero Trust token (input hidden): ${NC}"
      stty -echo 2>/dev/null || true
      if ! read -r TOKEN; then
        stty echo 2>/dev/null || true
        echo
        info "No input received — skipping tunnel setup."
        return 1
      fi
      stty echo 2>/dev/null || true
      echo
    fi
    TOKEN=$(echo "$TOKEN" | tr -d '[:space:]')
    [ -n "$TOKEN" ] && [ "${#TOKEN}" -ge 30 ] && break
    error "Token empty or too short (${#TOKEN} chars). A valid token is 30+ chars."
    [ -n "${CFD_TOKEN:-}" ] && return 1
  done
  ok "Token accepted (${#TOKEN} chars) — never echoed or logged."

  # binary
  if [ "$MODE" = "system-service" ]; then BIN_PATH="/usr/local/bin/cloudflared"; else BIN_PATH="$HOME/.local/bin/cloudflared"; fi
  if [ -x "$BIN_PATH" ]; then
    CLOUDFLARED="$BIN_PATH"
    info "cloudflared already present: $($CLOUDFLARED --version | awk '{print $3}')"
  elif command -v cloudflared >/dev/null 2>&1; then
    CLOUDFLARED=$(command -v cloudflared)
    info "cloudflared already in PATH: $($CLOUDFLARED --version | awk '{print $3}')"
  else
    info "Downloading cloudflared (linux-${ARCH}) ..."
    mkdir -p "$(dirname "$BIN_PATH")"
    tmp_bin="${BIN_PATH}.part"
    if command -v curl >/dev/null 2>&1; then
      ( curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 \
          "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
          -o "$tmp_bin" ) &
    else
      ( wget -q --tries=3 --timeout=15 \
          "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
          -O "$tmp_bin" ) &
    fi
    spinner $!
    wait $! || { error "Download failed."; return 1; }
    chmod 755 "$tmp_bin"; mv "$tmp_bin" "$BIN_PATH"
    BIN_CREATED=1; CLOUDFLARED="$BIN_PATH"
  fi
  ok "cloudflared ready: $($CLOUDFLARED --version | awk '{print $3}')"

  # config
  if [ "$MODE" = "system-service" ]; then
    mkdir -p "$CFD_SYS_DIR"; chmod 700 "$CFD_SYS_DIR"
    umask 077
    { echo "token: $TOKEN"; } > "$CFD_SYS_DIR/config.yml"
    chmod 600 "$CFD_SYS_DIR/config.yml"
    CFG_PATH="$CFD_SYS_DIR/config.yml"
  else
    mkdir -p "$CFD_DIR_HOME"; chmod 700 "$CFD_DIR_HOME"
    umask 077
    { echo "token: $TOKEN"; } > "$CFD_CFG_HOME"
    chmod 600 "$CFD_CFG_HOME"
    CFG_PATH="$CFD_CFG_HOME"
  fi
  CFG_CREATED=1
  unset TOKEN CFD_TOKEN
  ok "Config written: ${CFG_PATH} (mode 600, owner-only)."

  RUN_CMD="$CLOUDFLARED --config $CFG_PATH tunnel run${EXTRA_FLAGS}"

  # start
  case "$MODE" in
    system-service)
      info "Installing systemd system service..."
      cloudflared service install || {
        warn "Fallback to manual systemd unit..."
        {
          echo "[Unit]"; echo "Description=Cloudflare Zero Trust Tunnel";
          echo "After=network-online.target"; echo "Wants=network-online.target";
          echo; echo "[Service]"; echo "ExecStart=${RUN_CMD}";
          echo "Restart=on-failure"; echo "RestartSec=5"; echo "LimitNOFILE=65536";
          echo; echo "[Install]"; echo "WantedBy=multi-user.target";
        } > /etc/systemd/system/cloudflared.service
        systemctl daemon-reload
      }
      SYS_SERVICE_INSTALLED=1
      systemctl enable cloudflared >/dev/null 2>&1 || true
      systemctl restart cloudflared
      sleep 3
      if systemctl is-active --quiet cloudflared; then
        RUN_MODE="system-service"
        ok "Tunnel service active and enabled at boot."
      else
        error "Service failed. Check: sudo journalctl -u cloudflared -n 50"
        return 1
      fi
      ;;
    user-service)
      info "Installing systemd user service..."
      mkdir -p "$(dirname "$SERVICE_UNIT_HOME")"
      {
        echo "[Unit]"; echo "Description=Cloudflare Zero Trust Tunnel";
        echo "After=network-online.target"; echo "Wants=network-online.target";
        echo; echo "[Service]"; echo "ExecStart=${RUN_CMD}";
        echo "Restart=on-failure"; echo "RestartSec=5"; echo "LimitNOFILE=65536";
        echo; echo "[Install]"; echo "WantedBy=default.target";
      } > "$SERVICE_UNIT_HOME"
      chmod 600 "$SERVICE_UNIT_HOME"
      if systemctl --user daemon-reload 2>/dev/null && \
         systemctl --user enable cloudflared >/dev/null 2>&1 && \
         systemctl --user restart cloudflared 2>/dev/null; then
        sleep 3
        if systemctl --user is-active --quiet cloudflared; then
          sudo -n loginctl enable-linger "$USER" >/dev/null 2>&1 || true
          UNIT_CREATED=1; RUN_MODE="user-service"
          ok "User service active and set to start at boot."
        else
          warn "User service inactive — falling back to background process."
          UNIT_CREATED=0; rm -f "$SERVICE_UNIT_HOME"
          systemctl --user daemon-reload 2>/dev/null || true
          start_background_tunnel
        fi
      else
        warn "systemd user bus unavailable — falling back to background process."
        UNIT_CREATED=0; rm -f "$SERVICE_UNIT_HOME"
        start_background_tunnel
      fi
      ;;
    background)
      start_background_tunnel
      ;;
  esac

  SUMMARIES+=("Cloudflare Zero Trust tunnel — domain: ${DOMAIN} (${RUN_MODE})")
  echo
  ok "Tunnel installed. Dashboard: ${CYAN}https://one.dash.cloudflare.com/${NC}"
  case "$RUN_MODE" in
    system-service)
      echo "  Status: sudo systemctl status cloudflared | Logs: sudo journalctl -u cloudflared -f" ;;
    user-service)
      echo "  Status: systemctl --user status cloudflared | Logs: journalctl --user -u cloudflared -f" ;;
    background)
      echo "  Manage: ${CFD_CTRL_HOME} status|stop|start | Logs: tail -f ${CFD_LOG_HOME}" ;;
  esac
  echo "  Next: dashboard → Access > Tunnels → add Public Hostname → ${BOLD}${DOMAIN}${NC} → http://localhost:<port>"
}

start_background_tunnel() {
  info "Starting cloudflared as background process..."
  mkdir -p "$CFD_DIR_HOME"
  nohup $RUN_CMD >> "$CFD_LOG_HOME" 2>&1 &
  echo $! > "$CFD_PID_HOME"
  PROC_STARTED=1
  sleep 3
  if ! kill -0 "$(cat "$CFD_PID_HOME")" 2>/dev/null; then
    error "cloudflared exited immediately. Log: tail -n 50 $CFD_LOG_HOME"
    return 1
  fi
  {
    echo "#!/usr/bin/env bash"
    echo "BIN='$CLOUDFLARED'"; echo "CFG='$CFG_PATH'"
    echo "PID='$CFD_PID_HOME'"; echo "LOG='$CFD_LOG_HOME'"
    echo "case \"\${1:-status}\" in"
    echo "  start)"
    echo "    if [ -f \"\$PID\" ] && kill -0 \"\$(cat \"\$PID\")\" 2>/dev/null; then"
    echo "      echo 'cloudflared already running.'; exit 0"
    echo "    fi"
    echo "    nohup \"\$BIN\" --config \"\$CFG\" tunnel run${EXTRA_FLAGS} >> \"\$LOG\" 2>&1 &"
    echo "    echo \$! > \"\$PID\"; echo 'cloudflared started.'"
    echo "    ;;"
    echo "  stop)"
    echo "    [ -f \"\$PID\" ] && kill \"\$(cat \"\$PID\")\" 2>/dev/null && rm -f \"\$PID\""
    echo "    echo 'cloudflared stopped.'"
    echo "    ;;"
    echo "  status)"
    echo "    if [ -f \"\$PID\" ] && kill -0 \"\$(cat \"\$PID\")\" 2>/dev/null; then"
    echo "      echo 'cloudflared is running (PID '\$(cat \"\$PID\")').'"
    echo "    else echo 'cloudflared is NOT running.'; fi"
    echo "    ;;"
    echo "esac"
  } > "$CFD_CTRL_HOME"
  chmod 755 "$CFD_CTRL_HOME"
  RUN_MODE="background"
  ok "cloudflared running (PID $(cat "$CFD_PID_HOME"))."
}

# ============================================================================
#  TOOL 2 — xrdp Remote Desktop
# ============================================================================
install_xrdp() {
  title "xrdp Remote Desktop (RDP)"
  require_root xrdp || return 1

  if [ "$ENV_TYPE" = "wsl1" ] || [ "$ENV_TYPE" = "container" ]; then
    warn "xrdp targets real servers. On ${ENV_LABEL} external RDP access usually won't work."
  elif [ "$ENV_TYPE" = "wsl2" ]; then
    warn "WSL2 RDP is experimental — it works, but a real VPS is recommended for RDP."
  fi
  confirm "Install xrdp with a desktop environment?" || { info "Skipped xrdp."; return 0; }

  DESKTOP="xfce"
  if [ "$ASK_CONFIRM" = "1" ]; then
    echo -e "  ${BOLD}Desktop:${NC} 1) XFCE (light, recommended)  2) GNOME (heavy)"
    echo -n -e "${CYAN}  ? Choose [1/2]: ${NC}"; read -r dk
    case "$dk" in 2) DESKTOP="gnome" ;; *) DESKTOP="xfce" ;; esac
  fi

  if [ "$DESKTOP" = "gnome" ]; then
    info "Installing GNOME desktop + xrdp (this takes a while)..."
    apt_install ubuntu-desktop xrdp || return 1
  else
    info "Installing XFCE desktop + xrdp..."
    apt_install xfce4 xfce4-goodies xrdp || return 1
  fi

  echo "xfce4-session" > /etc/skel/.xsession 2>/dev/null || true
  chmod +x /etc/skel/.xsession 2>/dev/null || true
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    echo "xfce4-session" > "/home/$SUDO_USER/.xsession" 2>/dev/null || true
    chmod +x "/home/$SUDO_USER/.xsession" 2>/dev/null || true
  fi

  if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl enable xrdp >/dev/null 2>&1 || true
    systemctl restart xrdp
  else
    service xrdp start >/dev/null 2>&1 || nohup xrdp >/dev/null 2>&1 &
    sleep 1
  fi

  if command -v ss >/dev/null 2>&1 && ss -tln | grep -q ':3389'; then
    ok "xrdp is listening on port 3389."
  else
    warn "xrdp installed but port 3389 not yet confirmed. Check: systemctl status xrdp"
  fi

  SUMMARIES+=("xrdp Remote Desktop — XFCE, port 3389")
  echo
  ok "xrdp installed."
  echo "  Connect from Windows: Start → 'Remote Desktop Connection' → IP:3389"
  echo "  Find your IP:  hostname -I"
  echo "  Login with:    any existing user + its password"
}

# ============================================================================
#  TOOL 3 — Docker
# ============================================================================
install_docker() {
  title "Docker + Docker Compose"
  require_root docker || return 1

  if command -v docker >/dev/null 2>&1; then
    info "Docker already installed: $(docker --version | awk '{print $3}')"
  else
    confirm "Install Docker from the official repository (get.docker.com)?" || { info "Skipped Docker."; return 0; }
    info "Downloading official Docker installer..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || { error "Download failed."; return 1; }
    info "Installing Docker (this takes a while)..."
    sh /tmp/get-docker.sh || { error "Docker install failed."; return 1; }
  fi

  if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  else
    service docker start >/dev/null 2>&1 || true
  fi

  DOCKER_USER="${SUDO_USER:-$USER}"
  if [ "$DOCKER_USER" != "root" ]; then
    usermod -aG docker "$DOCKER_USER" 2>/dev/null || true
    info "User '${DOCKER_USER}' added to the docker group (re-login to use docker without sudo)."
  fi

  ok "Docker ready: $(docker --version | awk '{print $3}')"
  SUMMARIES+=("Docker + Docker Compose")
  echo "  Test: docker run hello-world"
}

# ============================================================================
#  TOOL 4 — LEMP Stack
# ============================================================================
install_lemp() {
  title "LEMP Stack (Nginx + PHP + MariaDB)"
  require_root lemp || return 1
  confirm "Install Nginx + PHP-FPM + MariaDB?" || { info "Skipped LEMP."; return 0; }

  info "Installing Nginx, PHP and MariaDB (this takes a while)..."
  apt_install nginx php-fpm php-mysql mariadb-server || return 1

  if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl enable --now mariadb >/dev/null 2>&1 || true
    systemctl enable --now php8.*-fpm >/dev/null 2>&1 || true
  else
    service nginx start >/dev/null 2>&1 || true
    service mariadb start >/dev/null 2>&1 || true
  fi

  PHP_V=$(ls /etc/php/ 2>/dev/null | head -n1)
  if [ -n "$PHP_V" ]; then
    if [ "$HAS_SYSTEMD" = "1" ]; then
      systemctl enable --now "php${PHP_V}-fpm" >/dev/null 2>&1 || true
    fi
    info "PHP-FPM ${PHP_V} enabled."
  fi

  ok "LEMP stack ready."
  SUMMARIES+=("LEMP Stack — Nginx + PHP + MariaDB")
  echo "  Web root:  /var/www/html"
  echo "  Test:      curl -I http://localhost/   (expect HTTP/1.1 200)"
  echo "  Secure DB: sudo mysql_secure_installation"
}

# ============================================================================
#  TOOL 5 — Node.js LTS
# ============================================================================
install_node() {
  title "Node.js LTS"
  require_root node || return 1

  if command -v node >/dev/null 2>&1; then
    info "Node.js already installed: v$(node -v | tr -d 'v')"
  else
    confirm "Install Node.js 22 LTS (official NodeSource repo)?" || { info "Skipped Node.js."; return 0; }
    info "Adding NodeSource repository..."
    curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/node_setup.sh || { error "Download failed."; return 1; }
    bash /tmp/node_setup.sh 2>/dev/null || { error "NodeSource setup failed."; return 1; }
    info "Installing Node.js..."
    apt_install nodejs || return 1
  fi

  ok "Node.js ready: v$(node -v | tr -d 'v')  (npm v$(npm -v))"
  SUMMARIES+=("Node.js LTS v$(node -v | tr -d 'v')")
  echo "  Test: node -e 'console.log(\"hello\")'"
}

# ============================================================================
#  TOOL 6 — Security (UFW + Fail2ban)
# ============================================================================
install_security() {
  title "Security Hardening (UFW + Fail2ban)"
  require_root security || return 1

  if [ "$ENV_TYPE" = "container" ]; then
    warn "Inside a container the host manages the firewall — only Fail2ban will be installed."
  fi

  SSH_PORT=22
  if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    SSH_PORT=${SSH_PORT:-22}
  fi

  if [ "$ENV_TYPE" != "container" ]; then
    confirm "Enable UFW firewall (allow SSH ${SSH_PORT}/tcp, deny everything else)?" || UFW_SKIP=1
    if [ "${UFW_SKIP:-0}" != "1" ]; then
      info "Enabling UFW..."
      apt_install ufw || return 1
      ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
      ufw --force enable >/dev/null 2>&1 || true
      ok "UFW enabled — SSH (${SSH_PORT}/tcp) allowed."
    else
      info "UFW skipped."
    fi
  fi

  confirm "Install Fail2ban (blocks brute-force login attempts)?" || { info "Skipped Fail2ban."; return 0; }
  info "Installing Fail2ban..."
  apt_install fail2ban || return 1
  if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
  else
    service fail2ban start >/dev/null 2>&1 || nohup fail2ban-server >/dev/null 2>&1 &
  fi

  ok "Security hardening done."
  SUMMARIES+=("Security: UFW (SSH ${SSH_PORT}/tcp) + Fail2ban")
  echo "  Check bans:  sudo fail2ban-client status sshd"
}

# ============================================================================
#  TOOL 7 — Monitoring
# ============================================================================
install_monitoring() {
  title "Monitoring (btop, htop, Netdata)"
  require_root monitoring || return 1
  confirm "Install btop + htop + Netdata dashboard?" || { info "Skipped monitoring."; return 0; }

  info "Installing btop and htop..."
  apt_install btop htop || return 1

  if ! command -v netdata >/dev/null 2>&1; then
    if is_online; then
      info "Installing Netdata (official installer)..."
      curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh && \
        sh /tmp/netdata-kickstart.sh --non-interactive >/dev/null 2>&1 || \
        warn "Netdata install failed — btop/htop are still installed."
      rm -f /tmp/netdata-kickstart.sh 2>/dev/null || true
    else
      warn "No internet to github.com — skipping Netdata."
    fi
  else
    info "Netdata already installed."
  fi

  ok "Monitoring tools ready."
  SUMMARIES+=("Monitoring: btop, htop, Netdata")
  echo "  btop:      live CPU/RAM/network monitor"
  echo "  Netdata:   http://localhost:19999  (or use the Cloudflare tunnel to reach it)"
}

# ============================================================================
#  TOOL 8 — Cockpit admin panel
# ============================================================================
install_cockpit() {
  title "Admin Panel — Cockpit"
  require_root cockpit || return 1

  if [ "$HAS_SYSTEMD" = "0" ]; then
    warn "Cockpit needs systemd. It won't work in this environment — skipped."
    return 1
  fi
  confirm "Install Cockpit (browser-based admin panel)?" || { info "Skipped Cockpit."; return 0; }

  info "Installing Cockpit..."
  apt_install cockpit || return 1
  systemctl enable --now cockpit.socket >/dev/null 2>&1 || true

  ok "Cockpit installed."
  SUMMARIES+=("Admin Panel: Cockpit")
  echo "  Open: https://<server-ip>:9090  (accept the self-signed cert warning)"
  echo "  Login with any system user."
}

# ============================================================================
#  Docker helpers (used by app tools)
# ============================================================================
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    error "Docker is required for this tool and is not installed."
    echo -e "${YELLOW}Install it first:${NC} sudo bash installer.sh docker"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    error "Docker daemon is not running."
    echo -e "${YELLOW}Start it:${NC} sudo systemctl start docker   (or: sudo service docker start)"
    return 1
  fi
}

port_busy() {
  command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":${1} " && return 0
  return 1
}

docker_run() {
  local name="$1"; shift
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    warn "Container '${name}' already exists — skipping (it keeps its data)."
    return 0
  fi
  docker run -d --name "$name" --restart=always "$@" || { error "Failed to start container '${name}'."; return 1; }
}

# ============================================================================
#  TOOL 10 — Portainer (Docker GUI)
# ============================================================================
install_portainer() {
  title "Portainer — Docker Web GUI"
  require_root portainer || return 1
  require_docker || return 1
  confirm "Install Portainer (manage Docker by clicking, no commands)?" || { info "Skipped Portainer."; return 0; }
  info "Creating Portainer..."
  docker volume create portainer_data >/dev/null 2>&1 || true
  docker_run portainer -p 8000:8000 -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
    portainer/portainer-ce:latest || return 1
  ok "Portainer installed."
  SUMMARIES+=("Portainer — https://<server-ip>:9443 (set admin password on first visit)")
  echo "  Open: https://<server-ip>:9443  (accept the self-signed cert warning)"
}

# ============================================================================
#  TOOL 11 — CasaOS (app store dashboard)
# ============================================================================
install_casaos() {
  title "CasaOS — 1-click App Store dashboard"
  require_root casaos || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "CasaOS is designed for real servers; on ${ENV_LABEL} it may not work fully."
  fi
  confirm "Install CasaOS (App-Store-style dashboard, port 80)?" || { info "Skipped CasaOS."; return 0; }
  if port_busy 80; then
    warn "Port 80 is already in use — CasaOS needs it free (a web panel may be running)."
  fi
  info "Downloading official CasaOS installer..."
  curl -fsSL https://get.casaos.io/v0.4.1/install.sh -o /tmp/casaos-install.sh || { error "Download failed."; return 1; }
  info "Running CasaOS installer (downloads ~400MB, be patient)..."
  bash /tmp/casaos-install.sh || { error "CasaOS install failed."; return 1; }
  rm -f /tmp/casaos-install.sh 2>/dev/null || true
  ok "CasaOS installed."
  SUMMARIES+=("CasaOS — http://<server-ip>/")
  echo "  Open: http://<server-ip>/"
}

# ============================================================================
#  TOOL 12 — HestiaCP (web hosting panel)
# ============================================================================
install_hestiacp() {
  title "HestiaCP — lightweight web hosting panel"
  require_root hestiacp || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "Hosting panels need a real VPS; on ${ENV_LABEL} it won't be usable."
  fi
  warn "HestiaCP needs a FQDN hostname and takes 10-15 minutes."
  confirm "Install HestiaCP (websites + databases + email panel)?" || { info "Skipped HestiaCP."; return 0; }

  EMAIL="admin@example.com"
  if [ "$ASK_CONFIRM" = "1" ]; then
    echo -n -e "${CYAN}  ? Admin email for HestiaCP (e.g. admin@yourdomain.com): ${NC}"
    read -r EMAIL
    EMAIL=$(echo "$EMAIL" | tr -d '[:space:]')
    [ -z "$EMAIL" ] && EMAIL="admin@example.com"
  fi

  HN=$(hostname)
  if ! echo "$HN" | grep -q '\.'; then
    warn "Hostname '${HN}' has no domain part. HestiaCP needs a FQDN —"
    echo -e "${YELLOW}  Set it first:${NC} sudo hostnamectl set-hostname server.yourdomain.com"
  fi

  info "Downloading official HestiaCP installer..."
  curl -fsSL https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh \
    -o /tmp/hst-install.sh || { error "Download failed."; return 1; }
  info "Running HestiaCP installer (takes 10-15 min, silent)..."
  bash /tmp/hst-install.sh -y --force -e "$EMAIL" || { error "HestiaCP install failed."; return 1; }
  rm -f /tmp/hst-install.sh 2>/dev/null || true
  ok "HestiaCP installed."
  SUMMARIES+=("HestiaCP — https://$(hostname):8083 (admin panel)")
  echo "  Panel:  https://<server-hostname>:8083"
  echo "  Login:  admin / the password shown at the end of the install"
}

# ============================================================================
#  TOOL 13 — CyberPanel
# ============================================================================
install_cyberpanel() {
  title "CyberPanel — modern web hosting panel"
  require_root cyberpanel || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "Hosting panels need a real VPS; on ${ENV_LABEL} it won't be usable."
  fi
  warn "CyberPanel's installer is interactive — answer its questions (takes 10-20 min)."
  confirm "Install CyberPanel (websites + databases panel)?" || { info "Skipped CyberPanel."; return 0; }
  info "Downloading official CyberPanel installer..."
  curl -fsSL https://cyberpanel.net/install.sh -o /tmp/cyberpanel.sh || { error "Download failed."; return 1; }
  info "Running CyberPanel installer (follow the prompts)..."
  bash /tmp/cyberpanel.sh || { error "CyberPanel install failed."; return 1; }
  rm -f /tmp/cyberpanel.sh 2>/dev/null || true
  ok "CyberPanel installed."
  SUMMARIES+=("CyberPanel — https://<server-ip>:8090 (admin: admin | password from install log)")
  echo "  Panel: https://<server-ip>:8090"
}

# ============================================================================
#  TOOL 14 — aaPanel
# ============================================================================
install_aapanel() {
  title "aaPanel — free web hosting panel"
  require_root aapanel || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "Hosting panels need a real VPS; on ${ENV_LABEL} it won't be usable."
  fi
  warn "aaPanel's installer is interactive — answer its questions (takes 10-20 min)."
  confirm "Install aaPanel (websites + databases panel)?" || { info "Skipped aaPanel."; return 0; }
  if [ "${ID:-}" = "debian" ]; then
    AA_SCRIPT="https://www.aapanel.com/script/install-debian_6.0_en.sh"
  else
    AA_SCRIPT="https://www.aapanel.com/script/install-ubuntu_6.0_en.sh"
  fi
  info "Downloading official aaPanel installer..."
  curl -fsSL "$AA_SCRIPT" -o /tmp/aapanel-install.sh || { error "Download failed."; return 1; }
  info "Running aaPanel installer (follow the prompts)..."
  bash /tmp/aapanel-install.sh || { error "aaPanel install failed."; return 1; }
  rm -f /tmp/aapanel-install.sh 2>/dev/null || true
  ok "aaPanel installed."
  SUMMARIES+=("aaPanel — http://<server-ip>:7800 (admin login shown at the end)")
  echo "  Panel: http://<server-ip>:7800"
}

# ============================================================================
#  TOOL 15 — Uptime Kuma (monitoring + alerts)
# ============================================================================
install_uptimekuma() {
  title "Uptime Kuma — uptime monitor with alerts"
  require_root uptimekuma || return 1
  require_docker || return 1
  confirm "Install Uptime Kuma (alerts to Discord/Telegram when a service is down)?" || { info "Skipped Uptime Kuma."; return 0; }
  if port_busy 3001; then
    warn "Port 3001 is busy — Uptime Kuma may not be reachable."
  fi
  docker volume create uptime-kuma-data >/dev/null 2>&1 || true
  docker_run uptime-kuma -p 3001:3001 -v uptime-kuma-data:/app/data \
    louislam/uptime-kuma:1 || return 1
  ok "Uptime Kuma installed."
  SUMMARIES+=("Uptime Kuma — http://<server-ip>:3001")
  echo "  Open: http://<server-ip>:3001  (create the admin account on first visit)"
}

# ============================================================================
#  TOOL 16 — Pi-hole (DNS ad blocker)
# ============================================================================
install_pihole() {
  title "Pi-hole — network-wide ad blocker"
  require_root pihole || return 1
  if [ "$ENV_TYPE" = "container" ]; then
    error "Pi-hole needs its own IP/port 53 — it cannot work inside a container."
    return 1
  fi
  if [ "$ENV_TYPE" = "wsl2" ] || [ "$ENV_TYPE" = "wsl1" ]; then
    warn "Pi-hole under WSL only affects the WSL instance, not your Windows network."
  fi
  confirm "Install Pi-hole (own DNS server + ad blocking)?" || { info "Skipped Pi-hole."; return 0; }
  warn "Its installer asks a few questions (interface, upstream DNS, blocking list)."
  info "Running official Pi-hole installer..."
  curl -sSL https://install.pi-hole.net | bash || { error "Pi-hole install failed."; return 1; }
  ok "Pi-hole installed."
  SUMMARIES+=("Pi-hole — http://<server-ip>/admin (set the password with: pihole -a -p)")
  echo "  Admin:   http://<server-ip>/admin"
  echo "  Set pw:  sudo pihole -a -p"
}

# ============================================================================
#  TOOL 17 — AdGuard Home (DNS ad blocker)
# ============================================================================
install_adguard() {
  title "AdGuard Home — DNS ad blocker + parental control"
  require_root adguard || return 1
  if [ "$ENV_TYPE" = "container" ]; then
    warn "Inside a container, port 53 is usually not bindable — install may fail."
  fi
  confirm "Install AdGuard Home (ad blocking DNS server)?" || { info "Skipped AdGuard Home."; return 0; }
  info "Running official AdGuard Home installer..."
  curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
    | sh -s -- -v || { error "AdGuard Home install failed."; return 1; }
  if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl enable --now AdGuardHome >/dev/null 2>&1 || true
  fi
  ok "AdGuard Home installed."
  SUMMARIES+=("AdGuard Home — admin at http://<server-ip>:3000 (first-time setup)")
  echo "  Setup: http://<server-ip>:3000  (finish wizard, then use port 80 for admin)"
}

# ============================================================================
#  TOOL 18 — Nginx Proxy Manager (subdomains + SSL)
# ============================================================================
install_npm() {
  title "Nginx Proxy Manager — subdomains + SSL for all apps"
  require_root npm || return 1
  require_docker || return 1
  confirm "Install Nginx Proxy Manager (e.g. app.yourdomain.com with free SSL)?" || { info "Skipped NPM."; return 0; }
  if port_busy 80 || port_busy 443; then
    warn "Ports 80/443 look busy — NPM needs them free (stop web panels/CasaOS first)."
  fi
  docker volume create npm-data >/dev/null 2>&1 || true
  docker volume create npm-letsencrypt >/dev/null 2>&1 || true
  docker_run nginx-proxy-manager -p 80:80 -p 443:443 -p 81:81 \
    -v npm-data:/data -v npm-letsencrypt:/etc/letsencrypt \
    jc21/nginx-proxy-manager:latest || return 1
  ok "Nginx Proxy Manager installed."
  SUMMARIES+=("Nginx Proxy Manager — http://<server-ip>:81 (admin@example.com / changeme)")
  echo "  Admin:  http://<server-ip>:81   (default login: admin@example.com / changeme)"
  echo "  Tip:    point app.domain.com → NPM → your app, free SSL via Let's Encrypt"
}

# ============================================================================
#  TOOL 19 — Nextcloud (private cloud)
# ============================================================================
install_nextcloud() {
  title "Nextcloud — your own Google Drive"
  require_root nextcloud || return 1
  require_docker || return 1
  confirm "Install Nextcloud (files/photos/contacts sync)?" || { info "Skipped Nextcloud."; return 0; }
  if port_busy 8080; then
    warn "Port 8080 is busy — Nextcloud may not be reachable."
  fi
  docker volume create nextcloud-data >/dev/null 2>&1 || true
  docker_run nextcloud -p 8080:80 -v nextcloud-data:/var/www/html \
    nextcloud:stable || return 1
  ok "Nextcloud installed."
  SUMMARIES+=("Nextcloud — http://<server-ip>:8080")
  echo "  Open: http://<server-ip>:8080  (create admin account on first visit)"
}

# ============================================================================
#  TOOL 20 — Jellyfin (media streaming)
# ============================================================================
install_jellyfin() {
  title "Jellyfin — your own Netflix"
  require_root jellyfin || return 1
  require_docker || return 1
  confirm "Install Jellyfin (stream movies/series to any device)?" || { info "Skipped Jellyfin."; return 0; }
  if port_busy 8096; then
    warn "Port 8096 is busy — Jellyfin may not be reachable."
  fi
  mkdir -p /opt/jellyfin/media 2>/dev/null || true
  docker volume create jellyfin-config >/dev/null 2>&1 || true
  docker_run jellyfin -p 8096:8096 \
    -v jellyfin-config:/config -v /opt/jellyfin/media:/media \
    jellyfin/jellyfin || return 1
  ok "Jellyfin installed."
  SUMMARIES+=("Jellyfin — http://<server-ip>:8096")
  echo "  Open: http://<server-ip>:8096  (put movies in /opt/jellyfin/media)"
}

# ============================================================================
#  TOOL 21 — Plex (media streaming)
# ============================================================================
install_plex() {
  title "Plex — media streaming (needs a free Plex account)"
  require_root plex || return 1
  require_docker || return 1
  confirm "Install Plex Media Server?" || { info "Skipped Plex."; return 0; }
  if port_busy 32400; then
    warn "Port 32400 is busy — Plex may not be reachable."
  fi
  mkdir -p /opt/plex/media 2>/dev/null || true
  docker volume create plex-config >/dev/null 2>&1 || true
  docker_run plex -p 32400:32400 -e TZ=UTC \
    -v plex-config:/config -v /opt/plex/media:/media \
    plexinc/pms-docker || return 1
  ok "Plex installed."
  SUMMARIES+=("Plex — http://<server-ip>:32400/web (login with your Plex account)")
  echo "  Open: http://<server-ip>:32400/web"
  echo "  Put media in /opt/plex/media"
}

# ============================================================================
#  TOOL 22 — PufferPanel (game server panel)
# ============================================================================
install_pufferpanel() {
  title "PufferPanel — lightweight game server panel"
  require_root pufferpanel || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "PufferPanel is meant for real servers; on ${ENV_LABEL} it may not work."
  fi
  confirm "Install PufferPanel (manage game servers in the browser)?" || { info "Skipped PufferPanel."; return 0; }
  info "Running official PufferPanel installer..."
  curl -fsSL https://install.pufferpanel.com -o /tmp/pufferpanel-install.sh || { error "Download failed."; return 1; }
  bash /tmp/pufferpanel-install.sh || { error "PufferPanel install failed."; return 1; }
  rm -f /tmp/pufferpanel-install.sh 2>/dev/null || true
  if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl enable --now pufferpanel >/dev/null 2>&1 || true
  fi
  ok "PufferPanel installed."
  SUMMARIES+=("PufferPanel — http://<server-ip>:8080 (register first admin at /auth/register)")
  echo "  Open: http://<server-ip>:8080  → register the first admin account"
}

# ============================================================================
#  TOOL 23 — Pelican Panel (Pterodactyl successor)
# ============================================================================
install_pelican() {
  title "Pelican Panel — game server panel (Pterodactyl fork)"
  require_root pelican || return 1
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "Pelican officially supports Ubuntu 24.04+ — other distros may fail."
  fi
  confirm "Install Pelican Panel files (panel setup is finished via browser)?" || { info "Skipped Pelican."; return 0; }
  info "Installing requirements (PHP 8.3, MariaDB, Nginx, Composer)..."
  apt_install curl tar git composer mariadb-server nginx \
    php8.3-cli php8.3-common php8.3-gd php8.3-mysql php8.3-mbstring \
    php8.3-xml php8.3-curl php8.3-zip php8.3-intl || {
    error "Requirements failed — Pelican needs Ubuntu 24.04 with PHP 8.3 packages."
    return 1
  }
  info "Downloading official Pelican release..."
  mkdir -p /var/www/pelican
  curl -fsSL "https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz" \
    -o /tmp/pelican.tar.gz || { error "Download failed."; return 1; }
  tar -xzf /tmp/pelican.tar.gz -C /var/www/pelican || { error "Extract failed."; return 1; }
  rm -f /tmp/pelican.tar.gz 2>/dev/null || true
  info "Installing PHP dependencies (Composer)..."
  ( cd /var/www/pelican && composer install --no-dev --optimize-autoloader --no-interaction ) || {
    warn "Composer install failed — panel files are in /var/www/pelican."
    return 1
  }
  chown -R www-data:www-data /var/www/pelican
  ok "Pelican panel files installed."
  SUMMARIES+=("Pelican Panel — files at /var/www/pelican (run setup steps below)")
  echo "  Next steps:"
  echo "    1. sudo -u www-data php /var/www/pelican/artisan p:environment:setup"
  echo "    2. Open http://<server-ip>/installer in the browser and follow the wizard"
  echo "  (Wings daemon is installed separately after the panel is running)"
}

# ============================================================================
#  TOOL 24 — FeatherPanel (modern game server panel)
# ============================================================================
install_featherpanel() {
  title "FeatherPanel — modern game server panel (MythicalSystems)"
  require_root featherpanel || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "FeatherPanel needs Docker + systemd; on ${ENV_LABEL} it may not work."
  fi
  confirm "Install FeatherPanel (official installer — panel + FeatherWings daemon)?" || { info "Skipped FeatherPanel."; return 0; }
  info "Downloading official FeatherPanel installer..."
  curl -fsSL https://get.featherpanel.com/installer.sh -o /tmp/featherpanel-install.sh || { error "Download failed."; return 1; }
  info "Running FeatherPanel installer (sets up panel, Docker and FeatherWings)..."
  bash /tmp/featherpanel-install.sh || { error "FeatherPanel install failed."; return 1; }
  rm -f /tmp/featherpanel-install.sh 2>/dev/null || true
  ok "FeatherPanel installed."
  SUMMARIES+=("FeatherPanel — http://<server-ip>:8080 (panel + FeatherWings)")
  echo "  Panel:   http://<server-ip>:8080  (or the port shown at the end of install)"
  echo "  Wings:   config at /etc/featherpanel/config.yml — paste from Panel → Nodes → Configuration"
}

# ============================================================================
#  TOOL 25 — Pterodactyl (classic game panel)
# ============================================================================
install_pterodactyl() {
  title "Pterodactyl — the classic top game panel"
  require_root pterodactyl || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "Pterodactyl needs Docker + systemd; on ${ENV_LABEL} it may not work."
  fi
  warn "The official installer is interactive — it asks panel/wings, country and timezone."
  confirm "Install Pterodactyl Panel (official installer, uses port 80)?" || { info "Skipped Pterodactyl."; return 0; }
  info "Downloading official Pterodactyl installer..."
  curl -fsSL https://pterodactyl-installer.se -o /tmp/pterodactyl-install.sh || { error "Download failed."; return 1; }
  info "Running Pterodactyl installer (follow the prompts)..."
  bash /tmp/pterodactyl-install.sh || { error "Pterodactyl install failed."; return 1; }
  rm -f /tmp/pterodactyl-install.sh 2>/dev/null || true
  ok "Pterodactyl installed."
  SUMMARIES+=("Pterodactyl Panel + Wings — http://<server-ip> (admin created during install)")
  echo "  Panel: http://<server-ip>   (admin account is set up inside the installer)"
}

# ============================================================================
#  TOOL 26 — Crafty Controller (Minecraft)
# ============================================================================
install_crafty() {
  title "Crafty Controller — Minecraft dashboard"
  require_root crafty || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "Crafty is meant for real servers; on ${ENV_LABEL} it may not work."
  fi
  warn "Interactive installer — it asks for API port (8444), web port (8443) and RCON port."
  confirm "Install Crafty Controller (Minecraft-only web dashboard)?" || { info "Skipped Crafty."; return 0; }
  info "Downloading official Crafty installer..."
  curl -fsSL "https://gitlab.com/crafty-controller/crafty-installer/-/archive/main/crafty-installer-main.tar.gz" \
    -o /tmp/crafty.tar.gz || { error "Download failed."; return 1; }
  rm -rf /tmp/crafty-installer 2>/dev/null || true
  mkdir -p /tmp/crafty-installer
  tar -xzf /tmp/crafty.tar.gz -C /tmp/crafty-installer --strip-components=1 || { error "Extract failed."; return 1; }
  rm -f /tmp/crafty.tar.gz 2>/dev/null || true
  info "Running Crafty installer (follow the prompts)..."
  ( cd /tmp/crafty-installer && chmod +x install.sh && ./install.sh ) || { error "Crafty install failed."; return 1; }
  ok "Crafty Controller installed."
  SUMMARIES+=("Crafty Controller — https://<server-ip>:8443 (default user: admin / crafty)")
  echo "  Web: https://<server-ip>:8443   (default login: admin / crafty)"
  echo "  API: port 8444"
}

# ============================================================================
#  TOOL 27 — MineOS (classic Minecraft management)
# ============================================================================
install_mineos() {
  title "MineOS — classic Minecraft server management"
  require_root mineos || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "MineOS is meant for real servers; on ${ENV_LABEL} it may not work."
  fi
  warn "MineOS and Crafty both use web port 8443 — do not install both on one server."
  confirm "Install MineOS (web UI to run Minecraft servers)?" || { info "Skipped MineOS."; return 0; }
  info "Downloading official MineOS installer..."
  curl -fsSL https://raw.githubusercontent.com/hexparrot/mineos-node/master/install.sh \
    -o /tmp/mineos-install.sh || { error "Download failed."; return 1; }
  info "Running MineOS installer (installs Node.js + Java + UI)..."
  bash /tmp/mineos-install.sh || { error "MineOS install failed."; return 1; }
  rm -f /tmp/mineos-install.sh 2>/dev/null || true
  service mineos start >/dev/null 2>&1 || systemctl start mineos >/dev/null 2>&1 || true
  ok "MineOS installed."
  SUMMARIES+=("MineOS — https://<server-ip>:8443 (login with a system user)")
  echo "  Web: https://<server-ip>:8443  (self-signed cert — accept the warning)"
  echo "  Login with any system user that has /usr/games/minecraft rights"
}

# ============================================================================
#  TOOL 28 — Open Game Panel (OGP)
# ============================================================================
install_ogp() {
  title "Open Game Panel (OGP) — classic panel"
  require_root ogp || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "OGP needs MySQL and systemd; on ${ENV_LABEL} it may not work."
  fi
  warn "Interactive installer — it asks for MySQL details and panel settings."
  confirm "Install Open Game Panel (panel + agent)?" || { info "Skipped OGP."; return 0; }
  info "Downloading official OGP installer..."
  curl -fsSL "https://github.com/OpenGamePanel/OGP-Installer-Linux/archive/master.tar.gz" \
    -o /tmp/ogp.tar.gz || { error "Download failed."; return 1; }
  rm -rf /tmp/ogp-installer 2>/dev/null || true
  mkdir -p /tmp/ogp-installer
  tar -xzf /tmp/ogp.tar.gz -C /tmp/ogp-installer --strip-components=1 || { error "Extract failed."; return 1; }
  rm -f /tmp/ogp.tar.gz 2>/dev/null || true
  info "Running OGP installer (follow the prompts)..."
  ( cd /tmp/ogp-installer && chmod +x install.sh && ./install.sh ) || { error "OGP install failed."; return 1; }
  ok "Open Game Panel installed."
  SUMMARIES+=("Open Game Panel — http://<server-ip> (admin panel from installer)")
  echo "  Panel: http://<server-ip>  — login details shown at the end of install"
}

# ============================================================================
#  TOOL 29 — GameAP (game server management)
# ============================================================================
install_gameap() {
  title "GameAP — fast game server management panel"
  require_root gameap || return 1
  if [ "$ENV_TYPE" != "vps" ]; then
    warn "GameAP needs systemd; on ${ENV_LABEL} it may not work."
  fi
  warn "The official installer asks a few questions (installer URL, ports, admin)."
  confirm "Install GameAP (official installer, written in Go)?" || { info "Skipped GameAP."; return 0; }
  info "Running official GameAP installer..."
  bash <(curl -s https://gameap.com/install.sh) || { error "GameAP install failed."; return 1; }
  ok "GameAP installed."
  SUMMARIES+=("GameAP — http://<server-ip> (details shown by the installer)")
  echo "  Panel:  http://<server-ip>  — created during install"
  echo "  Daemon: sudo gameapctl daemon install  (after creating a node in the panel)"
}

# ============================================================================
#  TOOL 30 — LinuxGSM (command-line game server manager)
# ============================================================================
install_linuxgsm() {
  title "LinuxGSM — 100+ games via command line"
  require_root linuxgsm || return 1
  confirm "Install LinuxGSM (scripts to deploy 100+ game servers)?" || { info "Skipped LinuxGSM."; return 0; }
  info "Downloading LinuxGSM..."
  curl -fsSL -o /root/linuxgsm.sh https://linuxgsm.sh || { error "Download failed."; return 1; }
  chmod +x /root/linuxgsm.sh
  ok "LinuxGSM installed."
  SUMMARIES+=("LinuxGSM — /root/linuxgsm.sh")
  echo "  Usage:"
  echo "    1. Create a dedicated user:  sudo useradd -m -s /bin/bash gameserver"
  echo "    2. sudo -u gameserver -i && cd ~"
  echo "    3. bash /root/linuxgsm.sh mcserver      (Minecraft example)"
  echo "    4. ./mcserver install"
  echo "    5. ./mcserver start"
}

# ============================================================================
#  TOOL 31 — Pterodactyl Wings (daemon)
# ============================================================================
install_pterowings() {
  title "Pterodactyl Wings — game server daemon"
  require_root pterowings || return 1
  require_docker || return 1
  confirm "Install Pterodactyl Wings (official installer, daemon only)?" || { info "Skipped Pterodactyl Wings."; return 0; }
  info "Running official Pterodactyl installer in Wings mode..."
  bash <(curl -sSL https://pterodactyl-installer.se) wings || { error "Wings install failed."; return 1; }
  ok "Pterodactyl Wings installed."
  SUMMARIES+=("Pterodactyl Wings — daemon installed")
  echo "  Next: in the Pterodactyl Panel → Nodes → create a node, copy its config to:"
  echo "    /etc/pterodactyl/config.yml   (or run the Auto Deploy command)"
  echo "    Then: sudo systemctl restart wings"
}

# ============================================================================
#  TOOL 32 — Pelican Wings (daemon, fully automatic)
# ============================================================================
install_pelicanwings() {
  title "Pelican Wings — game server daemon (automatic)"
  require_root pelicanwings || return 1
  require_docker || return 1
  confirm "Install Pelican Wings (binary + systemd service automatically)?" || { info "Skipped Pelican Wings."; return 0; }
  WINGS_ARCH="amd64"
  [ "$ARCH" = "arm64" ] && WINGS_ARCH="arm64"
  info "Downloading wings (linux-${WINGS_ARCH}) from official releases..."
  mkdir -p /etc/pelican /var/run/wings
  curl -fsSL -o /usr/local/bin/wings \
    "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${WINGS_ARCH}" || { error "Download failed."; return 1; }
  chmod 755 /usr/local/bin/wings
  info "Creating systemd service..."
  {
    echo "[Unit]"
    echo "Description=Wings Daemon"
    echo "After=docker.service"
    echo "Requires=docker.service"
    echo "PartOf=docker.service"
    echo
    echo "[Service]"
    echo "User=root"
    echo "WorkingDirectory=/etc/pelican"
    echo "LimitNOFILE=4096"
    echo "PIDFile=/var/run/wings/daemon.pid"
    echo "ExecStart=/usr/local/bin/wings"
    echo "Restart=on-failure"
    echo "StartLimitInterval=180"
    echo "StartLimitBurst=30"
    echo "RestartSec=5s"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > /etc/systemd/system/wings.service
  systemctl daemon-reload
  systemctl enable --now wings >/dev/null 2>&1 || true
  ok "Pelican Wings installed and enabled."
  SUMMARIES+=("Pelican Wings — binary + systemd service (auto-installed)")
  echo "  Next: in the Pelican Panel → Nodes → create a node, copy its config to:"
  echo "    /etc/pelican/config.yml   (or run the Auto Deploy command)"
  echo "    Then: sudo systemctl restart wings"
}

# ============================================================================
#  TOOL 33 — FeatherWings (daemon)
# ============================================================================
install_featherwings() {
  title "FeatherWings — game server daemon for FeatherPanel"
  require_root featherwings || return 1
  require_docker || return 1
  confirm "Install FeatherWings (official installer)?" || { info "Skipped FeatherWings."; return 0; }
  info "Downloading official FeatherWings installer..."
  curl -fsSL https://get.featherpanel.com/beta.sh -o /tmp/featherwings-install.sh || { error "Download failed."; return 1; }
  info "Running FeatherWings installer..."
  bash /tmp/featherwings-install.sh || { error "FeatherWings install failed."; return 1; }
  rm -f /tmp/featherwings-install.sh 2>/dev/null || true
  ok "FeatherWings installed."
  SUMMARIES+=("FeatherWings — daemon installed")
  echo "  Next: in FeatherPanel → Nodes → create a node, copy its config to:"
  echo "    /etc/featherpanel/config.yml   (or run the Auto Deploy command)"
}

# ============================================================================
#  TOOL 34 — Let's Encrypt SSL (Certbot)
# ============================================================================
install_ssl() {
  title "Let's Encrypt SSL — free certificates (Certbot)"
  require_root ssl || return 1
  if [ "$ENV_TYPE" = "container" ]; then
    warn "Inside a container, ports 80/443 must be forwarded by the host for issuance."
  fi
  confirm "Install Certbot and issue a free SSL certificate?" || { info "Skipped SSL."; return 0; }

  DOMAINS=""
  if [ -n "${CFD_DOMAIN:-}" ]; then DOMAINS="$CFD_DOMAIN"; fi
  if [ -z "$DOMAINS" ]; then
    echo -n -e "${CYAN}  ? Domain(s) for the certificate (e.g. example.com,www.example.com): ${NC}"
    read -r DOMAINS || { echo; info "No input — skipping SSL."; return 1; }
  fi
  DOMAINS=$(echo "$DOMAINS" | tr -d '[:space:]')
  [ -z "$DOMAINS" ] && { error "Domain required."; return 1; }

  EMAIL=""
  if [ -n "${CFD_EMAIL:-}" ]; then EMAIL="$CFD_EMAIL"; fi
  if [ -z "$EMAIL" ]; then
    echo -n -e "${CYAN}  ? Email for expiry notices (e.g. admin@yourdomain.com): ${NC}"
    read -r EMAIL || EMAIL=""
  fi
  [ -z "$EMAIL" ] && { error "An email address is required by Let's Encrypt."; return 1; }

  info "Installing Certbot..."
  apt_install certbot python3-certbot-nginx || return 1

  PLUGIN="standalone"
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    PLUGIN="nginx"
  elif command -v apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2 2>/dev/null; then
    PLUGIN="apache"
  fi
  info "Issuing certificate for: ${DOMAINS}  (plugin: ${PLUGIN})..."
  case "$PLUGIN" in
    nginx)  certbot --nginx --non-interactive --agree-tos --redirect -m "$EMAIL" -d "$DOMAINS" ;;
    apache) certbot --apache --non-interactive --agree-tos --redirect -m "$EMAIL" -d "$DOMAINS" ;;
    *)      certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAINS" ;;
  esac || { error "Issuance failed — check DNS points here and port 80 is open."; return 1; }

  systemctl enable certbot.timer >/dev/null 2>&1 || true
  ok "SSL certificate issued for: $DOMAINS"
  SUMMARIES+=("SSL — Let's Encrypt cert for ${DOMAINS} (auto-renew enabled)")
  echo "  Certificates: /etc/letsencrypt/live/<first-domain>/"
  echo "  Test auto-renew: sudo certbot renew --dry-run"
}

# ============================================================================
#  Runner + Menu
# ============================================================================
run_tool() {
  local tool="$1"
  if install_$tool; then
    ok "($tool) installed."
  else
    warn "($tool) skipped or failed — continuing with the next tool."
  fi
}

install_all() {
  for t in tunnel xrdp docker lemp node security monitoring cockpit \
           portainer casaos uptimekuma adguard npm nextcloud jellyfin \
           pufferpanel featherpanel crafty linuxgsm; do
    echo
    run_tool "$t"
  done
}

run_selection() {
  local input="$1"
  [ -z "$input" ] && return 0
  input=$(echo "$input" | tr -d '\r')
  if [ "$input" = "all" ] || [ "$input" = "a" ] || [ "$input" = "9" ]; then
    install_all; return 0
  fi
  IFS=',' read -ra picks <<< "$input"
  for p in "${picks[@]}"; do
    case "$p" in
      1|tunnel)   run_tool tunnel ;;
      2|xrdp)     run_tool xrdp ;;
      3|docker)   run_tool docker ;;
      4|lemp)     run_tool lemp ;;
      5|node|nodejs) run_tool node ;;
      6|security) run_tool security ;;
      7|monitor|monitoring) run_tool monitoring ;;
      8|cockpit)  run_tool cockpit ;;
      10|portainer)  run_tool portainer ;;
      11|casaos)     run_tool casaos ;;
      12|hestia|hestiacp) run_tool hestiacp ;;
      13|cyberpanel) run_tool cyberpanel ;;
      14|aapanel|aa)  run_tool aapanel ;;
      15|uptimekuma|kuma) run_tool uptimekuma ;;
      16|pihole|pi-hole) run_tool pihole ;;
      17|adguard)    run_tool adguard ;;
      18|npm|proxymanager) run_tool npm ;;
      19|nextcloud)  run_tool nextcloud ;;
      20|jellyfin)   run_tool jellyfin ;;
      21|plex)       run_tool plex ;;
      22|pufferpanel|puffer) run_tool pufferpanel ;;
      23|pelican)    run_tool pelican ;;
      24|feather|featherpanel) run_tool featherpanel ;;
      25|pterodactyl) run_tool pterodactyl ;;
      26|crafty)      run_tool crafty ;;
      27|mineos)      run_tool mineos ;;
      28|ogp)         run_tool ogp ;;
      29|gameap)      run_tool gameap ;;
      30|linuxgsm|lgsm) run_tool linuxgsm ;;
      31|pterowings|pterodactylwings) run_tool pterowings ;;
      32|pelicanwings)  run_tool pelicanwings ;;
      33|featherwings)  run_tool featherwings ;;
      34|ssl|certbot)   run_tool ssl ;;
      0|q|quit|exit) info "Exiting."; exit 0 ;;
      *) warn "Unknown selection: ${p} (try 1-9, tool names, or 'all')" ;;
    esac
  done
}

# ============================================================================
#  Uninstaller
# ============================================================================
run_uninstall() {
  local tool="$1"
  if uninstall_$tool; then
    ok "($tool) uninstalled."
  else
    warn "($tool) uninstall skipped or failed — continuing."
  fi
}

uninstall_tunnel() {
  title "Uninstalling Cloudflare Tunnel"
  confirm "Remove the Cloudflare tunnel and all its config?" || { info "Skipped."; return 1; }
  command -v cloudflared >/dev/null 2>&1 && cloudflared service uninstall >/dev/null 2>&1 || true
  systemctl is-active --quiet cloudflared 2>/dev/null && { systemctl stop cloudflared 2>/dev/null || true; systemctl disable cloudflared 2>/dev/null || true; }
  systemctl --user is-active --quiet cloudflared 2>/dev/null && systemctl --user disable --now cloudflared 2>/dev/null || true
  if [ -f "$CFD_PID_HOME" ]; then kill "$(cat "$CFD_PID_HOME")" 2>/dev/null || true; fi
  rm -f "$SERVICE_UNIT_HOME" /etc/systemd/system/cloudflared.service 2>/dev/null || true
  rm -rf "$CFD_DIR_HOME" "$CFD_SYS_DIR" 2>/dev/null || true
  rm -f /usr/local/bin/cloudflared "$HOME/.local/bin/cloudflared" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  ok "Cloudflare tunnel removed."
}

uninstall_xrdp() {
  title "Uninstalling xrdp"
  confirm "Remove xrdp Remote Desktop (your desktop environment stays)?" || { info "Skipped."; return 1; }
  apt-get purge -y xrdp >/dev/null 2>&1 || true
  ok "xrdp removed."
}

uninstall_docker() {
  title "Uninstalling Docker"
  confirm "Stop/remove ALL Docker containers, images and volumes? This deletes their data!" || { info "Skipped."; return 1; }
  command -v docker >/dev/null 2>&1 && docker rm -f "$(docker ps -aq)" >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker system prune -af --volumes >/dev/null 2>&1 || true
  systemctl stop docker 2>/dev/null || true
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-ce-rootless-extras >/dev/null 2>&1 || true
  rm -rf /var/lib/docker /etc/docker 2>/dev/null || true
  ok "Docker removed."
}

uninstall_lemp() {
  title "Uninstalling LEMP Stack"
  confirm "Remove Nginx, PHP-FPM and MariaDB (websites/databases are deleted)?" || { info "Skipped."; return 1; }
  systemctl stop nginx php8.3-fpm mariadb 2>/dev/null || true
  apt-get purge -y nginx nginx-common php-fpm php-mysql mariadb-server >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
  rm -rf /var/www/html /etc/nginx/sites-enabled/default 2>/dev/null || true
  ok "LEMP removed."
}

uninstall_node() {
  title "Uninstalling Node.js"
  confirm "Remove Node.js and the NodeSource repo?" || { info "Skipped."; return 1; }
  apt-get purge -y nodejs >/dev/null 2>&1 || true
  rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
  ok "Node.js removed."
}

uninstall_security() {
  title "Uninstalling Security Hardening"
  confirm "Disable UFW and remove Fail2ban?" || { info "Skipped."; return 1; }
  ufw --force disable >/dev/null 2>&1 || true
  systemctl stop fail2ban 2>/dev/null || true
  apt-get purge -y ufw fail2ban >/dev/null 2>&1 || true
  ok "Firewall/fail2ban removed."
}

uninstall_monitoring() {
  title "Uninstalling Monitoring"
  confirm "Remove btop, htop and Netdata?" || { info "Skipped."; return 1; }
  apt-get purge -y btop htop >/dev/null 2>&1 || true
  if command -v netdata >/dev/null 2>&1; then
    netdata -u >/dev/null 2>&1 || true
  fi
  curl -fsSL https://raw.githubusercontent.com/netdata/netdata/master/packaging/installer/netdata-uninstaller.sh -o /tmp/netdata-uninstaller.sh 2>/dev/null \
    && bash /tmp/netdata-uninstaller.sh --yes >/dev/null 2>&1 || true
  rm -f /tmp/netdata-uninstaller.sh 2>/dev/null || true
  apt-get purge -y netdata >/dev/null 2>&1 || true
  ok "Monitoring tools removed."
}

uninstall_cockpit() {
  title "Uninstalling Cockpit"
  confirm "Remove Cockpit?" || { info "Skipped."; return 1; }
  systemctl stop cockpit 2>/dev/null || true
  apt-get purge -y cockpit >/dev/null 2>&1 || true
  ok "Cockpit removed."
}

uninstall_portainer() {
  title "Uninstalling Portainer"
  confirm "Remove Portainer and its data volume?" || { info "Skipped."; return 1; }
  command -v docker >/dev/null 2>&1 && docker rm -f portainer >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker volume rm portainer_data >/dev/null 2>&1 || true
  ok "Portainer removed."
}

uninstall_casaos() {
  title "Uninstalling CasaOS"
  confirm "Remove CasaOS? (installed apps may remain in Docker)" || { info "Skipped."; return 1; }
  systemctl stop casaos 2>/dev/null || true
  command -v casaos-uninstall >/dev/null 2>&1 && casaos-uninstall >/dev/null 2>&1 || true
  rm -rf /opt/casaos /usr/bin/casaos* /etc/systemd/system/casaos* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "CasaOS removed."
}

uninstall_uptimekuma() {
  title "Uninstalling Uptime Kuma"
  confirm "Remove Uptime Kuma and its data volume?" || { info "Skipped."; return 1; }
  command -v docker >/dev/null 2>&1 && docker rm -f uptime-kuma >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker volume rm uptime-kuma-data >/dev/null 2>&1 || true
  ok "Uptime Kuma removed."
}

uninstall_pihole() {
  title "Uninstalling Pi-hole"
  confirm "Run Pi-hole's official uninstaller?" || { info "Skipped."; return 1; }
  if command -v pihole >/dev/null 2>&1; then
    pihole uninstall || true
  else
    apt-get purge -y pihole >/dev/null 2>&1 || true
  fi
  ok "Pi-hole removed."
}

uninstall_adguard() {
  title "Uninstalling AdGuard Home"
  confirm "Remove AdGuard Home?" || { info "Skipped."; return 1; }
  [ -f /opt/AdGuardHome/AdGuardHome ] && /opt/AdGuardHome/AdGuardHome -s uninstall >/dev/null 2>&1 || true
  rm -rf /opt/AdGuardHome 2>/dev/null || true
  ok "AdGuard Home removed."
}

uninstall_npm() {
  title "Uninstalling Nginx Proxy Manager"
  confirm "Remove NPM and its data volumes?" || { info "Skipped."; return 1; }
  command -v docker >/dev/null 2>&1 && docker rm -f nginx-proxy-manager >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker volume rm npm-data npm-letsencrypt >/dev/null 2>&1 || true
  ok "Nginx Proxy Manager removed."
}

uninstall_nextcloud() {
  title "Uninstalling Nextcloud"
  confirm "Remove Nextcloud and ALL its files (volume deleted)?" || { info "Skipped."; return 1; }
  command -v docker >/dev/null 2>&1 && docker rm -f nextcloud >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker volume rm nextcloud-data >/dev/null 2>&1 || true
  ok "Nextcloud removed."
}

uninstall_jellyfin() {
  title "Uninstalling Jellyfin"
  confirm "Remove Jellyfin (media in /opt/jellyfin/media stays)?" || { info "Skipped."; return 1; }
  command -v docker >/dev/null 2>&1 && docker rm -f jellyfin >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker volume rm jellyfin-config >/dev/null 2>&1 || true
  rm -rf /opt/jellyfin 2>/dev/null || true
  ok "Jellyfin removed."
}

uninstall_plex() {
  title "Uninstalling Plex"
  confirm "Remove Plex (media in /opt/plex/media stays)?" || { info "Skipped."; return 1; }
  command -v docker >/dev/null 2>&1 && docker rm -f plex >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker volume rm plex-config >/dev/null 2>&1 || true
  rm -rf /opt/plex 2>/dev/null || true
  ok "Plex removed."
}

uninstall_pufferpanel() {
  title "Uninstalling PufferPanel"
  confirm "Remove PufferPanel (server files are deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now pufferpanel 2>/dev/null || true
  rm -rf /etc/pufferpanel /var/lib/pufferpanel /var/cache/pufferpanel /usr/local/bin/pufferpanel 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "PufferPanel removed."
}

uninstall_pelican() {
  title "Uninstalling Pelican Panel"
  confirm "Remove the Pelican Panel? (Wings daemon is removed separately via tool 32)" || { info "Skipped."; return 1; }
  systemctl disable --now pelican 2>/dev/null || true
  rm -rf /var/www/pelican /etc/pelican/panel.env /etc/systemd/system/pelican* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "Pelican panel removed."
}

uninstall_featherpanel() {
  title "Uninstalling FeatherPanel"
  confirm "Remove FeatherPanel? (FeatherWings daemon is removed separately via tool 33)" || { info "Skipped."; return 1; }
  systemctl disable --now featherpanel 2>/dev/null || true
  rm -rf /etc/featherpanel /var/lib/featherpanel /opt/featherpanel /usr/local/bin/featherpanel /etc/systemd/system/featherpanel* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "FeatherPanel removed."
}

uninstall_pterodactyl() {
  title "Uninstalling Pterodactyl"
  confirm "Remove the Pterodactyl panel and Wings? (all game server data is deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now panel wings 2>/dev/null || true
  rm -rf /var/www/pterodactyl /etc/pterodactyl /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf /etc/systemd/system/wings.service /etc/systemd/system/panel.service /usr/local/bin/wings 2>/dev/null || true
  apt-get purge -y mariadb-server redis-server >/dev/null 2>&1 || true
  systemctl daemon-reload 2>/dev/null || true
  nginx -s reload 2>/dev/null || true
  ok "Pterodactyl removed."
}

uninstall_crafty() {
  title "Uninstalling Crafty Controller"
  confirm "Remove Crafty Controller? (all server worlds/configs are deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now crafty 2>/dev/null || true
  rm -rf /var/opt/minecraft/crafty_controller /opt/crafty /etc/systemd/system/crafty* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "Crafty removed."
}

uninstall_mineos() {
  title "Uninstalling MineOS"
  confirm "Remove MineOS? (Minecraft worlds in /var/games/minecraft are deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now mineos 2>/dev/null || true
  rm -rf /usr/games/minecraft /var/games/minecraft /etc/mineos.conf /usr/local/bin/mineos /etc/systemd/system/mineos* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "MineOS removed."
}

uninstall_ogp() {
  title "Uninstalling Open Game Panel"
  confirm "Remove OGP panel + agent? (game server files are deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now ogp-panel ogp-agent 2>/dev/null || true
  rm -rf /var/www/ogp_panel /usr/local/ogp_agent /etc/systemd/system/ogp-* /etc/systemd/system/ogp* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "OGP removed."
}

uninstall_gameap() {
  title "Uninstalling GameAP"
  confirm "Remove GameAP panel? (game server data in /var/lib/gameap is deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now gameap 2>/dev/null || true
  rm -rf /etc/gameap /var/lib/gameap /var/www/gameap /usr/local/bin/gameap* /etc/systemd/system/gameap* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "GameAP removed."
}

uninstall_linuxgsm() {
  title "Uninstalling LinuxGSM"
  confirm "Remove LinuxGSM and all downloaded game servers?" || { info "Skipped."; return 1; }
  rm -rf /root/linuxgsm.sh /root/log /root/serverfiles /root/lgsm /root/.config 2>/dev/null || true
  find /root -maxdepth 1 -name "server" -o -maxdepth 1 -name "mcserver" 2>/dev/null | xargs -r rm -rf 2>/dev/null || true
  ok "LinuxGSM removed."
}

uninstall_pterowings() {
  title "Uninstalling Pterodactyl Wings"
  confirm "Remove Wings daemon (all server data is deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now wings 2>/dev/null || true
  rm -rf /etc/pterodactyl /var/lib/pterodactyl /usr/local/bin/wings /etc/systemd/system/wings.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "Wings removed."
}

uninstall_pelicanwings() {
  title "Uninstalling Pelican Wings"
  confirm "Remove Wings daemon (all server data in /var/lib/pelican is deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now wings 2>/dev/null || true
  rm -rf /etc/pelican /var/lib/pelican /var/run/wings /usr/local/bin/wings /etc/systemd/system/wings.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "Wings removed."
}

uninstall_featherwings() {
  title "Uninstalling FeatherWings"
  confirm "Remove FeatherWings daemon (all server data is deleted)?" || { info "Skipped."; return 1; }
  systemctl disable --now featherwings wings 2>/dev/null || true
  rm -rf /etc/featherwings /var/lib/featherwings /usr/local/bin/featherwings* /etc/systemd/system/featherwings* /etc/systemd/system/wings.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "FeatherWings removed."
}

uninstall_ssl() {
  title "Uninstalling Certbot / SSL"
  confirm "Remove Certbot and ALL issued certificates (sites lose HTTPS)?" || { info "Skipped."; return 1; }
  systemctl stop certbot.timer 2>/dev/null || true
  apt-get purge -y certbot python3-certbot-nginx python3-certbot-apache >/dev/null 2>&1 || true
  rm -rf /etc/letsencrypt 2>/dev/null || true
  ok "Certbot and certificates removed."
}

uninstall_selection() {
  local input="$1"
  [ -z "$input" ] && return 0
  input=$(echo "$input" | tr -d '\r')
  case "$input" in
    all|a)
      confirm "This uninstalls EVERYTHING installed by this script. Continue?" || { info "Skipped."; return 1; }
      for t in tunnel xrdp docker lemp node security monitoring cockpit portainer casaos uptimekuma pihole adguard npm nextcloud jellyfin plex pufferpanel pelican featherpanel pterodactyl crafty mineos ogp gameap linuxgsm pterowings pelicanwings featherwings ssl; do
        echo
        run_uninstall "$t"
      done
      return 0 ;;
  esac
  IFS=',' read -ra picks <<< "$input"
  for p in "${picks[@]}"; do
    case "$p" in
      1|tunnel)   run_uninstall tunnel ;;
      2|xrdp)     run_uninstall xrdp ;;
      3|docker)   run_uninstall docker ;;
      4|lemp)     run_uninstall lemp ;;
      5|node|nodejs) run_uninstall node ;;
      6|security) run_uninstall security ;;
      7|monitor|monitoring) run_uninstall monitoring ;;
      8|cockpit)  run_uninstall cockpit ;;
      10|portainer)  run_uninstall portainer ;;
      11|casaos)     run_uninstall casaos ;;
      12|hestia|hestiacp) warn "HestiaCP ships its own removal: bash hst-install-ubuntu.sh --removeall — manual removal is risky. Skipping." ;;
      13|cyberpanel) warn "CyberPanel: use its built-in uninstaller. Skipping." ;;
      14|aapanel|aa) warn "aaPanel: use its built-in uninstaller in the panel. Skipping." ;;
      15|uptimekuma|kuma) run_uninstall uptimekuma ;;
      16|pihole|pi-hole) run_uninstall pihole ;;
      17|adguard)    run_uninstall adguard ;;
      18|npm|proxymanager) run_uninstall npm ;;
      19|nextcloud)  run_uninstall nextcloud ;;
      20|jellyfin)   run_uninstall jellyfin ;;
      21|plex)       run_uninstall plex ;;
      22|pufferpanel|puffer) run_uninstall pufferpanel ;;
      23|pelican)    run_uninstall pelican ;;
      24|feather|featherpanel) run_uninstall featherpanel ;;
      25|pterodactyl) run_uninstall pterodactyl ;;
      26|crafty)      run_uninstall crafty ;;
      27|mineos)      run_uninstall mineos ;;
      28|ogp)         run_uninstall ogp ;;
      29|gameap)      run_uninstall gameap ;;
      30|linuxgsm|lgsm) run_uninstall linuxgsm ;;
      31|pterowings|pterodactylwings) run_uninstall pterowings ;;
      32|pelicanwings)  run_uninstall pelicanwings ;;
      33|featherwings)  run_uninstall featherwings ;;
      34|ssl|certbot)   run_uninstall ssl ;;
      *) warn "Unknown selection: ${p}" ;;
    esac
  done
}

uninstall_menu() {
  while :; do
    echo
    echo -e "${BOLD}  ═══ UNINSTALLER — choose what to remove ═══${NC}"
    echo "    [1] Cloudflare Tunnel     [10] Portainer          [22] PufferPanel"
    echo "    [2] xrdp                  [11] CasaOS              [23] Pelican Panel"
    echo "    [3] Docker (ALL data)     [15] Uptime Kuma         [24] FeatherPanel"
    echo "    [4] LEMP Stack            [16] Pi-hole             [25] Pterodactyl+Wings"
    echo "    [5] Node.js               [17] AdGuard Home        [26] Crafty"
    echo "    [6] Security/UFW          [18] Nginx Proxy Mgr     [27] MineOS"
    echo "    [7] Monitoring/Netdata    [19] Nextcloud           [28] OGP"
    echo "    [8] Cockpit               [20] Jellyfin            [29] GameAP"
    echo "    [12] HestiaCP (manual)    [21] Plex                [30] LinuxGSM"
    echo "    [13] CyberPanel (manual)  [31] Pterodactyl Wings   [34] SSL/Certbot"
    echo "    [14] aaPanel (manual)     [32] Pelican Wings"
    echo "                              [33] FeatherWings"
    echo
    echo -e "    [9]  Uninstall EVERYTHING"
    echo -e "    [0]  Back"
    echo
    echo -n -e "${CYAN}  Select tools to uninstall (comma-separated, e.g. 1,16, or 'all', 0 = back): ${NC}"
    read -r choice || { echo; return 0; }
    choice=$(echo "$choice" | tr -d '\r')
    case "$choice" in
      ""|0|q|quit|exit) info "Back to main menu."; return 0 ;;
      all|a|9)
        uninstall_selection "all"
        return 0 ;;
      *) uninstall_selection "$choice" ;;
    esac
  done
}

show_menu() {
  echo
  echo -e "${BOLD}  ═══ Core Server ═══${NC}"
  echo "    [1] Cloudflare Zero Trust Tunnel   — secure remote access"
  echo "    [2] xrdp Remote Desktop            — RDP into the server (XFCE/GNOME)"
  echo "    [3] Docker + Docker Compose        — containerized apps"
  echo "    [4] LEMP Stack                     — Nginx + PHP + MariaDB"
  echo "    [5] Node.js LTS                    — JavaScript runtime"
  echo "    [6] Security Hardening             — UFW firewall + Fail2ban"
  echo "    [7] Monitoring                     — btop, htop, Netdata"
  echo "    [8] Admin Panel: Cockpit           — browser-based management"
  echo
  echo -e "${BOLD}  ═══ Containers & Apps (need Docker) ═══${NC}"
  echo "    [10] Portainer                     — Docker web GUI (manage by clicking)"
  echo "    [11] CasaOS                        — App-Store-style dashboard (port 80)"
  echo
  echo -e "${BOLD}  ═══ Web Hosting Panels (ports 80/443) ═══${NC}"
  echo "    [12] HestiaCP                      — lightweight hosting panel"
  echo "    [13] CyberPanel                    — modern hosting panel"
  echo "    [14] aaPanel                       — free hosting panel"
  echo
  echo -e "${BOLD}  ═══ Network, DNS & Monitoring ═══${NC}"
  echo "    [15] Uptime Kuma                   — uptime monitor + Discord/Telegram alerts"
  echo "    [16] Pi-hole                       — network-wide ad blocker (DNS)"
  echo "    [17] AdGuard Home                  — DNS ad blocker (port 53)"
  echo "    [18] Nginx Proxy Manager           — subdomains + free SSL for your apps"
  echo
  echo -e "${BOLD}  ═══ Personal Cloud & Media ═══${NC}"
  echo "    [19] Nextcloud                     — your own Google Drive (port 8080)"
  echo "    [20] Jellyfin                      — your own Netflix (port 8096)"
  echo "    [21] Plex                          — media streaming (port 32400)"
  echo
  echo -e "${BOLD}  ═══ Game Server Panels ═══${NC}"
  echo "    [22] PufferPanel                   — simple game server panel (port 8080)"
  echo "    [23] Pelican Panel                 — Pterodactyl fork (Ubuntu 24.04+)"
  echo "    [24] FeatherPanel                  — modern panel + FeatherWings (Docker)"
  echo "    [25] Pterodactyl                   — the classic top game panel (port 80)"
  echo "    [26] Crafty Controller             — Minecraft-only dashboard (8443)"
  echo "    [27] MineOS                        — classic Minecraft management (8443)"
  echo "    [28] Open Game Panel (OGP)         — classic panel (Windows/Linux)"
  echo "    [29] GameAP                        — fast Go-based panel"
  echo "    [30] LinuxGSM                      — 100+ games via command line"
  echo "    [31] Pterodactyl Wings             — daemon only (official installer)"
  echo "    [32] Pelican Wings                 — daemon only (automatic install)"
  echo "    [33] FeatherWings                  — daemon only (official installer)"
  echo
  echo -e "${BOLD}  ═══ SSL Certificates ═══${NC}"
  echo "    [34] Let's Encrypt SSL             — free certs via Certbot (auto-renew)"
  echo
  echo -e "    [9]  Install Recommended Stack   — core + Docker apps (skips conflicting panels)"
  echo -e "    [0]  Exit"
  echo
}

final_summary() {
  if [ "${#SUMMARIES[@]}" -eq 0 ]; then return 0; fi
  echo
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════════╗"
  echo "  ║                    INSTALLED TOOLS SUMMARY                       ║"
  echo "  ╚══════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  local i
  for i in "${SUMMARIES[@]}"; do
    echo -e "  ${GREEN}✔${NC} ${i}"
  done
  echo
  echo -e "  ${BOLD}Server:${NC} $(hostname) | ${DISTRO} (${ARCH}) | ${ENV_LABEL}"
  echo
}

# ----------------------------------------------------------------------------
#  Main
# ----------------------------------------------------------------------------
ASK_CONFIRM=1
CFD_DOMAIN=""; CFD_TOKEN=""
UNINSTALL_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain) CFD_DOMAIN="${2:-}"; shift 2 ;;
    -t|--token)  CFD_TOKEN="${2:-}"; shift 2 ;;
    -y|--yes)    ASK_CONFIRM=0; shift ;;
    --uninstall) UNINSTALL_MODE=1; shift ;;
    --list)      show_menu; exit 0 ;;
    -h|--help)
      head -n 40 "$0" | grep -E '^#|^$' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) break ;;
  esac
done

detect_environment

# non-interactive: uninstall mode
if [ "$UNINSTALL_MODE" = "1" ]; then
  clear
  echo
  echo -e "${RED}${BOLD}  ════════════════════════════════════════════════════════════${NC}"
  echo -e "${RED}${BOLD}           UNINSTALLER — removes installed tools              ${NC}"
  echo -e "${RED}${BOLD}  ════════════════════════════════════════════════════════════${NC}"
  echo
  if [ $# -gt 0 ]; then
    for arg in "$@"; do
      case "$arg" in
        -y|--yes) : ;;
        *) uninstall_selection "$arg" ;;
      esac
    done
  else
    uninstall_menu
  fi
  echo -e "${RED}${BOLD}  Done. Re-run 'sudo bash installer.sh --uninstall' anytime.${NC}"
  exit 0
fi

clear
echo
echo -e "${VIOLET}${BOLD}  ╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${VIOLET}${BOLD}  ║${NC}              ${NEON}☢ TYXEN MEGA SERVER INSTALLER${NC} ${WHITE}—${NC} ${GRAY}VIP ELITE${NC}              ${VIOLET}${BOLD}║${NC}"
echo -e "${VIOLET}${BOLD}  ║${NC}     34 tools | Panels | Docker apps | Media | Game servers     ${VIOLET}${BOLD}║${NC}"
echo -e "${VIOLET}${BOLD}  ╚══════════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${WHITE}${BOLD}Environment:${NC} ${GREEN}${ENV_LABEL}${NC} | $(uname -m) | ${DISTRO}"
echo -e "  ${WHITE}${BOLD}systemd:${NC} $([ "$HAS_SYSTEMD" = "1" ] && echo "${GREEN}active${NC}" || echo "${RED}not active${NC}") | ${WHITE}${BOLD}Privileges:${NC} $([ "$IS_ROOT" = "1" ] && echo "${GREEN}root${NC}" || echo "${YELLOW}user${NC}")"
echo

# non-interactive: tunnel flags given
if [ -n "$CFD_DOMAIN" ] || [ -n "$CFD_TOKEN" ]; then
  install_tunnel
  final_summary
  exit 0
fi

# non-interactive: tool names/numbers as arguments
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) : ;;
      *) run_selection "$arg" ;;
    esac
  done
  final_summary
  exit 0
fi

# interactive menu loop
while :; do
  show_menu
  echo -n -e "${CYAN}  ? Select tools (e.g. '1,3,6' | 'xrdp,docker' | 'all' | '0' to exit): ${NC}"
  if ! read -r choice; then
    echo
    info "No more input — exiting."
    break
  fi
  choice=$(echo "$choice" | tr -d '\r')
  [ -z "$choice" ] && continue
  case "$choice" in
    0|q|quit|exit) info "Exiting."; break ;;
    *) run_selection "$choice" ;;
  esac
done

final_summary
echo -e "${GREEN}${BOLD}  Done. Re-run 'sudo bash installer.sh' anytime to install more tools.${NC}"