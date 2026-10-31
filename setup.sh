#!/usr/bin/env bash
# Interactive server setup for this project — generic, re-runnable, no fixed domains.
#
# Usage: deploy/setup.sh [command] [options]
#   init                  full wizard (default): project, envs, domains, variables, services, edge, deploy
#   add-env <env>         enable another environment (asks its domains + variables)
#   remove-env <env>      stop and disable an environment (data and backups are kept)
#   vars <env>            edit any catalog variable of an env (all groups)
#   domains               change frontend/API/media hosts, then re-sync envs + edge
#   edge                  re-render nginx / re-issue certificates / print panel upstreams
#   services              (re)start bundled Postgres/Redis/MinIO and align roles/buckets
#   rotate-secrets        regenerate DB/Redis/MinIO passwords and apply them everywhere
#   harden                optional server hardening (firewall, swap, log limits, updates)
#   deploy <env>          same as deploy/deploy.sh <env>
#   migrate <env> | seed-admin <env> | backup <env> | restore <env> <file>
#   status | doctor       health dashboard / diagnostics
#   export-answers [file] write a re-usable answers file (no secrets)
#
# Options: --answers FILE (pre-filled KEY=VALUE; <ENV>__KEY for per-env catalog vars)
#          --yes (accept defaults) --skip-services --skip-edge --skip-deploy --skip-preflight
set -euo pipefail

DP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DP_ROOT}/.." && pwd)"
for f in ui envfile state system env-urls services edge backend-run; do
  # shellcheck source=/dev/null
  source "${DP_ROOT}/lib/${f}.sh"
done

