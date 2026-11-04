#!/usr/bin/env bash
# Operating-system layer: everything that differs between Linux distributions.
# OS_FAMILY is asked in setup (default: detected from /etc/os-release) and saved in project.env.
#   debian  Debian, Ubuntu and derivatives                                     (apt)
#   rhel    RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Fedora, Amazon Linux (dnf)
#   suse    openSUSE Leap / Tumbleweed, SLES                                   (zypper)
#   arch    Arch Linux, Manjaro                                                (pacman)
# Every family needs systemd.

DP_OS_FAMILIES=(debian rhel suse arch)

_dp_os_field() { (. /etc/os-release 2>/dev/null && eval "printf '%s' \"\${$1:-}\""); }

dp_os_detect() {
  local ids
  ids=" $(_dp_os_field ID) $(_dp_os_field ID_LIKE) "
  case "$ids" in
    *" debian "* | *" ubuntu "*) echo debian; return ;;
    *" rhel "* | *" fedora "* | *" centos "* | *" amzn "*) echo rhel; return ;;
    *" suse "* | *" opensuse"* | *" sles "* | *" sle "*) echo suse; return ;;
    *" arch "* | *" manjaro "*) echo arch; return ;;
  esac
  if command -v apt-get >/dev/null 2>&1; then echo debian
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then echo rhel
  elif command -v zypper >/dev/null 2>&1; then echo suse
  elif command -v pacman >/dev/null 2>&1; then echo arch
  else echo debian; fi
}
dp_os() { echo "${OS_FAMILY:-$(dp_os_detect)}"; }

# Setup question; the detected family is the default (Enter keeps it).
dp_ask_os() {
  local det; det="$(dp_os_detect)"
  dp_choose OS_FAMILY "Server OS: debian = Debian/Ubuntu (apt); rhel = RHEL/Rocky/Alma/CentOS/Oracle/Fedora/Amazon (dnf); suse = openSUSE/SLES (zypper); arch = Arch/Manjaro (pacman)" \
    "$det" "${DP_OS_FAMILIES[@]}"
  [[ "$OS_FAMILY" == "$det" ]] || dp_warn "This server looks like '${det}' ($(dp_os_name)); package names and paths will follow '${OS_FAMILY}' as chosen."
  command -v systemctl >/dev/null 2>&1 || dp_die "systemd is required (services, timers and user units); $(dp_os_name) does not run it."
  dp_ok "OS: $(dp_os_name) (${OS_FAMILY})"
}
dp_os_name() { _dp_os_field PRETTY_NAME; }
dp_os_is_fedora() { [[ "$(_dp_os_field ID)" == fedora ]]; }
dp_os_is_ubuntu() { [[ " $(_dp_os_field ID) $(_dp_os_field ID_LIKE) " == *" ubuntu "* ]]; }
# Major release of an Enterprise Linux clone (8, 9, 10); empty on Fedora/Amazon.
dp_os_el() {
  dp_os_is_fedora && return 0
  [[ "$(_dp_os_field ID)" == amzn ]] && return 0
  _dp_os_field VERSION_ID | cut -d. -f1
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
_dp_dnf() { command -v dnf >/dev/null 2>&1 && echo dnf || echo yum; }

dp_pkg_install() {
  local pkgs=("$@")
  (( ${#pkgs[@]} )) || return 0
  if [[ "${DP_ASSUME_INSTALL:-0}" != "1" ]] && ! dp_yes "Install missing package(s): ${pkgs[*]}?" y; then
    dp_die "Required package(s) missing: ${pkgs[*]}"
  fi
  case "$(dp_os)" in
    debian)
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" ;;
    rhel) sudo "$(_dp_dnf)" install -y -q "${pkgs[@]}" ;;
    suse) sudo zypper --non-interactive --quiet install --no-recommends "${pkgs[@]}" ;;
    arch) sudo pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    *) dp_die "Unknown OS family '$(dp_os)'; install manually: ${pkgs[*]}" ;;
  esac
}

