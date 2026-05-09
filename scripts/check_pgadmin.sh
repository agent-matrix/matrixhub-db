#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# --- Adjust these variables to match your setup ---
PG_CONTAINER="matrixhub-db"
PGADMIN_CONTAINER="pgadmin"
DB_PORT="5432"
PUBLIC_IP="141.148.40.165" # IMPORTANT: Your server's public IP address

# ==============================================================================
# SCRIPT LOGIC (No need to edit below this line)
# ==============================================================================

# --- Pretty Printing ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'

step() { printf "\n${C_BLUE}${C_BOLD}▶ %s${C_RESET}\n" "$*"; }
pass() { printf "${C_GREEN}✅ PASS:${C_RESET} %s\n" "$*"; }
fail() { printf "${C_RED}❌ FAIL:${C_RESET} %s\n" "$*"; EXIT_CODE=1; }
warn() { printf "${C_YELLOW}🟡 WARN:${C_RESET} %s\n" "$*"; }
info() { printf "   ${C_RESET}ℹ %s\n" "$*"; }

# --- Docker Runner ---
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
    info "Using 'sudo docker' for commands."
  else
    fail "Docker daemon is not accessible. Please ensure Docker is running and you have permissions."
    exit 1
  fi
fi

# --- Main Test Functions ---
check_containers_running() {
  step "Checking if containers are running..."
  local all_ok=true
  for container in "$PG_CONTAINER" "$PGADMIN_CONTAINER"; do
    if ! ${DOCKER} ps --filter "name=^${container}$" --format "{{.Names}}" | grep -q "^${container}$"; then
      fail "Container '$container' is not running."
      all_ok=false
    else
      pass "Container '$container' is running."
    fi
  done
  [[ "$all_ok" == true ]]
}

check_host_ports() {
  step "Checking if host ports are listening..."
  local port_checker
  port_checker=$(command -v ss || command -v netstat)
  if [[ -z "$port_checker" ]]; then
    warn "Cannot find 'ss' or 'netstat' to check ports. Skipping."
    return
  fi

  if ! sudo "${port_checker}" -lntp | grep -q ":${DB_PORT} "; then
    fail "Port ${DB_PORT} (Postgres) is not listening on the host."
  else
    pass "Port ${DB_PORT} (Postgres) is listening on the host."
  fi
}

check_internal_network() {
  step "Checking Docker internal network..."
  info "Testing DNS resolution from '$PGADMIN_CONTAINER' to '$PG_CONTAINER'..."
  local ip
  ip=$(${DOCKER} exec "$PGADMIN_CONTAINER" getent hosts "$PG_CONTAINER" | awk '{print $1}')
  if [[ -z "$ip" ]]; then
    fail "DNS resolution failed. '$PGADMIN_CONTAINER' cannot find '$PG_CONTAINER'."
    return 1
  fi
  pass "DNS resolution OK. '$PG_CONTAINER' resolves to '$ip'."

  info "Testing connectivity from '$PGADMIN_CONTAINER' to '$PG_CONTAINER' on port ${DB_PORT}..."
  local result
  result=$(${DOCKER} exec "$PGADMIN_CONTAINER" bash -lc "python3 -c \"
import socket; s=socket.socket(); s.settimeout(3)
try:
    s.connect(('${PG_CONTAINER}', ${DB_PORT})); print('OK')
except Exception:
    print('FAIL')
\"")

  if [[ "$result" == "OK" ]]; then
    pass "Internal connection successful. This is the correct path for pgAdmin."
  else
    fail "Internal connection failed. '$PGADMIN_CONTAINER' cannot reach '$PG_CONTAINER'."
  fi
}

check_external_loopback() {
  step "Checking external 'loopback' connection (this test is EXPECTED to fail)..."
  info "Testing connectivity from '$PGADMIN_CONTAINER' to public IP ${PUBLIC_IP}..."
  local result
  result=$(${DOCKER} exec "$PGADMIN_CONTAINER" bash -lc "python3 -c \"
import socket; s=socket.socket(); s.settimeout(5)
try:
    s.connect(('${PUBLIC_IP}', ${DB_PORT})); print('OK')
except Exception:
    print('FAIL')
\"")

  if [[ "$result" == "FAIL" ]]; then
    pass "Connection to public IP failed as expected (Hairpin NAT)."
    info "This confirms you MUST use the internal hostname ('${PG_CONTAINER}') in pgAdmin."
  else
    warn "Connection to public IP succeeded. This is unusual but not necessarily an error."
  fi
}

check_db_logs() {
  step "Checking database logs for recent fatal errors..."
  if ${DOCKER} logs --tail 100 "$PG_CONTAINER" 2>&1 | grep -q "FATAL"; then
    warn "Found 'FATAL' errors in recent database logs. Please review:"
    info "$(${DOCKER} logs --tail 20 "$PG_CONTAINER" 2>&1 | grep 'FATAL' || true)"
  else
    pass "No recent 'FATAL' errors found in database logs."
  fi
}

# --- Main Execution ---
EXIT_CODE=0
echo "========================================="
echo "  MatrixHub Docker Diagnostics"
echo "========================================="

check_containers_running
check_host_ports
check_internal_network
check_external_loopback
check_db_logs

step "Summary"
if [[ "$EXIT_CODE" -eq 0 ]]; then
  printf "\n${C_GREEN}${C_BOLD}✅ All critical tests passed! Your setup appears to be correct.${C_RESET}\n"
  info "Remember to use the pre-configured 'MatrixHub DB' server in pgAdmin."
else
  printf "\n${C_RED}${C_BOLD}❌ One or more critical tests failed. Please review the output above.${C_RESET}\n"
fi

exit "$EXIT_CODE"