CMD="init" ARGS=() SKIP_SERVICES=0 SKIP_EDGE=0 SKIP_DEPLOY=0 SKIP_PREFLIGHT=0
while (( $# )); do
  case "$1" in
    --answers) [[ -f "$2" ]] || dp_die "answers file not found: $2"; dp_env_load_prefixed "$2" ''; shift 2 ;;
    --yes|-y) DP_YES=1; DP_ASSUME_INSTALL=1; shift ;;
    --skip-services) SKIP_SERVICES=1; shift ;;
    --skip-edge) SKIP_EDGE=1; shift ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*) dp_die "unknown option $1" ;;
    *) if [[ "$CMD" == "init" && ${#ARGS[@]} -eq 0 && "$1" =~ ^[a-z-]+$ && -z "${DP_CMD_SET:-}" ]]; then CMD="$1"; DP_CMD_SET=1; else ARGS+=("$1"); fi; shift ;;
  esac
done

DP_KNOWN_ENVS=(production staging dev)

# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------
declare -a CAT_KEYS=()
declare -A CAT_KIND=() CAT_GROUP=() CAT_DEFAULT=() CAT_HELP=()
while IFS='|' read -r key kind group def help; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  CAT_KEYS+=("$key"); CAT_KIND[$key]="$kind"; CAT_GROUP[$key]="$group"; CAT_DEFAULT[$key]="$def"; CAT_HELP[$key]="$help"
done <"${DP_ROOT}/vars.catalog"
CAT_GROUPS=(mail payments oauth sms storage)

declare -A VALS=()   # "env|KEY" → value chosen in this run

_dp_fill_placeholders() {
  local v="$1" env="$2"
  v="${v//\{SLUG\}/$PROJECT_SLUG}"; v="${v//\{ENV\}/$env}"
  v="${v//\{ROOT_DOMAIN\}/${ROOT_DOMAIN:-$(dp_ev "$env" FRONTEND_HOST)}}"
  v="${v//\{FRONTEND_HOST\}/$(dp_ev "$env" FRONTEND_HOST)}"
  v="${v//\{APP_NAME\}/${VALS[$env|APP_NAME]:-}}"
  printf '%s' "$v"
}

# Ask one catalog key for one env. Precedence: answers <ENV>__KEY > answers KEY >
# existing .env value > same key chosen for the previous env > catalog default.
_dp_ask_catalog_key() {
  local env="$1" key="$2" prev_env="$3" up file preset existing def val kind
  up="$(dp_env_upper "$env")"; file="$(dp_env_file "$env")"; kind="${CAT_KIND[$key]}"
  preset="${up}__${key}"; preset="${!preset:-${!key:-}}"
  existing="$(dp_env_value "$file" "$key")"
  if [[ "$kind" == "gen" ]]; then
    def="$existing"   # generated secrets are never copied from another env
  else
    def="${existing:-${VALS[$prev_env|$key]:-$(_dp_fill_placeholders "${CAT_DEFAULT[$key]}" "$env")}}"
  fi
  if [[ -n "$preset" ]]; then
    val="$preset"
  elif [[ "$kind" == "gen" ]]; then
    val="${def:-base64:$(openssl rand -base64 32)}"
  elif [[ "${DP_YES:-0}" == "1" ]]; then
    val="$def"
  elif [[ "$kind" == "secret" ]]; then
    read -r -s -p "  ${CAT_HELP[$key]} [${key}]$([[ -n "$def" ]] && echo ' (Enter=keep)'): " val || true; echo
    val="${val:-$def}"
  else
    read -r -p "  ${CAT_HELP[$key]} [${key}=${def}]: " val || true
    val="${val:-$def}"
  fi
  [[ "$kind" == "required" && -z "$val" ]] && dp_die "${env}: ${key} is required"
  VALS[$env|$key]="$val"
}

# ask_vars <env> <prev_env> [all-groups]
dp_ask_env_vars() {
  local env="$1" prev="$2" all="${3:-}" key group up
  up="$(dp_env_upper "$env")"
  dp_section "Variables for ${env}"
  for key in "${CAT_KEYS[@]}"; do
    case "${CAT_KIND[$key]}" in required|gen) _dp_ask_catalog_key "$env" "$key" "$prev" ;; esac
  done
  for group in "${CAT_GROUPS[@]}"; do
    local configured=n gvar="${up}__CONFIGURE_${group^^}"
    for key in "${CAT_KEYS[@]}"; do
      [[ "${CAT_GROUP[$key]}" == "$group" && "${CAT_KIND[$key]}" =~ ^(optional|secret)$ ]] || continue
      [[ -n "$(dp_env_value "$(dp_env_file "$env")" "$key")" ]] && configured=y
    done
    if [[ -n "$all" ]] || dp_yes "Configure ${group} settings for ${env} now?" "$configured" "$gvar"; then
      for key in "${CAT_KEYS[@]}"; do
        [[ "${CAT_GROUP[$key]}" == "$group" && "${CAT_KIND[$key]}" =~ ^(optional|secret)$ ]] && _dp_ask_catalog_key "$env" "$key" "$prev"
      done
    fi
  done
}

dp_write_env_vars() {
  local env="$1" file k key
  file="$(dp_env_file "$env")"
  mkdir -p "$(dirname "$file")"; [[ -f "$file" ]] || install -m 600 /dev/null "$file"
  for k in "${!VALS[@]}"; do
    [[ "$k" == "$env|"* ]] || continue
    key="${k#*|}"
    dp_env_sync "$file" "$key" "${VALS[$k]}" "$([[ ${CAT_KIND[$key]} =~ ^(secret|gen)$ ]] && echo 1 || echo 0)" >/dev/null
  done
}

# ---------------------------------------------------------------------------
# Wizard pieces
# ---------------------------------------------------------------------------
dp_load_existing() {
  if [[ -z "${APP_HOME:-}" ]]; then dp_locate_app_home "$REPO_ROOT" || true; fi
  if [[ -n "${APP_HOME:-}" && -f "${APP_HOME}/project.env" ]]; then
    dp_state_load_saved
    dp_info "Existing setup found at ${APP_HOME} — values are pre-filled; Enter keeps them."
  fi
}

dp_ask_project() {
  dp_section "Project"
  local slug_def remote
  slug_def="$(basename "$REPO_ROOT" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]//g')"
  dp_ask PROJECT_SLUG "Project slug (prefixes DBs, buckets, containers, units)" "$slug_def" dp_v_slug
  dp_ask APP_HOME "App home (state, env files, backups)" "${HOME}/${PROJECT_SLUG}" dp_v_path
  APP_HOME="$(dp_expand_path "$APP_HOME")"
  if [[ -f "${APP_HOME}/project.env" && -z "$(dp_saved PROJECT_SLUG)" ]]; then dp_state_load_saved; fi
  REPO_PATH="$REPO_ROOT"
  remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  REPO_URL="${REPO_URL:-$remote}"

  dp_choose RUNTIME "Runtime: docker = app in containers; host = PHP-FPM/Node via systemd (Horizon always in Docker)" docker docker host
  dp_choose SERVICES_MODE "Data services: bundled = Postgres/Redis/MinIO in Docker; external = your own servers" bundled bundled external
  dp_choose EDGE_MODE "Public edge: certbot = nginx + Let's Encrypt; byo = nginx + your cert; panel = existing panel proxies to loopback ports" certbot certbot byo panel
  if [[ "$EDGE_MODE" != "panel" ]]; then
    dp_ask PUBLIC_HTTP_PORT "Public HTTP port" 80 dp_v_port
    dp_ask PUBLIC_HTTPS_PORT "Public HTTPS port" 443 dp_v_port
  else
    PUBLIC_HTTP_PORT=80 PUBLIC_HTTPS_PORT=443
    dp_ask PUBLIC_HTTPS_PORT "HTTPS port the panel serves on (used in generated URLs)" 443 dp_v_port
  fi
  [[ "$EDGE_MODE" == "certbot" ]] && dp_ask_required CERTBOT_EMAIL "Let's Encrypt account email" "" dp_v_email
  if [[ "$EDGE_MODE" == "byo" ]]; then
    dp_ask_required TLS_CERT "TLS certificate (fullchain) path covering all hosts" "" dp_v_path
    dp_ask_required TLS_KEY "TLS private key path" "" dp_v_path
  fi
  if [[ "$RUNTIME" == "host" ]]; then
    local sock; sock="$(ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -1 || true)"
    dp_ask_required FPM_SOCK "PHP-FPM socket" "${sock:-/run/php/php8.4-fpm.sock}"
    local svc; svc="$(basename "${FPM_SOCK%.sock}")"
    dp_ask FPM_SERVICE "PHP-FPM systemd service (reloaded after deploys)" "$svc"
  fi
  dp_ask ROOT_DOMAIN "Root domain (only used to suggest hosts; blank to type every host)" "" dp_v_host_opt
}

# Reserve ports already assigned to other envs / services (state or this run).
dp_claim_known_ports() {
  local skip="$1" e k v
  for e in $ENABLED_ENVS; do
    [[ "$e" == "$skip" ]] && continue
    for k in API_PORT FRONTEND_PORT; do
      k="$(dp_env_upper "$e")_${k}"; v="${!k:-$(dp_saved "$k")}"; [[ -n "$v" ]] && dp_claim_port "$v"
    done
  done
  for k in PG_PORT REDIS_PORT MINIO_PORT MINIO_CONSOLE_PORT; do
    v="${!k:-$(dp_saved "$k")}"; [[ -n "$v" ]] && dp_claim_port "$v"
  done
  return 0
}

dp_ask_env_hosts() {
  local env="$1" up fe_def api_def br_def
  up="$(dp_env_upper "$env")"
  if [[ -n "${ROOT_DOMAIN:-}" ]]; then
    if [[ "$env" == "production" ]]; then fe_def="$ROOT_DOMAIN" api_def="api.${ROOT_DOMAIN}"
    else fe_def="${env}.${ROOT_DOMAIN}" api_def="api-${env}.${ROOT_DOMAIN}"; fi
  fi
  case "$env" in production) br_def=main ;; *) br_def="$env" ;; esac
  dp_section "Environment: ${env}"
  dp_ask "${up}_FRONTEND_HOST" "${env} client (frontend) domain" "${fe_def:-}" dp_v_host
  dp_ask "${up}_API_HOST" "${env} API domain (must differ from the client domain)" "${api_def:-}" dp_v_host
  local fe="${up}_FRONTEND_HOST" api="${up}_API_HOST"
  [[ "${!fe}" != "${!api}" ]] || dp_die "${env}: client and API domains must differ"
  dp_ask "${up}_BRANCH" "${env} git branch" "$br_def"
  dp_claim_known_ports "$env"
  dp_ask_port "${up}_API_PORT" "${env} API loopback port" 8100
  dp_ask_port "${up}_FRONTEND_PORT" "${env} frontend loopback port" 3100
  local rdb="${up}_REDIS_DB"
  if [[ -z "${!rdb:-}" ]]; then printf -v "$rdb" '%s' "$(dp_saved "$rdb")"; fi
  if [[ -z "${!rdb:-}" ]]; then
    local used="" e n=0
    local k
    for e in $ENABLED_ENVS; do k="$(dp_env_upper "$e")_REDIS_DB"; used+=" ${!k:-$(dp_saved "$k")} "; done
    while [[ "$used" == *" $n "* ]]; do n=$((n + 1)); done
    printf -v "$rdb" '%s' "$n"
  fi
  if [[ "$SERVICES_MODE" == "external" ]]; then
    dp_ask_required "${up}_DB_HOST" "${env} Postgres host" "127.0.0.1"
    dp_ask_required "${up}_DB_PORT" "${env} Postgres port" "5432" dp_v_port
    dp_ask_required "${up}_DB_DATABASE" "${env} database name" "$(dp_db_name "$env")"
    dp_ask_required "${up}_DB_USERNAME" "${env} database user" "$(dp_db_name "$env")"
  fi
  dp_ask_secret "DB_PASSWORD_${up}" "${env} database password" "$([[ $SERVICES_MODE == bundled ]] && echo 1 || echo 0)"
}

