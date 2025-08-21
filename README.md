# MatrixHub PostgreSQL — Production Stack (OCI / Oracle Linux 9)

A production-grade PostgreSQL 16 setup purpose-built for **MatrixHub**:

- **One command** bootstrap: `make init`
- Idempotent **schema init** (entity, embedding_chunk, remote) on first boot
- Durable data via Docker volume, **systemd** auto-start on boot
- Optional **PgBouncer** connection pooling, **Prometheus** exporter
- Backup/restore automation (CLI + systemd nightly timer)
- Secure defaults with configurable `pg_hba` CIDR allow list

> **Compatibility:** Mirrors the MatrixHub models/migrations you provided (columns, JSONB defaults, check constraints, indexes). No breaking changes.

---

## 🚀 Quick Start (Oracle Linux 9 on OCI)

```bash
# 1) Connect to your instance
ssh -i /path/to/your_key opc@<public-ip>

# 2) Install git & make and clone the repo
sudo dnf -y install git make
git clone https://github.com/agent-matrix/matrixhub-db.git
cd matrixhub-db

# 3) Configure secrets
cp .env.db.example .env.db
nano .env.db  # set a strong POSTGRES_PASSWORD; adjust PG_ALLOW_CIDR

# 4) Bootstrap everything
make init

# 5) Verify
make verify
```

### Connect from apps:

```
postgres://matrix:<PASSWORD>@<server-ip>:5432/matrixhub
```

### What `make init` does
1. Installs Docker CE
2. Opens firewall 5432/tcp (configurable via `PG_HOST_PORT`)
3. Builds the custom Postgres image (schema/extension init)
4. Runs the DB container with durable volume & healthcheck
5. Installs and enables a systemd unit for auto-start
6. Waits until the DB is healthy

---

## Optional Components

### PgBouncer (recommended at scale)
Start a pooler on the same Docker network (port 6432 by default):
```bash
make pgbouncer-up
```
Apps connect to `pgbouncer:6432` (inside the Docker network) or `host:<PGBOUNCER_PORT>` if you publish it.

### Prometheus Exporter
Create a read-only monitoring role and run the exporter:
```bash
make exporter-up
```
It listens on host port 9187 by default.

### Backups
- **On-demand:** `make backup-now`
- **Nightly (02:30) with systemd timer:** `make backup-install`

Backups are stored in the `./backups/` directory.

---

## Security Notes
- **Passwords**: Never commit `.env.db`.
- **`pg_hba`**: Restrict `PG_ALLOW_CIDR` in `.env.db` to your VCN subnets/VPN.
- **TLS**: For client TLS, set `TLS_ENABLE=1` in `.env.db`, create a `certs` directory with `server.crt`/`server.key`, and re-run `make up`.
- **Users**: Prefer separate DB users per service (rw vs ro) with least privilege.

---

## Uninstall
```bash
make systemd-remove
make clean # DANGER: This deletes the data volume
```