# Is a package installable from the configured repositories?
dp_pkg_available() {
  case "$(dp_os)" in
    debian) apt-cache show "$1" >/dev/null 2>&1 ;;
    rhel) "$(_dp_dnf)" -q info "$1" >/dev/null 2>&1 ;;
    suse) zypper --non-interactive -q search -x "$1" >/dev/null 2>&1 ;;
    arch) pacman -Si "$1" >/dev/null 2>&1 ;;
  esac
}

# First installable name from a list (packages renamed between releases, e.g. redis → valkey).
dp_pkg_first() { local p; for p in "$@"; do dp_pkg_available "$p" && { echo "$p"; return 0; }; done; return 1; }

# Package(s) providing a tool or service, by family. $1 = logical name.
dp_pkg_name() {
  local f; f="$(dp_os)"
  case "$1" in
    envsubst) case "$f" in debian) echo gettext-base ;; suse) echo gettext-runtime ;; *) echo gettext ;; esac ;;
    flock) echo util-linux ;;
    awk) echo gawk ;;
    ssh-keygen) case "$f" in debian) echo openssh-client ;; arch) echo openssh ;; *) echo openssh-clients ;; esac ;;
    certbot) case "$f" in suse) dp_pkg_first certbot python3-certbot || echo certbot ;; *) echo certbot ;; esac ;;
    mariadb) case "$f" in suse | arch) echo mariadb ;; *) echo mariadb-server ;; esac ;;
    redis) case "$f" in debian) echo redis-server ;; arch) echo valkey ;; *) dp_pkg_first redis valkey || echo redis ;; esac ;;
    firewall) case "$f" in rhel | suse) echo firewalld ;; *) echo ufw ;; esac ;;
    selinux-tools) echo policycoreutils-python-utils ;;
    *) echo "$1" ;;
  esac
}

# EPEL (certbot, extra PHP extensions) on Enterprise Linux clones; Fedora needs none.
dp_os_epel() {
  [[ "$(dp_os)" == rhel ]] || return 0
  local el; el="$(dp_os_el)"; [[ -n "$el" ]] || return 0
  rpm -q epel-release >/dev/null 2>&1 && return 0
  dp_info "Enabling EPEL (Extra Packages for Enterprise Linux ${el})"
  sudo "$(_dp_dnf)" install -y -q epel-release 2>/dev/null \
    || sudo "$(_dp_dnf)" install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${el}.noarch.rpm"
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
dp_os_install_docker() {
  case "$(dp_os)" in
    debian) curl -fsSL https://get.docker.com | sudo sh ;;
    rhel)
      if [[ "$(_dp_os_field ID)" == amzn ]]; then
        sudo dnf install -y -q docker
      else
        local repo="https://download.docker.com/linux/$(dp_os_is_fedora && echo fedora || echo centos)/docker-ce.repo"
        sudo "$(_dp_dnf)" install -y -q dnf-plugins-core 2>/dev/null || true
        # dnf4 and dnf5 spell "add a repo" differently.
        sudo dnf config-manager --add-repo "$repo" 2>/dev/null || sudo dnf config-manager addrepo --from-repofile="$repo"
        sudo dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      fi ;;
    suse) sudo zypper --non-interactive --quiet install docker docker-compose ;;
    arch) sudo pacman -S --needed --noconfirm docker docker-compose ;;
  esac
  sudo systemctl enable --now docker >/dev/null 2>&1 || true
  # Distros without the compose v2 plugin package: install the plugin binary.
  if ! sudo docker compose version >/dev/null 2>&1; then
    local arch; case "$(uname -m)" in x86_64) arch=x86_64 ;; aarch64 | arm64) arch=aarch64 ;; *) dp_die "docker compose: unsupported CPU $(uname -m)" ;; esac
    dp_info "Installing the docker compose plugin"
    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    sudo curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
      "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
    sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
}

