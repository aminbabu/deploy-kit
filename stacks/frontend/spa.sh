#!/usr/bin/env bash
# Frontend adapter: spa (Vue.js, SolidJS, Vite static dist/ served directly by Nginx).

fe_public_env_prefix() { printf 'VITE_'; }
fe_runtime_mode() { printf 'static'; }
fe_entry_relpath() { printf ''; }

fe_publish_native() {
  local fe_src="$1" env_dir="$2"
  local dist_dir="${fe_src}/dist"
  [[ -d "$dist_dir" ]] || dist_dir="${fe_src}/build"
  [[ -d "$dist_dir" ]] || dp_die "Static SPA build output missing (expected ${fe_src}/dist or ${fe_src}/build)"
  mkdir -p "${env_dir}/frontend"
  cp -a "${dist_dir}/." "${env_dir}/frontend/"
  return 0
}
