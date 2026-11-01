#!/usr/bin/env bash
# Deploy one environment from this checkout (CI/CD and manual).
#
#   deploy/deploy.sh <env> [--pull] [--no-backup] [--rollback]
#     --pull       fetch + hard-reset the checkout to the env's branch first
#     --no-backup  skip the pre-migration database dump
#     --rollback   (docker runtime) restart the previous release's images
#
# Reads <APP_HOME>/project.env (written by deploy/setup.sh). Serialized by a lock;
# every run is appended to <APP_HOME>/shared/deploy.log.
set -euo pipefail
# corepack's pnpm/yarn shims live here (CI shells don't read ~/.bashrc).
export PATH="${HOME}/.local/bin:${PATH}"

DP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DP_ROOT}/.." && pwd)"
for f in ui envfile state system env-urls services backend-run native; do
  # shellcheck source=/dev/null
  source "${DP_ROOT}/lib/${f}.sh"
done

ENV_NAME="" PULL=0 BACKUP=1 ROLLBACK=0
for a in "$@"; do
  case "$a" in
    --pull) PULL=1 ;;
    --no-backup) BACKUP=0 ;;
    --rollback) ROLLBACK=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) dp_die "unknown option ${a}" ;;
    *) ENV_NAME="$a" ;;
  esac
done
[[ -n "$ENV_NAME" ]] || dp_die "usage: deploy.sh <env> [--pull] [--no-backup] [--rollback]"

dp_locate_app_home "$REPO_ROOT" || dp_die "Cannot find project state. Set APP_HOME or run deploy/setup.sh."
dp_state_load
dp_secrets_load
dp_env_enabled "$ENV_NAME" || dp_die "${ENV_NAME} is not enabled (ENABLED_ENVS=${ENABLED_ENVS}). Add it: deploy/setup.sh add-env ${ENV_NAME}"

UP="$(dp_env_upper "$ENV_NAME")"
ENV_DIR="$(dp_env_dir "$ENV_NAME")"
ENV_FILE="$(dp_env_file "$ENV_NAME")"
[[ -f "$ENV_FILE" ]] || dp_die "Missing ${ENV_FILE}. Run deploy/setup.sh."
BACKEND_SRC="${REPO_ROOT}/${BACKEND_DIR}"
FRONTEND_SRC="${REPO_ROOT}/${FRONTEND_DIR}"

# --pull: move the checkout to the env branch, then re-exec the (possibly updated) script.
if [[ "$PULL" == "1" ]]; then
  branch="$(dp_ev "$ENV_NAME" BRANCH)"
  dp_info "Sync checkout to origin/${branch}"
  git -C "$REPO_ROOT" fetch --prune origin "$branch"
  git -C "$REPO_ROOT" checkout -f -B "$branch" "origin/${branch}"
  args=()
  for a in "$@"; do [[ "$a" == "--pull" ]] || args+=("$a"); done
  exec "$0" "${args[@]}"
fi

# --- lock + audit -------------------------------------------------------------
mkdir -p "${APP_HOME}/shared"
exec 9>"${APP_HOME}/shared/deploy.lock"
flock -w 1800 9 || dp_die "Another deploy is still running (lock ${APP_HOME}/shared/deploy.lock)."
SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
STARTED=$SECONDS
RESULT=failed
trap 'echo "$(date -Is) env=${ENV_NAME} sha=${SHA} user=${SUDO_USER:-$USER} result=${RESULT} secs=$((SECONDS - STARTED))" >>"${APP_HOME}/shared/deploy.log"' EXIT
dp_section "Deploy ${ENV_NAME} @ ${SHA} (${RUNTIME} runtime)"

# Keep the env's managed settings in step with state/secrets before building.
dp_write_managed "$ENV_NAME"

HEALTH_HOST="$(dp_ev "$ENV_NAME" API_HOST)"
API_PORT="$(dp_ev "$ENV_NAME" API_PORT)"
FRONTEND_PORT="$(dp_ev "$ENV_NAME" FRONTEND_PORT)"

# Optional parts of the app, as chosen in setup.sh.
DP_ON="" DP_OFF=""
_dp_part() { if [[ "$2" == y ]]; then DP_ON+=" $1"; else DP_OFF+=" $1"; fi; }
_dp_part frontend "$FRONTEND_ENABLED"
_dp_part horizon "$([[ $QUEUE_WORKER == horizon ]] && echo y || echo n)"
_dp_part worker "$([[ $QUEUE_WORKER == worker ]] && echo y || echo n)"
_dp_part scheduler "$SCHEDULER_ENABLED"
QUEUE_WORK_ARGS="${QUEUE_WORK_ARGS:---sleep=3 --tries=3 --max-time=3600}"

