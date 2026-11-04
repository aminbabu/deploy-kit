#!/usr/bin/env bash
# Native (non-Docker) installs on this host: PostgreSQL, MariaDB, Redis, MinIO, and the
# PHP-FPM / Composer / Node toolchain for RUNTIME=native. Distro packages through the
# OS layer (lib/os.sh: apt, dnf, zypper or pacman; asked first); MinIO from dl.min.io. When the app runs in Docker, native services
# also listen on the project network's gateway so containers can reach them.

# Start <unit> after Docker so the gateway address exists when it binds.
dp_after_docker() {
  [[ "$RUNTIME" == docker ]] || return 0
  local dir="/etc/systemd/system/${1}.service.d"
  sudo mkdir -p "$dir"
  printf '[Unit]\nAfter=docker.service\nWants=docker.service\n' | sudo tee "${dir}/10-after-docker.conf" >/dev/null
  sudo systemctl daemon-reload
}

# Let containers reach native services through an active firewall (ufw or firewalld).
dp_allow_bridge() {
  [[ "$RUNTIME" == docker ]] || return 0
  dp_fw_allow_bridge "$(dp_bridge_subnet)" "$(dp_bridge_ip)"
}

# Set "key value" in a space-separated config file (replaces an existing or commented line).
_dp_conf_set() {
  local f="$1" k="$2" v="$3" esc
  esc="$(printf '%s' "$v" | sed 's/[&/\]/\\&/g')"
  if sudo grep -qE "^#? *${k} " "$f"; then
    sudo sed -i -E "0,/^#? *${k} .*/s//${k} ${esc}/" "$f"
  else
    printf '%s %s\n' "$k" "$v" | sudo tee -a "$f" >/dev/null
  fi
}

dp_native_pg() {
  DP_PG_SERVICE="$(dp_pg_service)"
  if command -v psql >/dev/null 2>&1 && systemctl cat "$DP_PG_SERVICE" >/dev/null 2>&1; then
    local have; have="$(psql --version | grep -oE '[0-9]+' | head -1)"
    [[ -z "${DB_VERSION:-}" || "$have" == "${DB_VERSION%%.*}" ]] \
      || dp_warn "PostgreSQL ${have} is already installed; using it (DB_VERSION=${DB_VERSION} needs a manual upgrade)."
  else
    # The distro ships one major; others come from the PostgreSQL project's repos (PGDG).
    dp_os_install_pg "${DB_VERSION:-}"
  fi
  sudo systemctl enable --now "$DP_PG_SERVICE" >/dev/null 2>&1 || true
  dp_pg_hba_scram
  local listen="localhost" hba line reload=0
  if [[ "$RUNTIME" == docker ]]; then
    listen="localhost,$(dp_bridge_ip)"
    hba="$(_dp_pg_admin -tAc 'SHOW hba_file' </dev/null)"
    line="host all all $(dp_bridge_subnet) scram-sha-256"
    sudo grep -qxF "$line" "$hba" || { echo "$line" | sudo tee -a "$hba" >/dev/null; reload=1; }
    dp_after_docker "$DP_PG_SERVICE"
  fi
  if [[ "$(_dp_pg_admin -tAc 'SHOW listen_addresses' </dev/null)" != "$listen" ]]; then
    _dp_pg_admin -c "ALTER SYSTEM SET listen_addresses = '${listen}'" </dev/null
    sudo systemctl restart "$DP_PG_SERVICE"
  elif (( reload )); then
    _dp_pg_admin -c 'SELECT pg_reload_conf()' </dev/null >/dev/null
  fi
  dp_allow_bridge
  dp_ok "PostgreSQL (native) listening on ${listen}:5432"
}

dp_native_mariadb() {
  command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || dp_pkg_install "$(dp_pkg_name mariadb)"
  dp_os_mariadb_init
  local svc=mariadb conf="/etc/mysql/mariadb.conf.d/60-${PROJECT_SLUG}.cnf" bind="127.0.0.1" want
  systemctl cat mariadb >/dev/null 2>&1 || svc=mysql
  [[ -d /etc/mysql/mariadb.conf.d ]] || conf="/etc/my.cnf.d/60-${PROJECT_SLUG}.cnf"
  [[ "$RUNTIME" == docker ]] && bind="127.0.0.1,$(dp_bridge_ip)" && dp_after_docker "$svc"
  want="$(printf '[mysqld]\nbind-address = %s\n' "$bind")"
  if [[ "$(sudo cat "$conf" 2>/dev/null)" != "$want" ]]; then
    sudo mkdir -p "$(dirname "$conf")"; printf '%s\n' "$want" | sudo tee "$conf" >/dev/null
    sudo systemctl restart "$svc"
  fi
  sudo systemctl enable --now "$svc" >/dev/null 2>&1 || true
  dp_allow_bridge
  dp_ok "MySQL/MariaDB (native) listening on ${bind}:3306"
}

