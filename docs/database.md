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
