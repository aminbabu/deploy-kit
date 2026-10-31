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
| `managed` | Written by the scripts; never asked |

Example: let the user pick a search engine, and ask Meilisearch settings only when it's chosen:

```
SEARCH_DRIVER|select|search|database|Search engine|database meilisearch
MEILISEARCH_HOST|optional|search-meilisearch|http://127.0.0.1:7700|Meilisearch URL
MEILISEARCH_KEY|secret|search-meilisearch||Meilisearch key
```

Defaults may use `{SLUG}`, `{ENV}`, `{ROOT_DOMAIN}`, `{FRONTEND_HOST}`, `{APP_NAME}`, `{DISK}` (`s3` or `local`) and `{KV}` (`redis` or `database`).

## Settings you can add to `~/<project>/project.env`

| Setting | Effect |
|---|---|
| `POSTGRES_IMAGE`, `MARIADB_IMAGE`, `REDIS_IMAGE`, `MINIO_IMAGE` | Docker image versions for the services |
| `APP_MEM_LIMIT`, `NGINX_MEM_LIMIT`, `HORIZON_MEM_LIMIT`, `WORKER_MEM_LIMIT`, `SCHEDULER_MEM_LIMIT`, `FRONTEND_MEM_LIMIT` | Container memory limits (e.g. `1G`) |
| `QUEUE_WORK_ARGS` | Options for `queue:work` (default `--sleep=3 --tries=3 --max-time=3600`) |
| `SEED_ADMIN_CLASS` | Seeder used by `setup.sh seed-admin`, e.g. `Database\Seeders\AdminSeeder` |
| `BACKUP_ENVS`, `BACKUP_KEEP` | Which environments are backed up before migrating, and how many backups to keep |
| `HEALTH_PATH` | API path the deploy checks for a 200 response (default `/up`, Laravel 11+'s health route) |

## Templates

- nginx: `nginx/*.template`
- Docker Compose: `compose/*.yml`
- systemd units: `systemd/*.tmpl`

## Unattended setup

Put every answer in a file and run `deploy/setup.sh --answers answers.env --yes`. See [`answers.example.env`](../answers.example.env). Per-environment values use the form `PRODUCTION__MAIL_HOST=...`. To create a file from a running server, use `deploy/setup.sh export-answers` (passwords are left out).
