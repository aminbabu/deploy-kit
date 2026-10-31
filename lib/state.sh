#!/usr/bin/env bash
# Project state: <APP_HOME>/project.env (no secrets) + pointer ~/.<slug>.deploy.
#
#   PROJECT_SLUG, APP_HOME, REPO_URL, REPO_PATH, RUNTIME (docker|host),
#   EDGE_MODE (certbot|byo|panel), ENABLED_ENVS, MEDIA_MODE, ...
#   per env (ENV upper-cased, '-' → '_'): <E>_FRONTEND_HOST, <E>_API_HOST,
#   <E>_BRANCH, <E>_API_PORT, <E>_FRONTEND_PORT
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

# Load saved state into S_* (defaults for the wizard) or plain vars (for deploy).
dp_state_load_saved() { dp_env_load_prefixed "$(dp_state_file)" S_; dp_env_load_prefixed "$(dp_secrets_file)" S_; }
dp_state_load() {
  dp_env_load_prefixed "$(dp_state_file)" ''
  [[ -n "${PROJECT_SLUG:-}" ]] || dp_die "No project state at $(dp_state_file). Run deploy/setup.sh first."
}
dp_secrets_load() { dp_env_load_prefixed "$(dp_secrets_file)" ''; }

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
