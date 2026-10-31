#!/usr/bin/env bash
# Data services, each in its own mode: docker (compose/services.yml), native (installed
# on this host, see native.sh) or external (only connection details are stored).
# Idempotent: every run creates missing roles/databases/buckets for enabled envs and
# re-applies passwords from secrets.env, so a rotation reaches the live services.

# Compose profiles for the components running in Docker.
dp_services_profiles() {
  local p=()
  if [[ "$DB_MODE" == docker ]]; then [[ "$DB_ENGINE" == mysql ]] && p+=(mariadb) || p+=(postgres); fi
  [[ "$REDIS_MODE" == docker ]] && p+=(redis)
  [[ "$(dp_minio_mode)" == docker ]] && p+=(minio)
  local IFS=,; printf '%s' "${p[*]}"
}

dp_services_compose() {
  PROJECT_SLUG="$PROJECT_SLUG" DP_NETWORK="$(dp_network)" COMPOSE_PROFILES="${DP_PROFILES-$(dp_services_profiles)}" \
  DB_ROOT_USER="${DB_ROOT_USER:-}" DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}" DB_LOCAL_PORT="${DB_LOCAL_PORT:-}" \
  REDIS_PASSWORD="${REDIS_PASSWORD:-}" REDIS_PORT="${REDIS_PORT:-6379}" \
  MINIO_ROOT_USER="${MINIO_ROOT_USER:-}" MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}" \
  MINIO_PORT="${MINIO_PORT:-9000}" MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}" \
    docker compose -f "${DP_ROOT}/compose/services.yml" "$@"
}

dp_services_up() {
  local prof off=() s
  prof="$(dp_services_profiles)"
  if [[ -n "$prof" ]]; then
    dp_info "Starting Docker services (${prof//,/, }) on loopback"
    dp_ensure_network
    dp_services_compose up -d --wait
  fi
  # Components moved off Docker: stop their containers (volumes and data are kept).
  command -v docker >/dev/null 2>&1 || return 0
  for s in postgres:db mariadb:mariadb redis:redis minio:minio; do
    [[ ",${prof}," == *",${s%%:*},"* ]] || off+=("${s#*:}")
  done
  DP_PROFILES=postgres,mariadb,redis,minio dp_services_compose rm -sf "${off[@]}" >/dev/null 2>&1 || true
}

dp_services_native() {
  if [[ "$DB_MODE" == native ]]; then
    if [[ "$DB_ENGINE" == mysql ]]; then dp_native_mariadb; else dp_native_pg; fi
  fi
  [[ "$REDIS_MODE" == native ]] && dp_native_redis
  [[ "$(dp_minio_mode)" == native ]] && dp_native_minio
  return 0
}

