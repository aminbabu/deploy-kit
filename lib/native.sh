#!/usr/bin/env bash
# Native (non-Docker) installs on this host: PostgreSQL, MariaDB, Redis, MinIO, and the
# PHP-FPM / Composer / Node toolchain for RUNTIME=native. Distro packages via apt/dnf
# (asked first); MinIO from dl.min.io. When the app runs in Docker, native services
# also listen on the project network's gateway so containers can reach them.

# Start <unit> after Docker so the gateway address exists when it binds.
dp_after_docker() {
  [[ "$RUNTIME" == docker ]] || return 0
  local dir="/etc/systemd/system/${1}.service.d"
  sudo mkdir -p "$dir"
  printf '[Unit]\nAfter=docker.service\nWants=docker.service\n' | sudo tee "${dir}/10-after-docker.conf" >/dev/null
  sudo systemctl daemon-reload
}

# Let containers reach native services through an active ufw.
dp_allow_bridge() {
  [[ "$RUNTIME" == docker ]] || return 0
  command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  sudo ufw allow from "$(dp_bridge_subnet)" to "$(dp_bridge_ip)" comment "${PROJECT_SLUG} containers" >/dev/null
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
  if command -v psql >/dev/null 2>&1 && systemctl cat postgresql >/dev/null 2>&1; then
    local have; have="$(psql --version | grep -oE '[0-9]+' | head -1)"
    [[ -z "${DB_VERSION:-}" || "$have" == "${DB_VERSION%%.*}" ]] \
      || dp_warn "PostgreSQL ${have} is already installed; using it (DB_VERSION=${DB_VERSION} needs a manual upgrade)."
  elif [[ -n "${DB_VERSION:-}" ]]; then
    # The distro ships one major; others come from the PostgreSQL project's apt repo (PGDG).
    apt-cache show "postgresql-${DB_VERSION}" >/dev/null 2>&1 || dp_pgdg_repo
    dp_pkg_install "postgresql-${DB_VERSION}"   # contrib modules ship inside it (PG 10+)
  else
    dp_pkg_install postgresql postgresql-contrib
  fi
  sudo systemctl enable --now postgresql >/dev/null 2>&1 || true
  local listen="localhost" hba line reload=0
  if [[ "$RUNTIME" == docker ]]; then
    listen="localhost,$(dp_bridge_ip)"
    hba="$(_dp_pg_admin -tAc 'SHOW hba_file' </dev/null)"
    line="host all all $(dp_bridge_subnet) scram-sha-256"
    sudo grep -qxF "$line" "$hba" || { echo "$line" | sudo tee -a "$hba" >/dev/null; reload=1; }
    dp_after_docker postgresql
  fi
  if [[ "$(_dp_pg_admin -tAc 'SHOW listen_addresses' </dev/null)" != "$listen" ]]; then
    _dp_pg_admin -c "ALTER SYSTEM SET listen_addresses = '${listen}'" </dev/null
    sudo systemctl restart postgresql
  elif (( reload )); then
    _dp_pg_admin -c 'SELECT pg_reload_conf()' </dev/null >/dev/null
  fi
  dp_allow_bridge
  dp_ok "PostgreSQL (native) listening on ${listen}:5432"
}

