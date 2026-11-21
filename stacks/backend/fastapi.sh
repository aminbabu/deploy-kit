#!/usr/bin/env bash
# Backend adapter: fastapi (Python ASGI — Gunicorn + UvicornWorker + Alembic).

be_health_path() { printf '/health'; }

be_prereqs() {
  command -v python3 >/dev/null 2>&1 || dp_pkg_install python3
  python3 -m venv --help >/dev/null 2>&1 || dp_pkg_install python3-venv
}

be_env_sync() {
  local env="$1" file="$2" port
  port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  port="${port:-8000}"
  dp_env_sync "$file" PORT "$port"
}

be_build_native() {
  local src="$1" run="$2" env_file="$3"
  local venv="${run}/.venv"
  python3 -m venv "$venv"
  "${venv}/bin/pip" install --upgrade pip >/dev/null
  if [[ -f "${run}/requirements.txt" ]]; then
    "${venv}/bin/pip" install -r "${run}/requirements.txt" >/dev/null
  elif [[ -f "${run}/pyproject.toml" ]]; then
    "${venv}/bin/pip" install "$run" >/dev/null
  fi
  : "$src" "$env_file"
}

be_migrate() {
  local run="$1" env_file="$2"
  local venv="${run}/.venv"
  if [[ -n "${MIGRATE_CMD:-}" ]]; then
    local cmd_parts=()
    read -r -a cmd_parts <<< "$MIGRATE_CMD"
    ((${#cmd_parts[@]})) && (cd "$run" && set -a && source "$env_file" && set +a && "${cmd_parts[@]}")
  elif [[ -f "${run}/alembic.ini" ]]; then
    (cd "$run" && set -a && source "$env_file" && set +a && "${venv}/bin/alembic" upgrade head)
  fi
}

be_nginx_native() {
  local env="$1" out_conf="$2" internal_port
  internal_port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  internal_port="${internal_port:-8000}"
  _dp_render api-proxy.conf.template "$out_conf" \
    ENV_NAME="$env" \
    SLUG="$PROJECT_SLUG" \
    API_PORT="$(dp_ev "$env" API_PORT)" \
    APP_UPSTREAM_PORT="$internal_port" \
    MAX_BODY="${MAX_UPLOAD_MB:-64}m" \
    EXTRA_LOCATIONS=""
}

be_systemd_units() {
  local env="$1" run="$2" env_file="$3" venv="${run}/.venv" entry internal_port cmd unit_name unit
  internal_port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  internal_port="${internal_port:-8000}"
  entry="${BACKEND_ENTRY:-app.main:app}"
  if [[ -x "${venv}/bin/gunicorn" ]]; then
    cmd="${venv}/bin/gunicorn ${entry} -k uvicorn.workers.UvicornWorker -w ${WEB_CONCURRENCY:-2} -b 127.0.0.1:${internal_port}"
  else
    cmd="${venv}/bin/uvicorn ${entry} --host 127.0.0.1 --port ${internal_port}"
  fi
  unit_name="${PROJECT_SLUG}-${env}-app"
  unit="$(sed \
    -e "s|__SLUG__|${PROJECT_SLUG}|g" \
    -e "s|__DESC__|FastAPI|g" \
    -e "s|__ENV__|${env}|g" \
    -e "s|__RUN__|${run}|g" \
    -e "s|__ENV_FILE__|${env_file}|g" \
    -e "s|__CMD__|${cmd}|g" \
    "${DP_ROOT}/systemd/app-service.tmpl")"
  printf '%s\n' "$unit" | sudo tee "/etc/systemd/system/${unit_name}.service" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${unit_name}.service" >/dev/null 2>&1 || true
  sudo systemctl restart "${unit_name}.service"
}