dp_native_redis() {
  [[ -n "$(dp_redis_server_bin)" ]] || dp_pkg_install "$(dp_pkg_name redis)"
  dp_redis_layout
  local conf="$DP_REDIS_CONF" svc="$DP_REDIS_SERVICE" before bind="127.0.0.1 -::1" pw
  before="$(sudo md5sum "$conf")"
  # "-" = optional address (Redis 7): the gateway may not exist yet at boot.
  [[ "$RUNTIME" == docker ]] && bind+=" -$(dp_bridge_ip)" && dp_after_docker "$svc"
  _dp_conf_set "$conf" bind "$bind"
  _dp_conf_set "$conf" port 6379
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    pw="${REDIS_PASSWORD//\\/\\\\}"; _dp_conf_set "$conf" requirepass "\"${pw//\"/\\\"}\""
  fi
  sudo systemctl enable "$svc" >/dev/null 2>&1 || true
  [[ "$(sudo md5sum "$conf")" == "$before" ]] && sudo systemctl start "$svc" || sudo systemctl restart "$svc"
  dp_allow_bridge
  dp_ok "Redis (native, ${svc}) listening on ${bind}:6379"
}

dp_native_minio() {
  local arch name="${PROJECT_SLUG}-minio" bin dir data envf unit addr
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) dp_die "MinIO: unsupported CPU $(uname -m)" ;; esac
  dir="/usr/local/lib/${name}"; bin="${dir}/minio"; data="/var/lib/${name}"; envf="/etc/default/${name}"
  sudo mkdir -p "$dir" /etc/default
  if [[ ! -x "$bin" ]]; then
    dp_info "Installing MinIO server + client → ${dir}"
    sudo curl -fsSL -o "$bin" "https://dl.min.io/server/minio/release/linux-${arch}/minio"
    sudo curl -fsSL -o "${dir}/mc" "https://dl.min.io/client/mc/release/linux-${arch}/mc"
    sudo chmod +x "$bin" "${dir}/mc"
  fi
  id minio-user >/dev/null 2>&1 || sudo useradd -r -s /usr/sbin/nologin minio-user
  sudo mkdir -p "$data"; sudo chown minio-user: "$data"
  addr="$(dp_minio_bind)"
  printf 'MINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" | sudo tee "$envf" >/dev/null
  sudo chmod 600 "$envf"
  unit="$(sed -e "s|__SLUG__|${PROJECT_SLUG}|g" -e "s|__BIN__|${bin}|g" -e "s|__DATA__|${data}|g" -e "s|__ENVFILE__|${envf}|g" \
    -e "s|__ADDR__|${addr}:${MINIO_PORT}|g" -e "s|__CONSOLE__|127.0.0.1:${MINIO_CONSOLE_PORT}|g" \
    -e "s|__AFTER__|$([[ $RUNTIME == docker ]] && echo docker.service)|g" "${DP_ROOT}/systemd/minio.service.tmpl")"
  printf '%s\n' "$unit" | sudo tee "/etc/systemd/system/${name}.service" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable "${name}.service" >/dev/null 2>&1
  sudo systemctl restart "${name}.service"   # picks up rotated credentials
  local i; for i in $(seq 1 30); do curl -fsS -o /dev/null "http://${addr}:${MINIO_PORT}/minio/health/live" && break; sleep 1; done
  dp_allow_bridge
  dp_ok "MinIO (native) on ${addr}:${MINIO_PORT}, console 127.0.0.1:${MINIO_CONSOLE_PORT}"
}

