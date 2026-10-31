#!/usr/bin/env bash
# Host checks, package installs (with consent), ports, opt-in hardening.

dp_pkg_install() {
  local pkgs=("$@")
  if [[ "${DP_ASSUME_INSTALL:-0}" != "1" ]] && ! dp_yes "Install missing package(s): ${pkgs[*]}?" y; then
    dp_die "Required package(s) missing: ${pkgs[*]}"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "${pkgs[@]}"
  else
    dp_die "No supported package manager; install manually: ${pkgs[*]}"
  fi
}

dp_install_docker() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && return 0
  dp_yes "Docker (with compose plugin) is required. Install it via get.docker.com?" y || dp_die "Docker is required."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
  dp_warn "Added ${USER} to the docker group; if docker commands fail, log out/in and re-run."
}

dp_docker() { if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }

dp_preflight() {
  dp_section "Preflight"
  (( BASH_VERSINFO[0] >= 4 )) || dp_die "bash >= 4 required (found ${BASH_VERSION})."
  [[ "$(uname -s)" == "Linux" ]] || dp_warn "Not Linux ($(uname -s)); server features (systemd, nginx, apt) may not work."
  if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    dp_info "Some steps need sudo; you may be asked for your password."
  fi
  local missing=() c
  for c in git curl openssl rsync awk flock envsubst; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if (( ${#missing[@]} )); then
    local pkgs=() m
    for m in "${missing[@]}"; do case "$m" in envsubst) pkgs+=(gettext-base) ;; flock) pkgs+=(util-linux) ;; *) pkgs+=("$m") ;; esac; done
    dp_pkg_install "${pkgs[@]}"
  fi
  local mem_mb disk_gb
  mem_mb="$(awk '/MemTotal/ { print int($2/1024) }' /proc/meminfo 2>/dev/null || echo 0)"
  disk_gb="$(df -Pk "$HOME" | awk 'NR==2 { print int($4/1024/1024) }')"
  dp_ok "memory ${mem_mb} MB, free disk ${disk_gb} GB"
  (( mem_mb == 0 || mem_mb >= 1800 )) || dp_warn "Under 2 GB RAM: Next.js builds may be killed; enable swap in the hardening step."
  (( disk_gb >= 8 )) || dp_warn "Under 8 GB free disk; Docker images and backups need room."
}

dp_port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -tlnH "sport = :${p}" 2>/dev/null | grep -q .; return; fi
  if command -v lsof >/dev/null 2>&1; then lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; return; fi
  return 1
}

# Sets DP_PICKED to the first port >= $1 that is free and not in $DP_CLAIMED_PORTS
# (no subshell, so claims made for earlier envs are remembered).
dp_pick_port() {
  local p="$1"
  while dp_port_in_use "$p" || [[ " ${DP_CLAIMED_PORTS:-} " == *" ${p} "* ]]; do p=$((p + 1)); done
  DP_PICKED="$p"
}
dp_claim_port() { DP_CLAIMED_PORTS+=" $1"; }

# dp_ask_port VAR "Label" base — saved/answered value wins, else the next free port.
dp_ask_port() {
  local var="$1" label="$2" base="$3" def
  def="$(dp_saved "$var")"; def="${!var:-$def}"
  if [[ -z "$def" ]]; then dp_pick_port "$base"; def="$DP_PICKED"; fi
  dp_ask "$var" "$label" "$def" dp_v_port
  dp_claim_port "${!var}"
}

dp_public_ip() { curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true; }

# Warn when a host does not resolve to this server.
dp_dns_check() {
  local host="$1" ip want="${DP_PUBLIC_IP:-}"
  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 { print $1 }')"
  if [[ -z "$ip" ]]; then dp_warn "DNS: ${host} does not resolve yet"; return 1; fi
  if [[ -n "$want" && "$ip" != "$want" ]]; then dp_warn "DNS: ${host} → ${ip}, this server is ${want} (fine behind a proxy/CDN)"; return 1; fi
  dp_ok "DNS ${host} → ${ip}"
}

dp_harden() {
  dp_section "Server hardening (each step optional)"
  if command -v ufw >/dev/null 2>&1 || dp_yes "Install ufw firewall?" n DP_HARDEN_UFW_INSTALL; then
    command -v ufw >/dev/null 2>&1 || dp_pkg_install ufw
    if dp_yes "Firewall: allow only SSH + HTTP/HTTPS (${PUBLIC_HTTP_PORT:-80}/${PUBLIC_HTTPS_PORT:-443})?" y DP_HARDEN_UFW; then
      sudo ufw allow OpenSSH >/dev/null
      if [[ "$EDGE_MODE" != "panel" ]]; then
        sudo ufw allow "${PUBLIC_HTTP_PORT:-80}/tcp" >/dev/null
        sudo ufw allow "${PUBLIC_HTTPS_PORT:-443}/tcp" >/dev/null
      fi
      sudo ufw --force enable >/dev/null && dp_ok "ufw enabled"
    fi
  fi
  if ! swapon --show 2>/dev/null | grep -q . && dp_yes "No swap found. Create a 2 GB swapfile (helps builds on small VPS)?" y DP_HARDEN_SWAP; then
    sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    dp_ok "swap enabled"
  fi
  if [[ ! -f /etc/docker/daemon.json ]] && command -v docker >/dev/null 2>&1 \
    && dp_yes "Limit Docker container logs (10 MB × 5 per container)?" y DP_HARDEN_DOCKER_LOGS; then
    printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "5" }\n}\n' | sudo tee /etc/docker/daemon.json >/dev/null
    sudo systemctl restart docker && dp_ok "docker log rotation set"
  fi
  if command -v apt-get >/dev/null 2>&1 && ! dpkg -s unattended-upgrades >/dev/null 2>&1 \
    && dp_yes "Enable automatic security updates (unattended-upgrades)?" y DP_HARDEN_UPGRADES; then
    dp_pkg_install unattended-upgrades && sudo dpkg-reconfigure -f noninteractive unattended-upgrades
  fi
  if sudo sshd -T 2>/dev/null | grep -q '^passwordauthentication yes'; then
    dp_warn "SSH password login is enabled; consider key-only auth (PasswordAuthentication no)."
  fi
}
