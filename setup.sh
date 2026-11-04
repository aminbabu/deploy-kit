#!/usr/bin/env bash
# Interactive server setup for a Laravel API (+ optional Next.js frontend) — generic,
# re-runnable, no fixed domains. Every component runs in Docker or natively on this host.
#
# Usage: deploy/setup.sh [command] [options]
#   init                  full wizard (default): app, components, envs, domains, variables, services, edge, deploy
#   add-env <env>         enable another environment (asks its domains + variables)
#   remove-env <env>      stop and disable an environment (data and backups are kept)
#   uninstall [--purge]   remove this project from the server (services, nginx sites, PHP-FPM pool,
#                         sudoers rule); --purge also deletes its app home (databases are kept)
#   vars <env>            edit the catalog variables of an env (mail, SMS, payments, OAuth, …)
#   domains               change frontend/API/media hosts, then re-sync envs + edge
#   components            change app paths/runtime and each component's mode (docker/native/external)
#   steps                 change deploy steps: health path, extra artisan commands, queue:work options, Node version
#   cd-workflow           write .github/workflows/cd.yml for this project (deploy on push, or after CI passes)
#   edge                  re-render nginx / re-issue certificates / print panel upstreams
#   services              (re)start Docker/native data services and align roles/buckets
#   rotate-secrets        regenerate DB/Redis/MinIO passwords and apply them everywhere
#   credentials           show the stored service passwords (DB, Redis, MinIO)
#   harden                optional server hardening (firewall, swap, log limits, updates)
#   deploy <env>          same as deploy/deploy.sh <env>
#   migrate <env> | seed-admin <env> | backup <env> | restore <env> <file>
#   artisan <env> -- <command> [args]   run any artisan command in an env (its PHP, .env and storage)
#   status | doctor       health dashboard / diagnostics
#   export-answers [file] write a re-usable answers file (no secrets)
#
# Options: --answers FILE (pre-filled KEY=VALUE; <ENV>__KEY for per-env catalog vars)
#          --yes (accept defaults) --skip-services --skip-edge --skip-deploy --skip-preflight
set -euo pipefail

DP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DP_ROOT}/.." && pwd)"
for f in ui envfile os state system env-urls services native edge backend-run; do
  # shellcheck source=/dev/null
  source "${DP_ROOT}/lib/${f}.sh"
done

CMD="init" ARGS=() SKIP_SERVICES=0 SKIP_EDGE=0 SKIP_DEPLOY=0 SKIP_PREFLIGHT=0
while (( $# )); do
  case "$1" in
    --answers) [[ -f "$2" ]] || dp_die "answers file not found: $2"; dp_env_load_prefixed "$2" ''; dp_state_compat ''; shift 2 ;;
    --yes|-y) DP_YES=1; DP_ASSUME_INSTALL=1; shift ;;
    --skip-services) SKIP_SERVICES=1; shift ;;
    --skip-edge) SKIP_EDGE=1; shift ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    --purge) ARGS+=("--purge"); shift ;;   # uninstall
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    -*) dp_die "unknown option $1" ;;
    *) if [[ "$CMD" == "init" && ${#ARGS[@]} -eq 0 && "$1" =~ ^[a-z-]+$ && -z "${DP_CMD_SET:-}" ]]; then CMD="$1"; DP_CMD_SET=1; else ARGS+=("$1"); fi; shift ;;
  esac
done

DP_KNOWN_ENVS=(production staging dev)

# ---------------------------------------------------------------------------
# Catalog (vars.catalog + optional vars.extra.catalog)
# ---------------------------------------------------------------------------
declare -a CAT_KEYS=()
declare -A CAT_KIND=() CAT_GROUP=() CAT_DEFAULT=() CAT_HELP=() CAT_OPTS=()
for f in "${DP_ROOT}/vars.catalog" "${DP_ROOT}/vars.extra.catalog"; do
  [[ -f "$f" ]] || continue
  while IFS='|' read -r key kind group def help opts; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ -n "${CAT_KIND[$key]:-}" ]] || CAT_KEYS+=("$key")
    CAT_KIND[$key]="$kind"; CAT_GROUP[$key]="$group"; CAT_DEFAULT[$key]="$def"; CAT_HELP[$key]="$help"; CAT_OPTS[$key]="$opts"
  done <"$f"
done

declare -A VALS=()   # "env|KEY" → value chosen in this run

_dp_fill_placeholders() {
  local v="$1" env="$2"
  v="${v//\{SLUG\}/$PROJECT_SLUG}"; v="${v//\{ENV\}/$env}"
  v="${v//\{ROOT_DOMAIN\}/${ROOT_DOMAIN:-$(dp_ev "$env" API_HOST)}}"
  v="${v//\{FRONTEND_HOST\}/$(dp_ev "$env" FRONTEND_HOST)}"
  v="${v//\{FRONTEND_URL\}/$([[ -n "$(dp_ev "$env" FRONTEND_HOST)" ]] && dp_origin "$(dp_ev "$env" FRONTEND_HOST)")}"
  v="${v//\{API_URL\}/$([[ -n "$(dp_ev "$env" API_HOST)" ]] && dp_origin "$(dp_ev "$env" API_HOST)")}"
  v="${v//\{APP_NAME\}/${VALS[$env|APP_NAME]:-}}"
  v="${v//\{DISK\}/$([[ $STORAGE_MODE == local ]] && echo local || echo s3)}"
  v="${v//\{KV\}/$([[ $REDIS_MODE == none ]] && echo database || echo redis)}"
  printf '%s' "$v"
}

# Normalize a select/multi answer; warns about values without catalog groups.
_dp_norm_choice() {
  local key="$1" val="$2" kind="${CAT_KIND[$1]}" t out=()
  val="${val//,/ }"
  [[ "$kind" == select ]] && { val="${val%% *}"; [[ -n "$val" ]] || return 1; }
  for t in $val; do
    [[ "$t" == none ]] && continue
    [[ " ${CAT_OPTS[$key]} " == *" ${t} "* ]] || dp_warn "${key}: '${t}' is not one of: ${CAT_OPTS[$key]} (kept; no extra keys asked)"
    [[ " ${out[*]} " == *" ${t} "* ]] || out+=("$t")
  done
  local IFS=,; printf '%s' "${out[*]}"
}

# Ask one catalog key for one env. Precedence: answers <ENV>__KEY > answers KEY >
# existing .env value > same key chosen for the previous env > catalog default.
_dp_ask_catalog_key() {
  local env="$1" key="$2" prev_env="$3" up file preset existing def val kind hint
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
  elif [[ "$kind" == "file" ]]; then
    read -r -p "  ${CAT_HELP[$key]}: path to the file on this server [${key}$([[ -n "$def" ]] && echo "=${def}")]: " val || true
    val="${val:-$def}"
  elif [[ "$kind" == "secret" ]]; then
    read -r -s -p "    ${CAT_HELP[$key]} [${key}]$([[ -n "$def" ]] && echo ' (Enter=keep)'): " val || true; echo
    val="${val:-$def}"
  elif [[ "$kind" == select || "$kind" == multi ]]; then
    hint="${CAT_OPTS[$key]// /|}"; [[ "$kind" == multi ]] && hint+="; several comma-separated, none = clear"
    read -r -p "  ${CAT_HELP[$key]} (${hint}) [${def:-none}]: " val || true
    val="${val:-$def}"
  else
    read -r -p "  ${CAT_HELP[$key]} [${key}=${def}]: " val || true
    val="${val:-$def}"
  fi
  if [[ "$kind" == select || "$kind" == multi ]]; then
    val="$(_dp_norm_choice "$key" "$val")" || dp_die "${env}: ${key} needs one of: ${CAT_OPTS[$key]}"
  fi
  [[ "$kind" == "required" && -z "$val" ]] && dp_die "${env}: ${key} is required"
  [[ "$kind" == "file" && -n "$val" ]] && val="$(_dp_store_file "$env" "$key" "$val")"
  VALS[$env|$key]="$val"
}

# Copy a file a setting points to (service-account JSON, key, certificate) into
# <env>/files/ (mode 600); the setting gets the stored path. Docker mounts that dir at the same path.
_dp_store_file() { # env key path
  local dir dest src="${3/#\~/$HOME}"
  dir="$(dp_env_dir "$1")/files"
  [[ "$src" == "${dir}/"* && -f "$src" ]] && { printf '%s' "$src"; return 0; }
  [[ -f "$src" ]] || dp_die "${1}: ${2}: file not found: ${src}"
  mkdir -p "$dir"; chmod 700 "$dir"
  dest="${dir}/$(tr 'A-Z_' 'a-z-' <<<"$2")"; [[ "$src" == *.* ]] && dest+=".${src##*.}"
  install -m 600 "$src" "$dest"
  printf '%s' "$dest"
}

_dp_ask_group() { # env group prev
  local key
  for key in "${CAT_KEYS[@]}"; do
    [[ "${CAT_GROUP[$key]}" == "$2" && "${CAT_KIND[$key]}" =~ ^(optional|secret|file)$ ]] && _dp_ask_catalog_key "$1" "$key" "$3"
  done
  return 0
}

# Asks core values, then each select/multi and only the keys of what was chosen.
dp_ask_env_vars() {
  local env="$1" prev="$2" key choice
  dp_section "Variables for ${env}"
  for key in "${CAT_KEYS[@]}"; do
    case "${CAT_KIND[$key]}" in
      required|gen) _dp_ask_catalog_key "$env" "$key" "$prev" ;;
      # group "core" = always asked; other groups only when chosen. kind "skip" (set in a
      # project's vars.extra.catalog) hides a core question the app does not use.
      optional|secret|file) [[ "${CAT_GROUP[$key]}" == core ]] && _dp_ask_catalog_key "$env" "$key" "$prev" ;;
      select|multi)
        _dp_ask_catalog_key "$env" "$key" "$prev"
        for choice in ${VALS[$env|$key]//,/ }; do _dp_ask_group "$env" "${CAT_GROUP[$key]}-${choice}" "$prev"; done ;;
    esac
  done
  if [[ "$STORAGE_MODE" == s3 ]]; then
    echo "  External S3 storage:"
    _dp_ask_group "$env" storage-s3 "$prev"
  fi
}

