# deploy-kit

Put your **Laravel** app (with or without a **Next.js** frontend) on your own Linux server by answering a few questions.

- One script installs everything, sets up HTTPS, and deploys your app.
- Run production, staging, dev, or any environment you name, side by side on one server.
- Each piece can run **in Docker**, be **installed directly on the server**, or live **on another server**. You choose per piece.
- Safe to run again: it remembers your answers, so pressing Enter keeps everything as it is.

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Add the kit to your app](#2-add-the-kit-to-your-app)
3. [Set up a server](#3-set-up-a-server)
4. [What the setup asks](#4-what-the-setup-asks)
5. [Everyday commands](#5-everyday-commands)
6. [What happens when you deploy](#6-what-happens-when-you-deploy)
7. [Deploy automatically from GitHub](#7-deploy-automatically-from-github)
8. [Where things are stored](#8-where-things-are-stored)
9. [Customising](#9-customising)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Before you start

**You need:**

- A Linux server with **systemd**. Ubuntu or Debian is recommended.
- A user on that server who can run `sudo`. Don't use root.
- A domain name, with its DNS pointing at the server. You can add DNS records during setup, but HTTPS certificates are issued only once DNS works.

**You don't need to pre-install anything else.** Docker, nginx, certbot, PHP, Composer, Node, PostgreSQL, MariaDB, Redis and MinIO are installed only if your choices need them, and the script asks before each install.

> Automatic installs use Ubuntu/Debian package names. On other distributions, install those programs yourself first; the script then uses them.

**Your app repository should look roughly like this.** Folder names can differ, because the setup asks for them:

```
your-app/
├── backend/    Laravel app
├── frontend/   Next.js app (optional, skip it for API-only projects)
└── deploy/     this kit (must be in a folder named "deploy")
```

**What your app needs:**

| | Needs |
|---|---|
| Laravel | A health route at `/up` (Laravel 11+ has it by default). |
| Next.js | `output: "standalone"` in `next.config.*`. |
| Docker runtime only | A backend `Dockerfile` running PHP-FPM on port **9000** with the code in `/var/www/html`, and a frontend `Dockerfile` serving port **3000**. |

**Docker image details** (only if you use the Docker runtime):

- Your frontend Dockerfile receives every `NEXT_PUBLIC_*` value as a build argument (`ARG NEXT_PUBLIC_API_URL` and so on).
- Backend containers get `CACHE_CONFIG=1` (cache the config on start) and `RUN_MIGRATIONS=0`, because the deploy script runs migrations itself. If your image has its own entrypoint script, make it honour these two variables.

---

## 2. Add the kit to your app

**Do this once per app, on your own computer.** It copies this kit into your app as a `deploy/` folder. The server gets the kit later by cloning your app, so the folder has to be committed and pushed.

Run this inside your app repository:

```bash
git subtree add --prefix deploy git@github.com:aminbabu/deploy-kit.git main --squash
```

To get kit updates later:

```bash
git subtree pull --prefix deploy git@github.com:aminbabu/deploy-kit.git main --squash
```

Push your app. Every clone of it now includes `deploy/`.

---

## 3. Set up a server

**Do this once per server.** Copy the installer from your app's `deploy/` folder to the server and run it:

```bash
scp deploy/install.sh user@your-server:~
ssh -t user@your-server 'bash ~/install.sh'
```

It asks for your **app's** Git URL and clones it. The kit comes along in `deploy/` from step 2, so deploy-kit itself isn't downloaded separately. It can create a read-only deploy key for you. Then it starts the setup questions, and when it finishes your app is live.

If your app is already on the server, answer **no** to "Clone?" and give its folder instead.

**Unattended setup:** put your answers in a file and add `--yes`:

```bash
bash ~/install.sh --answers answers.env --yes
```

See [`answers.example.env`](answers.example.env) for every option. Anything missing from the file falls back to its default.

---

## 4. What the setup asks

Every question shows a default in `[brackets]`. Press **Enter** to accept it.

### Your app

| Question | Example answer | What it means |
|---|---|---|
| Project name (slug) | `shop` | Used to name databases, containers, files. |
| Backend folder | `backend` | Where Laravel lives (detected automatically). |
| Next.js frontend? | `y` / `n` | `n` = API-only project. |
| Frontend folder | `frontend` | Where Next.js lives (detected automatically). |
| API path prefix | `/api/v1` | Used to build API and login-callback URLs. `none` = no prefix. |
| How to run the app | `docker` / `native` | See below. |

**docker vs native:**

- **docker:** your app runs in containers built from your Dockerfiles. Each release is an image, so a bad deploy rolls back automatically.
- **native:** PHP-FPM and Node run directly on the server under systemd. No Docker needed, and it uses less memory.

### The pieces your app uses

| Piece | Choices |
|---|---|
| Database | **PostgreSQL** or **MySQL/MariaDB**, run as `docker`, `native` or `external` |
| Redis | `docker`, `native`, `external`, or `none` (the database is used instead) |
| File uploads | `minio-docker`, `minio-native` (your own S3-compatible storage), `s3` (AWS S3, Cloudflare R2, Backblaze B2…), or `local` (server disk) |
| Background jobs | `horizon`, `worker` (plain `queue:work`), or `none` |
| Scheduled tasks | Laravel scheduler on or off |

- **docker** = runs in a container on this server
- **native** = installed directly on this server
- **external** = you already have it somewhere else; you enter its address

You can mix freely, for example: app in Docker, database installed natively, Redis in Docker.

### HTTPS

| Choice | Use when |
|---|---|
| `certbot` | Most servers. Free Let's Encrypt certificates, renewed automatically. |
| `byo` | You already have a certificate file. |
| `panel` | A hosting panel (CloudPanel, aaPanel…) already handles HTTPS. The setup prints the addresses to enter in the panel. |

### Environments

Pick any of `production`, `staging`, `dev`, `all`, or type your own names. For each one:

- **Domains:** for example `example.com` for the website and `api.example.com` for the API. Suggested automatically if you give a root domain.
- **Git branch:** for example `main` for production, `staging` for staging.
- **Ports:** internal only; free ones are suggested.

### Passwords

Database, Redis and MinIO passwords are **generated for you** when you just press Enter. You never need to type or remember them.

### App settings (`.env`)

You only get asked about what you use:

| Topic | You choose | Then it asks |
|---|---|---|
| Email | `log` (don't send), `smtp`, `mailgun`, `postmark`, `resend` | that service's settings only |
| SMS | `log` (don't send), `twilio`, `ssl`, `http` | that provider's settings only |
| Payments | any of `stripe`, `paypal`, `sslcommerz`, `bkash`, `nagad` (comma-separated), or none | keys for the ones you picked |
| Social login | any of `google`, `facebook`, `github`, or none | client ID and secret; callback URLs are filled in |

Environments after the first one reuse your earlier answers as defaults, so they're mostly Enter, Enter, Enter.

### Review and apply

You see a summary of everything before anything changes. Answer `y` and the setup:

1. saves your settings
2. installs what your choices need
3. starts the database, Redis and storage, and creates a database and bucket per environment
4. sets up nginx and HTTPS
5. offers optional server hardening (firewall, swap, automatic security updates)
6. builds and deploys your environments

---

## 5. Everyday commands

Run these on the server, inside your app folder.

| I want to… | Command |
|---|---|
| Deploy the latest code | `deploy/deploy.sh production --pull` |
| Deploy what's checked out | `deploy/deploy.sh production` |
| Undo the last deploy (docker runtime) | `deploy/deploy.sh production --rollback` |
| See if everything is running | `deploy/setup.sh status` |
| Find out what's wrong | `deploy/setup.sh doctor` |
| Change email, SMS, payment or login settings | `deploy/setup.sh vars production` |
| Change a domain | `deploy/setup.sh domains` |
| Switch how something runs (e.g. Redis docker → native) | `deploy/setup.sh components` |
| Add another environment | `deploy/setup.sh add-env staging` |
| Remove an environment (keeps its data) | `deploy/setup.sh remove-env staging` |
| Back up a database | `deploy/setup.sh backup production` |
| Restore a backup | `deploy/setup.sh restore production <file>` |
| Run migrations | `deploy/setup.sh migrate production` |
| Change all service passwords | `deploy/setup.sh rotate-secrets` |
| Redo HTTPS / nginx | `deploy/setup.sh edge` |
| Restart database/Redis/storage | `deploy/setup.sh services` |
| Harden the server | `deploy/setup.sh harden` |
| Save my answers for another server | `deploy/setup.sh export-answers` |

Add `--help` to either script to see all options.

---

## 6. What happens when you deploy

`deploy/deploy.sh <env>` does this, in order:

1. **Locks:** two deploys never run at once. Every deploy is logged.
2. **Refreshes settings:** URLs, CORS, database and Redis addresses are rewritten from your saved setup.
3. **Builds:** Docker images (docker runtime), or Composer install plus a Next.js build (native runtime).
4. **Backs up the database:** production and staging by default; the 10 newest backups are kept.
5. **Migrates:** runs `php artisan migrate`.
6. **Restarts gracefully:** background jobs finish their current task first.
7. **Checks health:** the API (`/up`) and the website must respond.
   - **docker:** if they don't, the previous release is restored automatically. Database migrations are not undone.
   - **native:** the deploy stops with an error so you can fix it.
8. **Checks CORS:** confirms the website can call the API.

---

## 7. Deploy automatically from GitHub

Copy [`examples/github-actions-cd.yml`](examples/github-actions-cd.yml) to `.github/workflows/cd.yml` in your app. Every push to `main` then deploys production.

Add these secrets in GitHub (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|---|---|
| `DEPLOY_SSH_HOST` | Server address |
| `DEPLOY_SSH_USER` | The deploy user |
| `DEPLOY_SSH_KEY` | A private SSH key that can log in as that user |
| `DEPLOY_REPO_PATH` | Optional. The app folder on the server; otherwise found automatically (set `DEPLOY_SLUG` in the workflow to your project name). |

Your app's secrets stay on the server. GitHub only triggers the deploy.

---

## 8. Where things are stored

With project name `shop`:

| Path | What's inside |
|---|---|
| `~/shop/project.env` | Your setup answers (no passwords) |
| `~/shop/shared/secrets.env` | Generated passwords (private, chmod 600) |
| `~/shop/production/.env` | The Laravel `.env` for production. Lines you add by hand are kept. |
| `~/shop/backups/production/` | Database backups (`.dump` for PostgreSQL, `.sql.gz` for MySQL) |
| `~/shop/shared/deploy.log` | History of every deploy |

---

## 9. Customising

**Add your own `.env` settings to the questions.** Create `deploy/vars.extra.catalog` (start from [`vars.extra.catalog.example`](vars.extra.catalog.example)). One line per setting:

```
KEY|kind|group|default|help text|options
```

| kind | Behaviour |
|---|---|
| `required` | Always asked |
| `gen` | Generated secret (like `APP_KEY`) |
| `select` | Pick one of `options`; then asks the keys in group `<group>-<choice>` |
| `multi` | Pick several of `options`; each one asks its group |
| `optional` / `secret` | Asked only when their group is picked (`secret` hides the input) |
| `managed` | Written by the scripts; never asked |

Defaults may use `{SLUG}`, `{ENV}`, `{ROOT_DOMAIN}`, `{FRONTEND_HOST}`, `{APP_NAME}`, `{DISK}` and `{KV}`.

**Other things you can change:**

- Docker image versions and memory limits: add `POSTGRES_IMAGE`, `MARIADB_IMAGE`, `REDIS_IMAGE`, `MINIO_IMAGE` or `APP_MEM_LIMIT` (also `NGINX_`, `HORIZON_`, `WORKER_`, `SCHEDULER_` and `FRONTEND_MEM_LIMIT`) to `~/<project>/project.env`.
- Queue worker options: `QUEUE_WORK_ARGS` in `project.env`.
- The superadmin seeder for `seed-admin`: `SEED_ADMIN_CLASS` in `project.env`.
- nginx, Docker Compose and systemd templates: in `nginx/`, `compose/` and `systemd/`.

---

## 10. Troubleshooting

| Problem | Fix |
|---|---|
| Docker commands say "permission denied" right after install | Log out, log back in, and run the command again (your user was just added to the `docker` group). |
| HTTPS certificate failed | Check that the domain's DNS points to this server and port 80 is open, then run `deploy/setup.sh edge`. |
| Website works but API calls fail (CORS) | Run `deploy/setup.sh doctor`. It tests the connection and tells you what's wrong. |
| Build gets killed on a small server | Add swap: `deploy/setup.sh harden`. |
| Backups fail with an external database | Install `postgresql-client` or `mariadb-client` on the server. |
| Something else | `deploy/setup.sh doctor`, then `deploy/setup.sh status`. |

Upgrading from an older version of this kit? Nothing to do: old settings are converted automatically.

---

## License

[MIT](LICENSE) © 2026 Amin Babu
