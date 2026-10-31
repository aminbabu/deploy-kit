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

DP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DP_ROOT}/.." && pwd)"
for f in ui envfile state system env-urls services backend-run; do
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

dp_health() {
  local i api_ok=0 fe_ok=0
  for i in $(seq 1 45); do
    [[ $api_ok == 1 ]] || { curl -fsS -o /dev/null --max-time 5 -H "Host: ${HEALTH_HOST}" "http://127.0.0.1:${API_PORT}/up" && api_ok=1; }
    [[ $fe_ok == 1 ]] || { curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${FRONTEND_PORT}/" && fe_ok=1; }
    [[ $api_ok == 1 && $fe_ok == 1 ]] && { dp_ok "health: API :${API_PORT} and frontend :${FRONTEND_PORT}"; return 0; }
    sleep 2
  done
  dp_warn "health check failed (api=${api_ok} frontend=${fe_ok})"
  return 1
}

dp_maybe_backup() {
  [[ "$BACKUP" == "1" && " ${BACKUP_ENVS:-production staging} " == *" ${ENV_NAME} "* ]] || return 0
  dp_backup_db "$ENV_NAME"
}

# --- docker runtime -----------------------------------------------------------
# Compose interpolation inputs (exported once; image tags vary per call).
export PROJECT_SLUG ENV_FILE API_PORT FRONTEND_PORT
export DP_ENV="$ENV_NAME" DP_NETWORK; DP_NETWORK="$(dp_network)"

dp_app_compose() { # <release-sha> compose-args...
  BACKEND_IMAGE="${PROJECT_SLUG}-backend:${ENV_NAME}-$1" FRONTEND_IMAGE="${PROJECT_SLUG}-frontend:${ENV_NAME}-$1" \
    docker compose -f "${DP_ROOT}/compose/app.yml" "${@:2}"
}

deploy_docker() {
  local prev; prev="$(dp_ev "$ENV_NAME" DEPLOYED_SHA)"
  if [[ "$ROLLBACK" == "1" ]]; then
    local target; target="$(dp_ev "$ENV_NAME" PREV_SHA)"
    [[ -n "$target" ]] || dp_die "No previous release recorded for ${ENV_NAME}."
    dp_info "Rolling back ${ENV_NAME} to ${target} (database migrations are NOT reverted)"
    dp_app_compose "$target" up -d --remove-orphans
    dp_health || dp_die "rollback release is unhealthy too"
    dp_state_set "${UP}_DEPLOYED_SHA" "$target"; dp_state_set "${UP}_PREV_SHA" "$prev"
    SHA="$target"; RESULT=rolled-back; return 0
  fi

  dp_ensure_network
  local nb; nb="$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_ENABLE_DIAGNOSTICS)"
  dp_info "Build backend image"
  docker build -q -t "${PROJECT_SLUG}-backend:${ENV_NAME}-${SHA}" -f "${REPO_ROOT}/backend/Dockerfile" "${REPO_ROOT}/backend" >/dev/null
  dp_info "Build frontend image (NEXT_PUBLIC_* from ${ENV_FILE})"
  docker build -q -t "${PROJECT_SLUG}-frontend:${ENV_NAME}-${SHA}" -f "${REPO_ROOT}/frontend/Dockerfile" \
    --build-arg "NEXT_PUBLIC_SITE_URL=$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_SITE_URL)" \
    --build-arg "NEXT_PUBLIC_API_URL=$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_API_URL)" \
    --build-arg "NEXT_PUBLIC_MINIO_PUBLIC_BASE=$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_MINIO_PUBLIC_BASE)" \
    --build-arg "NEXT_PUBLIC_ENABLE_DIAGNOSTICS=${nb:-false}" "$REPO_ROOT" >/dev/null

  dp_maybe_backup
  dp_info "Migrate"
  dp_app_compose "$SHA" run --rm -T app php artisan migrate --force
  [[ -n "$prev" ]] && dp_app_compose "$prev" exec -T horizon php artisan horizon:terminate 2>/dev/null || true
  dp_info "Start release ${SHA}"
  dp_app_compose "$SHA" up -d --remove-orphans

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
  for repo in backend frontend; do
    docker image ls --format '{{.Repository}}:{{.Tag}} {{.CreatedAt}}' "${PROJECT_SLUG}-${repo}" \
      | grep " " | grep ":${ENV_NAME}-" | sort -k2 -r | awk 'NR > 3 { print $1 }' | xargs -r docker image rm >/dev/null 2>&1 || true
  done
}

# --- host runtime -------------------------------------------------------------
deploy_host() {
  [[ "$ROLLBACK" == "0" ]] || dp_die "--rollback is only available for the docker runtime."
  local php_bin node_bin
  php_bin="$(command -v php)" || dp_die "php not found"
  node_bin="$(command -v node)" || dp_die "node not found"

  dp_info "Backend dependencies"
  (cd "${REPO_ROOT}/backend" && composer install --no-dev --optimize-autoloader --no-interaction --quiet)
  dp_publish_backend "$ENV_DIR" "${REPO_ROOT}/backend" "$ENV_FILE"

  dp_maybe_backup
  dp_info "Migrate + caches"
  (cd "$BACKEND_RUN" && "$php_bin" artisan migrate --force && "$php_bin" artisan config:cache \
    && "$php_bin" artisan route:cache && "$php_bin" artisan view:cache && "$php_bin" artisan event:cache)
  dp_verify_backend_config "$BACKEND_RUN" "$(dp_env_value "$ENV_FILE" APP_URL)" "$(dp_env_value "$ENV_FILE" FRONTEND_URL)"

  dp_info "Frontend build"
  (cd "$REPO_ROOT" && { command -v pnpm >/dev/null 2>&1 || corepack enable; } \
    && pnpm install --frozen-lockfile --filter frontend... >/dev/null \
    && NEXT_PUBLIC_SITE_URL="$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_SITE_URL)" \
       NEXT_PUBLIC_API_URL="$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_API_URL)" \
       NEXT_PUBLIC_MINIO_PUBLIC_BASE="$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_MINIO_PUBLIC_BASE)" \
       NEXT_PUBLIC_ENABLE_DIAGNOSTICS="$(dp_env_value "$ENV_FILE" NEXT_PUBLIC_ENABLE_DIAGNOSTICS)" \
       NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1536}" \
       pnpm --filter frontend build)
  dp_publish_frontend "$ENV_DIR" "$REPO_ROOT"

  dp_info "Horizon container"
  docker build -q -t "${PROJECT_SLUG}-backend:${ENV_NAME}-${SHA}" -f "${REPO_ROOT}/backend/Dockerfile" "${REPO_ROOT}/backend" >/dev/null
  local image="${PROJECT_SLUG}-backend:${ENV_NAME}-${SHA}"
  STORAGE_DIR="${ENV_DIR}/storage" BACKEND_IMAGE="$image" DP_UID="$(id -u)" DP_GID="$(id -g)" \
    docker compose -f "${DP_ROOT}/compose/horizon.yml" up -d --remove-orphans

  dp_info "systemd units"
  local unit kind
  for kind in frontend scheduler; do
    unit="${PROJECT_SLUG}-${kind}-${ENV_NAME}.service"
    sed -e "s|__SLUG__|${PROJECT_SLUG}|g" -e "s|__ENV__|${ENV_NAME}|g" -e "s|__USER__|$(id -un)|g" -e "s|__GROUP__|$(id -gn)|g" \
        -e "s|__PORT__|${FRONTEND_PORT}|g" -e "s|__NODE__|${node_bin}|g" -e "s|__PHP__|${php_bin}|g" \
        -e "s|__RUN__|$([[ $kind == frontend ]] && echo "$FRONTEND_RUN" || echo "$BACKEND_RUN")|g" \
        "${DP_ROOT}/systemd/${kind}.service.tmpl" | sudo tee "/etc/systemd/system/${unit}" >/dev/null
  done
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${PROJECT_SLUG}-frontend-${ENV_NAME}.service" "${PROJECT_SLUG}-scheduler-${ENV_NAME}.service" >/dev/null
  sudo systemctl restart "${PROJECT_SLUG}-frontend-${ENV_NAME}.service" "${PROJECT_SLUG}-scheduler-${ENV_NAME}.service"
  [[ -n "${FPM_SERVICE:-}" ]] && sudo systemctl reload "$FPM_SERVICE"

  dp_health || dp_die "Release ${SHA} failed its health check."
  dp_state_set "${UP}_DEPLOYED_SHA" "$SHA"
}

if [[ "$RUNTIME" == "docker" ]]; then deploy_docker; else deploy_host; fi
dp_check_cors "$ENV_NAME" || true
RESULT=${RESULT/failed/ok}
dp_ok "Deployed ${ENV_NAME} @ ${SHA}"