# --- databases ------------------------------------------------------------------
# Run SQL as the database superuser of a docker/native server (stdin = SQL).
_dp_pg_admin() {
  if [[ "$DB_MODE" == docker ]]; then
    dp_services_compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U "$DB_ROOT_USER" -d postgres "$@"
  else
    (cd / && sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@")
  fi
}
_dp_my_admin() {
  if [[ "$DB_MODE" == docker ]]; then
    # DP_DB_ROOT_OLD: the root password still active inside a running server (rotation).
    dp_services_compose exec -T -e MYSQL_PWD="${DP_DB_ROOT_OLD:-$DB_ROOT_PASSWORD}" mariadb mariadb -uroot "$@"
  else
    sudo mariadb "$@" 2>/dev/null || sudo mysql "$@"
  fi
}
_dp_sql_str() { local v="${1//\\/\\\\}"; printf "'%s'" "${v//\'/\'\'}"; }

# Create role/user + database per enabled env and (re)apply passwords.
dp_services_db() {
  [[ "$DB_MODE" == external ]] && return 0
  local env name pw_key i=0 sql="" args=()
  if [[ "$DB_ENGINE" == pgsql ]]; then
    if [[ "$DB_MODE" == docker ]]; then
      sql+="SELECT format('ALTER ROLE %I PASSWORD %L', current_user, :'super')\\gexec"$'\n'
      args+=(-v "super=${DB_ROOT_PASSWORD}")
    fi
    for env in $ENABLED_ENVS; do
      i=$((i + 1)); name="$(dp_db_name "$env")"; pw_key="DB_PASSWORD_$(dp_env_upper "$env")"
      args+=(-v "n${i}=${name}" -v "p${i}=${!pw_key}")
      sql+="SELECT format('CREATE ROLE %I LOGIN', :'n${i}') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'n${i}')\\gexec"$'\n'
      sql+="SELECT format('ALTER ROLE %I PASSWORD %L', :'n${i}', :'p${i}')\\gexec"$'\n'
      sql+="SELECT format('CREATE DATABASE %I OWNER %I', :'n${i}', :'n${i}') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'n${i}')\\gexec"$'\n'
    done
    dp_info "Aligning PostgreSQL roles/databases (${DB_MODE}) for: ${ENABLED_ENVS}"
    printf '%s' "$sql" | _dp_pg_admin "${args[@]}"
  else
    if [[ "$DB_MODE" == docker ]]; then
      sql+="ALTER USER 'root'@'%' IDENTIFIED BY $(_dp_sql_str "$DB_ROOT_PASSWORD");"$'\n'
      sql+="ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY $(_dp_sql_str "$DB_ROOT_PASSWORD");"$'\n'
    fi
    for env in $ENABLED_ENVS; do
      name="$(dp_db_name "$env")"; pw_key="DB_PASSWORD_$(dp_env_upper "$env")"
      sql+="CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"$'\n'
      sql+="CREATE USER IF NOT EXISTS '${name}'@'%' IDENTIFIED BY $(_dp_sql_str "${!pw_key}");"$'\n'
      sql+="ALTER USER '${name}'@'%' IDENTIFIED BY $(_dp_sql_str "${!pw_key}");"$'\n'
      sql+="GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${name}'@'%';"$'\n'
    done
    dp_info "Aligning MySQL/MariaDB users/databases (${DB_MODE}) for: ${ENABLED_ENVS}"
    printf '%s' "$sql" | _dp_my_admin
  fi
}

# --- object storage ---------------------------------------------------------------
dp_services_buckets() {
  dp_minio_on || return 0
  local env cmds=":" host
  for env in $ENABLED_ENVS; do cmds+=" && mc mb -p local/$(dp_bucket "$env") >/dev/null"; done
  # No anonymous policy: buckets may hold private uploads; access is the app's call.
  dp_info "Ensuring MinIO buckets for: ${ENABLED_ENVS}"
  if [[ "$(dp_minio_mode)" == docker ]]; then
    docker run --rm --network "$(dp_network)" -e "MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" \
      --entrypoint sh minio/mc -c "$cmds"
  else
    host="$(dp_minio_upstream)"
    MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${host}" PATH="/usr/local/lib/${PROJECT_SLUG}-minio:${PATH}" \
      sh -c "$cmds"
  fi
}

dp_services_apply() {
  dp_services_native
  dp_services_up
  dp_services_db
  dp_services_buckets
}

# --- backups --------------------------------------------------------------------
# Dump one env's database to <APP_HOME>/backups/<env>, keep the newest $BACKUP_KEEP.
dp_backup_db() {
  local env="$1"
  local dir="${APP_HOME}/backups/${env}" out name keep="${BACKUP_KEEP:-10}" f
  name="$(dp_db_name "$env")"; f="$(dp_env_file "$env")"
  mkdir -p "$dir"; chmod 700 "$dir"
  if [[ "$DB_ENGINE" == pgsql ]]; then
    out="${dir}/${name}_$(date +%Y%m%d_%H%M%S).dump"
    dp_info "Backup ${name} → ${out}"
    case "$DB_MODE" in
      docker) dp_services_compose exec -T db pg_dump -U "$DB_ROOT_USER" -Fc "$name" >"$out" ;;
      native) (cd / && sudo -u postgres pg_dump -Fc "$name") >"$out" ;;
      external) PGPASSWORD="$(dp_env_value "$f" DB_PASSWORD)" pg_dump -h "$(dp_env_value "$f" DB_HOST)" -p "$(dp_env_value "$f" DB_PORT)" \
          -U "$(dp_env_value "$f" DB_USERNAME)" -Fc "$(dp_env_value "$f" DB_DATABASE)" >"$out" ;;
    esac
  else
    out="${dir}/${name}_$(date +%Y%m%d_%H%M%S).sql.gz"
    dp_info "Backup ${name} → ${out}"
    case "$DB_MODE" in
      docker) dp_services_compose exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb mariadb-dump -uroot --single-transaction --routines "$name" | gzip >"$out" ;;
      native) sudo "$(command -v mariadb-dump || echo mysqldump)" --single-transaction --routines "$name" | gzip >"$out" ;;
      external) MYSQL_PWD="$(dp_env_value "$f" DB_PASSWORD)" "$(command -v mariadb-dump || echo mysqldump)" --single-transaction --no-tablespaces \
          -h "$(dp_env_value "$f" DB_HOST)" -P "$(dp_env_value "$f" DB_PORT)" -u "$(dp_env_value "$f" DB_USERNAME)" \
          "$(dp_env_value "$f" DB_DATABASE)" | gzip >"$out" ;;
    esac
  fi
  chmod 600 "$out"
  # shellcheck disable=SC2012
  # Only existing globs: ls on a missing pattern fails, which aborts under pipefail.
  local old=(); compgen -G "${dir}/*.dump" >/dev/null && old+=("$dir"/*.dump)
  compgen -G "${dir}/*.sql.gz" >/dev/null && old+=("$dir"/*.sql.gz)
  ls -1t "${old[@]}" | tail -n +"$((keep + 1))" | xargs -r rm -f
}

dp_restore_db() {
  local env="$1" file="$2" name
  name="$(dp_db_name "$env")"
  [[ -f "$file" ]] || dp_die "No dump at ${file}"
  [[ "$DB_MODE" != external ]] || dp_die "restore supports docker/native databases; for external ones use pg_restore/mysql directly."
  dp_info "Restoring ${file} → ${name} (replaces existing objects)"
  if [[ "$DB_ENGINE" == pgsql ]]; then
    if [[ "$DB_MODE" == docker ]]; then
      dp_services_compose exec -T db pg_restore -U "$DB_ROOT_USER" -d "$name" --clean --if-exists --no-owner --role="$name" <"$file"
    else
      (cd / && sudo -u postgres pg_restore -d "$name" --clean --if-exists --no-owner --role="$name") <"$file"
    fi
  else
    gunzip -c "$file" | _dp_my_admin "$name"
  fi
}