dp_write_env_vars() {
  local env="$1" file k key
  file="$(dp_env_file "$env")"
  mkdir -p "$(dirname "$file")"; [[ -f "$file" ]] || install -m 600 /dev/null "$file"
  for key in "${CAT_KEYS[@]}"; do   # catalog order keeps the .env readable
    k="$env|$key"; [[ -n "${VALS[$k]+set}" ]] || continue
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
  # install.sh clones into ~/<app>/repo: name the project after <app>, not "repo".
  slug_def="$(basename "$REPO_ROOT")"; [[ "$slug_def" == repo ]] && slug_def="$(basename "$(dirname "$REPO_ROOT")")"
  slug_def="$(printf '%s' "$slug_def" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]//g')"
  dp_ask PROJECT_SLUG "Project slug (prefixes DBs, buckets, containers, units)" "$slug_def" dp_v_slug
  # Saved state belongs to another project: start fresh instead of overwriting it.
  if [[ -n "$(dp_saved PROJECT_SLUG)" && "$(dp_saved PROJECT_SLUG)" != "$PROJECT_SLUG" ]]; then
    dp_warn "Saved setup at ${APP_HOME:-?} is for '$(dp_saved PROJECT_SLUG)', not '${PROJECT_SLUG}'; starting a new setup."
    unset APP_HOME $(compgen -v S_ || true)
  fi
  dp_ask APP_HOME "App home (state, env files, backups)" "${HOME}/${PROJECT_SLUG}" dp_v_path
  APP_HOME="$(dp_expand_path "$APP_HOME")"
  # Each project keeps its state and secrets in its own home; never write into another's.
  local owner; owner="$(dp_env_value "${APP_HOME}/project.env" PROJECT_SLUG 2>/dev/null || true)"
  [[ -z "$owner" || "$owner" == "$PROJECT_SLUG" ]] \
    || dp_die "${APP_HOME} belongs to project '${owner}'. Use a separate app home for '${PROJECT_SLUG}' (default ${HOME}/${PROJECT_SLUG})."
  if [[ -f "${APP_HOME}/project.env" && -z "$(dp_saved PROJECT_SLUG)" ]]; then dp_state_load_saved; fi
  REPO_PATH="$REPO_ROOT"
  remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  REPO_URL="${REPO_URL:-$remote}"
}

# First of the candidate dirs (relative to the repo) containing a file matching $1.
_dp_find_dir() {
  local glob="$1" d; shift
  for d in "$@"; do compgen -G "${REPO_ROOT}/${d}/${glob}" >/dev/null && { printf '%s' "$d"; return 0; }; done
  # Monorepos (pnpm/npm/yarn workspaces, Turborepo, Nx): one level under the usual roots.
  for d in "${REPO_ROOT}"/{apps,services,packages}/*/; do
    d="${d%/}"; compgen -G "${d}/${glob}" >/dev/null && { printf '%s' "${d#"${REPO_ROOT}"/}"; return 0; }
  done
  return 1
}
_dp_reldir() { local d="${1#./}"; d="${d%/}"; printf '%s' "${d:-.}"; }

# Install/build commands for a native frontend build, from the lockfile in use.
_dp_fe_cmds() {
  local d="$FRONTEND_DIR" in="cd ${FRONTEND_DIR} && "
  [[ "$d" == . ]] && in=""
  if [[ -f "${REPO_ROOT}/pnpm-workspace.yaml" ]]; then
    FE_INSTALL_DEF="pnpm install --frozen-lockfile"; FE_BUILD_DEF="pnpm --filter ./${d} build"
    # Turborepo: build through turbo so workspace packages the app needs are built first.
    local pkg; pkg="$(sed -nE 's/^ *"name": *"([^"]+)".*/\1/p' "${REPO_ROOT}/${d}/package.json" 2>/dev/null | head -1)"
    [[ -f "${REPO_ROOT}/turbo.json" && -n "$pkg" ]] && FE_BUILD_DEF="pnpm turbo run build --filter=${pkg}"
  elif [[ -f "${REPO_ROOT}/${d}/pnpm-lock.yaml" ]]; then
    FE_INSTALL_DEF="${in}pnpm install --frozen-lockfile"; FE_BUILD_DEF="${in}pnpm build"
  elif [[ -f "${REPO_ROOT}/${d}/yarn.lock" || -f "${REPO_ROOT}/yarn.lock" ]]; then
    FE_INSTALL_DEF="${in}yarn install --frozen-lockfile"; FE_BUILD_DEF="${in}yarn build"
  elif [[ -f "${REPO_ROOT}/${d}/package-lock.json" ]]; then
    FE_INSTALL_DEF="${in}npm ci"; FE_BUILD_DEF="${in}npm run build"
  else
    FE_INSTALL_DEF="${in}npm install"; FE_BUILD_DEF="${in}npm run build"
  fi
}

dp_ask_app() {
  dp_section "Application"
  dp_ask BACKEND_DIR "Laravel backend directory in the repo (. = repo root)" "$(_dp_find_dir artisan backend api server . || echo backend)" dp_v_reldir
  BACKEND_DIR="$(_dp_reldir "$BACKEND_DIR")"
  [[ -f "${REPO_ROOT}/${BACKEND_DIR}/artisan" ]] || dp_warn "No artisan in ${REPO_ROOT}/${BACKEND_DIR} (fine if this checkout is not the app yet)"
  local fe_dir fe_def=n
  fe_dir="$(_dp_find_dir 'next.config.*' frontend web client app . || true)"
  [[ -n "$fe_dir" ]] && fe_def=y
  dp_choose FRONTEND_ENABLED "Deploy a Next.js frontend too? (n = API only)" "$fe_def" y n
  if dp_fe_on; then
    dp_ask FRONTEND_DIR "Next.js frontend directory in the repo" "${fe_dir:-frontend}" dp_v_reldir
    FRONTEND_DIR="$(_dp_reldir "$FRONTEND_DIR")"
    # rewrites() forwarding /api to Laravel = same-origin proxy: the browser never calls the API host.
    local mode_def=direct
    grep -qsE "source: *['\"]/api" "${REPO_ROOT}/${FRONTEND_DIR}"/next.config.* && mode_def=proxy
    dp_choose FRONTEND_API_MODE "How does the browser reach the API? direct = calls the API domain (CORS); proxy = through the frontend (Next.js rewrites)" "$mode_def" direct proxy
  fi
  dp_ask API_PREFIX "API path prefix for NEXT_PUBLIC_API_URL and OAuth callbacks (none = no prefix)" "/api/v1"

  dp_choose RUNTIME "App runtime: docker = containers from your Dockerfiles; native = PHP-FPM + Node under systemd" docker docker native
  if [[ "$RUNTIME" == docker ]]; then
    dp_ask BACKEND_DOCKERFILE "Backend Dockerfile (PHP-FPM on :9000, code in /var/www/html)" "${BACKEND_DIR}/Dockerfile" dp_v_reldir
    dp_ask BACKEND_CONTEXT "Backend build context" "$BACKEND_DIR" dp_v_reldir
    if dp_fe_on; then
      local ctx="$FRONTEND_DIR"
      [[ -f "${REPO_ROOT}/pnpm-workspace.yaml" ]] && ctx="."
      dp_ask FRONTEND_DOCKERFILE "Frontend Dockerfile (serves on :3000; NEXT_PUBLIC_* arrive as build args)" "${FRONTEND_DIR}/Dockerfile" dp_v_reldir
      dp_ask FRONTEND_CONTEXT "Frontend build context" "$ctx" dp_v_reldir
    fi
  else
    # The kit runs its own PHP-FPM pool for the app (as this user), so only the version is asked.
    dp_ask PHP_VERSION "PHP version for the app (a dedicated PHP-FPM pool is created)" "$(dp_php_default_ver)" dp_v_php_ver
    if dp_fe_on; then
      _dp_fe_cmds
      dp_ask FRONTEND_INSTALL_CMD "Frontend install command (run from the repo root)" "$FE_INSTALL_DEF"
      dp_ask FRONTEND_BUILD_CMD "Frontend build command (needs output: 'standalone')" "$FE_BUILD_DEF"
    fi
  fi
}

