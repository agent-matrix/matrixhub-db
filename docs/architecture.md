# Architecture & Stack Layout

> Mirrored verbatim across [`ruslanmv/matrixhub`](https://github.com/ruslanmv/matrixhub),
> [`agent-matrix/matrix-hub`](https://github.com/agent-matrix/matrix-hub),
> and this repo so operators see the same picture from any side.

```
   Browser → www.matrixhub.io  ──/api/* proxy──▶  api.matrixhub.io
            (Next.js, Vercel)                    (FastAPI on OCI Ubuntu)
                                                          │
                                                          │ TLS sslmode=require
                                                          ▼
                                                ┌──────────────────────┐
                                                │ Aiven Postgres 17    │
                                                │ pg-37455d5-…         │
                                                │ .aivencloud.com      │
                                                │ :24870  (PRIMARY)    │
                                                │                      │
                                                │  - entity            │
                                                │  - embedding_chunk   │
                                                │  - remote            │
                                                │  - daily backups     │
                                                │    (GH artifact)     │
                                                └──────────┬───────────┘
                                                           │ failover at
                                                           │ Hub container
                                                           │ startup only
                                                           ▼
                                                ┌──────────────────────┐
                                                │ matrixhub-db (this)  │
                                                │ Postgres 16 on OL9   │
                                                │ FALLBACK / DR        │
                                                └──────────────────────┘
```

| Component | Repo | Hosted on |
|---|---|---|
| Frontend | [`ruslanmv/matrixhub`](https://github.com/ruslanmv/matrixhub) | Vercel |
| Backend API | [`agent-matrix/matrix-hub`](https://github.com/agent-matrix/matrix-hub) | OCI Ubuntu VM (`api.matrixhub.io`) |
| **Primary DB** | Aiven managed Postgres 17 | DigitalOcean SFO |
| **Fallback DB** (this repo) | Postgres 16, Docker | OCI Oracle Linux 9 VM |

## How DB selection works

`matrix-hub`'s container boots `scripts/select_database_url.sh`, which:

1. tries `DATABASE_URL_PRIMARY` (Aiven) first,
2. falls back to `DATABASE_URL_FALLBACK` (this repo on OL9) only if the
   primary is unreachable at startup,
3. fails fast if neither responds.

Because failover only happens at boot, **writes never split-brain** — the
moment Aiven recovers, the next container restart picks it back up.

The fallback is meant to be temporary. Once Aiven has been stable for
~2 weeks, decommission OL9 and remove `DATABASE_URL_FALLBACK` from the
Hub's `.env`.

## Required environment for matrix-hub

```env
DATABASE_URL_PRIMARY=postgresql+psycopg://avnadmin:<PW>@pg-37455d5-matrixhub-db.c.aivencloud.com:24870/defaultdb?sslmode=require
DATABASE_URL_FALLBACK=postgresql+psycopg://matrix:<OL9_PW>@10.0.0.185:5432/matrixhub
```

## End-to-end smoke

```bash
# DB level (run on any host with outbound 24870)
psql "postgresql://avnadmin:<PW>@pg-37455d5-matrixhub-db.c.aivencloud.com:24870/defaultdb?sslmode=require" -c '\dt'

# Backend
curl -fsS https://api.matrixhub.io/health?check_db=true     # → db:"ok"
curl -fsS https://api.matrixhub.io/catalog?limit=1

# Frontend → backend round-trip
curl -fsS "https://www.matrixhub.io/api/search?q=watsonx&type=any&limit=5"
curl -sSI  https://www.matrixhub.io/status | head -1
```

If `/status` shows **API: Operational, Database: Connected**, the whole
stack is healthy. If it shows **Database: Unavailable**, run
`bash scripts/diagnosis.sh` on the OL9 host (or the Hub host's variant)
for an automatic root-cause hint.

## Repository roles

| Repo | Branch we develop on | What lives here |
|---|---|---|
| `ruslanmv/matrixhub` | `claude/fix-matrixhub-oH85Q` | Next.js front-end, status page, `/api/*` proxy |
| `agent-matrix/matrix-hub` | `claude/fix-matrixhub-oH85Q` | FastAPI backend, Docker image, ops scripts (`select_database_url.sh`, `init_aiven.sh`, `test_db.sh`, `update.sh`, `diagnosis.sh`, `bootstrap_host.sh`) |
| `agent-matrix/matrixhub-db` (this) | `claude/fix-matrixhub-oH85Q` | Postgres image + Makefile for the OL9 fallback box, plus Aiven verify/backup workflows and the `migrate_to_aiven.sh` cutover script |

For the unified update procedure (release → SSH → `update.sh` → smoke
probe) see `agent-matrix/matrix-hub/docs/update.md`.