dp_ask_services() {
  dp_section "Data services (${SERVICES_MODE})"
  if [[ "$SERVICES_MODE" == "bundled" ]]; then
    dp_ask_port PG_PORT "Postgres loopback port" 5432
    dp_ask_port REDIS_PORT "Redis loopback port" 6379
    dp_ask_port MINIO_PORT "MinIO API loopback port" 9000
    dp_ask_port MINIO_CONSOLE_PORT "MinIO console loopback port" 9001
    dp_ask POSTGRES_SUPERUSER "Postgres superuser" "$(dp_env_snake "$PROJECT_SLUG")_admin"
    dp_ask_secret POSTGRES_SUPERPASS "Postgres superuser password" 1
    dp_ask_secret REDIS_PASSWORD "Redis password" 1
    dp_ask MINIO_ROOT_USER "MinIO root user" "$(dp_env_snake "$PROJECT_SLUG")_minio"
    dp_ask_secret MINIO_ROOT_PASSWORD "MinIO root password" 1
    dp_ask MEDIA_HOST "Public media domain for uploads (blank = none)" "${ROOT_DOMAIN:+media.${ROOT_DOMAIN}}" dp_v_host_opt
  else
    dp_ask_required REDIS_HOST "Redis host" "127.0.0.1"
    dp_ask_required REDIS_PORT "Redis port" 6379 dp_v_port
    dp_ask_secret REDIS_PASSWORD "Redis password" 0
    MEDIA_HOST=""
  fi
  dp_ask BACKUP_ENVS "Back up the database before migrating in these envs" "production staging"
  dp_ask BACKUP_KEEP "Backups to keep per env" 10
}

