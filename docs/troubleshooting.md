
# Troubleshooting

## Hub worker exits with code 52
If Hub logs show:
```

\[ERROR] Worker (pid\:XX) exited with code 52

```
Check your environment files are present and valid:
- Hub: `.env` (or `.env.example`)
- Gateway: `.env.gateway.local` (or `.env.gateway.example`)
The launcher will create `.env.gateway.local` from the example if missing—update credentials there.

## HTTPS shows 525/526 via Cloudflare
- Use **Cloudflare Origin Certificates** at the origin (this project).
- Cloudflare SSL/TLS → **Full (strict)**.
- Verify the mounted files exist and are readable in the container:
  - `/etc/ssl/matrixhub/cf-origin.pem`
  - `/etc/ssl/matrixhub/cf-origin.key`

## Can’t bind to port 443
Ports <1024 may require extra capability. The run script configures the container appropriately. If you changed security settings, ensure the container can bind `:443`.

## pgAdmin can’t connect
- Ensure both DB and pgAdmin containers are on `matrixhub-net`.
- Use host `matrixhub-db` (or `db`), port `5432`.
- Verify DB is healthy:
  ```bash
  docker inspect -f '{{.State.Health.Status}}' matrixhub-db
```

* Confirm credentials match `.env.db`.

## Postgres not starting / healthcheck failing

* Check container logs:

  ```bash
  docker logs -f matrixhub-db
  ```
* Ensure `.env.db` exists (or the `.env.db.template` symlink fallback).
* If you changed tuning params (e.g., `shared_buffers`), roll them back and retry.

## Where are the env files?

* **DB:** `.env.db` (template auto-created as `.env.db.template` and symlinked)
* **Hub:** `.env` (or `.env.example`)
* **Gateway:** `.env.gateway.local` (or `.env.gateway.example`)

## Recreate containers cleanly

Stop & remove, then start again:

```bash
# Hub + Gateway
docker rm -f matrixhub || true
./scripts/run_container.sh

# Database
docker rm -f matrixhub-db || true
make -C matrixhub-db up
```
