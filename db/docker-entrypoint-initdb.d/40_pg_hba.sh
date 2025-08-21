#!/usr/bin/env bash
set -Eeuo pipefail
# Secure pg_hba configuration on first init
# Allows connections from CIDRs defined in PG_ALLOW_CIDR (comma-separated)

ALLOW_LIST=${PG_ALLOW_CIDR:-0.0.0.0/0}
HBA="$PGDATA/pg_hba.conf"

{
  echo "# Managed by init script (matrixhub-db)";
  echo "local   all             all                                     peer";
  IFS=',' read -ra L <<< "$ALLOW_LIST"
  for cidr in "${L[@]}"; do
    cidr="$(echo "$cidr" | xargs)"; [[ -z "$cidr" ]] && continue
    echo "host    all             all             ${cidr}              scram-sha-256"
  done
} > "$HBA"

chmod 0600 "$HBA"
