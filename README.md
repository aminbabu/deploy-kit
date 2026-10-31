# deploy-kit

Interactive, re-runnable server installer and deploy tooling for a **Laravel API + Next.js frontend** monorepo. Copy one file to any fresh Linux server, answer the prompts, and get one or more environments (production, staging, dev, or your own names). Each gets its own domains, database, Redis DB, bucket, TLS, Horizon and scheduler. Nothing is tied to a domain or hosting provider.

## What your app repo needs

```
your-app/
├── backend/            Laravel; Dockerfile (php-fpm, port 9000) + docker/entrypoint.sh honouring
│                       RUN_MIGRATIONS / CACHE_CONFIG; routes /up and /api/v1/health
├── frontend/           Next.js with output: "standalone"; Dockerfile taking NEXT_PUBLIC_* build args
├── pnpm-workspace.yaml (host runtime builds the frontend with pnpm)
└── deploy/             ← this kit (copy, git subtree, or submodule)
```

Add the kit to your app:

```bash
git subtree add --prefix deploy git@github.com:aminbabu/deploy-kit.git main --squash
# update later: git subtree pull --prefix deploy git@github.com:aminbabu/deploy-kit.git main --squash
```

## Quick start (fresh server)

```bash
scp deploy/install.sh user@server:~
ssh -t user@server 'bash ~/install.sh'
```

The installer asks, in order:

1. **Clone?** If yes, it asks for the repository URL, the target path and the branch. It can create a read-only deploy key and wait while you add it. If no, it asks for the path of an existing checkout.
2. **Project:** slug (names databases, buckets, containers, units and nginx files), app home (default `~/<slug>`) and runtime:
   - `docker`: the app runs in containers.
   - `host`: PHP-FPM and Node under systemd. Horizon still runs in a container.
3. **Data services:**
   - `bundled`: Postgres 16, Redis 7 and MinIO in Docker, bound to loopback.
   - `external`: your own servers.
4. **Public edge:**
   - `certbot`: nginx plus Let's Encrypt, with automatic renewal.
   - `byo`: nginx plus your own certificate.
   - `panel`: an existing panel such as CloudPanel terminates HTTPS. The installer prints the upstreams to paste into it.
5. **Environments:** any of `production`, `staging`, `dev`, `all`, or custom names. For each one it asks:
   - client domain and API domain (they must differ)
   - git branch
   - loopback ports (free ones are suggested)
6. **Variables** from [`vars.catalog`](vars.catalog):
   - Every required variable is asked. `APP_KEY` and passwords are generated.
   - Optional groups (mail, payments, oauth, sms, storage) can be configured now or later.
7. **Review**, then apply. Apply writes state and env files, starts the services, creates databases, roles and buckets, configures the edge, offers optional hardening, and builds and deploys the chosen environments one after another.

Re-runs pre-fill every answer, including secrets, so pressing Enter changes nothing. For unattended runs, use `deploy/setup.sh --answers answers.env --yes` (see [`answers.example.env`](answers.example.env)).

## Day-2 commands

```bash
deploy/deploy.sh <env> [--pull] [--no-backup] [--rollback]
deploy/setup.sh status | doctor
deploy/setup.sh add-env <env> | remove-env <env>
deploy/setup.sh vars <env> | domains | edge | services
deploy/setup.sh rotate-secrets | harden
deploy/setup.sh backup <env> | restore <env> <file>
deploy/setup.sh migrate <env> | seed-admin <env>      # seed-admin needs SEED_ADMIN_CLASS in project.env
deploy/setup.sh export-answers [file]
```

## What a deploy does

1. Takes the deploy lock (`flock`), so CD and manual deploys never overlap. Every run is appended to `<app home>/shared/deploy.log`.
2. Re-syncs the env's managed settings (URLs, CORS, Sanctum, session domain, OAuth callbacks, DB, Redis, storage) from state and secrets.
3. Builds:
   - **docker:** images tagged `<slug>-backend|frontend:<env>-<commit>`.
   - **host:** a per-env Laravel copy (its own config cache), a per-env Next.js standalone build, and a Horizon image.
4. Backs up the database before migrating (envs in `BACKUP_ENVS`, newest `BACKUP_KEEP` kept).
5. Migrates, terminates Horizon gracefully and starts the release.
6. Health gate on the API `/up` and the frontend.
   - **docker:** a failure restarts the previous release automatically (migrations are not reverted).
7. Checks CORS from the client origin.

## Files on the server

| Path | Contents |
|---|---|
| `~/<slug>/project.env` | State, no secrets: runtime, edge, envs, domains, ports, branches, releases |
| `~/<slug>/shared/secrets.env` | Service and DB passwords (chmod 600) |
| `~/<slug>/<env>/.env` | Env settings (chmod 600); keys you add by hand are kept |
| `~/<slug>/backups/<env>/` | Pre-migration dumps |
| `~/.<slug>.deploy` | Pointer to the app home and checkout (used by `deploy.sh` and CD) |

## CI/CD

[`examples/github-actions-cd.yml`](examples/github-actions-cd.yml) deploys `main` → production over SSH. On the server it hard-resets the checkout to the pushed branch, then runs `deploy/deploy.sh production`.

| Repository secret | Value |
|---|---|
| `DEPLOY_SSH_HOST`, `DEPLOY_SSH_USER`, `DEPLOY_SSH_KEY` | SSH access for the deploy user |
| `DEPLOY_REPO_PATH` | Optional; otherwise read from `~/.<slug>.deploy` (set `DEPLOY_SLUG` in the workflow) |

## Customising

- **New variable:** add `KEY|kind|group|default|help` to `vars.catalog`.
  - `kind` is one of `required`, `optional`, `secret`, `gen` or `managed`.
  - Defaults may use `{SLUG}`, `{ENV}`, `{ROOT_DOMAIN}`, `{FRONTEND_HOST}` and `{APP_NAME}`.
- **nginx output:** `nginx/*.template`. **Compose stacks:** `compose/*.yml`. **systemd units:** `systemd/*.tmpl`.

Requirements on the server: Linux with systemd, bash ≥ 4, sudo. Docker, nginx, certbot and the other packages are installed when missing, after asking.

## License

[MIT](LICENSE) © 2026 Amin Babu
