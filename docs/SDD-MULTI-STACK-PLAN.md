# Spec-Driven Development (SDD) Plan: Dynamic Platform & Stack-Agnostic `deploy-kit`

**Status:** Draft Specification & Implementation Plan  
**Target Repository:** `deploy-kit`  
**Core Constraint:** **100% Backward Compatible** — existing Laravel + Next.js deployments (`e-recruitment` client/root, existing `state.env`, `vars.catalog`, `compose/app.yml`, and `artisan.service.tmpl`) must continue to work with zero breaking changes.

---

## 1. Problem Statement & Goals

Currently, `deploy-kit` hardcodes **Laravel** (PHP-FPM, `artisan`, `APP_KEY`, `DB_*`) for the backend and **Next.js `output: "standalone"`** (`.next/standalone/server.js`, `NEXT_PUBLIC_*`) for the frontend. However, ~80% of `deploy-kit` (OS detection, `apt`/`dnf`/`zypper`/`pacman`, PostgreSQL/MariaDB, Redis/Valkey, MinIO/S3, Nginx, Certbot TLS, SELinux, firewall, zero-downtime release symlinks, and systemd management) is already **stack-agnostic**.

### Goals
1. Support **any backend stack** via pluggable adapters:
   - `laravel` (default, unchanged)
   - `node` / `nestjs` (NestJS, Express, Fastify, Hono)
   - `fastapi` (Python ASGI — Uvicorn / Gunicorn + Alembic)
   - `django` (Python WSGI/ASGI — Gunicorn/Uvicorn + `manage.py` + `collectstatic` + Celery)
   - `custom` (bring-your-own HTTP service + start/migrate commands)
2. Support **any frontend stack** via pluggable adapters:
   - `next` (default, unchanged — Next.js `.next/standalone/server.js`; `nextjs` accepted as alias)
   - `nuxt` (Nuxt 3/4 Nitro — `.output/server/index.mjs`)
   - `solidstart` (SolidStart / Vinxi / Nitro — `.output/server/index.mjs`)
   - `spa` (Static Vite / Vue.js / SolidJS / React SPA — Nginx serves `dist/` with zero Node runtime)
   - `none` (API-only)
3. Keep all existing Laravel + Next.js defaults, variable names, and behavior intact when `BACKEND_STACK` (default `laravel`) / `FRONTEND_STACK` (default `next`) are unset.

---

## 2. Architecture: Pluggable Stack Adapters

```text
deploy-kit/
├── stacks/
│   ├── backend/
│   │   ├── laravel.sh      # Wraps existing PHP-FPM / artisan / Horizon logic (default)
│   │   ├── node.sh         # NestJS / Express / Fastify (Node HTTP server + Prisma/TypeORM)
│   │   ├── fastapi.sh      # Python venv + Gunicorn/Uvicorn + Alembic
│   │   └── django.sh       # Python venv + Gunicorn/Uvicorn + manage.py + collectstatic
│   └── frontend/
│       ├── next.sh         # Wraps existing .next/standalone logic (default)
│       ├── nitro.sh        # Nuxt.js & SolidStart (.output/server/index.mjs)
│       └── spa.sh          # Static dist/ (Vue.js, SolidJS, Vite) served directly by Nginx
├── catalogs/
│   ├── base.catalog        # Core + DB + Redis + Storage + Mail (shared)
│   ├── laravel.catalog     # Laravel-specific keys (existing vars.catalog subset)
│   ├── node.catalog        # DATABASE_URL, REDIS_URL, JWT_SECRET, PORT
│   └── python.catalog      # DATABASE_URL, REDIS_URL, SECRET_KEY, ALLOWED_HOSTS
├── nginx/
│   ├── api-fpm.conf.template       # Existing (Laravel)
│   ├── api-proxy.conf.template     # New: generic HTTP proxy_pass (NestJS, FastAPI, Django)
│   ├── site.conf.template          # Existing (SSR proxy)
│   └── site-spa.conf.template      # New: static SPA root + try_files /index.html
├── systemd/
│   ├── artisan.service.tmpl        # Existing (Laravel)
│   ├── frontend.service.tmpl       # Existing (Node SSR: Next.js, Nuxt, SolidStart)
│   └── app-service.tmpl            # New: generic backend/worker unit (Node, Gunicorn, Celery)
└── compose/
    ├── app.yml                     # Existing (Laravel + Next.js, untouched)
    └── app-http.yml                # New: generic HTTP backend + optional worker + frontend
```

