#!/usr/bin/env bash
# Public edge: host nginx sites (certbot | byo cert) or upstream list for a panel (panel).
# Native runtime additionally gets a loopback nginx block per env in front of PHP-FPM.

# Site directories depend on the OS family (dp_nginx_dirs: sites-available/-enabled on
# Debian/Ubuntu, conf.d elsewhere); DP_NGINX_AVAIL / DP_NGINX_ENABLED override them.

_dp_render() { # template dest VAR=value...
  local tpl="$1" dest="$2"; shift 2
  local vars="" kv
  for kv in "$@"; do export "${kv?}"; vars+=" \${${kv%%=*}}"; done
  envsubst "$vars" <"${DP_ROOT}/nginx/${tpl}" | sudo tee "$dest" >/dev/null
}

# "host upstream" lines for every public site of the enabled envs.
dp_edge_sites() {
  local env
  for env in $ENABLED_ENVS; do
    dp_fe_on && echo "$(dp_ev "$env" FRONTEND_HOST) 127.0.0.1:$(dp_ev "$env" FRONTEND_PORT)"
    echo "$(dp_ev "$env" API_HOST) 127.0.0.1:$(dp_ev "$env" API_PORT)"
  done
  if [[ -n "${MEDIA_HOST:-}" ]] && dp_minio_on; then
    echo "${MEDIA_HOST} $(dp_minio_upstream)"
  fi
  return 0
}

dp_edge_need_nginx() { [[ "$EDGE_MODE" != "panel" || "$RUNTIME" == "native" ]]; }

dp_edge_prereqs() {
  dp_nginx_dirs
  dp_edge_need_nginx || return 0
  command -v nginx >/dev/null 2>&1 || { dp_pkg_install nginx; sudo systemctl enable --now nginx >/dev/null 2>&1 || true; }
  command -v envsubst >/dev/null 2>&1 || dp_pkg_install "$(dp_pkg_name envsubst)"
  if [[ "$EDGE_MODE" == "certbot" ]] && ! command -v certbot >/dev/null 2>&1; then
    dp_os_epel   # certbot is in EPEL on RHEL clones
    dp_pkg_install "$(dp_pkg_name certbot)"
  fi
  sudo mkdir -p "$DP_NGINX_AVAIL" "$DP_NGINX_ENABLED" /var/www/certbot
  dp_nginx_include_confd
  # Public sites need 80/443 through an active firewall (RHEL/openSUSE enable firewalld by default).
  [[ "$EDGE_MODE" != panel ]] && dp_fw_allow_ports "${PUBLIC_HTTP_PORT:-80}" "${PUBLIC_HTTPS_PORT:-443}"
  return 0
}

_dp_site_name() { printf '%s--%s.conf' "$PROJECT_SLUG" "$1"; }

_dp_enable() {
  local name="$1"
  # conf.d layouts load the file itself; sites-available needs the sites-enabled link.
  [[ "$DP_NGINX_AVAIL" == "$DP_NGINX_ENABLED" ]] || sudo ln -sfn "${DP_NGINX_AVAIL}/${name}" "${DP_NGINX_ENABLED}/${name}"
  DP_KEEP_SITES+=" ${name} "
}

_dp_reload_nginx() { sudo nginx -t && sudo systemctl reload nginx; }

# Remove this project's site files that are no longer wanted.
_dp_prune_sites() {
  local f base
  for f in "${DP_NGINX_AVAIL}/${PROJECT_SLUG}--"*.conf; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$DP_KEEP_SITES" == *" ${base} "* ]] && continue
    [[ "$DP_NGINX_AVAIL" == "$DP_NGINX_ENABLED" ]] || sudo rm -f "${DP_NGINX_ENABLED}/${base}"
    sudo rm -f "$f"
    echo "    removed stale site ${base}"
  done
}

