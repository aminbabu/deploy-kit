# Multi-Stack Implementation Plan (`deploy-kit`)

**Reference Spec:** [SDD-MULTI-STACK-PLAN.md](file:///Users/aminbabu/Development/WebWorld/deploy-kit/docs/SDD-MULTI-STACK-PLAN.md)  
**Defaults:** `BACKEND_STACK=laravel`, `FRONTEND_STACK=next` (`nextjs` aliased to `next`)  
**Constraint:** Zero breaking changes to existing Laravel + Next.js deployments.

---

## Task 1: Stack Loader & State Defaults
- **Files:** `lib/state.sh`, `lib/stack.sh` (new)
- **Changes:**
  - In `lib/state.sh`, default `BACKEND_STACK="${BACKEND_STACK:-laravel}"` and `FRONTEND_STACK="${FRONTEND_STACK:-next}"` (normalizing `nextjs` → `next`).
  - Create `lib/stack.sh`:
    - `dp_detect_backend_stack <repo_dir>`: returns `laravel` (`artisan` + `composer.json`), `node` (`package.json` with `@nestjs/core`, `express`, `fastify`, `hono`), `django` (`manage.py`), `fastapi` (`requirements.txt` / `pyproject.toml` containing `fastapi`), or `laravel` fallback.
    - `dp_detect_frontend_stack <fe_dir>`: returns `next` (`next.config.*`), `nitro` (`nuxt.config.*` or `app.config.*` with `@solidjs/start`), `spa` (`vite.config.*` / `index.html`), or `none`.
    - `dp_load_stacks`: sources `${DP_ROOT}/stacks/backend/${BACKEND_STACK}.sh` and `${DP_ROOT}/stacks/frontend/${FRONTEND_STACK}.sh`.
- **Verification:** `bash -n lib/stack.sh lib/state.sh`

---

## Task 2: Default Stack Adapters (`laravel` & `next`) — Zero Regression
- **Files:** `stacks/backend/laravel.sh` (new), `stacks/frontend/next.sh` (new)
- **Changes:**
  - Implement all 8 `be_*` contract functions in `stacks/backend/laravel.sh` delegating to the existing PHP-FPM / Composer / `artisan` / Horizon / `api-fpm.conf.template` behavior.
  - Implement all 5 `fe_*` contract functions in `stacks/frontend/next.sh` delegating to the existing `.next/standalone/server.js` / `NEXT_PUBLIC_*` / `frontend.service.tmpl` behavior.
- **Verification:** Existing Laravel + Next.js flow resolves identically (`BACKEND_STACK=laravel`, `FRONTEND_STACK=next`).

---

## Task 3: Agnostic Nginx, Systemd, Compose, & Env Primitives
- **Files:**
  - `nginx/api-proxy.conf.template` (new)
  - `nginx/site-spa.conf.template` (new)
  - `systemd/app-service.tmpl` (new)
  - `compose/app-http.yml` (new)
  - `lib/env-urls.sh` (update)
- **Changes:**
  - `nginx/api-proxy.conf.template`: HTTP `proxy_pass http://127.0.0.1:${API_PORT}`, WebSocket upgrade headers, `X-Served-By`, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, and optional `/static/` alias for Django.
  - `nginx/site-spa.conf.template`: Static `root ${FRONTEND_DIST}; try_files $uri $uri/ /index.html;` with TLS + security headers (`Strict-Transport-Security`, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`) and optional `/api/` proxy when `FRONTEND_API_MODE=proxy`.
  - `systemd/app-service.tmpl`: Generic systemd unit with `EnvironmentFile=-__ENV__`, `WorkingDirectory=__RUN__`, `ExecStart=__CMD__`, `NoNewPrivileges=true`, `PrivateTmp=true`.
  - `compose/app-http.yml`: Generic HTTP app container (`ports: 127.0.0.1:${API_PORT}:8000` or `${APP_PORT}`), optional `worker` profile, optional `frontend` profile, external `${DP_NETWORK:?}`.
  - `lib/env-urls.sh`: Keep all existing Laravel keys untouched; additionally emit `DATABASE_URL` (`postgresql://...` or `mysql://...`) and `REDIS_URL` (`redis://...`) when `BACKEND_STACK != laravel`.

---

## Task 4: New Backend Stack Adapters (`node`, `fastapi`, `django`)
- **Files:** `stacks/backend/node.sh`, `stacks/backend/fastapi.sh`, `stacks/backend/django.sh`, `catalogs/node.catalog`, `catalogs/python.catalog`
- **Changes:**
  - **`node.sh` (NestJS / Express / Fastify / Hono):**
    - `be_prereqs`: Node.js via `dp_os_install_node` (signed apt/rpm repo).
    - `be_build_native`: `npm ci` / `pnpm install --frozen-lockfile` + `npm run build` (`dist/main.js` or `package.json` `main`).
    - `be_migrate`: runs `$MIGRATE_CMD` if configured (e.g., `npx prisma migrate deploy`).
    - `be_systemd_units`: renders `systemd/app-service.tmpl` (`node dist/main.js` or `$START_CMD`).
  - **`fastapi.sh`:**
    - `be_prereqs`: `python3`, `python3-venv`, `python3-pip`.
    - `be_build_native`: creates `${run}/.venv`, installs `requirements.txt` or `pyproject.toml`.
    - `be_migrate`: runs `alembic upgrade head` if `alembic.ini` exists.
    - `be_systemd_units`: runs `.venv/bin/gunicorn -k uvicorn.workers.UvicornWorker` (or `uvicorn`) + optional Celery worker.
  - **`django.sh`:**
    - `be_prereqs`: `python3`, `python3-venv`, `python3-pip`.
    - `be_build_native`: creates `${run}/.venv`, installs deps, runs `python manage.py collectstatic --noinput`.
    - `be_migrate`: runs `python manage.py migrate --noinput`.
    - `be_systemd_units`: runs `.venv/bin/gunicorn` + optional Celery worker/beat.

---

## Task 5: New Frontend Stack Adapters (`nitro`, `spa`)
- **Files:** `stacks/frontend/nitro.sh`, `stacks/frontend/spa.sh`
- **Changes:**
  - **`nitro.sh` (Nuxt.js & SolidStart):**
    - `fe_public_env_prefix`: `NUXT_PUBLIC_` (Nuxt) or `VITE_` (SolidStart).
    - `fe_publish_native`: copies `.output/` into release directory.
    - `fe_runtime_mode`: `node` (`node .output/server/index.mjs` via `systemd/frontend.service.tmpl`).
  - **`spa.sh` (Vue.js, SolidJS, Vite):**
    - `fe_public_env_prefix`: `VITE_`.
    - `fe_publish_native`: copies `dist/` into release directory.
    - `fe_runtime_mode`: `static` (served directly by Nginx via `nginx/site-spa.conf.template`; no Node service).

---

## Task 6: Wire Adapters into `setup.sh` & `deploy.sh`
- **Files:** `setup.sh`, `deploy.sh`, `lib/native.sh`, `lib/edge.sh`
- **Changes:**
  - In `setup.sh`, auto-detect `BACKEND_STACK` and `FRONTEND_STACK` (defaulting to `laravel` and `next`), allow override, and load stack-specific catalog keys when `BACKEND_STACK != laravel`.
  - In `deploy.sh` and `lib/native.sh`, dispatch build, migrate, Nginx, and systemd/compose calls through `be_*` and `fe_*` adapter functions (preserving exact existing behavior for `laravel` + `next`).

---

## Task 7: Automated SDD Verification Harness (`tests/run.sh`)
- **Files:** `tests/run.sh` (new), `README.md` (update)
- **Changes:**
  - `bash -n` syntax validation across all `.sh` files (`setup.sh`, `deploy.sh`, `lib/*.sh`, `stacks/**/*.sh`).
  - Fixture-based tests for:
    1. `laravel` + `next` (default & auto-detect regression)
    2. `node` (NestJS) + `nitro` (Nuxt / SolidStart)
    3. `fastapi` + `spa` (Vue / SolidJS)
    4. `django` + `next`
  - Assertions on `DATABASE_URL` / `REDIS_URL` formatting, `SESSION_SECURE_COOKIE`, Nginx security headers, and `/storage/*.php` `403` block.