# Each data component: docker (container here), native (installed here) or external.
dp_ask_components() {
  dp_section "Components (docker = container on this server, native = installed on this server, external = elsewhere)"
  dp_choose DB_ENGINE "Database engine (pgsql = PostgreSQL, mysql = MySQL/MariaDB)" pgsql pgsql mysql
  dp_choose DB_MODE "Database" docker docker native external
  if [[ "$DB_MODE" != external && ! ( "$DB_ENGINE" == mysql && "$DB_MODE" == native ) ]]; then
    dp_ask DB_VERSION "$([[ $DB_ENGINE == mysql ]] && echo MariaDB || echo PostgreSQL) major version" "$(_dp_db_version_default)" dp_v_db_ver
  fi
  dp_choose REDIS_MODE "Redis for cache/session/queue (none = use the database)" docker docker native external none
  dp_choose STORAGE_MODE "File storage (minio-* = bundled MinIO; s3 = external S3/R2/B2; local = disk)" minio-docker minio-docker minio-native s3 local
  if [[ "$REDIS_MODE" == none ]]; then
    [[ "$(dp_saved QUEUE_WORKER)" == horizon ]] && S_QUEUE_WORKER=worker
    [[ "${QUEUE_WORKER:-}" == horizon ]] && dp_die "QUEUE_WORKER=horizon needs Redis"
    dp_choose QUEUE_WORKER "Queue worker (Horizon needs Redis; worker = queue:work)" worker worker none
  else
    dp_choose QUEUE_WORKER "Queue worker: horizon = Laravel Horizon; worker = plain queue:work; none" horizon horizon worker none
  fi
  dp_choose SCHEDULER_ENABLED "Run the Laravel scheduler (schedule:work)?" y y n
}

# What a deploy runs besides build/migrate/restart. Defaults are detected from the repo.
dp_ask_deploy_steps() {
  dp_section "Deploy steps"
  local be="${REPO_ROOT}/${BACKEND_DIR}" hp hint=()
  hp="$(sed -nE "s/.*health: *['\"]([^'\"]+)['\"].*/\1/p" "${be}/bootstrap/app.php" 2>/dev/null | head -1)"
  dp_ask HEALTH_PATH "API path that must answer 200 after a deploy" "${hp:-/up}"
  # Suggest artisan commands the app ships (API docs, *:sync catalogues); nothing runs unless typed.
  grep -q '"darkaonline/l5-swagger"' "${be}/composer.json" 2>/dev/null && hint+=("l5-swagger:generate")
  while IFS= read -r c; do hint+=("$c"); done < <(grep -rhoE "signature *= *'[a-z0-9-]+:sync[a-z0-9:-]*" "${be}/app" "${be}/packages" "${be}/src" 2>/dev/null \
    | sed -E "s/.*'//" | sort -u)
  (( ${#hint[@]} )) && dp_info "Artisan commands found in the app that deploys often run: ${hint[*]}"
  dp_ask POST_DEPLOY_ARTISAN "Extra artisan commands after migrate, ';'-separated (none = no extra steps)" none
  local adm="${SEED_ADMIN_CLASS:+db:seed --force --class=${SEED_ADMIN_CLASS}}" sig
  if [[ -z "$adm" && -f "${be}/database/seeders/AdminSeeder.php" ]]; then adm="db:seed --force --class=Database\\Seeders\\AdminSeeder"; fi
  if [[ -z "$adm" ]]; then
    sig="$(grep -rhoE "signature *= *'[a-z0-9-]*:?(create|make)-?(staff|admin|super-?admin|user)[^']*" "${be}/app" "${be}/packages" "${be}/src" 2>/dev/null | head -1 | sed -E "s/.*'//" || true)"
    adm="${sig:-none}"
  fi
  dp_ask SEED_ADMIN_CMD "Artisan command 'setup.sh seed-admin' runs to create the first admin ({x} = asked each time; none = not used)" "$adm"
  [[ "$QUEUE_WORKER" == worker ]] && dp_ask QUEUE_WORK_ARGS "Options for queue:work" "--sleep=3 --tries=3 --max-time=3600"
  if dp_fe_on && [[ "$RUNTIME" == native ]]; then
    local nv; nv="$(cat "${REPO_ROOT}/.nvmrc" "${REPO_ROOT}/.node-version" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    dp_ask NODE_VERSION "Node.js major version to install if Node is missing" "${nv:-22}" dp_v_node_major
  fi
  return 0
}
dp_v_node_major() { [[ "$1" =~ ^[0-9]{2}$ ]]; }
dp_v_db_ver() { [[ "$1" =~ ^[0-9]{1,2}(\.[0-9]+)?$ ]]; }

# Database major version to suggest: what the repo's CI/DDEV/compose use; an existing install
# keeps what it runs (the kit's old defaults), since a new major does not read old data.
_dp_db_version_default() {
  local v="" f
  if [[ -n "$(dp_saved PROJECT_SLUG)" ]]; then
    if [[ "$DB_MODE" == native ]] && command -v psql >/dev/null 2>&1; then
      psql --version | grep -oE '[0-9]+' | head -1; return 0
    fi
    [[ "$DB_ENGINE" == mysql ]] && echo 11 || echo 16; return 0
  fi
  for f in "${REPO_ROOT}"/.github/workflows/*.y*ml "${REPO_ROOT}"/docker-compose*.y*ml "${REPO_ROOT}"/compose*.y*ml; do
    [[ -f "$f" ]] || continue
    v="$(grep -oE "$([[ $DB_ENGINE == mysql ]] && echo 'mariadb:[0-9]+(\.[0-9]+)?' || echo 'postgres:[0-9]+')" "$f" | head -1 | cut -d: -f2)"
    [[ -n "$v" ]] && break
  done
  if [[ -z "$v" && -f "${REPO_ROOT}/.ddev/config.yaml" ]]; then
    v="$(sed -n '/^database:/,/^[a-z]/p' "${REPO_ROOT}/.ddev/config.yaml" | sed -nE 's/^ *version: *"?([0-9.]+)"?.*/\1/p' | head -1)"
  fi
  echo "${v:-$([[ $DB_ENGINE == mysql ]] && echo 11 || echo 17)}"
}

# Server-side settings for one env's Next.js server (not NEXT_PUBLIC_*), e.g. API_PROXY_TARGET.
# Stored as <ENV>_FRONTEND_ENV="K=v; K2=v2" and written to <env>/frontend.env on deploy.
dp_ask_frontend_env() {
  dp_fe_on || return 0
  local env="$1" up def="" k api
  up="$(dp_env_upper "$env")"; api="${up}_API_PORT"
  # process.env.X read by next.config (rewrites/redirects are fixed at build time).
  for k in $(grep -ohE 'process\.env\.[A-Z][A-Z0-9_]*' "${REPO_ROOT}/${FRONTEND_DIR}"/next.config.* 2>/dev/null \
    | sed 's/process\.env\.//' | grep -vE '^(NODE_ENV|NEXT_PUBLIC_.*|PORT|HOSTNAME)$' | sort -u); do
    case "$k" in
      *API*|*BACKEND*|*PROXY*) def+="${def:+; }${k}=http://127.0.0.1:${!api:-8100}" ;;
      *) def+="${def:+; }${k}=" ;;
    esac
  done
  dp_ask "${up}_FRONTEND_ENV" "${env} frontend server settings, 'KEY=value; KEY2=value' (none = nothing)" "${def:-none}"
}

