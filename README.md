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

- [ ] A **Linux server** (Ubuntu or Debian recommended) and a **user with `sudo`** (not root)
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
| `native` | Installed directly on this server, like `apt install`. Uses less memory. |
| `external` | Already running somewhere else; you type its address. |
| `none` | Not used. With no Redis, cache, sessions and queues use the database. |
| `certbot` | Free HTTPS certificates from Let's Encrypt, renewed automatically. |
| `panel` | A hosting panel already does HTTPS; the setup tells you what to enter in it. |

The other questions:

- **Environments:** choose `production`, `staging`, `dev`, or your own names. Each gets its own domains, database and Git branch.
- **Email / SMS / payments / social login:** pick only what you use (e.g. `smtp`, `stripe,bkash`, `google`). You're asked for those keys only. Choose `log` or leave blank to skip.
- **Background jobs:** `horizon` (needs Redis), `worker`, or `none`.

---

## Everyday commands

Run these on the server, in your app's folder.

| I want to… | Command |
|---|---|
| **Deploy the latest code** | `deploy/deploy.sh production --pull` |
| Undo the last deploy | `deploy/deploy.sh production --rollback` *(docker only)* |
| Check everything is running | `deploy/setup.sh status` |
| Find out what's wrong | `deploy/setup.sh doctor` |
| Change email / SMS / payment / login keys | `deploy/setup.sh vars production` |
| Change a domain | `deploy/setup.sh domains` |
| Change how something runs (e.g. Redis → native) | `deploy/setup.sh components` |
| Add or remove an environment | `deploy/setup.sh add-env staging` / `remove-env staging` |
| Back up / restore the database | `deploy/setup.sh backup production` / `restore production <file>` |
| Run migrations | `deploy/setup.sh migrate production` |
| Show database / Redis / MinIO passwords | `deploy/setup.sh credentials` |
| Change all generated passwords | `deploy/setup.sh rotate-secrets` |
| Firewall, swap, auto security updates | `deploy/setup.sh harden` |

Running `deploy/setup.sh` again is always safe: it remembers your answers, so pressing Enter changes nothing.

---

## Deploy on every push (GitHub Actions)

1. Copy [`examples/github-actions-cd.yml`](examples/github-actions-cd.yml) to `.github/workflows/cd.yml` in your app, and set `DEPLOY_SLUG` in it to your project name.
2. In GitHub → **Settings → Secrets and variables → Actions**, add:
   - `DEPLOY_SSH_HOST`: your server's address
   - `DEPLOY_SSH_USER`: the server user
   - `DEPLOY_SSH_KEY`: a private SSH key that can log in as that user
   - `DEPLOY_SSH_PORT` *(optional)*: the SSH port, if it isn't 22

Each push to `main` now deploys production. Your app's passwords stay on the server.

**Native runtime:** setup asks for your sudo password once. It lets your user's services start at boot (`loginctl enable-linger`) and allows exactly one command without a password: reloading the app's PHP-FPM (`/etc/sudoers.d/dk-<project>`). After that, deploys, CI included, never prompt. The frontend, queue worker and scheduler run as your user's systemd services: `systemctl --user status '<project>-*'`, logs with `journalctl --user -u <project>-worker-production`.

---

## What a deploy does

1. Builds your app (Docker images, or Composer + Next.js build)
2. Backs up the database (production and staging)
3. Runs migrations
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
| Backups fail with an external database | `sudo apt install postgresql-client` (or `mariadb-client`). |
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
