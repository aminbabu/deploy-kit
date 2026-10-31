#!/usr/bin/env bash
# Host runtime: per-env runtime copies so envs sharing one checkout never share
# Laravel's cached config or a Next.js build.
#   <env>/backend-run   Laravel copy (.env → <env>/.env, storage → <env>/storage)
#   <env>/frontend-run  Next.js standalone output for this env's NEXT_PUBLIC_* values

dp_publish_backend() {
  local env_dir="$1" src="$2" env_file="$3" storage="${1}/storage"
  BACKEND_RUN="${env_dir}/backend-run"
  [[ -f "${src}/artisan" ]] || dp_die "No Laravel app at ${src}"
  if [[ ! -d "$storage" ]]; then
    mkdir -p "$storage"
    [[ -d "${src}/storage" ]] && rsync -a "${src}/storage/" "${storage}/"
  fi
  mkdir -p "${storage}/app/public" "${storage}/framework/cache/data" \
    "${storage}/framework/sessions" "${storage}/framework/views" "${storage}/logs"
  dp_info "Publishing backend → ${BACKEND_RUN}"
  mkdir -p "$BACKEND_RUN"
  rsync -a --delete \
    --exclude='/.env' --exclude='/.env.*' \
    --exclude='/storage' --exclude='/public/storage' \
    --exclude='/bootstrap/cache/config.php' \
    --exclude='/bootstrap/cache/routes-*.php' \
    --exclude='/bootstrap/cache/events.php' \
    --exclude='/node_modules' --exclude='/tests' \
    "${src}/" "${BACKEND_RUN}/"
  ln -sfn "$storage" "${BACKEND_RUN}/storage"
  ln -sfn "$env_file" "${BACKEND_RUN}/.env"
  ln -sfn "${storage}/app/public" "${BACKEND_RUN}/public/storage"
}

# Fail before restarting anything if the cached config belongs to another env.
dp_verify_backend_config() {
  local dir="$1" want_app="$2" want_fe="$3" got got_app got_cors
  got="$(cd "$dir" && php -r '
    $c = require "bootstrap/cache/config.php";
    echo $c["app"]["url"], "\n", implode(",", (array) ($c["cors"]["allowed_origins"] ?? [])), "\n";
  ' 2>/dev/null)" || dp_die "Cannot read ${dir}/bootstrap/cache/config.php"
  got_app="$(sed -n 1p <<<"$got")"; got_cors="$(sed -n 2p <<<"$got")"
  [[ "${got_app%/}" == "${want_app%/}" ]] || dp_die "cached app.url '${got_app}' ≠ '${want_app}' — config belongs to another env"
  [[ -z "$want_fe" || ",${got_cors}," == *",${want_fe%/},"* ]] || dp_die "cached CORS '${got_cors}' lacks '${want_fe}'"
  dp_ok "config cache (app.url=${got_app})"
}

# Copy a finished `next build` (output: standalone) into <env>/frontend-run.
dp_publish_frontend() {
  local env_dir="$1" repo="$2" run="${1}/frontend-run"
  [[ -d "${repo}/frontend/.next/standalone" ]] || dp_die "No standalone build at ${repo}/frontend/.next/standalone"
  dp_info "Publishing frontend → ${run}"
  mkdir -p "$run"
  rsync -a --delete "${repo}/frontend/.next/standalone/" "${run}/"
  mkdir -p "${run}/frontend/.next"
  rsync -a --delete "${repo}/frontend/.next/static/" "${run}/frontend/.next/static/"
  [[ -d "${repo}/frontend/public" ]] && rsync -a --delete "${repo}/frontend/public/" "${run}/frontend/public/"
  FRONTEND_RUN="$run"
}
