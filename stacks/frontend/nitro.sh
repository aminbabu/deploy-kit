#!/usr/bin/env bash
# Frontend adapter: nitro (Nuxt.js & SolidStart — .output/server/index.mjs).

fe_public_env_prefix() { printf 'NUXT_PUBLIC_'; }
fe_runtime_mode() { printf 'node'; }
fe_entry_relpath() { printf 'server/index.mjs'; }

fe_publish_native() {
  local fe_src="$1" env_dir="$2"
  [[ -f "${fe_src}/.output/server/index.mjs" ]] || dp_die "Nitro build output missing at ${fe_src}/.output/server/index.mjs"
  mkdir -p "${env_dir}/frontend"
  cp -a "${fe_src}/.output/." "${env_dir}/frontend/"
  return 0
}