dp_save_state() {
  mkdir -p "${APP_HOME}/shared"; chmod 700 "$APP_HOME" "${APP_HOME}/shared"
  [[ -f "$(dp_state_file)" ]] || install -m 600 /dev/null "$(dp_state_file)"
  [[ -f "$(dp_secrets_file)" ]] || install -m 600 /dev/null "$(dp_secrets_file)"
  local k env up
  for k in PROJECT_SLUG APP_HOME REPO_URL REPO_PATH RUNTIME SERVICES_MODE EDGE_MODE PUBLIC_HTTP_PORT PUBLIC_HTTPS_PORT \
    CERTBOT_EMAIL TLS_CERT TLS_KEY FPM_SOCK FPM_SERVICE ROOT_DOMAIN ENABLED_ENVS MEDIA_HOST PG_PORT REDIS_PORT \
    MINIO_PORT MINIO_CONSOLE_PORT REDIS_HOST POSTGRES_SUPERUSER MINIO_ROOT_USER BACKUP_ENVS BACKUP_KEEP; do
    declare -p "$k" >/dev/null 2>&1 && dp_state_set "$k" "${!k}"
  done
  for env in $ENABLED_ENVS; do
    up="$(dp_env_upper "$env")"
    for k in FRONTEND_HOST API_HOST BRANCH API_PORT FRONTEND_PORT REDIS_DB DB_HOST DB_PORT DB_DATABASE DB_USERNAME; do
      local v="${up}_${k}"; declare -p "$v" >/dev/null 2>&1 && dp_state_set "$v" "${!v}"
    done
    local pw="DB_PASSWORD_${up}"; declare -p "$pw" >/dev/null 2>&1 && dp_secret_set "$pw" "${!pw}"
  done
  for k in POSTGRES_SUPERPASS REDIS_PASSWORD MINIO_ROOT_PASSWORD; do declare -p "$k" >/dev/null 2>&1 && dp_secret_set "$k" "${!k}"; done
  printf 'APP_HOME=%s\nREPO_PATH=%s\n' "$APP_HOME" "$REPO_PATH" >"${HOME}/.${PROJECT_SLUG}.deploy"
  chmod 600 "${HOME}/.${PROJECT_SLUG}.deploy"
}

