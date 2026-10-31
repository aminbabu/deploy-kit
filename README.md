# deploy-kit

Interactive, re-runnable server installer and deploy tooling for a **Laravel API, with an optional Next.js frontend**. Copy one file to any fresh Linux server, answer the prompts, and get one or more environments (production, staging, dev, or your own names). Each environment gets its own domains, database, Redis DB, bucket and TLS.

Every component can run **in Docker** or **natively** on the server (distro packages plus systemd), independently of the others. The database, Redis and storage can also be **external**. Nothing is tied to a domain, hosting provider or repository layout.

## What your app repo needs

Any layout works; the wizard asks for the directories and suggests the ones it finds. For example:

```
your-app/
├── backend/   Laravel (routes /up and <API prefix>/health)
│              docker runtime: a Dockerfile serving php-fpm on :9000 with the code in /var/www/html
├── frontend/  optional Next.js app with output: "standalone"
│              docker runtime: a Dockerfile serving :3000; every NEXT_PUBLIC_* is passed as a build arg
└── deploy/    ← this kit (copy, git subtree, or submodule)
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
2. **Project:** slug (names databases, buckets, containers, units and nginx files) and app home (default `~/<slug>`).
3. **Application:**
   - backend directory, and whether there is a Next.js frontend (and its directory). No frontend means an API-only deploy.
   - API path prefix (default `/api/v1`, `none` for no prefix)
   - runtime:
     - `docker`: containers built from your Dockerfiles (it asks which Dockerfile and build context to use)
     - `native`: PHP-FPM, Composer and Node on the host (installed when missing). Frontend install and build commands are detected from your lockfile.
4. **Components.** Each one is chosen on its own:

   | Component | Choices |
   |---|---|
   | Database | engine `pgsql` or `mysql` (MariaDB), run as `docker`, `native` or `external` |
   | Redis | `docker`, `native`, `external`, or `none` (cache, session and queue use the database) |
   | File storage | `minio-docker`, `minio-native`, `s3` (AWS S3/R2/B2) or `local` |
   | Queue worker | `horizon`, `worker` (plain `queue:work`) or `none`. It runs as a container or a systemd unit, following the app runtime. |
   | Scheduler | on or off |

   When the app runs in Docker and a service is native, that service also listens on the project's Docker network gateway, and ufw is opened for that subnet only.
5. **Public edge:**
   - `certbot`: nginx plus Let's Encrypt, with automatic renewal.
   - `byo`: nginx plus your own certificate.
   - `panel`: an existing panel such as CloudPanel terminates HTTPS. The installer prints the upstreams to paste into it.
6. **Environments:** any of `production`, `staging`, `dev`, `all`, or custom names. For each one it asks:
   - API domain, plus a client domain when there is a frontend (the two must differ)
   - git branch
   - loopback ports (free ones are suggested)
   - connection details, when the database is external
7. **Service settings:** ports, admin users and passwords (generated when left empty), and the public media domain for MinIO.
8. **Variables** from [`vars.catalog`](vars.catalog). Only what you choose is asked:
   - **Mail:** `log` (no mail), `smtp`, `mailgun`, `postmark` or `resend`, then that transport's keys
   - **SMS:** `log` (no SMS), `twilio`, `ssl` or `http`, then that provider's keys
   - **Payments:** any of `stripe`, `paypal`, `sslcommerz`, `bkash`, `nagad`, or none
   - **Social login:** any of `google`, `facebook`, `github`, or none. Callback URLs are generated.
   - **S3 keys**, when storage is `s3`
   - core settings. `APP_KEY` and passwords are generated.
9. **Review**, then apply. Apply writes state and env files, installs what the chosen modes need, starts or configures the services, creates databases, users and buckets, configures the edge, offers optional hardening, and builds and deploys the chosen environments one after another.

Re-runs pre-fill every answer, including secrets, so pressing Enter changes nothing. For unattended runs, use `deploy/setup.sh --answers answers.env --yes` (see [`answers.example.env`](answers.example.env)).

## Day-2 commands

```bash
deploy/deploy.sh <env> [--pull] [--no-backup] [--rollback]
deploy/setup.sh status | doctor
deploy/setup.sh add-env <env> | remove-env <env>
deploy/setup.sh vars <env>            # mail/SMS/payments/OAuth/… choices and keys
deploy/setup.sh components            # app paths, runtime, each component's mode
deploy/setup.sh domains | edge | services
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
   - **native:** a per-env Laravel copy (its own config cache) and a per-env Next.js standalone build. The frontend, queue worker and scheduler run as systemd units `<slug>-{frontend,worker,scheduler}-<env>`.