# Dedicated PHP-FPM pool for the app, running as the deploy user: PHP can read the
# releases in $HOME and write storage/ with no ACLs or chmod, like the CLI, Horizon and
# the scheduler. nginx reaches it through a socket owned by nginx's user. Older setups
# that pointed at a shared/panel pool are moved onto it.
dp_native_fpm_pool() {
  local v svc conf sock tmp fpm_bin web_user web_group u g backup=""
  v="$(dp_php_ver)"; [[ -n "$v" ]] || v="$(dp_php_default_ver)"
  dp_php_layout "$v"
  svc="$DP_FPM_SERVICE"; sock="$DP_FPM_SOCK"; conf="${DP_FPM_POOL_DIR}/dk-${PROJECT_SLUG}.conf"; fpm_bin="$DP_FPM_BIN"
  sudo test -x "$fpm_bin" || dp_die "PHP-FPM ${v} not found (${fpm_bin}). Install PHP-FPM or pick another PHP version: deploy/setup.sh components"
  dp_php_fpm_prepare
  u="$(id -un)"; g="$(id -gn)"
  web_user="$(sudo nginx -T 2>/dev/null | awk '$1 == "user" { sub(/;$/, "", $2); print $2; exit }' || true)"
  id "${web_user:-x}" >/dev/null 2>&1 || web_user="$(dp_os_web_user)"
  web_group="$(id -gn "$web_user")"
  tmp="$(mktemp)"
  printf '%s\n' \
    "; Managed by deploy-kit for ${PROJECT_SLUG}; changes are overwritten by setup.sh." \
    "[dk-${PROJECT_SLUG}]" \
    "user = ${u}" "group = ${g}" \
    "listen = ${sock}" "listen.owner = ${web_user}" "listen.group = ${web_group}" "listen.mode = 0660" \
    "pm = dynamic" "pm.max_children = ${FPM_MAX_CHILDREN:-10}" "pm.start_servers = 2" \
    "pm.min_spare_servers = 1" "pm.max_spare_servers = 4" "pm.max_requests = 500" >"$tmp"
  if ! sudo cmp -s "$tmp" "$conf"; then
    sudo test -f "$conf" && { backup="$(mktemp)"; sudo cat "$conf" >"$backup"; }
    sudo install -m 644 "$tmp" "$conf"
    # Never leave a broken pool behind: it would stop PHP for every site on the host.
    if ! sudo "$fpm_bin" -t >/dev/null 2>&1; then
      if [[ -n "$backup" ]]; then sudo install -m 644 "$backup" "$conf"; else sudo rm -f "$conf"; fi
      rm -f "$tmp" "$backup"
      dp_die "PHP-FPM rejected the pool for ${PROJECT_SLUG}; see: sudo ${fpm_bin} -t"
    fi
    if systemctl is-active --quiet "$svc"; then sudo systemctl reload "$svc"; else sudo systemctl enable --now "$svc"; fi
  fi
  rm -f "$tmp" "$backup"
  local i; for i in $(seq 1 15); do sudo test -S "$sock" && break; sleep 1; done
  sudo test -S "$sock" || dp_die "PHP-FPM pool socket ${sock} did not appear; see: journalctl -u ${svc}"
  PHP_VERSION="$v"; FPM_SERVICE="$svc"; FPM_SOCK="$sock"
  dp_state_set PHP_VERSION "$v"; dp_state_set FPM_SERVICE "$svc"; dp_state_set FPM_SOCK "$sock"
  dp_ok "PHP-FPM pool dk-${PROJECT_SLUG} (PHP ${v}, user ${u}) on ${sock}"
  dp_native_sudoers
}

# The one root action a routine deploy needs: reloading PHP-FPM (clears OPcache).
# Allow exactly that command without a password so CI deploys never prompt.
dp_native_sudoers() {
  [[ -n "${FPM_SERVICE:-}" ]] || return 0
  local u f tmp ctl
  u="$(id -un)"; f="/etc/sudoers.d/dk-${PROJECT_SLUG}"
  [[ "$u" == root ]] && return 0
  ctl="$(command -v systemctl)"
  tmp="$(mktemp)"
  printf '# Managed by deploy-kit for %s: lets deploys (incl. CI) reload PHP-FPM.\n%s ALL=(root) NOPASSWD: %s reload %s\n' \
    "$PROJECT_SLUG" "$u" "$ctl" "$FPM_SERVICE" >"$tmp"
  if ! sudo cmp -s "$tmp" "$f"; then
    # Validate first: a broken sudoers file can lock sudo out entirely.
    if sudo visudo -cqf "$tmp"; then
      sudo install -m 440 -o root -g root "$tmp" "$f"
      dp_ok "sudoers: ${u} may run '${ctl##*/} reload ${FPM_SERVICE}' without a password (${f})"
    else
      dp_warn "Could not validate the sudoers rule; PHP-FPM reloads from CI will be skipped."
    fi
  fi
  rm -f "$tmp"
}