---

## 3. Adapter Contract Specification

### 3.1 Backend Adapter Interface (`stacks/backend/<stack>.sh`)
Every backend adapter **must** implement the following bash functions:

| Function | Responsibility |
| :--- | :--- |
| `be_detect <repo_dir>` | Returns `0` if the repo matches this stack (used for auto-detection in `setup.sh`). |
| `be_prereqs` | Installs/verifies runtime prerequisites (`php`+`composer` \| `node` \| `python3`+`venv`). |
| `be_env_sync <env> <env_file>` | Writes stack-specific managed env vars (`DATABASE_URL`, `REDIS_URL`, `PORT`, etc.). |
| `be_build_native <src> <run> <env_file>` | Installs dependencies and builds artifacts (e.g., `npm ci && npm run build`, `pip install`). |
| `be_migrate <run> <env_file>` | Runs database migrations (`php artisan migrate --force`, `alembic upgrade head`, etc.). |
| `be_nginx_native <env> <out_conf>` | Renders Nginx loopback server config (`api-fpm.conf.template` or `api-proxy.conf.template`). |
| `be_systemd_units <env> <run> <env_file>` | Installs/restarts app server (+ optional worker/scheduler) systemd units. |
| `be_health_path <repo_dir>` | Suggests default health path (`/up` for Laravel, `/health` for NestJS/FastAPI, `/health/` for Django). |

### 3.2 Frontend Adapter Interface (`stacks/frontend/<stack>.sh`)
Every frontend adapter **must** implement:

| Function | Responsibility |
| :--- | :--- |
| `fe_detect <fe_dir>` | Returns `0` if `fe_dir` matches (`next.config.*`, `nuxt.config.*`, `vite.config.*`, etc.). |
| `fe_public_env_prefix` | Returns env prefix (`NEXT_PUBLIC_`, `NUXT_PUBLIC_`, `VITE_`). |
| `fe_publish_native <fe_src> <env_dir>` | Stages built output (`.next/standalone`, `.output`, or `dist/`) into the release directory. |
| `fe_runtime_mode` | Returns `node` (starts `frontend.service.tmpl` with `__ENTRY__`) or `static` (Nginx serves `dist/` directly). |
| `fe_entry_relpath` | Returns relative JS entrypoint (`server.js` for Next.js, `server/index.mjs` for Nuxt/SolidStart). |

---

## 4. Acceptance Specifications (BDD / Given-When-Then)

### Spec 1: Zero-Regression Backward Compatibility (`laravel` + `next`)
- **Given** a repository with `backend/artisan` and `frontend/next.config.ts` (and no `BACKEND_STACK` / `FRONTEND_STACK` in `state.env`)
- **When** `setup.sh` or `deploy.sh` runs
- **Then** `BACKEND_STACK` resolves to `laravel`, `FRONTEND_STACK` resolves to `next`, `compose/app.yml` and `nginx/api-fpm.conf.template` are used verbatim, and all existing `vars.catalog` keys behave identically.

### Spec 2: NestJS + Nuxt.js / SolidStart Deployment
- **Given** a repo with `backend/package.json` containing `@nestjs/core` and `frontend/nuxt.config.ts` (or SolidStart `app.config.ts`)
- **When** `setup.sh` runs
- **Then** `BACKEND_STACK=node` and `FRONTEND_STACK=nitro` are detected; `env-urls.sh` generates `DATABASE_URL` and `REDIS_URL`; Nginx uses `api-proxy.conf.template` (`proxy_pass http://127.0.0.1:${API_PORT}`); and `frontend.service.tmpl` launches `node .output/server/index.mjs`.

