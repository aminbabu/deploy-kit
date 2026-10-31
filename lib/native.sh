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
  command -v psql >/dev/null 2>&1 && systemctl cat postgresql >/dev/null 2>&1 || dp_pkg_install postgresql postgresql-contrib
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
  [[ -f "$conf" ]] || conf=/etc/redis.conf
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

# PHP-FPM + Composer (+ Node when a frontend is deployed) for RUNTIME=native.
dp_native_app_prereqs() {
  local pkgs=() db_ext
  db_ext="$([[ $DB_ENGINE == mysql ]] && echo php-mysql || echo php-pgsql)"
  if ! command -v php >/dev/null 2>&1 || ! compgen -G '/run/php/php*-fpm.sock' >/dev/null; then
    pkgs+=(php-fpm php-cli "$db_ext" php-redis php-mbstring php-xml php-curl php-zip php-bcmath php-intl php-gd unzip)
  elif ! php -m 2>/dev/null | grep -qi "$([[ $DB_ENGINE == mysql ]] && echo pdo_mysql || echo pdo_pgsql)"; then
    pkgs+=("$db_ext")
  fi
  (( ${#pkgs[@]} )) && dp_pkg_install "${pkgs[@]}"
  if ! command -v composer >/dev/null 2>&1; then
    dp_yes "Composer is missing. Install it to /usr/local/bin/composer?" y || dp_die "composer is required for RUNTIME=native"
    curl -fsSL https://getcomposer.org/installer | php -- --quiet --install-dir=/tmp --filename=composer
    sudo mv /tmp/composer /usr/local/bin/composer
  fi
  if dp_fe_on && ! command -v node >/dev/null 2>&1; then
    dp_yes "Node.js is missing. Install Node 22 LTS from NodeSource?" y || dp_die "node is required for the frontend"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    dp_pkg_install nodejs
  fi
  return 0
}
