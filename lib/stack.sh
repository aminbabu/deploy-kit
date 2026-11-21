#!/usr/bin/env bash
# Stack detection and adapter loader.
# Defaults: BACKEND_STACK=laravel, FRONTEND_STACK=next (nextjs aliased to next).

dp_normalize_backend_stack() {
  case "${1:-laravel}" in
    laravel | "") printf 'laravel' ;;
    node | nestjs | express | fastify | hono) printf 'node' ;;
    fastapi) printf 'fastapi' ;;
    django) printf 'django' ;;
    *) printf '%s' "$1" ;;
  esac
}

dp_normalize_frontend_stack() {
  case "${1:-next}" in
    next | nextjs | "") printf 'next' ;;
    nuxt | solidstart | nitro) printf 'nitro' ;;
    spa | vue | solid | vite) printf 'spa' ;;
    none) printf 'none' ;;
    *) printf '%s' "$1" ;;
  esac
}

dp_detect_backend_stack() {
  local dir="${1:-.}"
  if [[ -f "${dir}/artisan" && -f "${dir}/composer.json" ]]; then
    printf 'laravel'; return 0
  fi
  if [[ -f "${dir}/manage.py" ]]; then
    printf 'django'; return 0
  fi
  if [[ -f "${dir}/pyproject.toml" || -f "${dir}/requirements.txt" ]]; then
    if grep -qiE '\bfastapi\b' "${dir}/pyproject.toml" "${dir}/requirements.txt" 2>/dev/null; then
      printf 'fastapi'; return 0
    fi
    if grep -qiE '\bdjango\b' "${dir}/pyproject.toml" "${dir}/requirements.txt" 2>/dev/null; then
      printf 'django'; return 0
    fi
  fi
  if [[ -f "${dir}/package.json" ]]; then
    if grep -qiE '"(@nestjs/core|express|fastify|hono)"' "${dir}/package.json" 2>/dev/null; then
      printf 'node'; return 0
    fi
  fi
  printf 'laravel'
}

dp_detect_frontend_stack() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir" ]] || { printf 'none'; return 0; }
  if compgen -G "${dir}/next.config.*" >/dev/null 2>&1; then
    printf 'next'; return 0
  fi
  if compgen -G "${dir}/nuxt.config.*" >/dev/null 2>&1; then
    printf 'nitro'; return 0
  fi
  if compgen -G "${dir}/app.config.*" >/dev/null 2>&1 && grep -qiE '@solidjs/start' "${dir}/package.json" 2>/dev/null; then
    printf 'nitro'; return 0
  fi
  if compgen -G "${dir}/vite.config.*" >/dev/null 2>&1 || [[ -f "${dir}/index.html" ]]; then
    printf 'spa'; return 0
  fi
  printf 'next'
}

dp_load_stacks() {
  BACKEND_STACK="$(dp_normalize_backend_stack "${BACKEND_STACK:-laravel}")"
  FRONTEND_STACK="$(dp_normalize_frontend_stack "${FRONTEND_STACK:-next}")"

  local be_file="${DP_ROOT}/stacks/backend/${BACKEND_STACK}.sh"
  [[ -f "$be_file" ]] || dp_die "Unknown BACKEND_STACK '${BACKEND_STACK}' (expected file: ${be_file})"
  # shellcheck source=/dev/null
  source "$be_file"

  if [[ "$FRONTEND_STACK" != "none" ]]; then
    local fe_file="${DP_ROOT}/stacks/frontend/${FRONTEND_STACK}.sh"
    [[ -f "$fe_file" ]] || dp_die "Unknown FRONTEND_STACK '${FRONTEND_STACK}' (expected file: ${fe_file})"
    # shellcheck source=/dev/null
    source "$fe_file"
  fi
}