dp_health() {
  local i api_ok=0 fe_ok=1
  dp_fe_on && fe_ok=0
  for i in $(seq 1 45); do
    [[ $api_ok == 1 ]] || { curl -fsS -o /dev/null --max-time 5 -H "Host: ${HEALTH_HOST}" "http://127.0.0.1:${API_PORT}${HEALTH_PATH:-/up}" 2>/dev/null && api_ok=1; }
    [[ $fe_ok == 1 ]] || { curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${FRONTEND_PORT}/" 2>/dev/null && fe_ok=1; }
    [[ $api_ok == 1 && $fe_ok == 1 ]] && { dp_ok "health: API :${API_PORT}$(dp_fe_on && echo " and frontend :${FRONTEND_PORT}")"; return 0; }
    sleep 2
  done
  dp_warn "health check failed (api=${api_ok} frontend=${fe_ok})"
  if [[ $api_ok == 0 ]]; then
    dp_warn "API: GET http://127.0.0.1:${API_PORT}${HEALTH_PATH:-/up} (Host: ${HEALTH_HOST}) → $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: ${HEALTH_HOST}" "http://127.0.0.1:${API_PORT}${HEALTH_PATH:-/up}" || echo 'no answer')"
    dp_warn "Laravel 11+ serves /up via health: '/up' in bootstrap/app.php; otherwise set HEALTH_PATH in ${APP_HOME}/project.env to a route that returns 200."
  fi
  return 1
}

dp_maybe_backup() {
  [[ "$BACKUP" == "1" && " ${BACKUP_ENVS:-production staging} " == *" ${ENV_NAME} "* ]] || return 0
  dp_backup_db "$ENV_NAME"
}

# NEXT_PUBLIC_* values of this env: "KEY=value" lines (build args / build env).
dp_public_env() {
  local k
  while IFS= read -r k; do printf '%s=%s\n' "$k" "$(dp_env_value "$ENV_FILE" "$k")"; done \
    < <(grep -oE '^NEXT_PUBLIC_[A-Za-z0-9_]+' "$ENV_FILE" | sort -u)
}

# --- docker runtime -----------------------------------------------------------
# Compose interpolation inputs (exported once; image tags vary per call).
export PROJECT_SLUG ENV_FILE API_PORT FRONTEND_PORT QUEUE_WORK_ARGS
export DP_ENV="$ENV_NAME" DP_NETWORK COMPOSE_PROFILES
COMPOSE_PROFILES="$(echo $DP_ON | tr ' ' ',')"

dp_app_compose() { # <release-sha> compose-args...
  DP_NETWORK="$(dp_network)" BACKEND_IMAGE="${PROJECT_SLUG}-backend:${ENV_NAME}-$1" FRONTEND_IMAGE="${PROJECT_SLUG}-frontend:${ENV_NAME}-$1" \
    docker compose -f "${DP_ROOT}/compose/app.yml" "${@:2}"
}

# Stop parts that were switched off (a disabled profile is not an orphan).
dp_app_prune_off() { # <release-sha>
  [[ -n "${DP_OFF// }" ]] || return 0
  COMPOSE_PROFILES=frontend,horizon,worker,scheduler dp_app_compose "$1" rm -sf $DP_OFF >/dev/null 2>&1 || true
}

# Ask the running worker to finish its jobs and exit before the new release starts.
dp_worker_drain() { # <release-sha>
  [[ -n "$1" ]] || return 0
  case "$QUEUE_WORKER" in
    horizon) dp_app_compose "$1" exec -T horizon php artisan horizon:terminate 2>/dev/null || true ;;
    worker) dp_app_compose "$1" exec -T worker php artisan queue:restart 2>/dev/null || true ;;
  esac
}

