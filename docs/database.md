# Database (Postgres)

You can run Postgres in a separate container on the shared Docker network.

## Environment

We use `.env.db` at repo root. If it’s missing, a `.env.db.template` will be created and symlinked for you.

**.env.db (defaults):**
```env
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
PGDATA=/var/lib/postgresql/data/pgdata
```

## Makefile targets (DB repo)

From the DB directory (the Makefile auto-creates `.env.db.template` if needed):

```bash
make build     # builds custom postgres image (with db/ as context)
make up        # starts the container
make health    # waits until healthy
make logs      # follow logs
make psql      # open psql shell inside container
```

**Connection string**

```
postgres://POSTGRES_USER:POSTGRES_PASSWORD@<server-ip>:5432/POSTGRES_DB
```

```

---

### `docs/hub.md`
```markdown
# Run the Hub with TLS (no nginx)

Gunicorn terminates TLS directly using your **Cloudflare Origin Certificate**.

## Host prep (once)
```bash
sudo mkdir -p /etc/ssl/matrixhub
sudo cp cf-origin.pem cf-origin.key /etc/ssl/matrixhub/
sudo chmod 644 /etc/ssl/matrixhub/cf-origin.pem /etc/ssl/matrixhub/cf-origin.key
```

## Start

```bash
./scripts/run_container.sh
```

The script:

* mounts your envs (`.env` and `.env.gateway.*`)
* mounts the origin certs at `/etc/ssl/matrixhub` (read-only)
* starts the **Gateway** (port `4444`)
* starts the **Hub** (TLS on `:443`) with:

  ```
  --certfile /etc/ssl/matrixhub/cf-origin.pem
  --keyfile  /etc/ssl/matrixhub/cf-origin.key
  ```

## Cloudflare settings

* DNS A/AAAA → your server → **Proxied**
* SSL/TLS → **Full (strict)**
* Edge Certificates → (optional) Always Use HTTPS: **On**
* Network → HTTP/2 / HTTP/3: **On**

```

---

### `docs/pgadmin.md`
```markdown
# pgAdmin (optional)

Launch pgAdmin using the **same password** as your Postgres `.env.db`.

## Start
```bash
./scripts/start_pgadmin.sh
```

* UI: `http://localhost:5050`
* Login: `admin@local / <same as POSTGRES_PASSWORD>`

## Add your server in pgAdmin

* **Name:** MatrixHub DB
* **Host:** `matrixhub-db` (or `db`)
* **Port:** `5432`
* **Maintenance DB:** value of `POSTGRES_DB`
* **Username:** value of `POSTGRES_USER`
* **Password:** value of `POSTGRES_PASSWORD`
* SSL: Off (unless you enabled TLS in Postgres)

```

---

### `docs/troubleshooting.md`
```markdown
# Troubleshooting

## Worker exited with code 52
If you see in Hub logs:
```

\[ERROR] Worker (pid\:XX) exited with code 52

```
Ensure your Hub environment is valid. The launcher will copy `.env.gateway.example` to `.env.gateway.local` if missing; update credentials there as needed.

## Env files not found
- Hub: `.env` or `.env.example` at project root.
- Gateway: `.env.gateway.local` or `.env.gateway.example` at project root.
- DB: `.env.db` (or auto-generated `.env.db.template`).

## Can’t bind to :443
Docker grants `NET_BIND_SERVICE` by default; if you hardened your Docker daemon and removed it, add the capability back when running the container.

## Cloudflare returns 525/526
Use **Origin Certificates** on the origin (this project’s TLS), **Full (strict)** at Cloudflare, and ensure the cert/key filenames match:
```

/etc/ssl/matrixhub/cf-origin.pem
/etc/ssl/matrixhub/cf-origin.key

```

## pgAdmin shows “can’t connect”
- Confirm the DB container is on the same network (`matrixhub-net`).
- Use host `matrixhub-db` (alias `db`), port `5432`.
- Check `make health` for DB health status.
```