### Spec 3: FastAPI / Django + Static Vue.js / SolidJS SPA Deployment
- **Given** a Python backend (`pyproject.toml` / `requirements.txt` with `fastapi` or `django`) and a Vite SPA (`frontend/vite.config.ts`)
- **When** `setup.sh` and `deploy.sh` run
- **Then** `native.sh` creates a Python `venv`, installs dependencies, runs `alembic upgrade head` (FastAPI) or `manage.py migrate --noinput && collectstatic --noinput` (Django), runs Gunicorn/Uvicorn via `app-service.tmpl`, and configures Nginx with `site-spa.conf.template` serving `dist/` directly without a Node frontend service.

### Spec 4: Security Parity Across All Stacks
- **Then** every generated Nginx template (`api-proxy.conf.template`, `site-spa.conf.template`) **must** include `X-Frame-Options`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, and `Strict-Transport-Security`, and `services.yml` **must** enforce non-empty service passwords (`:?`).

---

## 5. Phased Implementation Roadmap

### Phase 1: Adapter Scaffolding & Backward-Compat Refactor
- [ ] Add `BACKEND_STACK` (default `laravel`) and `FRONTEND_STACK` (default `next`, aliasing `nextjs`) to `lib/state.sh`.
- [ ] Extract existing Laravel logic into `stacks/backend/laravel.sh` and Next.js logic into `stacks/frontend/next.sh` with **zero** behavioral change.
- [ ] Add `lib/stack.sh` loader (`dp_load_stacks`) and auto-detection in `setup.sh`.

### Phase 2: Generic HTTP Proxy, Systemd, Compose & Env Catalogs
- [ ] Add `nginx/api-proxy.conf.template` (HTTP `proxy_pass`, WebSocket headers, security headers) and `nginx/site-spa.conf.template` (static SPA + `/api` proxy option).
- [ ] Add `systemd/app-service.tmpl` and `compose/app-http.yml`.
- [ ] Update `lib/env-urls.sh` to emit `DATABASE_URL` and `REDIS_URL` for non-Laravel stacks alongside Laravel's `DB_*` / `REDIS_*`.
- [ ] Split `vars.catalog` cleanly or load `catalogs/<stack>.catalog` dynamically after `vars.catalog` (keeping `vars.catalog` intact for Laravel).

### Phase 3: New Stack Adapters
- [ ] Implement `stacks/backend/node.sh` (NestJS, Express, Fastify, Hono).
- [ ] Implement `stacks/backend/fastapi.sh` (Uvicorn/Gunicorn + Alembic + optional Celery).
- [ ] Implement `stacks/backend/django.sh` (Gunicorn/Uvicorn + `manage.py` + `collectstatic` + `/static/` Nginx alias + optional Celery).
- [ ] Implement `stacks/frontend/nitro.sh` (Nuxt.js & SolidStart `.output/server/index.mjs`).
- [ ] Implement `stacks/frontend/spa.sh` (Vue.js, SolidJS, Vite static `dist/`).

### Phase 4: SDD Test Harness & CI Verification
- [ ] Add `tests/run.sh` in `deploy-kit` testing:
  - Syntax (`bash -n`) across all scripts and adapters
  - Auto-detection on fixture directories (`laravel+nextjs`, `nestjs+nuxt`, `fastapi+spa`, `django+solidstart`)
  - Env generation (`DATABASE_URL`, `REDIS_URL`, `SESSION_SECURE_COOKIE`)
  - Nginx & systemd template rendering assertions (including security headers and `/storage/*.php` block).
- [ ] Update `deploy-kit/README.md` with multi-stack examples and matrix.
