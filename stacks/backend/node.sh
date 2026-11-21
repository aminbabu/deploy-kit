#!/usr/bin/env bash
# Backend adapter: node (NestJS, Express, Fastify, Hono).

be_health_path() { printf '/health'; }

be_prereqs() {
  command -v node >/dev/null 2>&1 || dp_os_install_node "${NODE_VERSION:-22}"
}

be_env_sync() {
  local env="$1" file="$2" port
  port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  port="${port:-3001}"
  dp_env_sync "$file" NODE_ENV production
  dp_env_sync "$file" PORT "$port"
}

be_build_native() {
  local src="$1" run="$2" env_file="$3"
  if [[ -f "${run}/pnpm-lock.yaml" ]]; then
    (cd "$run" && pnpm install --frozen-lockfile && pnpm build)
  elif [[ -f "${run}/yarn.lock" ]]; then
    (cd "$run" && yarn install --frozen-lockfile && yarn build)
  else
    (cd "$run" && npm ci && npm run build)
  fi
  : "$src" "$env_file"
}

be_migrate() {
  local run="$1" env_file="$2"
  if [[ -n "${MIGRATE_CMD:-}" ]]; then
    local cmd_parts=()
    read -r -a cmd_parts <<< "$MIGRATE_CMD"
    ((${#cmd_parts[@]})) && (cd "$run" && set -a && source "$env_file" && set +a && "${cmd_parts[@]}")
  elif [[ -f "${run}/prisma/schema.prisma" ]]; then
    (cd "$run" && set -a && source "$env_file" && set +a && npx prisma migrate deploy)
  fi
}

be_nginx_native() {
  local env="$1" out_conf="$2" internal_port
  internal_port="$(dp_ev "$env" APP_INTERNAL_PORT)"
  internal_port="${internal_port:-3001}"
  _dp_render api-proxy.conf.template "$out_conf" \
    ENV_NAME="$env" \
    SLUG="$PROJECT_SLUG" \
    API_PORT="$(dp_ev "$env" API_PORT)" \
    APP_UPSTREAM_PORT="$internal_port" \
    MAX_BODY="${MAX_UPLOAD_MB:-64}m" \
    EXTRA_LOCATIONS=""
}

be_systemd_units() {
  local env="$1" run="$2" env_file="$3" node_bin entry unit_name unit
  node_bin="$(command -v node)"
  entry="${BACKEND_ENTRY:-dist/main.js}"
  [[ -f "${run}/${entry}" ]] || entry="dist/index.js"
  unit_name="${PROJECT_SLUG}-${env}-app"
  unit="$(sed \
    -e "s|__SLUG__|${PROJECT_SLUG}|g" \
    -e "s|__DESC__|Node API|g" \
    -e "s|__ENV__|${env}|g" \
    -e "s|__RUN__|${run}|g" \
    -e "s|__ENV_FILE__|${env_file}|g" \
    -e "s|__CMD__|${node_bin} ${run}/${entry}|g" \
    "${DP_ROOT}/systemd/app-service.tmpl")"
  printf '%s\n' "$unit" | sudo tee "/etc/systemd/system/${unit_name}.service" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${unit_name}.service" >/dev/null 2>&1 || true
  sudo systemctl restart "${unit_name}.service"
}
