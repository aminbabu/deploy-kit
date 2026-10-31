#!/usr/bin/env bash
# Writes the "managed" keys of one env's .env from project state + secrets:
# URLs/CORS/Sanctum/session domain, OAuth callbacks, DB, Redis, storage, build URLs.
# Extra CORS/Sanctum origins added by hand are kept. Requires state + secrets loaded.

# Comma list with $2 guaranteed first; keeps any extra entries.
dp_merge_origin() {
  local list="$1" origin="$2" item out="$2"
  IFS=',' read -ra items <<<"$list"
  for item in "${items[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -z "$item" || "$item" == "$origin" ]] && continue
    out="${out},${item}"
  done
  printf '%s' "$out"
}

# Parent domain shared by frontend + api hosts (for SESSION_DOMAIN), e.g.
# app.example.com + api.example.com → example.com
dp_common_domain() {
  local a="$1" b="$2"
  while [[ "$a" == *.*.* && ".$b" != *".$a" ]]; do a="${a#*.}"; done
  [[ ".$b" == *".$a" ]] && printf '%s' "$a"
}

dp_write_managed() {
  local env="$1" file fe_host api_host fe api snake up media
  file="$(dp_env_file "$env")"
  up="$(dp_env_upper "$env")"
  snake="$(dp_env_snake "$env")"
  fe_host="$(dp_ev "$env" FRONTEND_HOST)"
  api_host="$(dp_ev "$env" API_HOST)"
  [[ -n "$fe_host" && -n "$api_host" ]] || dp_die "${env}: frontend/API host missing in state"
  [[ "$fe_host" != "$api_host" ]] || dp_die "${env}: the API needs its own host (e.g. api.${fe_host})"
  fe="$(dp_origin "$fe_host")"
  api="$(dp_origin "$api_host")"
  mkdir -p "$(dirname "$file")"

  dp_info "Sync managed settings for ${env} (frontend ${fe}, api ${api})"
  local app_env=production debug=false level=info encrypt=true
  case "$env" in
    production) ;;
    dev) app_env=development debug=true level=debug encrypt=false ;;
    *) app_env="$env" ;;
  esac
  dp_env_sync "$file" APP_ENV "$app_env"
  dp_env_sync "$file" APP_DEBUG "$debug"
  dp_env_sync "$file" LOG_LEVEL "$level"
  dp_env_sync "$file" SESSION_ENCRYPT "$encrypt"
  dp_env_sync "$file" APP_URL "$api"
  dp_env_sync "$file" FRONTEND_URL "$fe"
  dp_env_sync "$file" NEXT_PUBLIC_SITE_URL "$fe"
  dp_env_sync "$file" NEXT_PUBLIC_API_URL "${api}/api/v1"

  local cors stateful common
  cors="$(dp_merge_origin "$(dp_env_value "$file" CORS_ALLOWED_ORIGINS)" "$fe")"
  dp_env_sync "$file" CORS_ALLOWED_ORIGINS "$cors"
  stateful="$(dp_merge_origin "$(dp_env_value "$file" SANCTUM_STATEFUL_DOMAINS)" "${fe#https://}")"
  dp_env_sync "$file" SANCTUM_STATEFUL_DOMAINS "$stateful"
  common="$(dp_common_domain "$fe_host" "$api_host")"
  dp_env_sync "$file" SESSION_DOMAIN "${common:+.${common}}"

  # OAuth callbacks live on the API host; keep custom paths.
  local provider redirect path
  for provider in GOOGLE FACEBOOK; do
    redirect="$(dp_env_value "$file" "${provider}_REDIRECT_URI")"
    path="/api/v1/auth/oauth/${provider,,}/callback"
    [[ "$redirect" =~ ^https?://[^/]+(/.*)$ ]] && path="${BASH_REMATCH[1]}"
    dp_env_sync "$file" "${provider}_REDIRECT_URI" "${api}${path}"
  done

  # Database
  local db_host db_port db_name db_user db_pass_key="DB_PASSWORD_${up}"
  if [[ "$SERVICES_MODE" == "bundled" ]]; then
    if [[ "$RUNTIME" == "docker" ]]; then db_host=db db_port=5432; else db_host=127.0.0.1 db_port="$PG_PORT"; fi
    db_name="$(dp_db_name "$env")"; db_user="$db_name"
  else
    db_host="$(dp_ev "$env" DB_HOST)"; db_port="$(dp_ev "$env" DB_PORT)"
    db_name="$(dp_ev "$env" DB_DATABASE)"; db_user="$(dp_ev "$env" DB_USERNAME)"
  fi
  dp_env_sync "$file" DB_CONNECTION pgsql
  dp_env_sync "$file" DB_HOST "$db_host"
  dp_env_sync "$file" DB_PORT "$db_port"
  dp_env_sync "$file" DB_DATABASE "$db_name"
  dp_env_sync "$file" DB_USERNAME "$db_user"
  dp_env_sync "$file" DB_PASSWORD "${!db_pass_key:-}" 1

  # Redis (one DB index per env)
  local r_host r_port
  if [[ "$SERVICES_MODE" == "bundled" ]]; then
    if [[ "$RUNTIME" == "docker" ]]; then r_host=redis r_port=6379; else r_host=127.0.0.1 r_port="$REDIS_PORT"; fi
  else
    r_host="$REDIS_HOST"; r_port="$REDIS_PORT"
  fi
  dp_env_sync "$file" REDIS_CLIENT phpredis
  dp_env_sync "$file" REDIS_HOST "$r_host"
  dp_env_sync "$file" REDIS_PORT "$r_port"
  dp_env_sync "$file" REDIS_PASSWORD "${REDIS_PASSWORD:-}" 1
  dp_env_sync "$file" REDIS_DB "$(dp_ev "$env" REDIS_DB)"
  dp_env_sync "$file" CACHE_PREFIX "$(dp_env_snake "$PROJECT_SLUG")_${snake}_cache_"

  # Object storage (bundled MinIO); external storage keys come from the catalog.
  if [[ "$SERVICES_MODE" == "bundled" ]]; then
    local endpoint bucket
    bucket="$(dp_bucket "$env")"
    if [[ "$RUNTIME" == "docker" ]]; then endpoint="http://minio:9000"; else endpoint="http://127.0.0.1:${MINIO_PORT}"; fi
    dp_env_sync "$file" MINIO_ACCESS_KEY_ID "${MINIO_ROOT_USER:-}"
    dp_env_sync "$file" MINIO_SECRET_ACCESS_KEY "${MINIO_ROOT_PASSWORD:-}" 1
    dp_env_sync "$file" MINIO_REGION us-east-1
    dp_env_sync "$file" MINIO_BUCKET "$bucket"
    dp_env_sync "$file" MINIO_ENDPOINT "$endpoint"
    dp_env_sync "$file" MINIO_USE_PATH_STYLE_ENDPOINT true
    if [[ -n "${MEDIA_HOST:-}" ]]; then
      media="$(dp_origin "$MEDIA_HOST")"
      dp_env_sync "$file" MINIO_URL "${media}/${bucket}"
      dp_env_sync "$file" NEXT_PUBLIC_MINIO_PUBLIC_BASE "$media"
    fi
  fi
  chmod 600 "$file"
  return 0
}

# Live preflight from the frontend origin to the API. Prints and returns 1 on mismatch.
dp_check_cors() {
  local env="$1" fe api headers allow
  fe="$(dp_origin "$(dp_ev "$env" FRONTEND_HOST)")"
  api="$(dp_origin "$(dp_ev "$env" API_HOST)")"
  headers="$(curl -sS -o /dev/null -D - -X OPTIONS --max-time 15 \
    -H "Origin: ${fe}" -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: authorization,x-locale" \
    "${api}/api/v1/health" 2>/dev/null || true)"
  allow="$(printf '%s' "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin" { print $2; exit }')"
  if [[ "$allow" == "$fe" || "$allow" == "*" ]]; then
    dp_ok "CORS ${fe} → ${api}"
  else
    dp_warn "CORS preflight ${fe} → ${api} returned Access-Control-Allow-Origin='${allow:-<none>}' (DNS/TLS not ready, or CORS_ALLOWED_ORIGINS wrong)."
    return 1
  fi
}