dp_summary() {
  dp_section "Review"
  printf '  %-18s %s\n' project "$PROJECT_SLUG" home "$APP_HOME" repo "${REPO_URL:-$REPO_PATH}" \
    runtime "$RUNTIME" services "$SERVICES_MODE" edge "$EDGE_MODE (http ${PUBLIC_HTTP_PORT} / https ${PUBLIC_HTTPS_PORT})" \
    media "${MEDIA_HOST:-<none>}" envs "$ENABLED_ENVS"
  local env
  for env in $ENABLED_ENVS; do
    printf '  %-18s client %s | api %s | branch %s | ports api %s fe %s\n' "[$env]" \
      "$(dp_origin "$(dp_ev "$env" FRONTEND_HOST)")" "$(dp_origin "$(dp_ev "$env" API_HOST)")" \
      "$(dp_ev "$env" BRANCH)" "$(dp_ev "$env" API_PORT)" "$(dp_ev "$env" FRONTEND_PORT)"
  done
  echo "  secrets: stored in ${APP_HOME}/shared/secrets.env and <env>/.env (chmod 600), not shown"
}

dp_apply_envs() { # write catalog values + managed keys for the given envs
  local env
  for env in "$@"; do dp_write_env_vars "$env"; dp_write_managed "$env" >/dev/null; done
}

dp_deploy_envs() {
  local env
  for env in "$@"; do
    dp_section "Deploy ${env}"
    "${DP_ROOT}/deploy.sh" "$env" || dp_warn "${env} deploy failed; fix and run: deploy/deploy.sh ${env}"
  done
}

dp_reload_state() { dp_state_load; dp_secrets_load; }

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_init() {
  [[ "$SKIP_PREFLIGHT" == "1" ]] || dp_preflight
  dp_load_existing
  dp_ask_project
  dp_section "Environments"
  dp_multiselect ENABLED_ENVS "Which environments should this server host?" "production" "${DP_KNOWN_ENVS[@]}"
  local env prev=""
  for env in $ENABLED_ENVS; do dp_ask_env_hosts "$env"; done
  dp_ask_services
  for env in $ENABLED_ENVS; do dp_ask_env_vars "$env" "$prev"; prev="$env"; done
  dp_summary
  dp_yes "Apply this configuration?" y DP_APPLY || dp_die "Aborted; nothing written."

  dp_save_state
  dp_reload_state
  dp_apply_envs $ENABLED_ENVS
  dp_ok "State and env files written under ${APP_HOME}"
  if [[ "$SKIP_SERVICES" == "0" ]]; then
    dp_install_docker   # needed in every mode: app containers or the Horizon container
    dp_services_apply
  fi
  [[ "$SKIP_EDGE" == "0" ]] && dp_edge_apply
  if dp_yes "Run optional server hardening now?" n DP_HARDEN; then dp_harden; fi
  if [[ "$SKIP_DEPLOY" == "0" ]]; then
    dp_multiselect DEPLOY_NOW "Build and deploy now (one after another)" "$ENABLED_ENVS" $ENABLED_ENVS
    dp_deploy_envs $DEPLOY_NOW
  fi
  dp_section "Done"
  echo "  Deploy later:   deploy/deploy.sh <env> [--pull]"
  echo "  Add an env:     deploy/setup.sh add-env staging"
  echo "  Change values:  deploy/setup.sh vars <env> | domains | rotate-secrets"
  echo "  Health:         deploy/setup.sh status | doctor"
  echo "  Superadmin:     deploy/setup.sh seed-admin <env>"
}