# PHP-FPM + Composer (+ Node when a frontend is deployed) for RUNTIME=native.
dp_native_app_prereqs() {
  local pkgs=() php_bin v mods m p db_mod
  # Versioned packages (php8.4-redis) when the pool pins a version, else the distro default.
  [[ -n "$(dp_php_ver)" ]] || PHP_VERSION="$(dp_php_default_ver)"
  v="$(dp_php_ver)"
  db_mod="pdo_$([[ $DB_ENGINE == mysql ]] && echo mysql || echo pgsql)"
  php_bin="$(dp_php_bin || true)"
  # Laravel + Horizon needs: DB driver, redis, and the usual extensions (pcntl/posix for workers).
  # openssl..iconv are built in on most distros; openSUSE packages them separately.
  local need=(cli fpm "$db_mod" redis mbstring dom xml curl zip bcmath intl gd pcntl posix sodium openssl phar tokenizer ctype fileinfo iconv)
  if [[ -z "$php_bin" ]]; then
    dp_php_repo_enable "$v"
    [[ "$(dp_os)" == rhel ]] && dp_os_epel   # php-pecl-redis / zip live in EPEL or Remi
    for m in "${need[@]}"; do for p in $(dp_php_ext_pkgs "$v" "$m"); do [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p"); done; done
  else
    # Only add what is missing: panels (CloudPanel) ship their own PHP builds whose
    # files clash with the distro's extension packages.
    mods="$("$php_bin" -m 2>/dev/null | tr 'A-Z' 'a-z')"
    for m in "${need[@]}"; do
      [[ "$m" == cli || "$m" == fpm || "$m" == xml ]] && continue
      grep -qx "$m" <<<"$mods" && continue
      for p in $(dp_php_ext_pkgs "$v" "$m"); do [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p"); done
    done
    dp_php_layout "$v"; sudo test -x "$DP_FPM_BIN" || pkgs+=($(dp_php_ext_pkgs "$v" fpm))
  fi
  command -v unzip >/dev/null 2>&1 || pkgs+=(unzip)
  (( ${#pkgs[@]} )) && dp_pkg_install "${pkgs[@]}"
  # Bundled extensions some distros (Arch) leave commented out in php.ini.
  # igbinary first: Arch's redis extension is built against it.
  dp_php_enable_ext igbinary "${need[@]:2}" pdo_pgsql pgsql pdo_mysql mysqli iconv
  php_bin="$(dp_php_bin || true)"
  if [[ -n "$php_bin" ]]; then
    mods="$("$php_bin" -m 2>/dev/null | tr 'A-Z' 'a-z')"
    local miss=(); for m in "$db_mod" redis mbstring dom curl zip bcmath intl pcntl; do grep -qx "$m" <<<"$mods" || miss+=("$m"); done
    (( ${#miss[@]} )) && dp_warn "PHP is missing extension(s): ${miss[*]}. Install them for $(dp_os_name), then re-run: deploy/setup.sh services"
  fi
  dp_selinux_prepare
  dp_native_fpm_pool
  if ! command -v composer >/dev/null 2>&1; then
    dp_yes "Composer is missing. Install it to /usr/local/bin/composer?" y || dp_die "composer is required for RUNTIME=native"
    curl -fsSL https://getcomposer.org/installer | "${php_bin:-php}" -- --quiet --install-dir=/tmp --filename=composer
    sudo mv /tmp/composer /usr/local/bin/composer
  fi
  if dp_fe_on && ! command -v node >/dev/null 2>&1; then
    # NODE_VERSION from setup (defaults to the repo's .nvmrc / .node-version, else 22 LTS).
    local nv="${NODE_VERSION:-}"
    [[ -n "$nv" ]] || nv="$(cat "${REPO_ROOT}/.nvmrc" "${REPO_ROOT}/.node-version" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    nv="${nv:-22}"
    dp_yes "Node.js is missing. Install Node ${nv}?" y || dp_die "node is required for the frontend"
    dp_os_install_node "$nv"
  fi
  return 0
}
