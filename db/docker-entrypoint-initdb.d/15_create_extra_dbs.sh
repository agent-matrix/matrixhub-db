#!/usr/bin/env bash
set -Eeuo pipefail
# Runs during first init inside the container

if [[ -n "${CREATE_EXTRA_DBS:-}" ]]; then
  IFS=',' read -ra DBS <<< "${CREATE_EXTRA_DBS}"
  for db in "${DBS[@]}"; do
    db="$(echo "$db" | xargs)"
    [[ -z "$db" ]] && continue
    echo "Creating extra database (if missing): $db (owner: $POSTGRES_USER)"
    psql -v ON_ERROR_STOP=1 --username=postgres --dbname=postgres <<-SQL
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db') THEN
          EXECUTE format('CREATE DATABASE %I OWNER %I', '$db', '$POSTGRES_USER');
        END IF;
      END
      $$;
SQL
  done
fi
