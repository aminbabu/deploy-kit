# Customising deploy-kit

## Add your own `.env` settings to the setup questions

Create `deploy/vars.extra.catalog` in your app (start from [`vars.extra.catalog.example`](../vars.extra.catalog.example)). One line per setting:

```
KEY|kind|group|default|help text|options
```

| kind | Behaviour |
|---|---|
| `required` | Always asked |
| `gen` | Secret generated once (like `APP_KEY`) |
| `select` | Pick one of `options`; then the keys in group `<group>-<choice>` are asked |
| `multi` | Pick several of `options`; each one asks its group |
| `optional` / `secret` | Asked only when their group is picked (`secret` hides what you type) |
| `file` | Path to a file on the server, such as a service-account JSON, private key or certificate. It's copied into `~/<project>/<env>/files/` with mode 600, and the setting gets that path. Asked always for group `core`, otherwise when its group is picked. With `docker`, the folder is mounted read-only at the same path. |
| `managed` | Written by the scripts; never asked |
| `skip` | Hides a question from the kit's own catalog that your app doesn't use, e.g. `PAYMENT_GATEWAYS|skip` |

Group `core` means always asked, for every kind. A key in your file replaces the kit's line for that key, so you can change its default, help text or options.

Example: let the user pick a search engine, and ask Meilisearch settings only when it's chosen:

```
SEARCH_DRIVER|select|search|database|Search engine|database meilisearch
MEILISEARCH_HOST|optional|search-meilisearch|http://127.0.0.1:7700|Meilisearch URL
MEILISEARCH_KEY|secret|search-meilisearch||Meilisearch key
```

Defaults may use `{SLUG}`, `{ENV}`, `{ROOT_DOMAIN}`, `{FRONTEND_HOST}`, `{FRONTEND_URL}` and `{API_URL}` (full `https://` origins of that environment), `{APP_NAME}`, `{DISK}` (`s3` or `local`) and `{KV}` (`redis` or `database`).

## Deploy steps (asked in setup; change with `deploy/setup.sh steps`)

| Setting | Effect |
|---|---|
| `HEALTH_PATH` | API path the deploy checks for a 200 response. Default: the `health:` route in `bootstrap/app.php`, else `/up`. |
| `POST_DEPLOY_ARTISAN` | Artisan commands run after `migrate` on every deploy, separated by `;`, e.g. `permission:sync; l5-swagger:generate`. `none` = no extra commands. A failing command fails the deploy. |
| `QUEUE_WORK_ARGS` | Options for `queue:work`, asked when the queue worker is `worker`. Default: `--sleep=3 --tries=3 --max-time=3600`. |
| `NODE_VERSION` | Native runtime: Node.js major version installed when Node is missing. Default: `.nvmrc` / `.node-version`, else `22`. |
| `SEED_ADMIN_CMD` | Artisan command that `setup.sh seed-admin <env>` runs. Each `{name}` is asked when it runs; names containing `pass` or `secret` are hidden, and `{--options}` keep their defaults. Default: `db:seed --force --class=…AdminSeeder` when that seeder exists, else a `create/make-admin/staff/user` command found in the app, else `none`. |

Asked with the components (`setup.sh components`):

| Setting | Effect |
|---|---|
| `DB_VERSION` | Database major version. Default: the `postgres:N` / `mariadb:N` image in your CI or compose files, or DDEV's database version, else 17 (PostgreSQL) / 11 (MariaDB). Existing installs default to what they run. With `docker` it sets `POSTGRES_IMAGE`/`MARIADB_IMAGE`, unless you pin those. With `native` PostgreSQL it installs `postgresql-N`, from apt.postgresql.org if needed. Changing it asks first, because data isn't upgraded. |
| `FRONTEND_API_MODE` | `direct`: the browser calls the API domain, and the deploy checks CORS. `proxy`: Next.js `rewrites()` forward `/api` to Laravel, the CORS checks are skipped, and the API domain still serves other clients (mobile apps, merchants). Default: `proxy` when `next.config` has a `source: '/api…'` rewrite. |

The answers are saved in `~/<project>/project.env`, and editing them there works too.

## Settings you can add to `~/<project>/project.env`

| Setting | Effect |
|---|---|
| `POSTGRES_IMAGE`, `MARIADB_IMAGE`, `REDIS_IMAGE`, `MINIO_IMAGE` | Docker image versions for the services |
| `APP_MEM_LIMIT`, `NGINX_MEM_LIMIT`, `HORIZON_MEM_LIMIT`, `WORKER_MEM_LIMIT`, `SCHEDULER_MEM_LIMIT`, `FRONTEND_MEM_LIMIT` | Container memory limits (e.g. `1G`) |
| `SEED_ADMIN_CLASS` | Older form of `SEED_ADMIN_CMD`: seeder class used by `setup.sh seed-admin` when `SEED_ADMIN_CMD` isn't set |
| `BACKUP_ENVS`, `BACKUP_KEEP` | Which environments are backed up before migrating, and how many backups to keep |
| `FPM_MAX_CHILDREN` | Native runtime: max PHP-FPM workers in the app's pool (default `10`) |

## Frontend server-side settings

Setup asks for each environment's frontend server settings: values the Next.js server reads that aren't `NEXT_PUBLIC_*`. Change them with `deploy/setup.sh vars <env>`. Setup reads `process.env.X` in `next.config` and suggests a value. Names containing `API`, `BACKEND` or `PROXY` default to `http://127.0.0.1:<that env's API port>`. The answer is saved as `<ENV>_FRONTEND_ENV="KEY=value; KEY2=value"` in `project.env`, or `none`.

On each deploy, the answer is written to `~/<project>/<env>/frontend.env`. Lines you add to that file by hand are kept, so values that contain `;` go there. The values are:

- passed to the frontend build. For `docker`, they're passed as build args, so declare `ARG KEY` in your Dockerfile. This matters for `rewrites()`/`redirects()` in `next.config`, which are fixed at build time.
- loaded by the running server (`EnvironmentFile` of the systemd unit, `env_file` of the container).

Removing a key from the answer doesn't delete it from `frontend.env`; delete the line there. `NEXT_PUBLIC_*` values come from the app `.env`, which the kit manages.

## CD workflow

`deploy/setup.sh cd-workflow` writes `.github/workflows/cd.yml` from [`examples/`](../examples). It fills in your project name and one branch → environment line for each enabled environment. It asks:

- **Style:** `direct` deploys on every push. `after-ci` uses `workflow_run`: it deploys when the named CI workflow finished successfully for a push, and checks out exactly the commit CI tested.
- **CI workflow name** *(after-ci)*: the `name:` at the top of your CI file.
- **Output path.**

Answers files can pre-set `CD_STYLE`, `CD_CI_NAME` and `CD_OUT`.

## Templates

- nginx: `nginx/*.template`
- Docker Compose: `compose/*.yml`
- systemd units: `systemd/*.tmpl`

## Unattended setup

Put every answer in a file and run `deploy/setup.sh --answers answers.env --yes`. See [`answers.example.env`](../answers.example.env). Per-environment values use the form `PRODUCTION__MAIL_HOST=...`. To create a file from a running server, use `deploy/setup.sh export-answers` (passwords are left out).