dp_ask_edge() {
  dp_section "Public edge"
  dp_choose EDGE_MODE "certbot = nginx + Let's Encrypt; byo = nginx + your cert; panel = existing panel proxies to loopback ports" certbot certbot byo panel
  if [[ "$EDGE_MODE" != "panel" ]]; then
    dp_ask PUBLIC_HTTP_PORT "Public HTTP port" 80 dp_v_port
    dp_ask PUBLIC_HTTPS_PORT "Public HTTPS port" 443 dp_v_port
  else
    PUBLIC_HTTP_PORT=80
    dp_ask PUBLIC_HTTPS_PORT "HTTPS port the panel serves on (used in generated URLs)" 443 dp_v_port
  fi
  [[ "$EDGE_MODE" == "certbot" ]] && dp_ask_required CERTBOT_EMAIL "Let's Encrypt account email" "" dp_v_email
  if [[ "$EDGE_MODE" == "byo" ]]; then
    dp_ask_required TLS_CERT "TLS certificate (fullchain) path covering all hosts" "" dp_v_path
    dp_ask_required TLS_KEY "TLS private key path" "" dp_v_path
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
  for k in DB_LOCAL_PORT REDIS_PORT MINIO_PORT MINIO_CONSOLE_PORT; do
    v="${!k:-$(dp_saved "$k")}"; [[ -n "$v" ]] && dp_claim_port "$v"
  done
  # Ports of other projects on this server, even while their services are stopped.
  for v in $(dp_other_project_values '[A-Z0-9_]+_(API|FRONTEND)_PORT|DB_LOCAL_PORT|REDIS_PORT|MINIO_PORT|MINIO_CONSOLE_PORT'); do
    dp_claim_port "$v"
  done
  return 0
}

dp_ask_env_hosts() {
  local env="$1" up fe_def api_def br_def
  up="$(dp_env_upper "$env")"
  if [[ -n "${ROOT_DOMAIN:-}" ]]; then
    if [[ "$env" == "production" ]]; then fe_def="$ROOT_DOMAIN" api_def="api.${ROOT_DOMAIN}"
    else fe_def="${env}.${ROOT_DOMAIN}" api_def="api-${env}.${ROOT_DOMAIN}"; fi
    dp_fe_on || { [[ "$env" == production ]] && api_def="api.${ROOT_DOMAIN}"; }
  fi
  case "$env" in production) br_def=main ;; *) br_def="$env" ;; esac
  dp_section "Environment: ${env}"
  if dp_fe_on; then
    dp_ask "${up}_FRONTEND_HOST" "${env} client (frontend) domain" "${fe_def:-}" dp_v_host
  fi
  dp_ask "${up}_API_HOST" "${env} API domain$(dp_fe_on && echo ' (must differ from the client domain)')" "${api_def:-}" dp_v_host
  local fe="${up}_FRONTEND_HOST" api="${up}_API_HOST"
  dp_fe_on && { [[ "${!fe}" != "${!api}" ]] || dp_die "${env}: client and API domains must differ"; }
  dp_ask "${up}_BRANCH" "${env} git branch" "$br_def"
  dp_claim_known_ports "$env"
  dp_ask_port "${up}_API_PORT" "${env} API loopback port" 8100
  dp_fe_on && dp_ask_port "${up}_FRONTEND_PORT" "${env} frontend loopback port" 3100
  local rdb="${up}_REDIS_DB"
  if [[ -z "${!rdb:-}" ]]; then printf -v "$rdb" '%s' "$(dp_saved "$rdb")"; fi
  if [[ -z "${!rdb:-}" ]]; then
    local used="" e n=0 k
    for e in $ENABLED_ENVS; do k="$(dp_env_upper "$e")_REDIS_DB"; used+=" ${!k:-$(dp_saved "$k")} "; done
    # A shared Redis (native/external): skip DB numbers other projects already use.
    used+=" $(dp_other_project_values '[A-Z0-9_]+_REDIS_DB' | tr '\n' ' ') "
    while [[ "$used" == *" $n "* ]]; do n=$((n + 1)); done
    printf -v "$rdb" '%s' "$n"
  fi
  dp_ask_env_db "$env"
}

dp_ask_env_db() {
  local env="$1" up; up="$(dp_env_upper "$env")"
  if [[ "$DB_MODE" == "external" ]]; then
    dp_ask_required "${up}_DB_HOST" "${env} database host" "127.0.0.1"
    dp_ask_required "${up}_DB_PORT" "${env} database port" "$(dp_db_default_port)" dp_v_port
    dp_ask_required "${up}_DB_DATABASE" "${env} database name" "$(dp_db_name "$env")"
    dp_ask_required "${up}_DB_USERNAME" "${env} database user" "$(dp_db_name "$env")"
  fi
  dp_ask_secret "DB_PASSWORD_${up}" "${env} database password" "$([[ $DB_MODE == external ]] && echo 0 || echo 1)"
}

dp_ask_services() {
  dp_section "Service settings"
  case "$DB_MODE" in
    docker)
      dp_ask_port DB_LOCAL_PORT "Database loopback port" "$(dp_db_default_port)"
      if [[ "$DB_ENGINE" == mysql ]]; then DB_ROOT_USER=root
      else dp_ask DB_ROOT_USER "PostgreSQL superuser" "$(dp_env_snake "$PROJECT_SLUG")_admin"; fi
      dp_ask_secret DB_ROOT_PASSWORD "Database admin password" 1 ;;
    native) DB_LOCAL_PORT="$(dp_db_default_port)" ;;
  esac
  case "$REDIS_MODE" in
    docker) dp_ask_port REDIS_PORT "Redis loopback port" 6379; dp_ask_secret REDIS_PASSWORD "Redis password" 1 ;;
    native) REDIS_PORT=6379
      # The host's Redis is shared: keep its current password so other apps keep working.
      if [[ -z "${REDIS_PASSWORD:-}" && -z "$(dp_saved REDIS_PASSWORD)" ]]; then
        local cur; cur="$(dp_native_redis_password)"
        [[ -n "$cur" ]] && { REDIS_PASSWORD="$cur"; dp_info "Using the existing Redis password (shared with other apps on this server)."; }
      fi
      dp_ask_secret REDIS_PASSWORD "Redis password (set as requirepass)" 1 ;;
    external)
      dp_ask_required REDIS_HOST "Redis host" "127.0.0.1"
      dp_ask_required REDIS_PORT "Redis port" 6379 dp_v_port
      dp_ask_secret REDIS_PASSWORD "Redis password" 0 ;;
  esac
  if dp_minio_on; then
    dp_ask_port MINIO_PORT "MinIO API port" 9000
    dp_ask_port MINIO_CONSOLE_PORT "MinIO console port (loopback)" 9001
    dp_ask MINIO_ROOT_USER "MinIO root user" "$(dp_env_snake "$PROJECT_SLUG")_minio"
    dp_ask_secret MINIO_ROOT_PASSWORD "MinIO root password" 1
    dp_ask MEDIA_HOST "Public media domain for uploads (blank = none)" "${ROOT_DOMAIN:+media.${ROOT_DOMAIN}}" dp_v_host_opt
  else
    MEDIA_HOST=""
  fi
  dp_ask BACKUP_ENVS "Back up the database before migrating in these envs" "production staging"
  dp_ask BACKUP_KEEP "Backups to keep per env" 10
}

