# Use the official PostgreSQL 16 image from Docker Hub
FROM postgres:16

# --- REMOVED ---
# The ENV block for POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB has been
# removed. This is the modern security standard.
#
# WHY: Baking credentials into an image is a security risk. They should only be
# supplied at runtime when the container is started. Your 'run_db_prod.sh'
# script already does this correctly using the '--env-file' flag.

# Set arguments for creating a UTF-8 cluster. This is safe and recommended.
ENV POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C.UTF-8"

# The official postgres image will automatically run any .sql, .sql.gz, or .sh
# scripts found in this directory when the database is first created. This is
# the standard way to initialize a database schema.
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/