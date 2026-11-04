# deploy-kit

**Deploy a Laravel app (with or without a Next.js frontend) to your own Linux server by answering questions.**
It installs what's needed, sets up HTTPS, and deploys. No Docker or Linux expertise required.

---

## Quick start: 3 steps

### Step 1 — Add the kit to your app *(once, on your computer)*

In your app's repository:

```bash
git subtree add --prefix deploy git@github.com:aminbabu/deploy-kit.git main --squash
git push
```

Your app now has a `deploy/` folder. That's the only change to your app.

### Step 2 — Run the installer *(once, on the server)*

Log into your server and paste:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aminbabu/deploy-kit/main/install.sh)
```

It asks for your app's Git URL, clones it, and starts the setup.

### Step 3 — Answer the questions

Every question has a sensible default in `[brackets]`; **press Enter to accept it**. At the end you see a summary, type `y`, and your app is live at `https://your-domain`.

Passwords you leave empty are generated for you. **They're printed once at the end under "Generated credentials — save them now"**, so copy them to your password manager. To see them again later, run `deploy/setup.sh credentials`.

**To deploy new code later:**

```bash
deploy/deploy.sh production --pull
```

---

## Before you start

- [ ] A **Linux server with systemd** and a **user with `sudo`** (not root). Supported: Debian/Ubuntu, RHEL/Rocky/AlmaLinux/CentOS Stream/Oracle Linux/Fedora/Amazon Linux, openSUSE/SLES, and Arch/Manjaro. See [Which Linux?](#which-linux)
- [ ] Your **domain's DNS** pointing to the server (needed for HTTPS)
- [ ] Your Laravel app has the `/up` route (built into Laravel 11+)
- [ ] If you have a Next.js frontend: `output: "standalone"` in `next.config.js`

Nothing else needs installing; the setup installs what it needs and asks first.

Your app's folders can have any names, because the setup finds them. A typical layout:

```
your-app/
├── backend/     Laravel
├── frontend/    Next.js (optional)
└── deploy/      this kit (from step 1)
```

---

## Not sure what to answer?

Pick the row closest to your server and use those answers.

| Your situation | HTTPS | Run app as | Database | Redis | File uploads |
|---|---|---|---|---|---|
| **Fresh VPS** (most people) | `certbot` | `docker` | `docker` | `docker` | `minio-docker` |
| **CloudPanel / aaPanel already installed** | `panel` | `docker` | `docker` | `docker` | `minio-docker` |
| **Small VPS (1–2 GB RAM), no Docker** | `certbot` | `native` | `native` | `native` | `local` |
| **Managed DB + S3 (AWS, RDS…)** | `certbot` | `docker` | `external` | `external` | `s3` |

What the words mean:

| Word | Meaning |
|---|---|
| `docker` | Runs in a container on this server. Isolated and easy to remove. |
| `native` | Installed directly on this server with its package manager (`apt`, `dnf`, `zypper` or `pacman`). Uses less memory. |
| `external` | Already running somewhere else; you type its address. |
| `none` | Not used. With no Redis, cache, sessions and queues use the database. |
| `certbot` | Free HTTPS certificates from Let's Encrypt, renewed automatically. |
| `panel` | A hosting panel already does HTTPS; the setup tells you what to enter in it. |

The other questions:

- **Server OS:** detected from the server (`/etc/os-release`), so press Enter. See [Which Linux?](#which-linux).
- **Environments:** choose `production`, `staging`, `dev`, or your own names. Each gets its own domains, database and Git branch.
- **Email / SMS / payments / social login:** pick only what you use (e.g. `smtp`, `stripe,bkash`, `google`). You're asked for those keys only. Choose `log` or leave blank to skip.
- **Background jobs:** `horizon` (needs Redis), `worker`, or `none`.
- **Database version:** the PostgreSQL or MariaDB major version, read from your CI, compose or DDEV files (e.g. `postgres:17`). With `docker` it picks the image. With `native` PostgreSQL it installs that version, adding the official PostgreSQL repository (apt or dnf) if your distro doesn't ship it. An existing install keeps the version it runs: a new major version can't read old data.
- **How the browser reaches the API:** `direct` means the frontend calls the API domain, so the kit sets up CORS. `proxy` means the frontend forwards `/api` to Laravel with Next.js `rewrites()`, so there's no CORS. This is detected from `next.config`.
- **Deploy steps:** the health-check path (read from `bootstrap/app.php`), extra artisan commands to run after migrations, the command that creates your first admin user, and the Node.js version (read from `.nvmrc`). Setup lists commands your app ships that deploys often need, such as `l5-swagger:generate` and `*:sync` commands. Type the ones you want, separated by `;`, or `none`.
- **Frontend server settings (per environment):** values the Next.js server reads that aren't `NEXT_PUBLIC_*`. Setup looks for `process.env.X` in `next.config` and suggests a value. For example, `API_PROXY_TARGET` is suggested as `http://127.0.0.1:<that env's API port>`. Format: `KEY=value; KEY2=value`, or `none`.

---

## Which Linux?

The first question is the server's OS family. Setup detects it; you can override it, for example for a derivative it doesn't recognise. Each family uses its own packages and file locations:

| Family | Distributions | Packages | nginx sites | PHP-FPM pool | Firewall | Automatic updates |
|---|---|---|---|---|---|---|
| `debian` | Debian, Ubuntu | `apt` (other PHP versions: ondrej/php PPA on Ubuntu, packages.sury.org on Debian) | `sites-available` + `sites-enabled` | `/etc/php/<v>/fpm/pool.d` | ufw | unattended-upgrades |
| `rhel` | RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Fedora, Amazon Linux | `dnf` + EPEL (other PHP versions: Remi on EL 8/9) | `conf.d` | `/etc/php-fpm.d` | firewalld | dnf-automatic |
| `suse` | openSUSE Leap/Tumbleweed, SLES | `zypper` | `conf.d` | `/etc/php8/fpm/php-fpm.d` | firewalld | not set up (use `zypper patch`) |
| `arch` | Arch, Manjaro | `pacman` | `conf.d` (setup adds the include to `nginx.conf`) | `/etc/php/php-fpm.d` | ufw | not set up (rolling release) |

What setup handles for you:

- **PostgreSQL** at the version you choose, from the official PostgreSQL repository on Debian/Ubuntu and RHEL/Fedora, with the data directory initialised where the distro doesn't do it. Where that version isn't packaged, setup warns and installs the distro's own version instead: Arch ships only the newest PostgreSQL, and the PostgreSQL repository has no Fedora 41 builds for arm64. Outside Debian/Ubuntu, password logins over `127.0.0.1` are switched on, because those distros default to `ident`/`trust`.
- **Redis or Valkey,** whichever the distro ships. Arch and newer Fedora/RHEL ship Valkey, which works the same way.
- **PHP version:** openSUSE and Arch ship one PHP version, which is used even if you ask for another (setup warns).
- **SELinux** (RHEL family, when enforcing): allows nginx/PHP-FPM to proxy to loopback ports, read and write the app folder, and listen on the API's loopback port.
- **Firewall:** if ufw or firewalld is active, setup opens the HTTP/HTTPS ports for the public sites. RHEL and openSUSE turn firewalld on by default.

Docker installs from Docker's own repositories on Debian/Ubuntu and RHEL/Fedora, and from the distro on openSUSE, Arch and Amazon Linux. Setup adds the compose plugin if the distro lacks it.

Alpine, and other systems without systemd, aren't supported.

To change the family later: `deploy/setup.sh components`.

---

## Everyday commands

Run these on the server, in your app's checkout (e.g. `cd ~/shop/repo`). Replace `production` with any environment you set up (`staging`, `dev`, …).

### Deploy

| I want to… | Command |
|---|---|
| **Deploy the latest code** | `deploy/deploy.sh production --pull` |
| Deploy what's already checked out | `deploy/deploy.sh production` |
| Deploy without the pre-migration database backup | `deploy/deploy.sh production --no-backup` |
| Undo the last deploy | `deploy/deploy.sh production --rollback` *(docker only)* |
| See past deploys | `tail ~/shop/shared/deploy.log` |

### Check and troubleshoot

| I want to… | Command |
|---|---|
| Check everything is running | `deploy/setup.sh status` |
| Find out what's wrong | `deploy/setup.sh doctor` |
| See the app's services *(native)* | `systemctl --user status 'shop-*'` |
| Follow queue / Horizon logs *(native)* | `journalctl --user -u shop-worker-production -f` |
| Restart the frontend, worker and scheduler *(native)* | `systemctl --user restart 'shop-*-production'` |
| Laravel's own log | `tail -f ~/shop/production/storage/logs/laravel-*.log` |

### Change settings

| I want to… | Command |
|---|---|
| Change email / SMS / payment / login keys | `deploy/setup.sh vars production` |
| Change a domain | `deploy/setup.sh domains` |
| Change how something runs (e.g. Redis → native, PHP version) | `deploy/setup.sh components` |
| Change deploy steps (health path, extra artisan commands, `queue:work` options, Node version) | `deploy/setup.sh steps` |
| Change the frontend's server settings (e.g. `API_PROXY_TARGET`) | `deploy/setup.sh vars production`, then deploy |
| Create the GitHub Actions deploy workflow | `deploy/setup.sh cd-workflow` |
| Re-apply nginx, certificates, the PHP-FPM pool, or print the panel's proxy targets | `deploy/setup.sh edge` |
| Restart the database / Redis / MinIO and re-check their users and buckets | `deploy/setup.sh services` |
| Add or remove an environment | `deploy/setup.sh add-env staging` / `remove-env staging` |
| Remove this app from the server | `deploy/setup.sh uninstall` (add `--purge` to also delete `~/shop`; databases are kept) |
| Firewall, swap, automatic security updates | `deploy/setup.sh harden` |

### Database and passwords

| I want to… | Command |
|---|---|
| Back up / restore the database | `deploy/setup.sh backup production` / `restore production <file>` |
| Run migrations | `deploy/setup.sh migrate production` |
| Create the first admin user | `deploy/setup.sh seed-admin production`: runs the command chosen in setup, and asks for its `{email}`, `{name}`, … (change it with `setup.sh steps`) |
| Run any artisan command | `deploy/setup.sh artisan production -- queue:failed` (uses that environment's PHP, `.env` and storage) |
| Show database / Redis / MinIO passwords | `deploy/setup.sh credentials` |
| Change all generated passwords | `deploy/setup.sh rotate-secrets` (a Redis shared with other apps is left alone) |
| Save my answers to reuse on another server | `deploy/setup.sh export-answers` (no passwords) |

### Update the kit

The kit lives inside your app, so updating it is a normal commit. On your computer, in the app:

```bash
git subtree pull --prefix deploy git@github.com:aminbabu/deploy-kit.git main --squash
git push
```

Then on the server: `git pull` (or let CI deploy it). **Update before running `deploy/setup.sh` on a server that hosts other apps**, so you have the latest safety checks.

Running `deploy/setup.sh` again is safe: it remembers this app's answers, so pressing Enter changes nothing. Each app keeps its own settings, and setup refuses to use another app's folder.

---

## Deploy on every push (GitHub Actions)

1. On the server, run `deploy/setup.sh cd-workflow` and choose how deploys start:
   - `direct`: every push deploys.
   - `after-ci`: deploy only after your existing CI workflow passes. Setup asks for its `name:`.

   This writes `.github/workflows/cd.yml` with your project name and one branch → environment line for each environment you set up. Copy that file into your app on your computer and commit it. Or copy an example by hand and edit it: [`github-actions-cd.yml`](examples/github-actions-cd.yml) or [`github-actions-cd-after-ci.yml`](examples/github-actions-cd-after-ci.yml).
2. In GitHub → **Settings → Secrets and variables → Actions**, add:
   - `DEPLOY_SSH_HOST`: your server's address
   - `DEPLOY_SSH_USER`: the server user
   - `DEPLOY_SSH_KEY`: a private SSH key that can log in as that user
   - `DEPLOY_SSH_PORT` *(optional)*: the SSH port, if it isn't 22

Each push to an environment's branch now deploys it. Your app's passwords stay on the server.

**One CI workflow for the whole repo (monorepo, path filters)?** Choose `after-ci`. The deploy starts only after your CI workflow passes on a push, and it deploys the exact commit CI tested. Pull requests never deploy. Jobs skipped by path filters don't block the deploy. You don't need to change your CI file.

**Native runtime:** setup asks for your sudo password once. It lets your user's services start at boot (`loginctl enable-linger`) and allows exactly one command without a password: reloading the app's PHP-FPM (`/etc/sudoers.d/dk-<project>`). After that, deploys, CI included, never prompt. The frontend, queue worker and scheduler run as your user's systemd services: `systemctl --user status '<project>-*'`, logs with `journalctl --user -u <project>-worker-production`.

---

## What a deploy does

1. Builds your app (Docker images, or Composer + Next.js build)
2. Backs up the database (production and staging)
3. Runs migrations, then the extra artisan commands you chose in setup (`setup.sh steps`)
4. Restarts the app; background jobs finish their current task first
5. Checks the app responds
   - **docker:** if it doesn't, the previous version is restored automatically
   - **native:** the deploy stops with an error

Only one deploy runs at a time, and each one is logged in `~/<project>/shared/deploy.log`.

---

## Where your files are

With project name `shop`:

| Path | What's inside |
|---|---|
| `~/shop/repo/` | Your app's code (the Git clone) |
| `~/shop/production/.env` | Laravel `.env` for production. Your own edits are kept. |
| `~/shop/production/frontend.env` | Server-side settings for the Next.js frontend, such as `API_PROXY_TARGET`. Your setup answers are written here on each deploy. Lines you add by hand are kept. Used for the build and by the running server. |
| `~/shop/shared/secrets.env` | Generated passwords |
| `~/shop/backups/production/` | Database backups |
| `~/shop/project.env` | Your setup answers |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `permission denied` from Docker right after setup | Log out, log back in, run the command again. |
| HTTPS certificate failed | Check the domain's DNS points to this server, then run `deploy/setup.sh edge`. |
| Site loads but API calls fail | `deploy/setup.sh doctor` checks the connection and tells you what's wrong. |
| Build killed on a small server | `deploy/setup.sh harden` and say yes to swap. |
| Backups fail with an external database | Install the database client: `postgresql-client` / `mariadb-client` (Debian/Ubuntu), `postgresql` / `mariadb` (RHEL, openSUSE, Arch). |
| Anything else | `deploy/setup.sh doctor`, then `deploy/setup.sh status`. |

---

## FAQ

**Why is the kit inside my app (`deploy/`) instead of on its own?**
The server gets your app with a single `git clone`, and the deploy scripts always match the version of your app being deployed. You add the kit once (step 1). Get kit updates with:
`git subtree pull --prefix deploy git@github.com:aminbabu/deploy-kit.git main --squash`

**My app is already on the server. Do I need to clone again?**
No. Answer **no** to "Clone?" and give the folder's path. Or run `bash deploy/setup.sh` from inside it.

**I use CloudPanel (or another panel).**
Pick HTTPS → `panel`. At the end the setup lists lines like `api.example.com → http://127.0.0.1:8100`. In CloudPanel, create a **Reverse Proxy** site for each domain with that address, then enable Let's Encrypt in the site's SSL tab. Don't enable the firewall in `harden`, because it would block CloudPanel's admin page (port 8443). Use CloudPanel's own firewall instead.

**Can I host several apps on one server?**
Yes. Run the installer once per app and give each its own project name. Each app gets its own folder (`~/<project>`), databases, PHP-FPM pool, services and nginx sites. Setup avoids ports and Redis database numbers other apps already use, and reuses the existing password of a shared native Redis instead of changing it.

**My app is a monorepo (pnpm workspace / Turborepo), e.g. `apps/gateway` + `apps/web`.**
Supported with the `native` runtime. Setup asks every question below and suggests answers from your repo. Press Enter to accept, or type your own.
- **Directories:** found automatically under `apps/`, `services/` or `packages/`, e.g. `apps/gateway` for the backend and `apps/web` for the frontend.
- **Build:** `pnpm install --frozen-lockfile`, and `pnpm turbo run build --filter=<web package>` when there's a `turbo.json`. Set `outputFileTracingRoot` to the monorepo root in `next.config`; the kit finds the nested `server.js`.
- **Node version:** read from `.nvmrc`.
- **Frontend server settings:** if `next.config` proxies `/api` to Laravel through `rewrites()`, `API_PROXY_TARGET` is suggested for each environment. Rewrites are fixed at build time, so redeploy after changing it.
- **Extra artisan commands:** e.g. `permission:sync; l5-swagger:generate`. Setup lists the ones it finds in your app.
- **API access:** `proxy` when `next.config` rewrites `/api` to Laravel.
- **Database:** `pgsql`, at the version your CI uses. The health path comes from `bootstrap/app.php`.
- **First admin:** an artisan command such as `app:create-staff {email} {name}` is found and offered for `seed-admin`.
- **Files your app needs** (e.g. a Firebase service-account JSON): add them to your `vars.extra.catalog` as kind `file`. See [docs/CUSTOMISING.md](docs/CUSTOMISING.md).
- **CI/CD:** `deploy/setup.sh cd-workflow` → `after-ci` deploys after your existing CI passes.

**My app has no frontend (API only).**
Answer `n` to "Deploy a Next.js frontend too?".

**My app needs Docker files for the `docker` option?**
Yes: a backend `Dockerfile` running PHP-FPM on port 9000 (code in `/var/www/html`), and a frontend `Dockerfile` serving port 3000. `NEXT_PUBLIC_*` values arrive as build arguments. Don't have them? Choose `native`.

**Can I run the setup without answering questions?**
Yes: `deploy/setup.sh --answers answers.env --yes`. See [`answers.example.env`](answers.example.env).

**How do I add my own `.env` settings to the questions, or change image versions?**
See [docs/CUSTOMISING.md](docs/CUSTOMISING.md).

---

## License

[MIT](LICENSE) © 2026 Amin Babu