DP_STATE_KEYS=(OS_FAMILY PROJECT_SLUG APP_HOME REPO_URL REPO_PATH RUNTIME EDGE_MODE PUBLIC_HTTP_PORT PUBLIC_HTTPS_PORT
  CERTBOT_EMAIL TLS_CERT TLS_KEY PHP_VERSION FPM_SOCK FPM_SERVICE ROOT_DOMAIN ENABLED_ENVS MEDIA_HOST
  BACKEND_DIR FRONTEND_ENABLED FRONTEND_DIR API_PREFIX BACKEND_DOCKERFILE BACKEND_CONTEXT FRONTEND_DOCKERFILE FRONTEND_CONTEXT
  FRONTEND_INSTALL_CMD FRONTEND_BUILD_CMD HEALTH_PATH POST_DEPLOY_ARTISAN QUEUE_WORK_ARGS NODE_VERSION SEED_ADMIN_CMD FRONTEND_API_MODE
  DB_ENGINE DB_VERSION DB_MODE REDIS_MODE STORAGE_MODE QUEUE_WORKER SCHEDULER_ENABLED
  DB_LOCAL_PORT DB_ROOT_USER REDIS_HOST REDIS_PORT MINIO_PORT MINIO_CONSOLE_PORT MINIO_ROOT_USER BACKUP_ENVS BACKUP_KEEP)

dp_save_state() {
  mkdir -p "${APP_HOME}/shared"; chmod 700 "$APP_HOME" "${APP_HOME}/shared"
  [[ -f "$(dp_state_file)" ]] || install -m 600 /dev/null "$(dp_state_file)"
  [[ -f "$(dp_secrets_file)" ]] || install -m 600 /dev/null "$(dp_secrets_file)"
  local k env up
  for k in "${DP_STATE_KEYS[@]}"; do
    declare -p "$k" >/dev/null 2>&1 && dp_state_set "$k" "${!k}"
  done
  for env in $ENABLED_ENVS; do
    up="$(dp_env_upper "$env")"
    for k in FRONTEND_HOST API_HOST BRANCH API_PORT FRONTEND_PORT FRONTEND_ENV REDIS_DB DB_HOST DB_PORT DB_DATABASE DB_USERNAME; do
      local v="${up}_${k}"; declare -p "$v" >/dev/null 2>&1 && dp_state_set "$v" "${!v}"
    done
    local pw="DB_PASSWORD_${up}"; declare -p "$pw" >/dev/null 2>&1 && dp_secret_set "$pw" "${!pw}"
  done
  for k in DB_ROOT_PASSWORD REDIS_PASSWORD MINIO_ROOT_PASSWORD; do declare -p "$k" >/dev/null 2>&1 && dp_secret_set "$k" "${!k}"; done
  printf 'APP_HOME=%s\nREPO_PATH=%s\n' "$APP_HOME" "$REPO_PATH" >"${HOME}/.${PROJECT_SLUG}.deploy"
  chmod 600 "${HOME}/.${PROJECT_SLUG}.deploy"
}