deploy_docker() {
  local prev; prev="$(dp_ev "$ENV_NAME" DEPLOYED_SHA)"
  if [[ "$ROLLBACK" == "1" ]]; then
    local target; target="$(dp_ev "$ENV_NAME" PREV_SHA)"
    [[ -n "$target" ]] || dp_die "No previous release recorded for ${ENV_NAME}."
    dp_info "Rolling back ${ENV_NAME} to ${target} (database migrations are NOT reverted)"
    dp_app_compose "$target" up -d --remove-orphans
    dp_app_prune_off "$target"
    dp_health || dp_die "rollback release is unhealthy too"
    dp_state_set "${UP}_DEPLOYED_SHA" "$target"; dp_state_set "${UP}_PREV_SHA" "$prev"
    SHA="$target"; RESULT=rolled-back; return 0
  fi

  dp_ensure_network
  dp_info "Build backend image (${BACKEND_DOCKERFILE})"
  docker build -q -t "${PROJECT_SLUG}-backend:${ENV_NAME}-${SHA}" -f "${REPO_ROOT}/${BACKEND_DOCKERFILE}" "${REPO_ROOT}/${BACKEND_CONTEXT}" >/dev/null
  if dp_fe_on; then
    local bargs=() kv
    while IFS= read -r kv; do bargs+=(--build-arg "$kv"); done < <(dp_public_env)
    dp_info "Build frontend image (${FRONTEND_DOCKERFILE}; ${#bargs[@]} NEXT_PUBLIC_* args)"
    docker build -q -t "${PROJECT_SLUG}-frontend:${ENV_NAME}-${SHA}" -f "${REPO_ROOT}/${FRONTEND_DOCKERFILE}" \
      "${bargs[@]}" "${REPO_ROOT}/${FRONTEND_CONTEXT}" >/dev/null
  fi

  dp_maybe_backup
  dp_info "Migrate"
  dp_app_compose "$SHA" run --rm -T app php artisan migrate --force
  dp_worker_drain "$prev"
  dp_info "Start release ${SHA} (app, nginx${DP_ON// /, })"
  dp_app_compose "$SHA" up -d --remove-orphans
  dp_app_prune_off "$SHA"

  if ! dp_health; then
    if [[ -n "$prev" ]]; then
      dp_warn "Rolling back to ${prev} (migrations are not reverted)"
      dp_app_compose "$prev" up -d --remove-orphans
      dp_health || true
    fi
    dp_die "Release ${SHA} failed its health check."
  fi
  [[ "$prev" != "$SHA" ]] && dp_state_set "${UP}_PREV_SHA" "$prev"
  dp_state_set "${UP}_DEPLOYED_SHA" "$SHA"

  # Keep the 3 newest image tags per env.
  local repo
  for repo in backend $(dp_fe_on && echo frontend); do
    docker image ls --format '{{.Repository}}:{{.Tag}} {{.CreatedAt}}' "${PROJECT_SLUG}-${repo}" \
      | grep " " | grep ":${ENV_NAME}-" | sort -k2 -r | awk 'NR > 3 { print $1 }' | xargs -r docker image rm >/dev/null 2>&1 || true
  done
}

# --- native runtime -----------------------------------------------------------
DP_UNITS=() DP_UNITS_CHANGED=0
# Write (or remove when off) one systemd user unit for this env: <kind> <y|n> <template> sed-args...
_dp_unit() {
  local kind="$1" on="$2" tpl="$3" unit="${PROJECT_SLUG}-${1}-${ENV_NAME}.service" dir dest want; shift 3
  dir="$(dp_user_unit_dir)"; dest="${dir}/${unit}"
  dp_drop_system_unit "$unit"
  if [[ "$on" != y ]]; then
    [[ -e "$dest" ]] || return 0
    dp_userctl disable --now "$unit" 2>/dev/null || true
    rm -f "$dest"; DP_UNITS_CHANGED=1
    return 0
  fi
  want="$(sed -e "s|__SLUG__|${PROJECT_SLUG}|g" -e "s|__ENV__|${ENV_NAME}|g" "$@" "${DP_ROOT}/systemd/${tpl}")"
  if [[ "$(cat "$dest" 2>/dev/null)" != "$want" ]]; then
    mkdir -p "$dir"; printf '%s\n' "$want" >"$dest"; DP_UNITS_CHANGED=1
  fi
  DP_UNITS+=("$unit")
}

# PHP-FPM is a system service. A reload clears OPcache right away; without passwordless
# sudo (CI) it is skipped and OPcache picks up changed files on its own revalidation.
_dp_reload_fpm() {
  [[ -n "${FPM_SERVICE:-}" ]] || return 0
  sudo -n systemctl reload "$FPM_SERVICE" 2>/dev/null && return 0
  if [[ -t 2 ]]; then
    # Manual deploy on a setup from before the kit managed this: install the rule now.
    dp_native_sudoers
    sudo systemctl reload "$FPM_SERVICE"; return
  fi
  dp_warn "Skipped 'systemctl reload ${FPM_SERVICE}' (no passwordless sudo yet). Run one deploy by hand, or: deploy/setup.sh edge"
}