dp_edge_apply() {
  local map_var common=() host up name cert key https_suffix=""
  map_var="$(dp_env_snake "$PROJECT_SLUG")"
  DP_KEEP_SITES=" "
  dp_edge_prereqs

  if dp_edge_need_nginx; then
    _dp_render map.conf.template "/etc/nginx/conf.d/00-${PROJECT_SLUG}-map.conf" SLUG="$PROJECT_SLUG" MAP_VAR="$map_var"
  fi

  if [[ "$RUNTIME" == "native" ]]; then
    dp_native_fpm_pool
    dp_selinux_prepare
    local env
    for env in $ENABLED_ENVS; do
      dp_selinux_http_port "$(dp_ev "$env" API_PORT)"   # nginx listens on the loopback API port
      name="$(_dp_site_name "${env}-api-fpm")"
      _dp_render api-fpm.conf.template "${DP_NGINX_AVAIL}/${name}" \
        SLUG="$PROJECT_SLUG" ENV_NAME="$env" API_PORT="$(dp_ev "$env" API_PORT)" FPM_PASS="$([[ $FPM_SOCK == /* ]] && echo "unix:${FPM_SOCK}" || echo "$FPM_SOCK")" \
        BACKEND_PUBLIC="$(dp_env_dir "$env")/backend-run/public" MAX_BODY="${MAX_BODY:-64m}"
      _dp_enable "$name"
    done
  fi

  if [[ "$EDGE_MODE" == "panel" ]]; then
    _dp_prune_sites
    dp_edge_need_nginx && _dp_reload_nginx
    dp_section "Point your panel's reverse proxies at these upstreams (HTTPS terminated by the panel)"
    dp_edge_sites | awk '{ printf "  %-40s → http://%s\n", $1, $2 }'
    return 0
  fi

  [[ "${PUBLIC_HTTPS_PORT:-443}" != "443" ]] && https_suffix=":${PUBLIC_HTTPS_PORT}"
  common=(HTTP_PORT="${PUBLIC_HTTP_PORT:-80}" HTTPS_PORT="${PUBLIC_HTTPS_PORT:-443}" HTTPS_SUFFIX="$https_suffix"
    MAP_VAR="$map_var" MAX_BODY="${MAX_BODY:-64m}")

  while read -r host up; do
    name="$(_dp_site_name "$host")"
    if [[ "$EDGE_MODE" == "certbot" ]]; then
      cert="/etc/letsencrypt/live/${host}/fullchain.pem"; key="/etc/letsencrypt/live/${host}/privkey.pem"
      if ! sudo test -f "$cert"; then
        _dp_render acme.conf.template "${DP_NGINX_AVAIL}/${name}" SITE_HOST="$host" HTTP_PORT="${PUBLIC_HTTP_PORT:-80}"
        _dp_enable "$name"; _dp_reload_nginx
        dp_info "Requesting certificate for ${host}"
        if ! sudo certbot certonly --webroot -w /var/www/certbot -d "$host" --cert-name "$host" \
          --email "$CERTBOT_EMAIL" --agree-tos --non-interactive --keep-until-expiring; then
          dp_warn "certbot failed for ${host} (DNS must point here and port ${PUBLIC_HTTP_PORT:-80} be reachable). Site left in ACME-only mode; re-run: setup.sh edge"
          continue
        fi
      fi
    else
      cert="$TLS_CERT"; key="$TLS_KEY"
      sudo test -f "$cert" && sudo test -f "$key" || dp_die "TLS cert/key not found: ${cert} / ${key}"
    fi
    _dp_render site.conf.template "${DP_NGINX_AVAIL}/${name}" SITE_HOST="$host" UPSTREAM="$up" CERT="$cert" KEY="$key" "${common[@]}"
    _dp_enable "$name"
  done < <(dp_edge_sites)

  if [[ "$EDGE_MODE" == "certbot" ]]; then
    sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nnginx -t && systemctl reload nginx\n' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
    sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  fi
  _dp_prune_sites
  _dp_reload_nginx
  dp_ok "Edge configured (${EDGE_MODE})"
}