dp_summary() {
  dp_section "Review"
  printf '  %-18s %s\n' os "$(dp_os_name) (${OS_FAMILY})" project "$PROJECT_SLUG" home "$APP_HOME" repo "${REPO_URL:-$REPO_PATH}" \
    app "${RUNTIME} runtime, backend ./${BACKEND_DIR}$(dp_fe_on && echo ", frontend ./${FRONTEND_DIR}" || echo ', no frontend')" \
    database "${DB_ENGINE}${DB_VERSION:+ ${DB_VERSION}} (${DB_MODE})" redis "$REDIS_MODE" storage "$STORAGE_MODE" \
    "queue worker" "$QUEUE_WORKER" scheduler "$SCHEDULER_ENABLED" \
    edge "$EDGE_MODE (http ${PUBLIC_HTTP_PORT} / https ${PUBLIC_HTTPS_PORT})" media "${MEDIA_HOST:-<none>}" envs "$ENABLED_ENVS"
  local env
  for env in $ENABLED_ENVS; do
    printf '  %-18s %sapi %s | branch %s | port api %s%s\n' "[$env]" \
      "$(dp_fe_on && echo "client $(dp_origin "$(dp_ev "$env" FRONTEND_HOST)") | ")" "$(dp_origin "$(dp_ev "$env" API_HOST)")" \
      "$(dp_ev "$env" BRANCH)" "$(dp_ev "$env" API_PORT)" "$(dp_fe_on && echo " fe $(dp_ev "$env" FRONTEND_PORT)")"
    printf '  %-18s mail %s | sms %s | payments %s | oauth %s\n' "" "${VALS[$env|MAIL_MAILER]:-?}" \
      "${VALS[$env|SMS_DEFAULT_DRIVER]:-?}" "${VALS[$env|PAYMENT_GATEWAYS]:-none}" "${VALS[$env|OAUTH_PROVIDERS]:-none}"
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

# One credential line: label, user, password, where to use it.
_dp_cred() { printf '  %-22s user %-22s password %s\n' "$1" "${2:--}" "$3"; [[ -z "${4:-}" ]] || printf '  %-22s %s\n' "" "$4"; }

# Print credentials. $1 = space-separated secret names to show (default: all stored).
dp_print_credentials() {
  local only=" ${1:-} " env up k
  _want() { [[ "$only" == "  " || "$only" == *" $1 "* ]] && [[ -n "${!1:-}" ]]; }
  for env in $ENABLED_ENVS; do
    up="$(dp_env_upper "$env")"; k="DB_PASSWORD_${up}"
    _want "$k" || continue
    if [[ "$DB_MODE" == external ]]; then
      _dp_cred "${env} database" "$(dp_ev "$env" DB_USERNAME)" "${!k}" "database $(dp_ev "$env" DB_DATABASE) on $(dp_ev "$env" DB_HOST):$(dp_ev "$env" DB_PORT)"
    else
      _dp_cred "${env} database" "$(dp_db_name "$env")" "${!k}" "database $(dp_db_name "$env") on 127.0.0.1:${DB_LOCAL_PORT} (${DB_ENGINE}, ${DB_MODE})"
    fi
  done
  _want DB_ROOT_PASSWORD && [[ "$DB_MODE" == docker ]] && _dp_cred "Database admin" "$DB_ROOT_USER" "$DB_ROOT_PASSWORD" "127.0.0.1:${DB_LOCAL_PORT} — superuser, for maintenance only"
  _want REDIS_PASSWORD && [[ "$REDIS_MODE" != none ]] && _dp_cred "Redis" "" "$REDIS_PASSWORD" "${REDIS_HOST:-127.0.0.1}:${REDIS_PORT}"
  _want MINIO_ROOT_PASSWORD && dp_minio_on && _dp_cred "MinIO" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" \
    "console http://127.0.0.1:${MINIO_CONSOLE_PORT} (from your computer: ssh -L ${MINIO_CONSOLE_PORT}:127.0.0.1:${MINIO_CONSOLE_PORT} <server>)"
  return 0
}

# After apply: show the passwords generated in this run, once, with a notice.
dp_show_generated() {
  [[ -n "${DP_GENERATED:-}" && -n "${DP_GENERATED// }" ]] || return 0
  dp_section "Generated credentials — save them now"
  printf '%s  These passwords were generated for you and are shown only this once.%s\n' "$DP_C_YEL" "$DP_C_OFF"
  printf '%s  Copy them to your password manager.%s\n\n' "$DP_C_YEL" "$DP_C_OFF"
  dp_print_credentials "$DP_GENERATED"
  echo
  echo "  Stored on this server in $(dp_secrets_file) (chmod 600)."
  echo "  Show them again later: deploy/setup.sh credentials"
}

cmd_credentials() {
  dp_load_existing; dp_reload_state
  dp_yes "Print the stored service passwords on screen?" y || exit 0
  dp_section "Credentials for ${PROJECT_SLUG}"
  dp_print_credentials
  echo; echo "  Source: $(dp_secrets_file)"
}

# Toolchains + Docker for the chosen modes.
dp_prepare_host() {
  dp_needs_docker && dp_install_docker
  [[ "$RUNTIME" == native ]] && dp_native_app_prereqs
  return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_init() {
  dp_load_existing   # first: the saved OS family is the preflight's default
  if [[ "$SKIP_PREFLIGHT" == "1" ]]; then dp_ask_os; else dp_preflight; fi
  dp_ask_project
  dp_ask_app
  dp_ask_components
  dp_ask_deploy_steps
  dp_ask_edge
  dp_section "Environments"
  dp_multiselect ENABLED_ENVS "Which environments should this server host?" "production" "${DP_KNOWN_ENVS[@]}"
  local env prev=""
  for env in $ENABLED_ENVS; do dp_ask_env_hosts "$env"; dp_ask_frontend_env "$env"; done
  dp_ask_services
  for env in $ENABLED_ENVS; do dp_ask_env_vars "$env" "$prev"; prev="$env"; done
  dp_summary
  dp_yes "Apply this configuration?" y DP_APPLY || dp_die "Aborted; nothing written."

  dp_save_state
  dp_reload_state
  dp_prepare_host
  dp_apply_envs $ENABLED_ENVS
  dp_ok "State and env files written under ${APP_HOME}"
  [[ "$SKIP_SERVICES" == "0" ]] && dp_services_apply
  [[ "$SKIP_EDGE" == "0" ]] && dp_edge_apply
  if dp_yes "Run optional server hardening now?" n DP_HARDEN; then dp_harden; fi
  if [[ "$SKIP_DEPLOY" == "0" ]]; then
    dp_multiselect DEPLOY_NOW "Build and deploy now (one after another)" "$ENABLED_ENVS" $ENABLED_ENVS
    dp_deploy_envs $DEPLOY_NOW
  fi
  dp_show_generated
  dp_section "Done"
  echo "  Deploy later:   deploy/deploy.sh <env> [--pull]"
  echo "  Add an env:     deploy/setup.sh add-env staging"
  echo "  Change values:  deploy/setup.sh vars <env> | domains | components | steps | rotate-secrets"
  echo "  CI/CD:          deploy/setup.sh cd-workflow"
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
  dp_ask_frontend_env "$env"
  dp_ask_env_vars "$env" "$(awk '{ print $1 }' <<<"$ENABLED_ENVS")"
  dp_yes "Add ${env}?" y DP_APPLY || dp_die "Aborted."
  dp_save_state; dp_reload_state; dp_apply_envs "$env"
  [[ "$SKIP_SERVICES" == "1" ]] || dp_services_apply
  [[ "$SKIP_EDGE" == "1" ]] || dp_edge_apply
  [[ "$SKIP_DEPLOY" == "1" ]] || { dp_yes "Deploy ${env} now?" y DP_DEPLOY && dp_deploy_envs "$env"; } || true
  dp_show_generated
  dp_info "Remember: add the ${env} branch to .github/workflows/cd.yml if CI should deploy it."
}

dp_stop_env_app() {
  local env="$1" kind
  if command -v docker >/dev/null 2>&1; then
    docker compose -p "${PROJECT_SLUG}-${env}" down --remove-orphans 2>/dev/null || true
    docker compose -p "${PROJECT_SLUG}-${env}-horizon" down 2>/dev/null || true   # older native layout
  fi
  for kind in frontend worker scheduler; do
    dp_userctl disable --now "${PROJECT_SLUG}-${kind}-${env}.service" 2>/dev/null || true
    rm -f "$(dp_user_unit_dir)/${PROJECT_SLUG}-${kind}-${env}.service"
    dp_drop_system_unit "${PROJECT_SLUG}-${kind}-${env}.service"
  done
  dp_userctl daemon-reload 2>/dev/null || true
}

# Remove everything this project installed on the host. Other projects are untouched.
cmd_uninstall() {
  dp_load_existing; dp_reload_state
  local purge=0 env backup
  [[ " ${ARGS[*]:-} " == *" --purge "* ]] && purge=1
  dp_warn "This takes ${PROJECT_SLUG} offline: $(for env in $ENABLED_ENVS; do printf '%s ' "$(dp_ev "$env" API_HOST)"; done)"
  dp_yes "Uninstall ${PROJECT_SLUG}$( ((purge)) && echo " and DELETE ${APP_HOME}")? (databases are kept)" n || dp_die "Aborted."
  for env in $ENABLED_ENVS; do dp_stop_env_app "$env"; done
  dp_nginx_dirs
  # Globs are expanded by root: the deploy user cannot list these directories.
  # PHP-FPM pools: Debian (/etc/php/<v>/fpm/pool.d), RHEL (/etc/php-fpm.d), openSUSE (/etc/php8/fpm/php-fpm.d), Arch (/etc/php/php-fpm.d).
  sudo bash -c 'shopt -s nullglob; for f in "$1"/"$3"--*.conf "$2"/"$3"--*.conf /etc/nginx/conf.d/00-"$3"-map.conf \
      /etc/php/*/fpm/pool.d/dk-"$3".conf /etc/php-fpm.d/dk-"$3".conf /etc/php*/fpm/php-fpm.d/dk-"$3".conf \
      /etc/php/php-fpm.d/dk-"$3".conf /etc/sudoers.d/dk-"$3"; do rm -f "$f"; echo "  removed $f"; done' \
    _ "$DP_NGINX_ENABLED" "$DP_NGINX_AVAIL" "$PROJECT_SLUG"
  if command -v nginx >/dev/null 2>&1; then sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx; fi
  [[ -n "${FPM_SERVICE:-}" ]] && systemctl is-active --quiet "$FPM_SERVICE" && sudo systemctl reload "$FPM_SERVICE"
  rm -f "${HOME}/.${PROJECT_SLUG}.deploy"
  if ((purge)); then
    backup="${HOME}/${PROJECT_SLUG}-settings-$(date +%Y%m%d_%H%M%S).tar.gz"
    tar --exclude='repo' --exclude='*/backend-run' --exclude='*/frontend-run' -czf "$backup" -C "$(dirname "$APP_HOME")" "$(basename "$APP_HOME")" 2>/dev/null \
      && chmod 600 "$backup" && dp_info "Settings, secrets and DB backups saved to ${backup}"
    rm -rf "$APP_HOME"
  fi
  dp_ok "${PROJECT_SLUG} uninstalled. Still yours to remove if unwanted: databases ($(for env in $ENABLED_ENVS; do printf '%s ' "$(dp_db_name "$env")"; done)), panel sites / DNS, and $( ((purge)) && echo "the settings archive" || echo "${APP_HOME}")."
}

cmd_remove_env() {
  local env="${ARGS[0]:-}"; [[ -n "$env" ]] || dp_die "usage: setup.sh remove-env <env>"
  dp_load_existing; dp_reload_state
  dp_env_enabled "$env" || dp_die "${env} is not enabled"
  dp_yes "Stop ${env} and remove its sites/units? (database, files and backups are kept)" n || dp_die "Aborted."
  dp_stop_env_app "$env"
  ENABLED_ENVS="$(tr ' ' '\n' <<<"$ENABLED_ENVS" | grep -vx "$env" | xargs)"
  dp_state_set ENABLED_ENVS "$ENABLED_ENVS"
  [[ "$SKIP_EDGE" == "1" ]] || dp_edge_apply
  dp_ok "${env} disabled. Data kept: $(dp_env_dir "$env"), database $(dp_db_name "$env")."
}

cmd_vars() {
  local env="${ARGS[0]:-}"; [[ -n "$env" ]] || dp_die "usage: setup.sh vars <env>"
  dp_load_existing; dp_reload_state
  dp_env_enabled "$env" || dp_die "${env} is not enabled"
  unset "$(dp_env_upper "$env")_FRONTEND_ENV"
  dp_ask_frontend_env "$env"
  dp_ask_env_vars "$env" ""
  dp_save_state; dp_reload_state
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
  dp_minio_on && { unset MEDIA_HOST; dp_ask MEDIA_HOST "Public media domain (blank = none)" "" dp_v_host_opt; }
  dp_save_state; dp_reload_state
  for env in $ENABLED_ENVS; do dp_write_managed "$env"; done
  [[ "$SKIP_EDGE" == "1" ]] || dp_edge_apply
  dp_info "Rebuild so the frontend picks up new URLs: deploy/deploy.sh <env>"
}

# Run SEED_ADMIN_CMD, asking for each {placeholder} (password-like ones hidden).
cmd_seed_admin() {
  local env="$1" tpl="${SEED_ADMIN_CMD:-}" tok name val args=()
  [[ -z "$tpl" && -n "${SEED_ADMIN_CLASS:-}" ]] && tpl="db:seed --force --class=${SEED_ADMIN_CLASS}"
  [[ -n "$tpl" && "$tpl" != none ]] || dp_die "No admin command set. Choose one with: deploy/setup.sh steps"
  # {arg : description} → {arg}; {--option} / {--option=default} are left to their defaults.
  tpl="$(sed -E -e 's/\{ *([A-Za-z0-9_-]+\??) *:[^}]*\}/{\1}/g' -e 's/\{--[^}]*\}//g' <<<"$tpl")"
  for tok in $tpl; do
    if [[ "$tok" =~ ^\{([A-Za-z0-9_-]+)\??\}$ ]]; then
      name="${BASH_REMATCH[1]}"
      if [[ "$name" =~ pass|secret ]]; then read -r -s -p "  ${name}: " val; echo; else read -r -p "  ${name}: " val; fi
      args+=("$val")
    else
      args+=("$tok")
    fi
  done
  dp_info "artisan ${args[0]} (${env})"
  dp_artisan "$env" "${args[@]}"
}

cmd_steps() {
  dp_load_existing; dp_reload_state
  unset HEALTH_PATH POST_DEPLOY_ARTISAN QUEUE_WORK_ARGS NODE_VERSION SEED_ADMIN_CMD
  dp_ask_deploy_steps
  dp_save_state
  dp_ok "Saved. Used from the next deploy: deploy/deploy.sh <env>"
}

# Write a GitHub Actions CD workflow for this project (envs, branches, slug filled in).
cmd_cd_workflow() {
  dp_load_existing; dp_reload_state
  dp_section "CD workflow (GitHub Actions)"
  dp_choose CD_STYLE "direct = deploy on push; after-ci = deploy when your CI workflow passed (one CI file, path filters)" after-ci direct after-ci
  local tpl="${DP_ROOT}/examples/github-actions-cd.yml" out env br branches="" cases="" opts=""
  if [[ "$CD_STYLE" == after-ci ]]; then
    dp_ask CD_CI_NAME "name: of your CI workflow" CI
    tpl="${DP_ROOT}/examples/github-actions-cd-after-ci.yml"
  fi
  dp_ask CD_OUT "Write the workflow to" "${REPO_ROOT}/.github/workflows/cd.yml"
  for env in $ENABLED_ENVS; do
    br="$(dp_ev "$env" BRANCH)"
    branches+="${branches:+, }${br}"; opts+="${opts:+, }${env}"
    cases+="              ${br}) ENV=${env} ;;\n"
  done
  out="$CD_OUT"; mkdir -p "$(dirname "$out")"
  sed -E -e "s/^( *DEPLOY_SLUG:).*/\1 ${PROJECT_SLUG}/" \
    -e "s/^( *branches:) \[main\]/\1 [${branches}]/" -e "s/^( *options:) \[production\]/\1 [${opts}]/" \
    -e "s/^( *workflows:) \[CI\]/\1 [${CD_CI_NAME:-CI}]/" \
    -e '/^ *# staging\) ENV=staging/d' \
    -e "s/^ *main\) ENV=production ;;$/__CASES__/" "$tpl" \
    | awk -v c="$(printf '%b' "$cases")" -v style="$CD_STYLE" '
        # Replace the example'"'"'s "copy this file" header with a generated one.
        NR == 1 { print; print ""; print "# Generated by deploy/setup.sh cd-workflow (" style "). Re-run it after adding an env."; print "# Needs repo secrets DEPLOY_SSH_HOST, DEPLOY_SSH_USER, DEPLOY_SSH_KEY (DEPLOY_SSH_PORT if not 22)."; skip = 1; next }
        skip && /^on:/ { skip = 0; print "" }
        skip { next }
        /^__CASES__$/ { print c; next } { print }' >"$out"
  dp_ok "Wrote ${out}"
  echo "  Commit it in your app repo, then add the GitHub secrets: DEPLOY_SSH_HOST, DEPLOY_SSH_USER, DEPLOY_SSH_KEY (DEPLOY_SSH_PORT if not 22)."
  [[ "$CD_STYLE" == after-ci ]] && echo "  Your CI workflow must be named '${CD_CI_NAME}' and run on pushes to: ${branches}."
  return 0
}

cmd_components() {
  dp_load_existing; dp_reload_state
  local old="${DB_ENGINE}/${DB_MODE} redis:${REDIS_MODE} storage:${STORAGE_MODE} runtime:${RUNTIME}" env
  # Re-ask with the current values as defaults (saved state pre-fills S_*).
  unset BACKEND_DIR FRONTEND_ENABLED FRONTEND_DIR API_PREFIX RUNTIME BACKEND_DOCKERFILE BACKEND_CONTEXT \
    FRONTEND_DOCKERFILE FRONTEND_CONTEXT PHP_VERSION FPM_SOCK FPM_SERVICE FRONTEND_INSTALL_CMD FRONTEND_BUILD_CMD \
    DB_ENGINE DB_MODE REDIS_MODE STORAGE_MODE QUEUE_WORKER SCHEDULER_ENABLED MEDIA_HOST \
    HEALTH_PATH POST_DEPLOY_ARTISAN QUEUE_WORK_ARGS NODE_VERSION SEED_ADMIN_CMD FRONTEND_API_MODE DB_VERSION OS_FAMILY
  dp_ask_os
  dp_ask_app
  dp_ask_components
  local dbv_old; dbv_old="$(dp_saved DB_VERSION)"
  if [[ -n "$dbv_old" && "${DB_VERSION:-}" != "$dbv_old" && "$DB_MODE" != external ]]; then
    dp_warn "Database version ${dbv_old} → ${DB_VERSION}: existing data is NOT upgraded. Back up first (setup.sh backup <env>), then restore into the new version."
    dp_yes "Change the database version anyway?" n || dp_die "Aborted; nothing changed."
  fi
  dp_ask_deploy_steps
  if [[ "$DB_ENGINE" != "$(dp_saved DB_ENGINE)" ]]; then
    unset DB_LOCAL_PORT S_DB_LOCAL_PORT DB_ROOT_USER S_DB_ROOT_USER   # engine-specific defaults
  fi
  for env in $ENABLED_ENVS; do
    dp_fe_on && [[ -z "$(dp_ev "$env" FRONTEND_HOST)" ]] && { dp_section "Frontend for ${env}"; dp_ask "$(dp_env_upper "$env")_FRONTEND_HOST" "${env} client (frontend) domain" "" dp_v_host; dp_claim_known_ports "$env"; dp_ask_port "$(dp_env_upper "$env")_FRONTEND_PORT" "${env} frontend loopback port" 3100; }
    [[ "$DB_MODE" == external && -z "$(dp_ev "$env" DB_HOST)" ]] && dp_ask_env_db "$env"
  done
  dp_ask_services
  local new="${DB_ENGINE}/${DB_MODE} redis:${REDIS_MODE} storage:${STORAGE_MODE} runtime:${RUNTIME}"
  [[ "$old" == "$new" ]] || dp_warn "Changing ${old} → ${new} does not move data: dump/restore databases and copy buckets yourself."
  dp_yes "Apply?" y DP_APPLY || dp_die "Aborted."
  dp_save_state; dp_reload_state
  dp_prepare_host
  for env in $ENABLED_ENVS; do dp_write_managed "$env" >/dev/null; done
  [[ "$SKIP_SERVICES" == "1" ]] || dp_services_apply
  [[ "$SKIP_EDGE" == "1" ]] || dp_edge_apply
  if [[ "$old" == *"runtime:"* && "$old" != *"runtime:${RUNTIME}" ]]; then
    for env in $ENABLED_ENVS; do dp_stop_env_app "$env"; done
  fi
  dp_show_generated
  dp_info "Review mail/SMS/payment/storage variables with: setup.sh vars <env>"
  [[ "$SKIP_DEPLOY" == "1" ]] || { dp_yes "Redeploy all envs now to apply?" y DP_DEPLOY && dp_deploy_envs $ENABLED_ENVS; } || true
}

cmd_rotate_secrets() {
  dp_load_existing; dp_reload_state
  local what=() env k
  [[ "$DB_MODE" != external ]] && what+=(database)
  [[ "$REDIS_MODE" =~ ^(docker|native)$ ]] && what+=(Redis)
  dp_minio_on && what+=(MinIO)
  (( ${#what[@]} )) || dp_die "Nothing local to rotate; rotate external credentials at the provider, then run: setup.sh vars <env>"
  dp_yes "Generate new ${what[*]} passwords and apply them now? (APP_KEY is not touched)" n || dp_die "Aborted."
  if [[ "$DB_MODE" != external ]]; then
    DP_DB_ROOT_OLD="$DB_ROOT_PASSWORD"
    [[ "$DB_MODE" == docker ]] && { DB_ROOT_PASSWORD="$(dp_gen_secret)"; dp_secret_set DB_ROOT_PASSWORD "$DB_ROOT_PASSWORD"; }
    for env in $ENABLED_ENVS; do k="DB_PASSWORD_$(dp_env_upper "$env")"; printf -v "$k" '%s' "$(dp_gen_secret)"; dp_secret_set "$k" "${!k}"; done
  fi
  if [[ "$REDIS_MODE" == native ]] && dp_other_project_values REDIS_MODE | grep -qx native; then
    dp_warn "Redis password not rotated: the host's Redis is shared with other projects. Rotate it in the Redis/Valkey config (e.g. /etc/redis/redis.conf) and update each app's REDIS_PASSWORD."
  elif [[ "$REDIS_MODE" =~ ^(docker|native)$ ]]; then
    REDIS_PASSWORD="$(dp_gen_secret)"; dp_secret_set REDIS_PASSWORD "$REDIS_PASSWORD"
  fi
  dp_minio_on && { MINIO_ROOT_PASSWORD="$(dp_gen_secret)"; dp_secret_set MINIO_ROOT_PASSWORD "$MINIO_ROOT_PASSWORD"; }
  # Docker Postgres keeps its old superuser password until ALTERed (local socket = trust);
  # MariaDB is altered with the old root password; native services are reconfigured.
  dp_services_apply
  unset DP_DB_ROOT_OLD
  for env in $ENABLED_ENVS; do dp_write_managed "$env" >/dev/null; done
  dp_deploy_envs $ENABLED_ENVS
  DP_GENERATED="REDIS_PASSWORD MINIO_ROOT_PASSWORD"
  if [[ "$DB_MODE" != external ]]; then
    DP_GENERATED+=" DB_ROOT_PASSWORD"
    for env in $ENABLED_ENVS; do DP_GENERATED+=" DB_PASSWORD_$(dp_env_upper "$env")"; done
  fi
  dp_show_generated
}

cmd_status() {
  dp_load_existing; dp_reload_state
  dp_section "${PROJECT_SLUG} — ${RUNTIME} app, ${DB_ENGINE}:${DB_MODE}, redis:${REDIS_MODE}, storage:${STORAGE_MODE}, ${EDGE_MODE} edge"
  local env u
  for env in $ENABLED_ENVS; do
    local api fe sha
    api="$(dp_ev "$env" API_PORT)"; fe="$(dp_ev "$env" FRONTEND_PORT)"; sha="$(dp_ev "$env" DEPLOYED_SHA)"
    printf '  %-12s release %-14s api:%s %s' "$env" "${sha:-<none>}" "$api" \
      "$(curl -fsS -o /dev/null --max-time 5 -H "Host: $(dp_ev "$env" API_HOST)" "http://127.0.0.1:${api}/up" && echo up || echo DOWN)"
    dp_fe_on && printf '  fe:%s %s' "$fe" "$(curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${fe}/" && echo up || echo DOWN)"
    echo
    if [[ "$RUNTIME" == "docker" ]]; then docker compose -p "${PROJECT_SLUG}-${env}" ps --format '    {{.Service}}: {{.State}} {{.Health}}' 2>/dev/null || true
    else
      for u in frontend worker scheduler; do
        dp_userctl cat "${PROJECT_SLUG}-${u}-${env}" >/dev/null 2>&1 && printf '    %s: %s\n' "$u" "$(dp_userctl is-active "${PROJECT_SLUG}-${u}-${env}" 2>/dev/null)"
      done
    fi
    printf '    backups: %s\n' "$(ls "${APP_HOME}/backups/${env}" 2>/dev/null | wc -l | xargs)"
  done
  [[ -n "$(dp_services_profiles)" ]] && dp_services_compose ps --format '  docker {{.Service}}: {{.State}} {{.Health}}' 2>/dev/null
  [[ $REDIS_MODE == native ]] && dp_redis_layout
  for u in $([[ $DB_MODE == native ]] && { [[ $DB_ENGINE == mysql ]] && echo mariadb || dp_pg_service; }) \
           $([[ $REDIS_MODE == native ]] && echo "$DP_REDIS_SERVICE") $([[ "$(dp_minio_mode)" == native ]] && echo "${PROJECT_SLUG}-minio"); do
    printf '  native %s: %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
  done
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
  if dp_needs_docker; then
    command -v docker >/dev/null && docker info >/dev/null 2>&1 && dp_ok "docker reachable" || { dp_warn "docker not reachable by $(id -un)"; rc=1; }
  fi
  if [[ "$RUNTIME" == native ]]; then
    local c; for c in php composer $(dp_fe_on && echo node); do command -v "$c" >/dev/null && dp_ok "$c found" || { dp_warn "$c missing"; rc=1; }; done
  fi
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
    export PROJECT_SLUG
    DP_ENV="$env" DP_NETWORK="$(dp_network)" ENV_FILE="$(dp_env_file "$env")" \
    BACKEND_IMAGE="${PROJECT_SLUG}-backend:${env}-${sha}" FRONTEND_IMAGE="${PROJECT_SLUG}-frontend:${env}-${sha}" \
    API_PORT="$(dp_ev "$env" API_PORT)" FRONTEND_PORT="$(dp_ev "$env" FRONTEND_PORT)" \
    FRONTEND_ENV_FILE="$(dp_env_dir "$env")/frontend.env" DP_FILES_DIR="$(dp_env_dir "$env")/files" \
      docker compose -f "${DP_ROOT}/compose/app.yml" exec -T app php artisan "$@"
  else
    (cd "$(dp_env_dir "$env")/backend-run" && "$(dp_php_bin)" artisan "$@")
  fi
}

case "$CMD" in
  init) cmd_init ;;
  add-env) cmd_add_env ;;
  remove-env) cmd_remove_env ;;
  uninstall) cmd_uninstall ;;
  vars) cmd_vars ;;
  domains) cmd_domains ;;
  components) cmd_components ;;
  steps) cmd_steps ;;
  cd-workflow) cmd_cd_workflow ;;
  edge) dp_load_existing; dp_reload_state; dp_edge_apply ;;
  services) dp_load_existing; dp_reload_state; dp_prepare_host; dp_services_apply ;;
  rotate-secrets) cmd_rotate_secrets ;;
  credentials) cmd_credentials ;;
  harden) dp_load_existing; dp_reload_state; dp_harden ;;
  deploy) exec "${DP_ROOT}/deploy.sh" "${ARGS[@]}" ;;
  migrate) dp_load_existing; dp_reload_state; dp_artisan "${ARGS[0]:?env}" migrate --force ;;
  seed-admin) dp_load_existing; dp_reload_state; cmd_seed_admin "${ARGS[0]:?usage: setup.sh seed-admin <env>}" ;;
  artisan) dp_load_existing; dp_reload_state; dp_artisan "${ARGS[0]:?usage: setup.sh artisan <env> -- <command> [args]}" "${ARGS[@]:1}" ;;
  backup) dp_load_existing; dp_reload_state; dp_backup_db "${ARGS[0]:?env}" ;;
  restore) dp_load_existing; dp_reload_state
    dp_yes "Restore ${ARGS[1]:?file} into ${ARGS[0]:?env}? This overwrites its data." n || dp_die "Aborted."
    dp_backup_db "${ARGS[0]}"; dp_restore_db "${ARGS[0]}" "${ARGS[1]}" ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  export-answers)
    dp_load_existing; dp_reload_state
    out="${ARGS[0]:-${APP_HOME}/answers.env}"
    { grep -vE '_(DEPLOYED|PREV)_SHA=|^(SERVICES_MODE|MINIO_ENABLED|PG_PORT|POSTGRES_SUPERUSER)=' "$(dp_state_file)"
      for env in $ENABLED_ENVS; do
        for key in "${CAT_KEYS[@]}"; do
          [[ "${CAT_KIND[$key]}" =~ ^(required|optional|select|multi)$ ]] || continue
          v="$(dp_env_value "$(dp_env_file "$env")" "$key")"; [[ -n "$v" ]] && echo "$(dp_env_upper "$env")__${key}=$(_dp_quote "$v")"
        done
      done; } >"$out"
    chmod 600 "$out"; dp_ok "Answers written to ${out} (secrets excluded)" ;;
  *) dp_die "unknown command ${CMD} (see --help)" ;;
esac
