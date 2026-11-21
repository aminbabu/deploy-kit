#!/usr/bin/env bash
# Backend adapter: laravel (default, preserves existing PHP-FPM / artisan behavior).

be_health_path() {
  local repo="${1:-.}"
  if [[ -f "${repo}/${BACKEND_DIR:-backend}/bootstrap/app.php" ]]; then
    local h
    h="$(grep -oE "health:\s*['\"][^'\"]+['\"]" "${repo}/${BACKEND_DIR:-backend}/bootstrap/app.php" 2>/dev/null | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true)"
    [[ -n "$h" ]] && { printf '%s' "$h"; return 0; }
  fi
  printf '/up'
}

be_prereqs() {
  dp_native_app_prereqs
}

be_env_sync() {
  local env="$1" file="$2"
  # Standard Laravel keys are already written by dp_write_managed in lib/env-urls.sh.
  : "$env" "$file"
  return 0
}

be_build_native() {
  local src="$1" run="$2" env_file="$3"
  local php_bin
  php_bin="$(dp_php_bin)"
  (cd "$run" && composer install --no-dev --no-interaction --optimize-autoloader >/dev/null \
    && "$php_bin" artisan config:cache && "$php_bin" artisan route:cache \
    && "$php_bin" artisan view:cache && "$php_bin" artisan event:cache)
  : "$src" "$env_file"
}

be_migrate() {
  local run="$1" env_file="$2"
  local php_bin
  php_bin="$(dp_php_bin)"
  (cd "$run" && "$php_bin" artisan migrate --force)
  : "$env_file"
}

be_nginx_native() {
  local env="$1" out_conf="$2"
  _dp_render api-fpm.conf.template "$out_conf" \
    ENV_NAME="$env" \
    SLUG="$PROJECT_SLUG" \
    API_PORT="$(dp_ev "$env" API_PORT)" \
    BACKEND_PUBLIC="${APP_HOME}/${env}/backend-current/public" \
    MAX_BODY="${MAX_UPLOAD_MB:-64}m" \
    FPM_PASS="$DP_FPM_PASS"
}

be_systemd_units() {
  local env="$1" run="$2" env_file="$3"
  dp_native_workers_apply "$env" "$run"
  : "$env_file"
}