# ---------------------------------------------------------------------------
# Node.js
# ---------------------------------------------------------------------------
dp_os_install_node() { # major
  local nv="$1"
  case "$(dp_os)" in
    debian) curl -fsSL "https://deb.nodesource.com/setup_${nv}.x" | sudo -E bash - ; dp_pkg_install nodejs ;;
    rhel) curl -fsSL "https://rpm.nodesource.com/setup_${nv}.x" | sudo -E bash - ; dp_pkg_install nodejs ;;
    suse) dp_pkg_install "$(dp_pkg_first "nodejs${nv}" nodejs-default nodejs || echo "nodejs${nv}")" ;;
    arch)
      # Arch ships the current Node only (nodejs) or the LTS line (nodejs-lts-*).
      dp_pkg_install nodejs npm
      [[ "$(node -v 2>/dev/null | tr -d v | cut -d. -f1)" == "$nv" ]] || dp_warn "Arch installed Node $(node -v 2>/dev/null); Node ${nv} was asked for (use nvm for an exact version)."
      command -v corepack >/dev/null 2>&1 || dp_pkg_install corepack 2>/dev/null || true ;;
  esac
}

# ---------------------------------------------------------------------------
# PHP
# ---------------------------------------------------------------------------
# Paths of PHP-FPM for version $1 on this family. Sets DP_FPM_SERVICE, DP_FPM_BIN,
# DP_FPM_POOL_DIR, DP_FPM_SOCK (for the project's pool) and DP_PHP_CLI.
dp_php_layout() {
  local v="$1" slug="${PROJECT_SLUG:-app}"
  case "$(dp_os)" in
    debian)
      DP_FPM_SERVICE="php${v}-fpm"; DP_FPM_POOL_DIR="/etc/php/${v}/fpm/pool.d"
      DP_FPM_BIN="$(command -v "php-fpm${v}" || echo "/usr/sbin/php-fpm${v}")"
      DP_FPM_SOCK="/run/php/php${v}-${slug}-fpm.sock"; DP_PHP_CLI="php${v}" ;;
    rhel)
      DP_FPM_SERVICE="php-fpm"; DP_FPM_POOL_DIR="/etc/php-fpm.d"; DP_FPM_BIN="/usr/sbin/php-fpm"
      DP_FPM_SOCK="/run/php-fpm/dk-${slug}.sock"; DP_PHP_CLI="php" ;;
    suse)
      DP_FPM_SERVICE="php-fpm"; DP_FPM_POOL_DIR="/etc/php${v%%.*}/fpm/php-fpm.d"; DP_FPM_BIN="/usr/sbin/php-fpm"
      DP_FPM_SOCK="/run/php-fpm-dk-${slug}.sock"; DP_PHP_CLI="php" ;;
    arch)
      DP_FPM_SERVICE="php-fpm"; DP_FPM_POOL_DIR="/etc/php/php-fpm.d"; DP_FPM_BIN="/usr/bin/php-fpm"
      DP_FPM_SOCK="/run/php-fpm/dk-${slug}.sock"; DP_PHP_CLI="php" ;;
  esac
}

# major.minor of the PHP the distro (or an enabled repo) would install.
dp_php_repo_ver() {
  local v=""
  case "$(dp_os)" in
    debian) v="$(apt-cache depends php-fpm 2>/dev/null | grep -oE 'php[0-9]+\.[0-9]+-fpm' | head -1 | sed -E 's/^php|-fpm$//g' || true)" ;;
    rhel) v="$("$(_dp_dnf)" -q info php-cli 2>/dev/null | awk -F': *' '/^Version/ { print $2; exit }' || true)" ;;
    suse) v="$(zypper --non-interactive -q info php8 2>/dev/null | awk -F': *' '/^Version/ { print $2; exit }' || true)" ;;
    arch) v="$(pacman -Si php 2>/dev/null | awk -F': *' '/^Version/ { print $2; exit }' || true)" ;;
  esac
  grep -oE '^[0-9]+\.[0-9]+' <<<"$v" || true
}