4. Backs up the database before migrating (envs in `BACKUP_ENVS`, newest `BACKUP_KEEP` kept).
5. Migrates, drains the queue worker gracefully (`horizon:terminate` / `queue:restart`), starts the release and stops components that were switched off.
6. Health gate on the API `/up` and on the frontend, if there is one.
   - **docker:** a failure restarts the previous release automatically (migrations are not reverted).
7. Checks CORS from the client origin (frontend deployments only).

## Files on the server

| Path | Contents |
|---|---|
| `~/<slug>/project.env` | State, no secrets: app layout, component modes, edge, envs, domains, ports, branches, releases |
| `~/<slug>/shared/secrets.env` | Service and DB passwords (chmod 600) |
| `~/<slug>/<env>/.env` | Env settings (chmod 600); keys you add by hand are kept |
| `~/<slug>/backups/<env>/` | Pre-migration dumps (`.dump` for PostgreSQL, `.sql.gz` for MySQL/MariaDB) |
| `~/.<slug>.deploy` | Pointer to the app home and checkout (used by `deploy.sh` and CD) |

## CI/CD

[`examples/github-actions-cd.yml`](examples/github-actions-cd.yml) deploys `main` → production over SSH. On the server it hard-resets the checkout to the pushed branch, then runs `deploy/deploy.sh production`.

| Repository secret | Value |
|---|---|
| `DEPLOY_SSH_HOST`, `DEPLOY_SSH_USER`, `DEPLOY_SSH_KEY` | SSH access for the deploy user |
| `DEPLOY_REPO_PATH` | Optional; otherwise read from `~/.<slug>.deploy` (set `DEPLOY_SLUG` in the workflow) |

## Customising

- **New variable:** add `KEY|kind|group|default|help|options` to `vars.catalog`. For project-specific keys, use `deploy/vars.extra.catalog` (see [`vars.extra.catalog.example`](vars.extra.catalog.example)).
  - `kind` is `required`, `gen`, `managed`, `select` (pick one), `multi` (pick several), or `optional`/`secret` (asked only when their group is chosen).
  - A `select`/`multi` key in group `pay` with the choice `x` asks every key in group `pay-x`.
  - Defaults may use `{SLUG}`, `{ENV}`, `{ROOT_DOMAIN}`, `{FRONTEND_HOST}`, `{APP_NAME}`, `{DISK}` and `{KV}`.
- **Images and limits:** `POSTGRES_IMAGE`, `MARIADB_IMAGE`, `REDIS_IMAGE`, `MINIO_IMAGE`, `*_MEM_LIMIT` and `QUEUE_WORK_ARGS` can be set in `project.env`.
- **nginx output:** `nginx/*.template`. **Compose stacks:** `compose/*.yml`. **systemd units:** `systemd/*.tmpl`.

Requirements on the server: Linux with systemd (Debian/Ubuntu for native installs; dnf works for most packages), bash ≥ 4, sudo. Docker, nginx, certbot, PHP, Composer, Node, PostgreSQL, MariaDB, Redis and MinIO are installed when a chosen mode needs them, after asking.

Existing installs from earlier versions (`RUNTIME=host`, `SERVICES_MODE=bundled|external`) are read as the equivalent per-component settings.

## License

[MIT](LICENSE) © 2026 Amin Babu