cmd_add_env() {
  local env="${ARGS[0]:-}"; [[ -n "$env" ]] || dp_die "usage: setup.sh add-env <env>"
  [[ "$env" =~ ^[a-z][a-z0-9-]{0,19}$ ]] || dp_die "invalid env name '${env}' (a-z, 0-9, -)"
  dp_load_existing; dp_reload_state
  dp_env_enabled "$env" && dp_die "${env} is already enabled"
  ENABLED_ENVS="${ENABLED_ENVS} ${env}"
  dp_ask_env_hosts "$env"
  dp_ask_env_vars "$env" "$(awk '{ print $1 }' <<<"$ENABLED_ENVS")"
  dp_yes "Add ${env}?" y DP_APPLY || dp_die "Aborted."
  dp_save_state; dp_reload_state; dp_apply_envs "$env"
  [[ "$SKIP_SERVICES" == "1" ]] || dp_services_apply
  [[ "$SKIP_EDGE" == "1" ]] || dp_edge_apply
  [[ "$SKIP_DEPLOY" == "1" ]] || { dp_yes "Deploy ${env} now?" y DP_DEPLOY && dp_deploy_envs "$env"; } || true
  dp_info "Remember: add the ${env} branch to .github/workflows/cd.yml if CI should deploy it."
}

cmd_remove_env() {
  local env="${ARGS[0]:-}"; [[ -n "$env" ]] || dp_die "usage: setup.sh remove-env <env>"
  dp_load_existing; dp_reload_state
  dp_env_enabled "$env" || dp_die "${env} is not enabled"
  dp_yes "Stop ${env} and remove its sites/units? (database, files and backups are kept)" n || dp_die "Aborted."
  if [[ "$RUNTIME" == "docker" ]]; then
    docker compose -p "${PROJECT_SLUG}-${env}" down --remove-orphans || true
  else
    sudo systemctl disable --now "${PROJECT_SLUG}-frontend-${env}.service" "${PROJECT_SLUG}-scheduler-${env}.service" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${PROJECT_SLUG}-"{frontend,scheduler}"-${env}.service"; sudo systemctl daemon-reload
    docker compose -p "${PROJECT_SLUG}-${env}-horizon" down || true
  fi
  ENABLED_ENVS="$(tr ' ' '\n' <<<"$ENABLED_ENVS" | grep -vx "$env" | xargs)"
  dp_state_set ENABLED_ENVS "$ENABLED_ENVS"
  [[ "$SKIP_EDGE" == "1" ]] || dp_edge_apply
  dp_ok "${env} disabled. Data kept: $(dp_env_dir "$env"), database $(dp_db_name "$env")."
}

cmd_vars() {
  local env="${ARGS[0]:-}"; [[ -n "$env" ]] || dp_die "usage: setup.sh vars <env>"
  dp_load_existing; dp_reload_state
  dp_env_enabled "$env" || dp_die "${env} is not enabled"
  dp_ask_env_vars "$env" "" all
  dp_apply_envs "$env"
  dp_ok "Updated $(dp_env_file "$env"). Apply with: deploy/deploy.sh ${env}"
}

cmd_domains() {
  dp_load_existing; dp_reload_state
  local env; for env in $ENABLED_ENVS; do
    local up; up="$(dp_env_upper "$env")"
    unset "${up}_FRONTEND_HOST" "${up}_API_HOST"
    dp_ask_env_hosts "$env"
  done
  [[ "$SERVICES_MODE" == "bundled" ]] && { unset MEDIA_HOST; dp_ask MEDIA_HOST "Public media domain (blank = none)" "" dp_v_host_opt; }
  dp_save_state; dp_reload_state
  for env in $ENABLED_ENVS; do dp_write_managed "$env"; done
  [[ "$SKIP_EDGE" == "1" ]] || dp_edge_apply
  dp_info "Rebuild so the frontend picks up new URLs: deploy/deploy.sh <env>"
}

