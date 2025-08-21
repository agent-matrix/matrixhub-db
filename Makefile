# ==============================================================================
# Makefile for MatrixHub Database
#
# Manages a Dockerized PostgreSQL database, optimized for Oracle Linux 9 on OCI.
#
# Features:
#   - Automated Docker installation and firewall configuration.
#   - Idempotent setup: safe to re-run targets.
#   - Simplified environment management with .env.db.template fallback.
#   - Systemd integration for auto-start and nightly backups.
#   - Commands for database operations like backup, restore, and psql shell.
#   - Support for optional components like PgBouncer and Prometheus Exporter.
# ==============================================================================

# Set 'help' as the default target when 'make' is run without arguments.
.DEFAULT_GOAL := help

# Use bash for all shell commands.
SHELL := /bin/bash

# Terminal Colors for better output
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
NC     := \033[0m

# ==============================================================================
# SECTION: Configuration
#
# Override these from the command line, e.g., 'make up PG_HOST_PORT=5433'
# ==============================================================================

# --- Docker & Container Settings ---
IMAGE_NAME     ?= matrixhub-postgres
IMAGE_TAG      ?= 16-matrixhub
CONTAINER_NAME ?= matrixhub-db
NETWORK_NAME   ?= matrixhub-net
NETWORK_ALIAS  ?= db
VOLUME_NAME    ?= matrixhub-pgdata
PG_HOST_PORT   ?= 5432

# --- Backup Settings ---
BACKUP_DIR      ?= $(shell pwd)/backups
# Generates a timestamped filename, e.g., matrixhub-db-2025-08-22-013849.dump
BACKUP_FILENAME := matrixhub-db-$(shell date +%F-%H%M%S).dump

# ==============================================================================
# SECTION: Internal Variables
# ==============================================================================

# --- Environment File Handling ---
# We prioritize .env.db, fall back to .env.db.template, and export the variables.
ENV_DB          := .env.db
ENV_DB_TEMPLATE := .env.db.template

ifneq ($(wildcard $(ENV_DB)),)
    -include $(ENV_DB)
else ifneq ($(wildcard $(ENV_DB_TEMPLATE)),)
    -include $(ENV_DB_TEMPLATE)
endif
export

# --- Derived Variables ---
FULL_IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

# Check if sudo is required to run docker. This makes the Makefile more portable.
SUDO := $(shell docker info >/dev/null 2>&1 || echo "sudo")

# ==============================================================================
# SECTION: Phony Targets
#
# Declares all targets that do not produce output files.
# ==============================================================================

.PHONY: help init build up down start stop restart logs health clean
.PHONY: psql backup restore verify
.PHONY: install-docker firewall-open firewall-close
.PHONY: systemd-install systemd-remove backup-install backup-remove backup-now
.PHONY: pgbouncer-up pgbouncer-down exporter-up exporter-down
.PHONY: _ensure-env _ensure-scripts-executable

# ==============================================================================
# ✨ Main Targets
# ==============================================================================

help: ## Show this help message.
	@echo -e "$(CYAN)MatrixHub Database Makefile$(NC)"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: install-docker firewall-open up health ## Bootstrap host: Install dependencies, configure, build, and run the database.

# ==============================================================================
# 🐳 Docker & Container Lifecycle
# ==============================================================================

build: _ensure-scripts-executable _ensure-env ## Build the custom PostgreSQL Docker image.
	@echo "--> Building Docker image: $(FULL_IMAGE)..."
	$(SUDO) -E ./scripts/build_db_image.sh $(FULL_IMAGE)

up: _ensure-scripts-executable _ensure-env ## Start the DB container (creates network/volume if needed).
	@echo "--> Bringing up container '$(CONTAINER_NAME)'..."
	$(SUDO) -E ./scripts/run_db_prod.sh $(CONTAINER_NAME) $(VOLUME_NAME) $(NETWORK_NAME) $(NETWORK_ALIAS) $(PG_HOST_PORT)

down: ## Stop and remove the database container.
	@echo "--> Stopping and removing container '$(CONTAINER_NAME)'..."
	-$(SUDO) docker stop $(CONTAINER_NAME)
	-$(SUDO) docker rm $(CONTAINER_NAME)
	@echo "$(GREEN)✓ Container '$(CONTAINER_NAME)' stopped and removed.$(NC)"

start: ## Start an existing, stopped container.
	@echo "--> Starting container '$(CONTAINER_NAME)'..."
	$(SUDO) docker start $(CONTAINER_NAME)

stop: ## Stop the running container without removing it.
	@echo "--> Stopping container '$(CONTAINER_NAME)'..."
	$(SUDO) docker stop $(CONTAINER_NAME)

restart: stop start ## Restart the container.

logs: ## Follow the logs of the database container.
	@echo "--> Following logs for '$(CONTAINER_NAME)' (Ctrl+C to exit)..."
	$(SUDO) docker logs -f $(CONTAINER_NAME)

health: _ensure-scripts-executable ## Wait for the container to become healthy.
	@echo "--> Waiting for container '$(CONTAINER_NAME)' to be healthy..."
	$(SUDO) ./scripts/health_wait.sh $(CONTAINER_NAME)

clean: down ## Stop container and PERMANENTLY DELETE the database volume.
	@echo -e "$(RED)DANGER: This will PERMANENTLY delete all data in volume '$(VOLUME_NAME)'!$(NC)"
	@read -p "Are you sure you want to proceed? Type 'yes' to confirm: " c; \
	if [ "$$c" = "yes" ]; then \
		echo "--> Deleting volume '$(VOLUME_NAME)'..."; \
		$(SUDO) docker volume rm $(VOLUME_NAME) && echo "$(GREEN)✓ Volume '$(VOLUME_NAME)' deleted.$(NC)"; \
	else \
		echo "Volume deletion aborted."; \
	fi

# ==============================================================================
# 🗃️ Database Operations
# ==============================================================================

psql: _ensure-scripts-executable _ensure-env ## Open an interactive psql shell to the database.
	@echo "--> Connecting to '$(POSTGRES_DB)' as user '$(POSTGRES_USER)'..."
	$(SUDO) ./scripts/psql_shell.sh $(POSTGRES_USER) $(POSTGRES_DB) $(CONTAINER_NAME)

backup: _ensure-env ## Create a new database backup in the ./backups directory.
	@mkdir -p $(BACKUP_DIR)
	@echo "--> Backing up database '$(POSTGRES_DB)'..."
	$(SUDO) docker exec $(CONTAINER_NAME) pg_dump -U $(POSTGRES_USER) -d $(POSTGRES_DB) -Fc > $(BACKUP_DIR)/$(BACKUP_FILENAME)
	@echo "$(GREEN)✓ Backup complete: $(BACKUP_DIR)/$(BACKUP_FILENAME)$(NC)"

restore: _ensure-env ## Restore from the most recent backup (DANGER: Overwrites current data!).
	@LATEST_BACKUP=$$($(SUDO) ls -t $(BACKUP_DIR)/*.dump 2>/dev/null | head -n 1); \
	if [ -z "$$LATEST_BACKUP" ]; then \
		echo "$(RED)✖ No backups found in $(BACKUP_DIR). Aborting.$(NC)" >&2; exit 1; \
	fi; \
	echo -e "$(YELLOW)WARNING: This will overwrite all data in the '$(POSTGRES_DB)' database.$(NC)"; \
	read -p "Restore from '$$LATEST_BACKUP'? Type 'yes' to confirm: " c; \
	if [ "$$c" = "yes" ]; then \
		echo "--> Restoring from $$LATEST_BACKUP..."; \
		cat $$LATEST_BACKUP | $(SUDO) docker exec -i $(CONTAINER_NAME) pg_restore -U $(POSTGRES_USER) -d $(POSTGRES_DB) --clean --if-exists; \
		echo "$(GREEN)✓ Restore complete.$(NC)"; \
	else \
		echo "Restore aborted."; \
	fi

verify: _ensure-env ## Run a quick verification of the database schema.
	@echo "--> Verifying schema in database '$(POSTGRES_DB)'..."
	@$(SUDO) docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) \
		-c '\echo -e "\\n--- Tables ---"; \dt' \
		-c '\echo -e "\\n--- Details: entity ---"; \d+ entity' \
		-c '\echo -e "\\n--- Details: embedding_chunk ---"; \d+ embedding_chunk' \
		-c '\echo -e "\\n--- Details: remote ---"; \d+ remote'

# ==============================================================================
# ⚙️ Host System Integration
# ==============================================================================

install-docker: _ensure-scripts-executable ## Install Docker CE on Oracle Linux 9 (idempotent).
	@if command -v docker >/dev/null 2>&1; then \
		echo "$(GREEN)✓ Docker is already installed. Skipping.$(NC)"; \
	else \
		echo "--> Installing Docker CE..."; \
		sudo ./scripts/install_docker_ol9.sh; \
	fi

firewall-open: _ensure-scripts-executable ## Open PostgreSQL port $(PG_HOST_PORT)/tcp in the firewall (idempotent).
	@echo "--> Opening firewall port $(PG_HOST_PORT)/tcp..."
	sudo ./scripts/open_firewall_ol9.sh $(PG_HOST_PORT)

firewall-close: _ensure-scripts-executable ## Close PostgreSQL port $(PG_HOST_PORT)/tcp in the firewall.
	@echo "--> Closing firewall port $(PG_HOST_PORT)/tcp..."
	sudo ./scripts/close_firewall_ol9.sh $(PG_HOST_PORT)

systemd-install: _ensure-scripts-executable ## Install and enable the systemd service for auto-start on boot.
	@echo "--> Installing systemd service for '$(CONTAINER_NAME)'..."
	sudo ./scripts/install_systemd_service.sh

systemd-remove: _ensure-scripts-executable ## Disable and remove the systemd service.
	@echo "--> Removing systemd service for '$(CONTAINER_NAME)'..."
	sudo ./scripts/uninstall_systemd_service.sh

backup-install: _ensure-scripts-executable ## Install the systemd timer for nightly backups.
	@echo "--> Installing systemd timer for nightly backups..."
	sudo cp systemd/matrixhub-db-backup.service /etc/systemd/system/
	sudo cp systemd/matrixhub-db-backup.timer /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable --now matrixhub-db-backup.timer
	@echo "$(GREEN)✓ Backup timer installed. Check status with: systemctl list-timers | grep matrixhub$(NC)"

backup-remove: ## Remove the systemd backup timer.
	@echo "--> Removing systemd backup timer..."
	-sudo systemctl disable --now matrixhub-db-backup.timer
	-sudo rm -f /etc/systemd/system/matrixhub-db-backup.service /etc/systemd/system/matrixhub-db-backup.timer
	sudo systemctl daemon-reload
	@echo "$(GREEN)✓ Backup timer removed.$(NC)"

backup-now: _ensure-scripts-executable ## Trigger an on-demand backup using the systemd service script.
	@echo "--> Performing on-demand backup via helper script..."
	sudo ./scripts/backup_now.sh

# ==============================================================================
# 🧩 Optional Components (PgBouncer, Prometheus Exporter)
# ==============================================================================

pgbouncer-up: _ensure-scripts-executable ## Start PgBouncer for connection pooling.
	@echo "--> Bringing up PgBouncer..."
	sudo ./scripts/run_pgbouncer.sh up

pgbouncer-down: _ensure-scripts-executable ## Stop the PgBouncer container.
	@echo "--> Bringing down PgBouncer..."
	sudo ./scripts/run_pgbouncer.sh down

exporter-up: _ensure-scripts-executable ## Start Prometheus postgres_exporter for monitoring.
	@echo "--> Bringing up Prometheus postgres_exporter..."
	sudo ./scripts/run_exporter.sh up

exporter-down: _ensure-scripts-executable ## Stop the postgres_exporter container.
	@echo "--> Bringing down Prometheus postgres_exporter..."
	sudo ./scripts/run_exporter.sh down

# ==============================================================================
# 🛠️ Internal Helper Targets (Not intended for direct use)
# ==============================================================================

_ensure-env: ## Internal: Create .env.db from template if it's missing.
	@if [ ! -f "$(ENV_DB)" ] && [ ! -f "$(ENV_DB_TEMPLATE)" ]; then \
		echo "--> No database environment file found. Creating $(ENV_DB_TEMPLATE) with defaults."; \
		printf "POSTGRES_USER=postgres\nPOSTGRES_PASSWORD=postgres\nPOSTGRES_DB=postgres\nPGDATA=/var/lib/postgresql/data/pgdata\n" > $(ENV_DB_TEMPLATE); \
	fi
	@if [ ! -f "$(ENV_DB)" ] && [ -f "$(ENV_DB_TEMPLATE)" ]; then \
		echo "$(YELLOW)--> $(ENV_DB) not found. Creating symlink to $(ENV_DB_TEMPLATE) for compatibility.$(NC)"; \
		ln -sfn $(ENV_DB_TEMPLATE) $(ENV_DB); \
	fi

_ensure-scripts-executable: ## Internal: Make sure all helper scripts are executable.
	@chmod +x ./scripts/*.sh ./systemd/*.sh 2>/dev/null || true