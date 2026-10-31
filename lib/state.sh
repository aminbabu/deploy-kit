#!/usr/bin/env bash
# Project state: <APP_HOME>/project.env (no secrets) + pointer ~/.<slug>.deploy.
#
#   PROJECT_SLUG, APP_HOME, REPO_URL, REPO_PATH, EDGE_MODE (certbot|byo|panel), ENABLED_ENVS
#   app:        RUNTIME (docker|native), BACKEND_DIR, FRONTEND_ENABLED, FRONTEND_DIR, Dockerfiles/build cmds
#   components: DB_ENGINE (pgsql|mysql), DB_MODE (docker|native|external),
#               REDIS_MODE (docker|native|external|none), STORAGE_MODE (minio-docker|minio-native|s3|local),
#               QUEUE_WORKER (horizon|worker|none), SCHEDULER_ENABLED (y|n)
#   per env (ENV upper-cased, '-' → '_'): <E>_FRONTEND_HOST, <E>_API_HOST,
#   <E>_BRANCH, <E>_API_PORT, <E>_FRONTEND_PORT, <E>_REDIS_DB, <E>_DB_* (external DB)
#
# Secrets: <APP_HOME>/shared/secrets.env (chmod 600). Env files: <APP_HOME>/<env>/.env.

dp_env_upper() { local e="${1^^}"; printf '%s' "${e//-/_}"; }
dp_env_snake() { printf '%s' "${1//-/_}"; }

dp_state_file() { printf '%s/project.env' "$APP_HOME"; }
dp_secrets_file() { printf '%s/shared/secrets.env' "$APP_HOME"; }
dp_env_dir() { printf '%s/%s' "$APP_HOME" "$1"; }
dp_env_file() { printf '%s/%s/.env' "$APP_HOME" "$1"; }