cmd_rotate_secrets() {
  dp_load_existing; dp_reload_state
  [[ "$SERVICES_MODE" == "bundled" ]] || dp_die "rotate-secrets manages bundled services only; rotate external credentials at the provider, then run: setup.sh vars <env>"
  dp_yes "Generate new Postgres, Redis and MinIO passwords and apply them now? (APP_KEY is not touched)" n || dp_die "Aborted."
  local env k
  POSTGRES_SUPERPASS="$(dp_gen_secret)"; REDIS_PASSWORD="$(dp_gen_secret)"; MINIO_ROOT_PASSWORD="$(dp_gen_secret)"
  for k in POSTGRES_SUPERPASS REDIS_PASSWORD MINIO_ROOT_PASSWORD; do dp_secret_set "$k" "${!k}"; done
  for env in $ENABLED_ENVS; do k="DB_PASSWORD_$(dp_env_upper "$env")"; printf -v "$k" '%s' "$(dp_gen_secret)"; dp_secret_set "$k" "${!k}"; done
  # Postgres keeps the old superuser password until ALTERed: connect via the local socket (trust).
  dp_services_db
  dp_services_compose up -d --wait redis minio
  for env in $ENABLED_ENVS; do dp_write_managed "$env" >/dev/null; done
  dp_deploy_envs $ENABLED_ENVS
}

cmd_status() {
  dp_load_existing; dp_reload_state
  dp_section "${PROJECT_SLUG} — ${RUNTIME} runtime, ${SERVICES_MODE} services, ${EDGE_MODE} edge"
  local env
  for env in $ENABLED_ENVS; do
    local api fe sha
    api="$(dp_ev "$env" API_PORT)"; fe="$(dp_ev "$env" FRONTEND_PORT)"; sha="$(dp_ev "$env" DEPLOYED_SHA)"
    printf '  %-12s release %-14s api:%s %s  fe:%s %s\n' "$env" "${sha:-<none>}" "$api" \
      "$(curl -fsS -o /dev/null --max-time 5 -H "Host: $(dp_ev "$env" API_HOST)" "http://127.0.0.1:${api}/up" && echo up || echo DOWN)" \
      "$fe" "$(curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${fe}/" && echo up || echo DOWN)"
    if [[ "$RUNTIME" == "docker" ]]; then docker compose -p "${PROJECT_SLUG}-${env}" ps --format '    {{.Service}}: {{.State}} {{.Health}}' 2>/dev/null || true
    else systemctl is-active "${PROJECT_SLUG}-frontend-${env}" "${PROJECT_SLUG}-scheduler-${env}" 2>/dev/null | paste -sd' ' | sed 's/^/    frontend,scheduler: /'
         docker compose -p "${PROJECT_SLUG}-${env}-horizon" ps --format '    horizon: {{.State}}' 2>/dev/null || true; fi
    printf '    backups: %s\n' "$(ls "${APP_HOME}/backups/${env}" 2>/dev/null | wc -l | xargs)"
  done
  [[ "$SERVICES_MODE" == "bundled" ]] && dp_services_compose ps --format '  services {{.Service}}: {{.State}} {{.Health}}' 2>/dev/null
  if [[ "$EDGE_MODE" == "certbot" ]]; then
    local host _
    while read -r host _; do
      local end; end="$(sudo openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${host}/fullchain.pem" 2>/dev/null | cut -d= -f2)"
      printf '  cert %-36s %s\n' "$host" "${end:-MISSING}"
    done < <(dp_edge_sites)
  fi
  printf '  disk free: %s\n' "$(df -h "$APP_HOME" | awk 'NR==2 { print $4 }')"
  echo "  recent deploys:"; tail -n 5 "${APP_HOME}/shared/deploy.log" 2>/dev/null | sed 's/^/    /' || true
}