dp_pgdg_repo() {
  command -v apt-get >/dev/null 2>&1 || dp_die "PostgreSQL ${DB_VERSION}: install it yourself (no apt here), then re-run."
  dp_info "Adding the PostgreSQL apt repository (apt.postgresql.org) for PostgreSQL ${DB_VERSION}"
  local codename; codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || dp_die "Cannot read the distro codename from /etc/os-release"
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

dp_native_mariadb() {
  command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || dp_pkg_install mariadb-server
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
  command -v redis-server >/dev/null 2>&1 || dp_pkg_install redis-server
  local conf=/etc/redis/redis.conf svc=redis-server before bind="127.0.0.1 -::1" pw
  sudo test -f "$conf" || conf=/etc/redis.conf
  systemctl cat redis-server >/dev/null 2>&1 || svc=redis
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
  dp_ok "Redis (native) listening on ${bind}:6379"
}

dp_native_minio() {
  local arch name="${PROJECT_SLUG}-minio" bin dir data envf unit addr
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) dp_die "MinIO: unsupported CPU $(uname -m)" ;; esac
  dir="/usr/local/lib/${name}"; bin="${dir}/minio"; data="/var/lib/${name}"; envf="/etc/default/${name}"
  sudo mkdir -p "$dir"
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
  svc="php${v}-fpm"; sock="/run/php/php${v}-${PROJECT_SLUG}-fpm.sock"
  conf="/etc/php/${v}/fpm/pool.d/dk-${PROJECT_SLUG}.conf"
  fpm_bin="$(command -v "php-fpm${v}" || echo "/usr/sbin/php-fpm${v}")"
  sudo test -x "$fpm_bin" || dp_die "PHP-FPM ${v} not found (${fpm_bin}). Install php${v}-fpm or pick another PHP version: deploy/setup.sh components"
  u="$(id -un)"; g="$(id -gn)"
  web_user="$(sudo nginx -T 2>/dev/null | awk '$1 == "user" { sub(/;$/, "", $2); print $2; exit }' || true)"
  id "${web_user:-x}" >/dev/null 2>&1 || web_user=www-data
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
  local pkgs=() db_ext php_bin p
  # Versioned names (php8.4-redis) when the pool pins a version, else the distro default.
  [[ -n "$(dp_php_ver)" ]] || PHP_VERSION="$(dp_php_default_ver)"
  p="php$(dp_php_ver)-"
  db_ext="${p}$([[ $DB_ENGINE == mysql ]] && echo mysql || echo pgsql)"
  php_bin="$(dp_php_bin || true)"
  if [[ -z "$php_bin" ]]; then
    pkgs+=("${p}fpm" "${p}cli" "$db_ext" "${p}redis" "${p}mbstring" "${p}xml" "${p}curl" "${p}zip" "${p}bcmath" "${p}intl" "${p}gd")
  else
    # Only add what is missing: panels (CloudPanel) ship their own PHP builds whose
    # files clash with the distro's extension packages.
    local mods ext pkg
    mods="$("$php_bin" -m 2>/dev/null | tr 'A-Z' 'a-z')"
    for ext in "pdo_${db_ext##*-}:${db_ext}" redis:redis mbstring:mbstring dom:xml curl:curl \
      zip:zip bcmath:bcmath intl:intl gd:gd; do
      pkg="${ext#*:}"; ext="${ext%%:*}"; [[ "$pkg" == "$db_ext" ]] || pkg="${p}${pkg}"
      grep -qx "$ext" <<<"$mods" || pkgs+=("$pkg")
    done
    command -v "php-fpm$(dp_php_ver)" >/dev/null 2>&1 || [[ -x "/usr/sbin/php-fpm$(dp_php_ver)" ]] || pkgs+=("${p}fpm")
  fi
  command -v unzip >/dev/null 2>&1 || pkgs+=(unzip)
  (( ${#pkgs[@]} )) && dp_pkg_install "${pkgs[@]}"
  dp_native_fpm_pool
  if ! command -v composer >/dev/null 2>&1; then
    dp_yes "Composer is missing. Install it to /usr/local/bin/composer?" y || dp_die "composer is required for RUNTIME=native"
    curl -fsSL https://getcomposer.org/installer | php -- --quiet --install-dir=/tmp --filename=composer
    sudo mv /tmp/composer /usr/local/bin/composer
  fi
  if dp_fe_on && ! command -v node >/dev/null 2>&1; then
    # NODE_VERSION from setup (defaults to the repo's .nvmrc / .node-version, else 22 LTS).
    local nv="${NODE_VERSION:-}"
    [[ -n "$nv" ]] || nv="$(cat "${REPO_ROOT}/.nvmrc" "${REPO_ROOT}/.node-version" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    nv="${nv:-22}"
    dp_yes "Node.js is missing. Install Node ${nv} from NodeSource?" y || dp_die "node is required for the frontend"
    curl -fsSL "https://deb.nodesource.com/setup_${nv}.x" | sudo -E bash -
    dp_pkg_install nodejs
  fi
  return 0
}
