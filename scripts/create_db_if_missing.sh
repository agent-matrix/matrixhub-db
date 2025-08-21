#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-matrixhub-db}"

get_env() {
  docker exec "${CONTAINER_NAME}" bash -lc 'env' | awk -F= '
    $1=="POSTGRES_USER"{u=$2}
    $1=="POSTGRES_PASSWORD"{p=$2}
    $1=="POSTGRES_DB"{d=$2}
    END{print u "|" p "|" d}
  '
}

step(){ printf "▶ %s\n" "$*"; }
die(){ printf "✖ %s\n" "$*" >&2; exit 1; }

docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" || die "Container ${CONTAINER_NAME} not running."

IFS='|' read -r PGUSER PGPASS PGDB <<<"$(get_env)"
[ -n "${PGUSER}" ] && [ -n "${PGPASS}" ] && [ -n "${PGDB}" ] || die "Could not read env."
export PGPASSWORD="${PGPASS}"

step "Ensuring role '${PGUSER}' exists"
docker exec -e PGPASSWORD="${PGPASS}" "${CONTAINER_NAME}" \
  psql -U postgres -h 127.0.0.1 -tc "SELECT 1 FROM pg_roles WHERE rolname='${PGUSER}'" | grep -q 1 \
  || docker exec -e PGPASSWORD="${PGPASS}" -i "${CONTAINER_NAME}" \
     psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 \
     -c "CREATE ROLE ${PGUSER} LOGIN PASSWORD '${PGPASS}';"

step "Ensuring database '${PGDB}' exists"
docker exec -e PGPASSWORD="${PGPASS}" "${CONTAINER_NAME}" \
  psql -U postgres -h 127.0.0.1 -tc "SELECT 1 FROM pg_database WHERE datname='${PGDB}'" | grep -q 1 \
  || docker exec -e PGPASSWORD="${PGPASS}" -i "${CONTAINER_NAME}" \
     psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 \
     -c "CREATE DATABASE ${PGDB} OWNER ${PGUSER};"

echo "✅ Role '${PGUSER}' and database '${PGDB}' ensured."