cmd_doctor() {
  dp_load_existing; dp_reload_state
  dp_section "Doctor"
  local env host _ rc=0
  [[ "$(stat -c %a "$(dp_secrets_file)" 2>/dev/null || stat -f %Lp "$(dp_secrets_file)")" == 600 ]] && dp_ok "secrets.env is 600" || { dp_warn "secrets.env permissions are not 600"; rc=1; }
  command -v docker >/dev/null && docker info >/dev/null 2>&1 && dp_ok "docker reachable" || { dp_warn "docker not reachable by $(id -un)"; rc=1; }
  DP_PUBLIC_IP="$(dp_public_ip)"; [[ -n "$DP_PUBLIC_IP" ]] && dp_ok "public IP ${DP_PUBLIC_IP}"
  [[ "$EDGE_MODE" == "panel" ]] || while read -r host _; do dp_dns_check "$host" || rc=1; done < <(dp_edge_sites)
  for env in $ENABLED_ENVS; do
    local f; f="$(dp_env_file "$env")"
    [[ -f "$f" ]] || { dp_warn "${env}: missing ${f}"; rc=1; continue; }
    local key; for key in "${CAT_KEYS[@]}"; do
      [[ "${CAT_KIND[$key]}" =~ ^(required|gen)$ && -z "$(dp_env_value "$f" "$key")" ]] && { dp_warn "${env}: ${key} is empty"; rc=1; }
    done
    dp_port_in_use "$(dp_ev "$env" API_PORT)" && dp_ok "${env}: API port listening" || { dp_warn "${env}: nothing on API port $(dp_ev "$env" API_PORT)"; rc=1; }
    dp_check_cors "$env" || rc=1
  done
  (( rc == 0 )) && dp_ok "all checks passed" || dp_warn "some checks need attention"
  return $rc
}

dp_artisan() { # env cmd...
  local env="$1"; shift
  if [[ "$RUNTIME" == "docker" ]]; then
    local sha; sha="$(dp_ev "$env" DEPLOYED_SHA)"; [[ -n "$sha" ]] || dp_die "${env} has no deployed release yet"
    local backend="${PROJECT_SLUG}-backend:${env}-${sha}" frontend="${PROJECT_SLUG}-frontend:${env}-${sha}"
    export PROJECT_SLUG
    DP_ENV="$env" DP_NETWORK="$(dp_network)" ENV_FILE="$(dp_env_file "$env")" BACKEND_IMAGE="$backend" FRONTEND_IMAGE="$frontend" \
    API_PORT="$(dp_ev "$env" API_PORT)" FRONTEND_PORT="$(dp_ev "$env" FRONTEND_PORT)" \
      docker compose -f "${DP_ROOT}/compose/app.yml" exec -T app php artisan "$@"
  else
    (cd "$(dp_env_dir "$env")/backend-run" && php artisan "$@")
  fi
}

case "$CMD" in
  init) cmd_init ;;
  add-env) cmd_add_env ;;
  remove-env) cmd_remove_env ;;
  vars) cmd_vars ;;
  domains) cmd_domains ;;
  edge) dp_load_existing; dp_reload_state; dp_edge_apply ;;
  services) dp_load_existing; dp_reload_state; dp_services_apply ;;
  rotate-secrets) cmd_rotate_secrets ;;
  harden) dp_load_existing; dp_reload_state; dp_harden ;;
  deploy) exec "${DP_ROOT}/deploy.sh" "${ARGS[@]}" ;;
  migrate) dp_load_existing; dp_reload_state; dp_artisan "${ARGS[0]:?env}" migrate --force ;;
  seed-admin) dp_load_existing; dp_reload_state
    dp_artisan "${ARGS[0]:?env}" db:seed --force --class="${SEED_ADMIN_CLASS:?set SEED_ADMIN_CLASS in project.env (e.g. Database\\Seeders\\AdminSeeder)}" ;;
  backup) dp_load_existing; dp_reload_state; dp_backup_db "${ARGS[0]:?env}" ;;
  restore) dp_load_existing; dp_reload_state
    dp_yes "Restore ${ARGS[1]:?file} into ${ARGS[0]:?env}? This overwrites its data." n || dp_die "Aborted."
    dp_backup_db "${ARGS[0]}"; dp_restore_db "${ARGS[0]}" "${ARGS[1]}" ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  export-answers)
    dp_load_existing; dp_reload_state
    out="${ARGS[0]:-${APP_HOME}/answers.env}"
    { grep -vE '_(DEPLOYED|PREV)_SHA=' "$(dp_state_file)"
      for env in $ENABLED_ENVS; do
        for key in "${CAT_KEYS[@]}"; do
          [[ "${CAT_KIND[$key]}" =~ ^(required|optional)$ ]] || continue
          v="$(dp_env_value "$(dp_env_file "$env")" "$key")"; [[ -n "$v" ]] && echo "$(dp_env_upper "$env")__${key}=$(_dp_quote "$v")"
        done
      done; } >"$out"
    chmod 600 "$out"; dp_ok "Answers written to ${out} (secrets excluded)" ;;
  *) dp_die "unknown command ${CMD} (see --help)" ;;
esac
