#!/usr/bin/env bash
# Backend adapter: django (Python WSGI/ASGI — Gunicorn + manage.py + collectstatic).

be_health_path() { printf '/health/'; }

be_prereqs() {
  command -v python3 >/dev/null 2>&1 || dp_pkg_install python3
  python3 -m venv --help >/dev/null 2>&1 || dp_pkg_install python3-venv
}

be_env_sync() {
  local env="$1" file="$2" port api_host
  port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  port="${port:-8000}"
  api_host="$(dp_ev "$env" API_HOST)"
  dp_env_sync "$file" PORT "$port"
  dp_env_sync "$file" ALLOWED_HOSTS "${api_host},127.0.0.1,localhost"
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
  (cd "$run" && set -a && source "$env_file" && set +a && "${venv}/bin/python" manage.py collectstatic --noinput)
  : "$src"
}

be_migrate() {
  local run="$1" env_file="$2"
  local venv="${run}/.venv"
  (cd "$run" && set -a && source "$env_file" && set +a && "${venv}/bin/python" manage.py migrate --noinput)
}

be_nginx_native() {
  local env="$1" out_conf="$2" internal_port static_loc
  internal_port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  internal_port="${internal_port:-8000}"
  static_loc="location /static/ { alias ${APP_HOME}/${env}/backend-current/staticfiles/; }"
  _dp_render api-proxy.conf.template "$out_conf" \
    ENV_NAME="$env" \
    SLUG="$PROJECT_SLUG" \
    API_PORT="$(dp_ev "$env" API_PORT)" \
    APP_UPSTREAM_PORT="$internal_port" \
    MAX_BODY="${MAX_UPLOAD_MB:-64}m" \
    EXTRA_LOCATIONS="$static_loc"
}

be_systemd_units() {
  local env="$1" run="$2" env_file="$3" venv="${run}/.venv" entry internal_port cmd unit_name unit
  internal_port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  internal_port="${internal_port:-8000}"
  entry="${BACKEND_ENTRY:-config.wsgi:application}"
  cmd="${venv}/bin/gunicorn ${entry} --workers ${WEB_CONCURRENCY:-2} --bind 127.0.0.1:${internal_port}"
  unit_name="${PROJECT_SLUG}-${env}-app"
  unit="$(sed \
    -e "s|__SLUG__|${PROJECT_SLUG}|g" \
    -e "s|__DESC__|Django|g" \
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
