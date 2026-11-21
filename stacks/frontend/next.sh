#!/usr/bin/env bash
# Frontend adapter: next (default, Next.js standalone server).

fe_public_env_prefix() { printf 'NEXT_PUBLIC_'; }
fe_runtime_mode() { printf 'node'; }
fe_entry_relpath() { printf 'server.js'; }

fe_publish_native() {
  local fe_src="$1" env_dir="$2"
  local sa=""
  if [[ -f "${fe_src}/.next/standalone/server.js" ]]; then
    sa="${fe_src}/.next/standalone"
  else
    sa="$(dirname "$(find "${fe_src}/.next/standalone" -maxdepth 3 -name server.js -print -quit 2>/dev/null || true)")"
  fi
  [[ -n "$sa" && -f "${sa}/server.js" ]] || dp_die "Next.js standalone output missing under ${fe_src}/.next/standalone (set output: 'standalone')."
  mkdir -p "${env_dir}/frontend"
  cp -a "${sa}/." "${env_dir}/frontend/"
  mkdir -p "${env_dir}/frontend/.next"
  [[ -d "${fe_src}/.next/static" ]] && cp -a "${fe_src}/.next/static" "${env_dir}/frontend/.next/static"
  [[ -d "${fe_src}/public" ]] && cp -a "${fe_src}/public" "${env_dir}/frontend/public"
  return 0
}