# Make PHP <ver> installable where the distro ships another version:
# Ubuntu → ondrej/php PPA, Debian → packages.sury.org, EL 8/9 → Remi module stream.
dp_php_repo_enable() {
  local v="$1"
  case "$(dp_os)" in
    debian)
      dp_pkg_available "php${v}-fpm" && return 0
      dp_yes "PHP ${v} is not in this distro's repositories. Add $(dp_os_is_ubuntu && echo "the ondrej/php PPA" || echo "packages.sury.org") for it?" y \
        || dp_die "PHP ${v} unavailable; pick another version: deploy/setup.sh components"
      if dp_os_is_ubuntu; then
        dp_pkg_install software-properties-common
        sudo add-apt-repository -y ppa:ondrej/php >/dev/null
      else
        dp_pkg_install ca-certificates curl gnupg
        sudo curl -fsSL -o /usr/share/keyrings/sury-php.gpg https://packages.sury.org/php/apt.gpg
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(_dp_os_field VERSION_CODENAME) main" \
          | sudo tee /etc/apt/sources.list.d/sury-php.list >/dev/null
      fi
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
    rhel)
      [[ "$(dp_php_repo_ver)" == "$v" ]] && return 0
      local el; el="$(dp_os_el)"
      if [[ "$el" == 8 || "$el" == 9 ]]; then
        dp_yes "PHP ${v} is not the default here. Enable the Remi repository (php:remi-${v} module)?" y \
          || dp_die "PHP ${v} unavailable; pick $(dp_php_repo_ver) instead: deploy/setup.sh components"
        dp_os_epel
        rpm -q remi-release >/dev/null 2>&1 || sudo dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${el}.rpm"
        sudo dnf module reset -y -q php >/dev/null
        sudo dnf module enable -y -q "php:remi-${v}" >/dev/null
      else
        dp_warn "PHP ${v} was asked for, but this release ships PHP $(dp_php_repo_ver) and has no supported module repo; using that."
      fi ;;
    suse | arch)
      local have; have="$(dp_php_repo_ver)"
      [[ -z "$have" || "$have" == "$v" ]] || dp_warn "$(dp_os_name) ships PHP ${have}; PHP ${v} was asked for. Using ${have}."
      ;;
  esac
}

# Packages for PHP extension module $2 (as named by `php -m`) at version $1.
dp_php_ext_pkgs() {
  local v="$1" m="$2"
  case "$(dp_os)" in
    debian)
      case "$m" in
        fpm | cli | pgsql | mysql | redis | mbstring | xml | curl | zip | bcmath | intl | gd) echo "php${v}-${m}" ;;
        pdo_pgsql) echo "php${v}-pgsql" ;; pdo_mysql) echo "php${v}-mysql" ;; dom) echo "php${v}-xml" ;;
        *) ;; # pcntl, posix, sodium, tokenizer: built into php-cli
      esac ;;
    rhel)
      case "$m" in
        fpm | cli | mbstring | xml | bcmath | intl | gd | opcache | sodium) echo "php-${m}" ;;
        pdo_pgsql | pgsql) echo php-pgsql ;; pdo_mysql | mysql) echo php-mysqlnd ;; dom) echo php-xml ;;
        pcntl | posix) echo php-process ;; zip) dp_pkg_first php-pecl-zip php-zip || echo php-pecl-zip ;;
        redis) dp_pkg_first php-pecl-redis6 php-pecl-redis5 php-redis || echo php-pecl-redis5 ;;
        curl) echo php-common ;;
      esac ;;
    suse)
      local p="php${v%%.*}"
      case "$m" in
        cli) echo "${p}-cli" ;; pdo_pgsql) echo "${p}-pgsql" ;; pdo_mysql) echo "${p}-mysql" ;;
        xml) echo "${p}-xmlreader ${p}-xmlwriter" ;; dom) echo "${p}-dom" ;;
        *) echo "${p}-${m}" ;;
      esac ;;
    arch)
      case "$m" in
        cli) echo php ;; fpm) echo php-fpm ;; pdo_pgsql | pgsql) echo php-pgsql ;; redis) echo "php-igbinary php-redis" ;;
        intl) echo php-intl ;; gd) echo php-gd ;; sodium) echo php-sodium ;; igbinary) echo php-igbinary ;;
        *) ;; # bundled with php; enabled in php.ini by dp_php_enable_ext
      esac ;;
  esac
}

