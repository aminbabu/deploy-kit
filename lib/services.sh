#!/usr/bin/env bash
# Bundled data services (Postgres / Redis / MinIO in Docker) for SERVICES_MODE=bundled.
# Idempotent: every run creates missing roles/databases/buckets for enabled envs and
# re-applies passwords from secrets.env, so a rotation reaches the live services.

dp_services_compose() {
  PROJECT_SLUG="$PROJECT_SLUG" DP_NETWORK="$(dp_network)" \
  POSTGRES_SUPERUSER="$POSTGRES_SUPERUSER" POSTGRES_SUPERPASS="$POSTGRES_SUPERPASS" \
  REDIS_PASSWORD="${REDIS_PASSWORD:-}" MINIO_ROOT_USER="$MINIO_ROOT_USER" MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
  PG_PORT="$PG_PORT" REDIS_PORT="$REDIS_PORT" MINIO_PORT="$MINIO_PORT" MINIO_CONSOLE_PORT="$MINIO_CONSOLE_PORT" \
    docker compose -f "${DP_ROOT}/compose/services.yml" "$@"
}

dp_ensure_network() {
  docker network inspect "$(dp_network)" >/dev/null 2>&1 || docker network create "$(dp_network)" >/dev/null
}

dp_services_up() {
  [[ "$SERVICES_MODE" == "bundled" ]] || return 0
  dp_info "Starting bundled services (Postgres ${PG_PORT}, Redis ${REDIS_PORT}, MinIO ${MINIO_PORT}) on loopback"
  dp_ensure_network
  dp_services_compose up -d --wait
}

# Create role + database per enabled env, (re)apply passwords. Values are psql variables.
dp_services_db() {
  [[ "$SERVICES_MODE" == "bundled" ]] || return 0
  local env name pw_key args=() sql=""
  sql+="SELECT format('ALTER ROLE %I PASSWORD %L', current_user, :'super')\\gexec"$'\n'
  args+=(-v "super=${POSTGRES_SUPERPASS}")
  local i=0
  for env in $ENABLED_ENVS; do
    i=$((i + 1))
    name="$(dp_db_name "$env")"; pw_key="DB_PASSWORD_$(dp_env_upper "$env")"
    args+=(-v "n${i}=${name}" -v "p${i}=${!pw_key}")
    sql+="SELECT format('CREATE ROLE %I LOGIN', :'n${i}') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'n${i}')\\gexec"$'\n'
    sql+="SELECT format('ALTER ROLE %I PASSWORD %L', :'n${i}', :'p${i}')\\gexec"$'\n'
    sql+="SELECT format('CREATE DATABASE %I OWNER %I', :'n${i}', :'n${i}') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'n${i}')\\gexec"$'\n'
  done
  dp_info "Aligning Postgres roles/databases for: ${ENABLED_ENVS}"
  printf '%s' "$sql" | dp_services_compose exec -T db psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d postgres "${args[@]}"
}

dp_services_buckets() {
  [[ "$SERVICES_MODE" == "bundled" ]] || return 0
  local env cmds="mc alias set local http://minio:9000 \"\$U\" \"\$P\" >/dev/null"
  for env in $ENABLED_ENVS; do cmds+=" && mc mb -p local/$(dp_bucket "$env") >/dev/null"; done
  # No anonymous policy: buckets may hold private uploads (e.g. KYC); access is the app's call.
  dp_info "Ensuring MinIO buckets for: ${ENABLED_ENVS}"
  docker run --rm --network "$(dp_network)" -e U="$MINIO_ROOT_USER" -e P="$MINIO_ROOT_PASSWORD" \
    --entrypoint sh minio/mc -c "$cmds"
}

dp_services_apply() {
  dp_services_up
  dp_services_db
  dp_services_buckets
}

# pg_dump one env's database to <APP_HOME>/backups, keep the newest $BACKUP_KEEP.
dp_backup_db() {
  local env="$1"
  local dir="${APP_HOME}/backups/${env}" out name keep="${BACKUP_KEEP:-10}"
  name="$(dp_db_name "$env")"
  mkdir -p "$dir"; chmod 700 "$dir"
  out="${dir}/${name}_$(date +%Y%m%d_%H%M%S).dump"
  dp_info "Backup ${name} → ${out}"
  if [[ "$SERVICES_MODE" == "bundled" ]]; then
    dp_services_compose exec -T db pg_dump -U "$POSTGRES_SUPERUSER" -Fc "$name" >"$out"
  else
    local f; f="$(dp_env_file "$env")"
    PGPASSWORD="$(dp_env_value "$f" DB_PASSWORD)" pg_dump -h "$(dp_env_value "$f" DB_HOST)" -p "$(dp_env_value "$f" DB_PORT)" \
      -U "$(dp_env_value "$f" DB_USERNAME)" -Fc "$(dp_env_value "$f" DB_DATABASE)" >"$out"
  fi
  chmod 600 "$out"
  # shellcheck disable=SC2012
  ls -1t "$dir"/*.dump 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm -f
}

dp_restore_db() {
  local env="$1" file="$2" name
  name="$(dp_db_name "$env")"
  [[ -f "$file" ]] || dp_die "No dump at ${file}"
  [[ "$SERVICES_MODE" == "bundled" ]] || dp_die "restore supports bundled Postgres; for external DBs use pg_restore directly."
  dp_info "Restoring ${file} → ${name} (drops existing objects)"
  dp_services_compose exec -T db pg_restore -U "$POSTGRES_SUPERUSER" -d "$name" --clean --if-exists --no-owner --role="$name" <"$file"
}