deploy_native() {
  [[ "$ROLLBACK" == "0" ]] || dp_die "--rollback is only available for the docker runtime."
  local php_bin node_bin=""
  php_bin="$(dp_php_bin)" || dp_die "php not found (run: deploy/setup.sh services)"
  command -v composer >/dev/null 2>&1 || dp_die "composer not found"

  dp_info "Backend dependencies (${BACKEND_DIR})"
  (cd "$BACKEND_SRC" && "$php_bin" "$(command -v composer)" install --no-dev --optimize-autoloader --no-interaction --quiet)
  dp_publish_backend "$ENV_DIR" "$BACKEND_SRC" "$ENV_FILE"

  dp_maybe_backup
  dp_info "Migrate + caches"
  (cd "$BACKEND_RUN" && "$php_bin" artisan migrate --force && "$php_bin" artisan config:cache \
    && "$php_bin" artisan route:cache && "$php_bin" artisan view:cache && "$php_bin" artisan event:cache)
  dp_verify_backend_config "$BACKEND_RUN" "$(dp_env_value "$ENV_FILE" APP_URL)" "$(dp_fe_on && dp_env_value "$ENV_FILE" FRONTEND_URL)"

  if dp_fe_on; then
    node_bin="$(command -v node)" || dp_die "node not found"
    local pub=() kv
    while IFS= read -r kv; do pub+=("$kv"); done < <(dp_public_env)
    if [[ "$FRONTEND_INSTALL_CMD$FRONTEND_BUILD_CMD" =~ (pnpm|yarn) ]] && ! command -v "${BASH_REMATCH[1]}" >/dev/null 2>&1; then
      # Into a user-owned dir: a global Node (nvm under /opt, distro /usr) is not writable.
      mkdir -p "${HOME}/.local/bin"
      corepack enable --install-directory "${HOME}/.local/bin" "${BASH_REMATCH[1]}"
    fi
    dp_info "Frontend install + build (${FRONTEND_DIR})"
    (cd "$REPO_ROOT" && bash -c "$FRONTEND_INSTALL_CMD" >/dev/null \
      && env "${pub[@]}" NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1536}" bash -c "$FRONTEND_BUILD_CMD")
    dp_publish_frontend "$ENV_DIR" "$FRONTEND_SRC"
  fi

  # Layout before queue workers ran under systemd: a Horizon container per env.
  command -v docker >/dev/null 2>&1 && { docker compose -p "${PROJECT_SLUG}-${ENV_NAME}-horizon" down >/dev/null 2>&1 || true; }

  dp_info "systemd units (${DP_ON# })"
  local worker_cmd="horizon"
  [[ "$QUEUE_WORKER" == worker ]] && worker_cmd="queue:work ${QUEUE_WORK_ARGS}"
  _dp_unit frontend "$FRONTEND_ENABLED" frontend.service.tmpl \
    -e "s|__PORT__|${FRONTEND_PORT}|g" -e "s|__NODE__|${node_bin}|g" -e "s|__RUN__|${FRONTEND_RUN:-}|g" -e "s|__ENTRY__|${FRONTEND_ENTRY:-}|g"
  _dp_unit worker "$([[ $QUEUE_WORKER != none ]] && echo y || echo n)" artisan.service.tmpl \
    -e "s|__DESC__|queue worker (${QUEUE_WORKER})|g" -e "s|__CMD__|${worker_cmd}|g" -e "s|__PHP__|${php_bin}|g" -e "s|__RUN__|${BACKEND_RUN}|g"
  _dp_unit scheduler "$SCHEDULER_ENABLED" artisan.service.tmpl \
    -e "s|__DESC__|scheduler|g" -e "s|__CMD__|schedule:work|g" -e "s|__PHP__|${php_bin}|g" -e "s|__RUN__|${BACKEND_RUN}|g"
  if (( ${#DP_UNITS[@]} )) || (( DP_UNITS_CHANGED )); then
    dp_ensure_linger
    dp_userctl daemon-reload
    (( ${#DP_UNITS[@]} )) && dp_userctl enable "${DP_UNITS[@]}" >/dev/null 2>&1
  fi
  if (( ${#DP_UNITS[@]} )); then
    [[ "$QUEUE_WORKER" == horizon ]] && { (cd "$BACKEND_RUN" && "$php_bin" artisan horizon:terminate >/dev/null 2>&1) || true; }
    dp_userctl restart "${DP_UNITS[@]}"
  fi
  _dp_reload_fpm

  dp_health || dp_die "Release ${SHA} failed its health check."
  dp_state_set "${UP}_DEPLOYED_SHA" "$SHA"
}

if [[ "$RUNTIME" == "docker" ]]; then deploy_docker; else deploy_native; fi
dp_check_cors "$ENV_NAME" || true
RESULT=${RESULT/failed/ok}
dp_ok "Deployed ${ENV_NAME} @ ${SHA}"
