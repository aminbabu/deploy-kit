#!/usr/bin/env bash
# SDD verification harness for multi-stack deploy-kit.
set -euo pipefail

DP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (expected=%q, actual=%q)\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file"; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (%q not found in %s)\n' "$label" "$needle" "$file" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "1. Shell syntax checks (bash -n)"
while IFS= read -r -d '' shf; do
  bash -n "$shf"
done < <(find "$DP_ROOT" -maxdepth 3 -name "*.sh" -print0)
printf '  PASS: all .sh files pass bash -n\n'
PASS=$((PASS + 1))

# Load libraries for unit-level SDD assertions
for f in ui envfile os state system stack env-urls; do
  # shellcheck source=/dev/null
  source "${DP_ROOT}/lib/${f}.sh"
done

echo "2. Default stack invariant (laravel + next)"
unset BACKEND_STACK FRONTEND_STACK || true
PROJECT_SLUG="testapp"
dp_state_defaults
assert_eq "default BACKEND_STACK" "laravel" "$BACKEND_STACK"
assert_eq "default FRONTEND_STACK" "next" "$FRONTEND_STACK"
assert_eq "nextjs alias normalizes to next" "next" "$(dp_normalize_frontend_stack nextjs)"
assert_eq "nestjs alias normalizes to node" "node" "$(dp_normalize_backend_stack nestjs)"

echo "3. Auto-detection fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "${TMP}/lar/be" "${TMP}/lar/fe"
touch "${TMP}/lar/be/artisan" "${TMP}/lar/be/composer.json" "${TMP}/lar/fe/next.config.ts"
assert_eq "detect laravel" "laravel" "$(dp_detect_backend_stack "${TMP}/lar/be")"
assert_eq "detect next" "next" "$(dp_detect_frontend_stack "${TMP}/lar/fe")"

mkdir -p "${TMP}/nest/be" "${TMP}/nest/fe"
echo '{"dependencies":{"@nestjs/core":"^10.0.0"}}' > "${TMP}/nest/be/package.json"
touch "${TMP}/nest/fe/nuxt.config.ts"
assert_eq "detect node (nestjs)" "node" "$(dp_detect_backend_stack "${TMP}/nest/be")"
assert_eq "detect nitro (nuxt)" "nitro" "$(dp_detect_frontend_stack "${TMP}/nest/fe")"

mkdir -p "${TMP}/fast/be" "${TMP}/fast/fe"
printf 'fastapi==0.115.0\nuvicorn\n' > "${TMP}/fast/be/requirements.txt"
touch "${TMP}/fast/fe/vite.config.ts"
assert_eq "detect fastapi" "fastapi" "$(dp_detect_backend_stack "${TMP}/fast/be")"
assert_eq "detect spa (vite)" "spa" "$(dp_detect_frontend_stack "${TMP}/fast/fe")"

mkdir -p "${TMP}/dj/be" "${TMP}/dj/fe"
touch "${TMP}/dj/be/manage.py"
echo '{"dependencies":{"@solidjs/start":"^1.0.0"}}' > "${TMP}/dj/fe/package.json"
touch "${TMP}/dj/fe/app.config.ts"
assert_eq "detect django" "django" "$(dp_detect_backend_stack "${TMP}/dj/be")"
assert_eq "detect nitro (solidstart)" "nitro" "$(dp_detect_frontend_stack "${TMP}/dj/fe")"

echo "4. Adapter loading & health paths"
BACKEND_STACK=laravel FRONTEND_STACK=next dp_load_stacks
assert_eq "laravel health path" "/up" "$(be_health_path "${TMP}/lar")"
assert_eq "next runtime mode" "node" "$(fe_runtime_mode)"
assert_eq "next entrypoint" "server.js" "$(fe_entry_relpath)"

BACKEND_STACK=node FRONTEND_STACK=nitro dp_load_stacks
assert_eq "node health path" "/health" "$(be_health_path)"
assert_eq "nitro runtime mode" "node" "$(fe_runtime_mode)"
assert_eq "nitro entrypoint" "server/index.mjs" "$(fe_entry_relpath)"

BACKEND_STACK=fastapi FRONTEND_STACK=spa dp_load_stacks
assert_eq "fastapi health path" "/health" "$(be_health_path)"
assert_eq "spa runtime mode" "static" "$(fe_runtime_mode)"

BACKEND_STACK=django FRONTEND_STACK=next dp_load_stacks
assert_eq "django health path" "/health/" "$(be_health_path)"

echo "5. Security headers in new Nginx templates"
assert_contains "api-proxy X-Frame-Options" "X-Frame-Options" "${DP_ROOT}/nginx/api-proxy.conf.template"
assert_contains "api-proxy nosniff" "X-Content-Type-Options" "${DP_ROOT}/nginx/api-proxy.conf.template"
assert_contains "site-spa HSTS" "Strict-Transport-Security" "${DP_ROOT}/nginx/site-spa.conf.template"
assert_contains "site-spa X-Frame-Options" "X-Frame-Options" "${DP_ROOT}/nginx/site-spa.conf.template"
assert_contains "api-fpm blocks /storage/*.php" "/storage/.*\\.php" "${DP_ROOT}/nginx/api-fpm.conf.template"

printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