# Locate APP_HOME: explicit env var, else a pointer whose REPO_PATH is this checkout,
# else the only pointer present.
dp_locate_app_home() {
  local repo="${1:-}" p found=() rp
  [[ -n "${APP_HOME:-}" && -f "${APP_HOME}/project.env" ]] && return 0
  shopt -s nullglob
  for p in "$HOME"/.*.deploy; do
    rp="$(dp_env_value "$p" REPO_PATH)"
    if [[ -n "$repo" && "$(cd "$rp" 2>/dev/null && pwd -P)" == "$(cd "$repo" && pwd -P)" ]]; then
      APP_HOME="$(dp_env_value "$p" APP_HOME)"; shopt -u nullglob; return 0
    fi
    found+=("$p")
  done
  shopt -u nullglob
  if (( ${#found[@]} == 1 )); then
    APP_HOME="$(dp_env_value "${found[0]}" APP_HOME)"; return 0
  fi
  return 1
}

# Map state written by older versions (RUNTIME=host, SERVICES_MODE, MINIO_ENABLED,
# PG_PORT, POSTGRES_SUPER*) onto the per-component settings. $1 = variable prefix.
dp_state_compat() {
  local p="$1" v m k
  v="${p}RUNTIME"; [[ "${!v:-}" == host ]] && printf -v "$v" native
  v="${p}SERVICES_MODE"
  if [[ -n "${!v:-}" ]]; then
    m=docker; [[ "${!v}" == external ]] && m=external
    for k in DB_MODE REDIS_MODE; do k="${p}${k}"; [[ -n "${!k:-}" ]] || printf -v "$k" '%s' "$m"; done
    k="${p}STORAGE_MODE"; v="${p}MINIO_ENABLED"
    if [[ -z "${!k:-}" ]]; then
      if [[ "$m" == docker && "${!v:-y}" == y ]]; then printf -v "$k" minio-docker; else printf -v "$k" local; fi
    fi
  fi
  for k in PG_PORT:DB_LOCAL_PORT POSTGRES_SUPERUSER:DB_ROOT_USER POSTGRES_SUPERPASS:DB_ROOT_PASSWORD; do
    v="${p}${k%%:*}"; m="${p}${k#*:}"
    [[ -n "${!v:-}" && -z "${!m:-}" ]] && printf -v "$m" '%s' "${!v}"
  done
  return 0
}

# Defaults for anything older state does not record.
dp_state_defaults() {
  : "${RUNTIME:=docker}" "${DB_ENGINE:=pgsql}" "${DB_MODE:=docker}" "${REDIS_MODE:=docker}" "${STORAGE_MODE:=minio-docker}"
  : "${QUEUE_WORKER:=horizon}" "${SCHEDULER_ENABLED:=y}" "${FRONTEND_ENABLED:=y}"
  : "${BACKEND_DIR:=backend}" "${FRONTEND_DIR:=frontend}"
  : "${BACKEND_DOCKERFILE:=${BACKEND_DIR}/Dockerfile}" "${BACKEND_CONTEXT:=${BACKEND_DIR}}"
  : "${FRONTEND_DOCKERFILE:=${FRONTEND_DIR}/Dockerfile}" "${FRONTEND_CONTEXT:=.}"
  : "${DB_LOCAL_PORT:=$(dp_db_default_port)}" "${REDIS_PORT:=6379}" "${MINIO_PORT:=9000}" "${MINIO_CONSOLE_PORT:=9001}"
  : "${DB_ROOT_USER:=$([[ $DB_ENGINE == mysql ]] && echo root || echo "$(dp_env_snake "$PROJECT_SLUG")_admin")}"
  return 0
}

# Load saved state into S_* (defaults for the wizard) or plain vars (for deploy).
dp_state_load_saved() {
  dp_env_load_prefixed "$(dp_state_file)" S_; dp_env_load_prefixed "$(dp_secrets_file)" S_
  dp_state_compat S_
}
dp_state_load() {
  dp_env_load_prefixed "$(dp_state_file)" ''
  [[ -n "${PROJECT_SLUG:-}" ]] || dp_die "No project state at $(dp_state_file). Run deploy/setup.sh first."
  dp_state_compat ''
  dp_state_defaults
  # Compose overrides set in project.env (POSTGRES_IMAGE, APP_MEM_LIMIT, …).
  local k
  for k in $(compgen -v | grep -E '_(IMAGE|MEM_LIMIT)$' || true); do export "$k"; done
}
dp_secrets_load() { dp_env_load_prefixed "$(dp_secrets_file)" ''; dp_state_compat ''; }

dp_state_set() { dp_env_set "$(dp_state_file)" "$1" "$2"; }
dp_secret_set() { dp_env_set "$(dp_secrets_file)" "$1" "$2"; }

dp_env_enabled() { [[ " ${ENABLED_ENVS:-} " == *" $1 "* ]]; }

# Per-env state value: dp_ev production API_HOST
dp_ev() { local k; k="$(dp_env_upper "$1")_$2"; printf '%s' "${!k:-}"; }

# https://host[:port] (port omitted for 443/empty)
dp_origin() {
  local host="$1" port="${PUBLIC_HTTPS_PORT:-443}"
  if [[ -n "$port" && "$port" != "443" ]]; then printf 'https://%s:%s' "$host" "$port"; else printf 'https://%s' "$host"; fi
}

dp_db_name() { printf '%s_%s' "$(dp_env_snake "$PROJECT_SLUG")" "$(dp_env_snake "$1")"; }
dp_bucket() { printf '%s-%s' "$PROJECT_SLUG" "$1"; }
dp_network() { printf '%s_data' "$(dp_env_snake "$PROJECT_SLUG")"; }

# --- components -----------------------------------------------------------------
dp_db_default_port() { [[ "${DB_ENGINE:-pgsql}" == mysql ]] && echo 3306 || echo 5432; }
dp_db_connection() { [[ "${DB_ENGINE:-pgsql}" == mysql ]] && echo mysql || echo pgsql; }
dp_minio_mode() { case "${STORAGE_MODE:-}" in minio-docker) echo docker ;; minio-native) echo native ;; esac; }
dp_minio_on() { [[ -n "$(dp_minio_mode)" ]]; }
dp_fe_on() { [[ "${FRONTEND_ENABLED:-y}" == y ]]; }
dp_needs_docker() {
  [[ "$RUNTIME" == docker || "$DB_MODE" == docker || "$REDIS_MODE" == docker || "$(dp_minio_mode)" == docker ]]
}

# Gateway / subnet of the project network: how containers reach services installed
# natively on this host (they listen on loopback + this address).
dp_bridge_ip() {
  dp_ensure_network
  docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$(dp_network)"
}
dp_bridge_subnet() { docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$(dp_network)"; }
dp_ensure_network() {
  docker network inspect "$(dp_network)" >/dev/null 2>&1 || docker network create "$(dp_network)" >/dev/null
}

# Address of a component as the app sees it.
#   dp_svc_host <mode> <compose-service> [external-host]
#   dp_svc_port <mode> <container-port> <host-port>
dp_svc_host() {
  case "$1" in
    docker) [[ "$RUNTIME" == docker ]] && echo "$2" || echo 127.0.0.1 ;;
    native) [[ "$RUNTIME" == docker ]] && dp_bridge_ip || echo 127.0.0.1 ;;
    *) echo "${3:-}" ;;
  esac
}
dp_svc_port() { [[ "$1" == docker && "$RUNTIME" == docker ]] && echo "$2" || echo "$3"; }

# Address native MinIO listens on (one address only): the bridge gateway when
# containers must reach it, else loopback.
dp_minio_bind() { [[ "$RUNTIME" == docker ]] && dp_bridge_ip || echo 127.0.0.1; }
# host:port the edge proxies the public media host to.
dp_minio_upstream() {
  if [[ "$(dp_minio_mode)" == native ]]; then echo "$(dp_minio_bind):${MINIO_PORT}"; else echo "127.0.0.1:${MINIO_PORT}"; fi
}
