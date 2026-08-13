# MEGA SERVER INSTALLER

All-in-one server setup tool for **VPS, WSL1/WSL2 and Docker/LXC containers**. Auto-detects the environment and installs 34 tools — from a Cloudflare Zero Trust tunnel to game server panels, web hosting panels, media servers and free SSL certificates.

## Features

- **Auto-detection** — knows if it runs on a VPS, WSL or inside a container
- **34 tools** — install any combination, one script
- **Non-interactive** — run tools by number/name as CLI arguments
- **Built-in uninstaller** — remove any tool (or everything) cleanly
- **Secure by default** — Cloudflare tokens are never echoed/logged, configs are mode `600`
- **SSL** — free Let's Encrypt certificates with auto-renewal

## Quick Start

Run directly from GitHub — no file to save (the script downloads itself and
re-runs with `sudo` automatically):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Satyam-Bhaii/server-installer/main/installer.sh)
```

Or via `bash -c` (works over SSH too):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Satyam-Bhaii/server-installer/main/installer.sh)"
```

Want to keep the file for later use? Then use the menu:

```bash
curl -fsSL https://raw.githubusercontent.com/Satyam-Bhaii/server-installer/main/installer.sh -o installer.sh && sudo bash installer.sh
sudo bash installer.sh xrdp           # one tool by name
sudo bash installer.sh 1,3,6          # multiple tools by number
sudo bash installer.sh all            # install everything
```

## Available Tools

| # | Tool | Description |
|---|------|-------------|
| 1 | Cloudflare Zero Trust Tunnel | secure remote access to your server |
| 2 | xrdp | Remote Desktop (RDP) with XFCE/GNOME |
| 3 | Docker + Compose | containerized apps |
| 4 | LEMP Stack | Nginx + PHP + MariaDB |
| 5 | Node.js LTS | JavaScript runtime |
| 6 | Security Hardening | UFW firewall + Fail2ban |
| 7 | Monitoring | btop, htop, Netdata |
| 8 | Cockpit | browser-based admin panel |
| 10 | Portainer | Docker web GUI |
| 11 | CasaOS | App-Store-style dashboard |
| 12 | HestiaCP | lightweight hosting panel |
| 13 | CyberPanel | modern hosting panel |
| 14 | aaPanel | free hosting panel |
| 15 | Uptime Kuma | uptime monitor + alerts |
| 16 | Pi-hole | network-wide ad blocker (DNS) |
| 17 | AdGuard Home | DNS ad blocker |
| 18 | Nginx Proxy Manager | subdomains + free SSL |
| 19 | Nextcloud | your own Google Drive |
| 20 | Jellyfin | your own Netflix |
| 21 | Plex | media streaming |
| 22 | PufferPanel | simple game server panel |
| 23 | Pelican Panel | Pterodactyl fork |
| 24 | FeatherPanel | modern panel + FeatherWings |
| 25 | Pterodactyl | classic game panel |
| 26 | Crafty Controller | Minecraft dashboard |
| 27 | MineOS | Minecraft management |
| 28 | Open Game Panel | classic panel |
| 29 | GameAP | fast Go-based panel |
| 30 | LinuxGSM | 100+ games via CLI |
| 31 | Pterodactyl Wings | game server daemon |
| 32 | Pelican Wings | game server daemon (automatic) |
| 33 | FeatherWings | game server daemon |
| 34 | Let's Encrypt SSL | free certs via Certbot (auto-renew) |

## Tunnel (non-interactive)

```bash
sudo bash installer.sh -d example.com -t <TOKEN>
```

Installs cloudflared, configures the tunnel and sets it up as a background
process, user systemd service or system service — whichever fits your
environment.

## Uninstaller

```bash
sudo bash installer.sh --uninstall            # interactive uninstaller menu
sudo bash installer.sh --uninstall 1,16       # uninstall specific tools
sudo bash installer.sh --uninstall all        # remove everything
```

## Other Flags

| Flag | Meaning |
|------|---------|
| `-d, --domain` | tunnel domain (tunnel mode) |
| `-t, --token` | Cloudflare Zero Trust token (tunnel mode) |
| `-y, --yes` | skip all confirmations (put before tool arguments) |
| `--list` | show available tools |
| `--uninstall` | uninstaller mode |
| `-h, --help` | show help |

## Notes

- Some panels (HestiaCP, CyberPanel, aaPanel, Pterodactyl, Crafty, OGP, GameAP) run their own official interactive installers — keep your terminal open while they run.
- `[9]` installs a recommended stack of core tools + Docker apps, skipping conflicting web panels.
- WSL: systemd-based tools work best with `sudo systemctl` available (WSL2 with systemd enabled).

## Security

- Cloudflare tokens are never echoed, logged or written to shell history.
- Config files are created with `chmod 600`.
- Run on a fresh server or a server you understand — the uninstaller is best-effort, always keep backups.