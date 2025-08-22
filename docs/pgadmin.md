# pgAdmin UI (optional)

Use pgAdmin to inspect your Postgres on the same Docker network.

## Start pgAdmin
The helper script reuses your Postgres password from `.env.db` (or the template):

```bash
./scripts/start_pgadmin.sh
```

**Open:** `http://localhost:5050`
**Login:** `admin@local` / *same as your POSTGRES\_PASSWORD*

> A Docker volume `matrixhub-pgadmin` is created for persistence.

## Add your database in pgAdmin

* **General → Name:** `MatrixHub DB`
* **Connection → Host name/address:** `matrixhub-db` (or `db`)
* **Port:** `5432`
* **Maintenance DB:** value of `POSTGRES_DB`
* **Username:** value of `POSTGRES_USER`
* **Password:** value of `POSTGRES_PASSWORD`
* **SSL:** Off (unless you enabled TLS in Postgres and require it)

If you can’t connect, confirm both containers share the `matrixhub-net` network:

```bash
docker inspect matrixhub-db | grep -i matrixhub-net
docker inspect pgadmin      | grep -i matrixhub-net
```
