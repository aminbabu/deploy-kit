#!/usr/bin/env bash
# Writes the "managed" keys of one env's .env from project state + secrets:
# URLs/CORS/Sanctum/session domain (with a frontend), OAuth callbacks, DB, Redis, MinIO.
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
  local env="$1" file fe_host api_host fe="" api snake up media
  file="$(dp_env_file "$env")"
  up="$(dp_env_upper "$env")"
  snake="$(dp_env_snake "$env")"
  api_host="$(dp_ev "$env" API_HOST)"
  [[ -n "$api_host" ]] || dp_die "${env}: API host missing in state"
  api="$(dp_origin "$api_host")"
  if dp_fe_on; then
    fe_host="$(dp_ev "$env" FRONTEND_HOST)"
    [[ -n "$fe_host" ]] || dp_die "${env}: frontend host missing in state"
    [[ "$fe_host" != "$api_host" ]] || dp_die "${env}: the API needs its own host (e.g. api.${fe_host})"
    fe="$(dp_origin "$fe_host")"
  fi
  mkdir -p "$(dirname "$file")"

  local prefix="${API_PREFIX:-/api/v1}"; [[ "$prefix" == none ]] && prefix=""
  dp_info "Sync managed settings for ${env} (api ${api}${fe:+, frontend ${fe}})"
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

  if [[ -n "$fe" ]]; then
    dp_env_sync "$file" FRONTEND_URL "$fe"
    dp_env_sync "$file" NEXT_PUBLIC_SITE_URL "$fe"
    dp_env_sync "$file" NEXT_PUBLIC_API_URL "${api}${prefix}"
    local cors stateful common
    cors="$(dp_merge_origin "$(dp_env_value "$file" CORS_ALLOWED_ORIGINS)" "$fe")"
    dp_env_sync "$file" CORS_ALLOWED_ORIGINS "$cors"
    stateful="$(dp_merge_origin "$(dp_env_value "$file" SANCTUM_STATEFUL_DOMAINS)" "${fe#https://}")"
    dp_env_sync "$file" SANCTUM_STATEFUL_DOMAINS "$stateful"
    common="$(dp_common_domain "$fe_host" "$api_host")"
    dp_env_sync "$file" SESSION_DOMAIN "${common:+.${common}}"
  fi

  # OAuth callbacks (chosen providers only) live on the API host; keep custom paths.
  local provider redirect path
  for provider in $(dp_env_value "$file" OAUTH_PROVIDERS | tr ',' ' '); do
    provider="${provider^^}"
    redirect="$(dp_env_value "$file" "${provider}_REDIRECT_URI")"
    path="${prefix}/auth/oauth/${provider,,}/callback"
    [[ "$redirect" =~ ^https?://[^/]+(/.*)$ ]] && path="${BASH_REMATCH[1]}"
    dp_env_sync "$file" "${provider}_REDIRECT_URI" "${api}${path}"
  done

  # Database
  local db_host db_port db_name db_user db_pass_key="DB_PASSWORD_${up}"
  if [[ "$DB_MODE" == external ]]; then
    db_host="$(dp_ev "$env" DB_HOST)"; db_port="$(dp_ev "$env" DB_PORT)"
    db_name="$(dp_ev "$env" DB_DATABASE)"; db_user="$(dp_ev "$env" DB_USERNAME)"
  else
    db_host="$(dp_svc_host "$DB_MODE" db)"; db_port="$(dp_svc_port "$DB_MODE" "$(dp_db_default_port)" "$DB_LOCAL_PORT")"
    db_name="$(dp_db_name "$env")"; db_user="$db_name"
  fi
  dp_env_sync "$file" DB_CONNECTION "$(dp_db_connection)"
  dp_env_sync "$file" DB_HOST "$db_host"
  dp_env_sync "$file" DB_PORT "$db_port"
  dp_env_sync "$file" DB_DATABASE "$db_name"
  dp_env_sync "$file" DB_USERNAME "$db_user"
  dp_env_sync "$file" DB_PASSWORD "${!db_pass_key:-}" 1

  # Redis (one DB index per env)
  if [[ "$REDIS_MODE" != none ]]; then
    dp_env_sync "$file" REDIS_CLIENT phpredis
    dp_env_sync "$file" REDIS_HOST "$(dp_svc_host "$REDIS_MODE" redis "${REDIS_HOST:-}")"
    dp_env_sync "$file" REDIS_PORT "$(dp_svc_port "$REDIS_MODE" 6379 "$REDIS_PORT")"
    dp_env_sync "$file" REDIS_PASSWORD "${REDIS_PASSWORD:-}" 1
    dp_env_sync "$file" REDIS_DB "$(dp_ev "$env" REDIS_DB)"
  fi
  dp_env_sync "$file" CACHE_PREFIX "$(dp_env_snake "$PROJECT_SLUG")_${snake}_cache_"

  # Bundled MinIO: written as the standard S3 disk (AWS_*) and as MINIO_* for apps
  # that define a dedicated "minio" disk. External S3 keys come from the catalog.
  if dp_minio_on; then
    local endpoint bucket url=""
    bucket="$(dp_bucket "$env")"
    endpoint="http://$(dp_svc_host "$(dp_minio_mode)" minio):$(dp_svc_port "$(dp_minio_mode)" 9000 "$MINIO_PORT")"
    [[ -n "${MEDIA_HOST:-}" ]] && media="$(dp_origin "$MEDIA_HOST")" && url="${media}/${bucket}"
    local pfx
    for pfx in AWS MINIO; do
      dp_env_sync "$file" "${pfx}_ACCESS_KEY_ID" "${MINIO_ROOT_USER:-}"
      dp_env_sync "$file" "${pfx}_SECRET_ACCESS_KEY" "${MINIO_ROOT_PASSWORD:-}" 1
      dp_env_sync "$file" "${pfx}_$([[ $pfx == AWS ]] && echo DEFAULT_REGION || echo REGION)" us-east-1
      dp_env_sync "$file" "${pfx}_BUCKET" "$bucket"
      dp_env_sync "$file" "${pfx}_ENDPOINT" "$endpoint"
      dp_env_sync "$file" "${pfx}_USE_PATH_STYLE_ENDPOINT" true
      [[ -n "$url" ]] && dp_env_sync "$file" "${pfx}_URL" "$url"
    done
    [[ -n "$url" && -n "$fe" ]] && dp_env_sync "$file" NEXT_PUBLIC_MINIO_PUBLIC_BASE "$media"
  fi
  chmod 600 "$file"
  return 0
}

# Live preflight from the frontend origin to the API. Prints and returns 1 on mismatch.
dp_check_cors() {
  local env="$1" fe api headers allow
  dp_fe_on || return 0
  fe="$(dp_origin "$(dp_ev "$env" FRONTEND_HOST)")"
  api="$(dp_origin "$(dp_ev "$env" API_HOST)")"
  headers="$(curl -sS -o /dev/null -D - -X OPTIONS --max-time 15 \
    -H "Origin: ${fe}" -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: authorization,x-locale" \
    "${api}$([[ ${API_PREFIX:-/api/v1} == none ]] || echo "${API_PREFIX:-/api/v1}")/health" 2>/dev/null || true)"
  allow="$(printf '%s' "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin" { print $2; exit }')"
  if [[ "$allow" == "$fe" || "$allow" == "*" ]]; then
    dp_ok "CORS ${fe} → ${api}"
  else
    dp_warn "CORS preflight ${fe} → ${api} returned Access-Control-Allow-Origin='${allow:-<none>}' (DNS/TLS not ready, or CORS_ALLOWED_ORIGINS wrong)."
    return 1
  fi
}