# Arch (and some builds) ship extensions commented out in php.ini / conf.d: enable them.
dp_php_enable_ext() {
  local m f
  for m in "$@"; do
    for f in /etc/php/php.ini /etc/php/conf.d/*.ini; do
      sudo test -f "$f" && sudo grep -qE "^;(zend_)?extension=${m}(\.so)?$" "$f" \
        && sudo sed -i -E "s/^;((zend_)?extension=${m}(\.so)?)$/\1/" "$f"
    done
  done
  return 0
}

# Family-specific FPM setup before the first pool is added (suse ships only *.default files).
dp_php_fpm_prepare() {
  case "$(dp_os)" in
    suse)
      local d="/etc/php${PHP_VERSION%%.*}/fpm"
      sudo test -f "${d}/php-fpm.conf" || { sudo test -f "${d}/php-fpm.conf.default" && sudo cp "${d}/php-fpm.conf.default" "${d}/php-fpm.conf"; }
      sudo mkdir -p "${d}/php-fpm.d" ;;
    *) sudo mkdir -p "$DP_FPM_POOL_DIR" ;;
  esac
  sudo mkdir -p "$(dirname "$DP_FPM_SOCK")"
}

# nginx's worker user when nginx.conf does not say.
dp_os_web_user() { case "$(dp_os)" in debian) echo www-data ;; arch) echo http ;; *) echo nginx ;; esac; }

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
# Debian/Ubuntu use sites-available + sites-enabled; the others load /etc/nginx/conf.d/*.conf.
dp_nginx_dirs() {
  if [[ "$(dp_os)" == debian ]]; then
    DP_NGINX_AVAIL="${DP_NGINX_AVAIL:-/etc/nginx/sites-available}"
    DP_NGINX_ENABLED="${DP_NGINX_ENABLED:-/etc/nginx/sites-enabled}"
  else
    DP_NGINX_AVAIL="${DP_NGINX_AVAIL:-/etc/nginx/conf.d}"
    DP_NGINX_ENABLED="${DP_NGINX_ENABLED:-/etc/nginx/conf.d}"
  fi
}

# Arch's stock nginx.conf includes no directory: add conf.d to the http block.
dp_nginx_include_confd() {
  local conf=/etc/nginx/nginx.conf
  sudo mkdir -p /etc/nginx/conf.d
  sudo test -f "$conf" || return 0
  sudo grep -qE '^\s*include\s+/etc/nginx/conf\.d/\*\.conf;' "$conf" && return 0
  sudo sed -i -E '0,/^\s*http\s*\{/s//&\n    include \/etc\/nginx\/conf.d\/*.conf;/' "$conf"
  dp_info "nginx.conf now includes /etc/nginx/conf.d/*.conf"
}

# ---------------------------------------------------------------------------
# PostgreSQL / MariaDB / Redis service layouts
# ---------------------------------------------------------------------------
# Install PostgreSQL <major> (empty = distro default). Sets DP_PG_SERVICE.
dp_os_install_pg() {
  local v="${1:-}" f; f="$(dp_os)"
  case "$f" in
    debian)
      if [[ -n "$v" ]]; then
        dp_pkg_available "postgresql-${v}" || _dp_pgdg_apt
        dp_pkg_install "postgresql-${v}"
      else dp_pkg_install postgresql postgresql-contrib; fi
      DP_PG_SERVICE=postgresql ;;
    rhel)
      if [[ -n "$v" && "$(_dp_pg_repo_major)" != "$v" ]] && { _dp_pgdg_rpm || true; dp_pkg_available "postgresql${v}-server"; }; then
        sudo dnf -qy module disable postgresql >/dev/null 2>&1 || true
        dp_pkg_install "postgresql${v}-server"
        dp_pkg_available "postgresql${v}-contrib" && dp_pkg_install "postgresql${v}-contrib"   # not built for every release/arch
        DP_PG_SERVICE="postgresql-${v}"
        sudo test -f "/var/lib/pgsql/${v}/data/PG_VERSION" || sudo "/usr/pgsql-${v}/bin/postgresql-${v}-setup" initdb
      else
        [[ -z "$v" || "$(_dp_pg_repo_major)" == "$v" ]] \
          || dp_warn "PostgreSQL ${v} has no package for $(dp_os_name) ($(uname -m)); installing the distro's PostgreSQL $(_dp_pg_repo_major) instead."
        dp_pkg_install postgresql-server postgresql-contrib
        DP_PG_SERVICE=postgresql
        sudo test -f /var/lib/pgsql/data/PG_VERSION || sudo postgresql-setup --initdb
      fi ;;
    suse)
      dp_pkg_install "postgresql${v}-server"
      dp_pkg_available "postgresql${v}-contrib" && dp_pkg_install "postgresql${v}-contrib"
      DP_PG_SERVICE=postgresql ;;
    arch)
      local cur; cur="$(pacman -Si postgresql 2>/dev/null | awk -F': *' '/^Version/ { split($2, a, "."); print a[1]; exit }')"
      [[ -z "$v" || -z "$cur" || "$cur" == "$v" ]] || dp_warn "Arch ships PostgreSQL ${cur} only; PostgreSQL ${v} was asked for. Installing ${cur}."
      dp_pkg_install postgresql
      DP_PG_SERVICE=postgresql
      sudo test -f /var/lib/postgres/data/PG_VERSION || sudo -u postgres initdb --locale=C.UTF-8 -E UTF8 -D /var/lib/postgres/data >/dev/null ;;
  esac
}
_dp_pg_repo_major() { "$(_dp_dnf)" -q info postgresql-server 2>/dev/null | awk -F': *' '/^Version/ { split($2, a, "."); print a[1]; exit }' || true; }

# Service name of an installed PostgreSQL (versioned on PGDG RPM installs).
dp_pg_service() {
  local u
  [[ -n "${DP_PG_SERVICE:-}" ]] && { echo "$DP_PG_SERVICE"; return; }
  for u in postgresql "postgresql-${DB_VERSION:-x}" $(systemctl list-unit-files 'postgresql-*.service' --no-legend 2>/dev/null | awk '{ sub(/\.service$/, "", $1); print $1 }'); do
    systemctl cat "$u" >/dev/null 2>&1 && { echo "$u"; return; }
  done
  echo postgresql
}

_dp_pgdg_apt() {
  dp_info "Adding the PostgreSQL apt repository (apt.postgresql.org) for PostgreSQL ${DB_VERSION}"
  local codename; codename="$(_dp_os_field VERSION_CODENAME)"
  [[ -n "$codename" ]] || dp_die "Cannot read the distro codename from /etc/os-release"
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

_dp_pgdg_rpm() {
  rpm -qa 2>/dev/null | grep -q '^pgdg-.*-repo' && return 0
  local base="https://download.postgresql.org/pub/repos/yum/reporpms" url
  if dp_os_is_fedora; then url="${base}/F-$(_dp_os_field VERSION_ID)-$(uname -m)/pgdg-fedora-repo-latest.noarch.rpm"
  else url="${base}/EL-$(dp_os_el)-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm"; fi
  dp_info "Adding the PostgreSQL yum repository (download.postgresql.org) for PostgreSQL ${DB_VERSION}"
  sudo dnf install -y -q "$url" 2>/dev/null || { dp_warn "No PostgreSQL repository for this release/CPU (${url})."; return 1; }
}

# Password logins over TCP: RHEL/Fedora/openSUSE default to "ident" and Arch to "trust" for
# 127.0.0.1, which an app user cannot pass (or which skips the password). The first match wins.
dp_pg_hba_scram() {
  [[ "$(dp_os)" == debian ]] && return 0
  local hba line changed=0 tmp
  hba="$(_dp_pg_admin -tAc 'SHOW hba_file' </dev/null)"
  tmp="$(mktemp)"
  for line in "host all all ::1/128 scram-sha-256" "host all all 127.0.0.1/32 scram-sha-256"; do
    sudo grep -qxF "$line" "$hba" && continue
    { echo "$line"; sudo cat "$hba"; } >"$tmp" && sudo tee "$hba" <"$tmp" >/dev/null; changed=1
  done
  rm -f "$tmp"
  (( changed )) && _dp_pg_admin -c 'SELECT pg_reload_conf()' </dev/null >/dev/null
  return 0
}

# MariaDB: Arch leaves the data directory uninitialised.
dp_os_mariadb_init() {
  [[ "$(dp_os)" == arch ]] || return 0
  sudo test -d /var/lib/mysql/mysql || sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null
}

# Redis or Valkey on this host. Sets DP_REDIS_SERVICE and DP_REDIS_CONF.
dp_redis_layout() {
  local u
  for u in redis-server redis valkey "redis@default"; do
    systemctl cat "$u" >/dev/null 2>&1 || continue
    DP_REDIS_SERVICE="$u"; break
  done
  DP_REDIS_SERVICE="${DP_REDIS_SERVICE:-$([[ "$(dp_os)" == debian ]] && echo redis-server || echo redis)}"
  case "$DP_REDIS_SERVICE" in
    valkey) DP_REDIS_CONF=/etc/valkey/valkey.conf ;;
    redis@default)
      DP_REDIS_CONF=/etc/redis/default.conf
      # openSUSE runs named instances from /etc/redis/<name>.conf (only an example ships).
      if ! sudo test -f "$DP_REDIS_CONF" && sudo test -f /etc/redis/default.conf.example; then
        sudo cp /etc/redis/default.conf.example "$DP_REDIS_CONF"; sudo chown root:redis "$DP_REDIS_CONF"; sudo chmod 640 "$DP_REDIS_CONF"
      fi ;;
    *) DP_REDIS_CONF=/etc/redis/redis.conf; sudo test -f "$DP_REDIS_CONF" || DP_REDIS_CONF=/etc/redis.conf ;;
  esac
}
dp_redis_server_bin() { command -v redis-server || command -v valkey-server || true; }

# ---------------------------------------------------------------------------
# Firewall (ufw or firewalld, whichever is active)
# ---------------------------------------------------------------------------
dp_fw_active() {
  if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
  elif systemctl is-active --quiet firewalld 2>/dev/null; then echo firewalld
  else echo none; fi
}

dp_fw_allow_ports() { # port...
  local p fw; fw="$(dp_fw_active)"
  case "$fw" in
    ufw) for p in "$@"; do sudo ufw allow "${p}/tcp" >/dev/null; done ;;
    firewalld)
      for p in "$@"; do sudo firewall-cmd -q --permanent --add-port="${p}/tcp"; done
      sudo firewall-cmd -q --reload ;;
  esac
  return 0
}

dp_fw_allow_ssh() {
  case "$(dp_fw_active)" in
    ufw) sudo ufw allow OpenSSH >/dev/null 2>&1 || sudo ufw allow 22/tcp >/dev/null ;;
    firewalld) sudo firewall-cmd -q --permanent --add-service=ssh && sudo firewall-cmd -q --reload ;;
  esac
  return 0
}

# Containers (Docker bridge subnet $1, gateway $2) reaching natively installed services.
dp_fw_allow_bridge() {
  case "$(dp_fw_active)" in
    ufw) sudo ufw allow from "$1" to "$2" comment "${PROJECT_SLUG} containers" >/dev/null ;;
    firewalld) sudo firewall-cmd -q --permanent --zone=trusted --add-source="$1" && sudo firewall-cmd -q --reload ;;
  esac
  return 0
}

# Enable the family's usual firewall with only SSH open (callers open web ports next).
dp_fw_enable() {
  if [[ "$(dp_pkg_name firewall)" == ufw ]]; then
    command -v ufw >/dev/null 2>&1 || dp_pkg_install ufw
    sudo ufw allow OpenSSH >/dev/null 2>&1 || sudo ufw allow 22/tcp >/dev/null
    sudo ufw --force enable >/dev/null
  else
    command -v firewall-cmd >/dev/null 2>&1 || dp_pkg_install firewalld
    sudo systemctl enable --now firewalld >/dev/null
    dp_fw_allow_ssh
  fi
}

# ---------------------------------------------------------------------------
# Automatic security updates
# ---------------------------------------------------------------------------
dp_os_auto_updates_on() {
  case "$(dp_os)" in
    debian) dpkg -s unattended-upgrades >/dev/null 2>&1 ;;
    rhel) systemctl is-enabled --quiet dnf-automatic-install.timer 2>/dev/null || systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null \
      || systemctl is-enabled --quiet dnf5-automatic.timer 2>/dev/null ;;
    *) return 0 ;; # not offered
  esac
}

dp_os_auto_updates_enable() {
  case "$(dp_os)" in
    debian) dp_pkg_install unattended-upgrades && sudo dpkg-reconfigure -f noninteractive unattended-upgrades ;;
    rhel)
      if command -v dnf5 >/dev/null 2>&1 && dnf --version 2>/dev/null | grep -q '^dnf5'; then
        dp_pkg_install dnf5-plugin-automatic
        printf '[commands]\napply_updates = yes\nupgrade_type = security\n' | sudo tee /etc/dnf/automatic.conf >/dev/null
        sudo systemctl enable --now dnf5-automatic.timer >/dev/null
      else
        dp_pkg_install dnf-automatic
        sudo sed -i -E 's/^upgrade_type *=.*/upgrade_type = security/' /etc/dnf/automatic.conf
        sudo systemctl enable --now dnf-automatic-install.timer >/dev/null
      fi ;;
  esac
}

