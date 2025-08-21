FROM postgres:16

# Defaults (override with --env-file at runtime)
ENV POSTGRES_USER=${POSTGRES_USER:-matrix} \
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-matrix} \
    POSTGRES_DB=${POSTGRES_DB:-matrixhub}

# UTF-8 cluster
ENV POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C.UTF-8"

# Run once on empty data dir
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