dp_os_auto_updates_note() {
  case "$(dp_os)" in
    suse) dp_info "Automatic updates: openSUSE/SLES use 'zypper patch' (or transactional-update on MicroOS); not configured here." ;;
    arch) dp_info "Automatic updates: Arch is a rolling release; update by hand with 'pacman -Syu'." ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# SELinux (RHEL family, enforcing)
# ---------------------------------------------------------------------------
dp_selinux_on() { command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == Enforcing ]]; }

# PHP-FPM and nginx run as httpd_t: allow proxying to loopback ports, reading/writing the
# app home (labelled as web content) and traversing home directories.
dp_selinux_prepare() {
  dp_selinux_on || return 0
  command -v semanage >/dev/null 2>&1 || dp_pkg_install "$(dp_pkg_name selinux-tools)"
  sudo setsebool -P httpd_can_network_connect 1 httpd_enable_homedirs 1 httpd_read_user_content 1
  if [[ -n "${APP_HOME:-}" ]]; then
    sudo semanage fcontext -a -t httpd_sys_rw_content_t "${APP_HOME}(/.*)?" 2>/dev/null \
      || sudo semanage fcontext -m -t httpd_sys_rw_content_t "${APP_HOME}(/.*)?"
    sudo restorecon -R "$APP_HOME"
  fi
  dp_ok "SELinux: web services may proxy to loopback ports and use ${APP_HOME:-the app home}"
}

# nginx may only listen on http_port_t ports.
dp_selinux_http_port() { # port...
  dp_selinux_on || return 0
  local p
  for p in "$@"; do
    sudo semanage port -l 2>/dev/null | awk '$1 == "http_port_t"' | grep -qE "[ ,]${p}(,|$)" && continue
    sudo semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null || sudo semanage port -m -t http_port_t -p tcp "$p"
  done
}
