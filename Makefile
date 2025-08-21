# Makefile for MatrixHub Database (OCI / Oracle Linux 9)
# This Makefile automates common tasks for managing a Dockerized PostgreSQL database
# specifically for Oracle Linux 9 instances on OCI.

# Includes environment variables from a .env.db file if it exists.
# This is crucial for variables like POSTGRES_USER, POSTGRES_DB, etc.
-include .env.db
export

# --- General Configuration Variables ---
# Default values for Docker image, container, network, and volume names.
# These can be overridden by environment variables (e.g., IMAGE_NAME=my-image make build)
# or by specifying them in the .env.db file.
IMAGE_NAME       ?= matrixhub-postgres
IMAGE_TAG        ?= 16-matrixhub
FULL_IMAGE       := $(IMAGE_NAME):$(IMAGE_TAG)
CONTAINER_NAME   ?= matrixhub-db
NETWORK_NAME     ?= matrixhub-net
NETWORK_ALIAS    ?= db
VOLUME_NAME      ?= matrixhub-pgdata
PG_HOST_PORT     ?= 5432 # Port exposed on the host for PostgreSQL (ensure this matches run_db_prod.sh)

# --- Backup Configuration ---
# Directory for storing database backups. Defaults to a 'backups' subdirectory in the current location.
BACKUP_DIR       ?= $(shell pwd)/backups
# Dynamic filename for backups including current date and time.
BACKUP_FILENAME  := matrixhub-$(shell date +%F-%H%M%S).dump

# --- PHONY Targets ---
# .PHONY declares targets that do not correspond to actual files. This ensures
# they are always run even if a file with the same name exists.
.PHONY: help init install-docker firewall-open firewall-close build up down start stop restart logs psql backup restore clean systemd-install systemd-remove health verify \
        pgbouncer-up pgbouncer-down exporter-up exporter-down backup-now backup-install backup-remove \
        _ensure_script_executables # Internal target to ensure scripts are executable

# Internal target: ensures all necessary scripts have executable permissions.
# This helps prevent "Permission denied" errors for shell scripts called by make.
_ensure_script_executables:
	@echo "Ensuring scripts in ./scripts/ and ./systemd/ have executable permissions..."
	chmod +x ./scripts/*.sh 2>/dev/null || true # Ignore errors if script dir/files don't exist yet
	chmod +x ./systemd/*.sh 2>/dev/null || true # If you have .sh scripts in systemd/


help: ## Show this help message
	@grep -E '^[a-zA-Z0-9_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

init: _ensure_script_executables ## Full bootstrap on OCI: docker, firewall, build+run DB, systemd, wait healthy
	@echo "Running full initialization sequence for OCI instance..."
	sudo ./scripts/bootstrap_host_oci.sh # Added sudo

install-docker: _ensure_script_executables ## Install Docker CE on Oracle Linux 9
	@echo "Installing Docker CE..."
	sudo ./scripts/install_docker_ol9.sh # Added sudo

firewall-open: _ensure_script_executables ## Open port $(PG_HOST_PORT)/tcp (firewalld) for PostgreSQL access
	@echo "Opening firewall port $(PG_HOST_PORT)/tcp..."
	sudo ./scripts/open_firewall_ol9.sh $(PG_HOST_PORT) # Added sudo, Pass port to script for dynamic use

firewall-close: _ensure_script_executables ## Close port $(PG_HOST_PORT)/tcp (firewalld)
	@echo "Closing firewall port $(PG_HOST_PORT)/tcp..."
	sudo ./scripts/close_firewall_ol9.sh $(PG_HOST_PORT) # Added sudo, Pass port to script for dynamic use

build: _ensure_script_executables ## Build the custom postgres DB image with schema init
	@echo "Building Docker image: $(FULL_IMAGE)..."
	sudo ./scripts/build_db_image.sh $(FULL_IMAGE) # Added sudo, Pass full image name to script

up: _ensure_script_executables ## Start the DB container (creates network/volume if missing), runs in detached mode
	@echo "Bringing up database container '$(CONTAINER_NAME)'..."
	sudo ./scripts/run_db_prod.sh $(CONTAINER_NAME) $(VOLUME_NAME) $(NETWORK_NAME) $(NETWORK_ALIAS) $(PG_HOST_PORT) # Added sudo, Pass all necessary vars

down: ## Stop & remove the DB container
	@echo "Stopping and removing container '$(CONTAINER_NAME)'..."
	-docker stop $(CONTAINER_NAME) # Attempt to stop gracefully
	-docker rm $(CONTAINER_NAME)   # Attempt to remove
	@echo "Container '$(CONTAINER_NAME)' stopped and removed (if it existed)."

start: ## Start an existing container
	@echo "Starting container '$(CONTAINER_NAME)'..."
	docker start $(CONTAINER_NAME)

stop: ## Stop the running container
	@echo "Stopping container '$(CONTAINER_NAME)'..."
	docker stop $(CONTAINER_NAME)

restart: stop start ## Restart container (stops then starts)

logs: ## Follow container logs
	@echo "Following logs for container '$(CONTAINER_NAME)':"
	docker logs -f $(CONTAINER_NAME)

psql: _ensure_script_executables ## Open interactive psql shell to $(POSTGRES_DB)
	@echo "Connecting to PostgreSQL database '$(POSTGRES_DB)'..."
	# Ensure POSTGRES_USER and POSTGRES_DB are set in .env.db or environment
	sudo ./scripts/psql_shell.sh $(POSTGRES_USER) $(POSTGRES_DB) $(CONTAINER_NAME) # Added sudo, Pass required variables

backup: ## Create backup (custom format) into ./backups/
	@mkdir -p $(BACKUP_DIR)
	@echo "▶ Backing up '$(POSTGRES_DB)' to $(BACKUP_DIR)/$(BACKUP_FILENAME)..."
	# Ensure POSTGRES_USER and POSTGRES_DB are set in .env.db or environment
	docker exec $(CONTAINER_NAME) pg_dump -U $(POSTGRES_USER) -d $(POSTGRES_DB) -Fc > $(BACKUP_DIR)/$(BACKUP_FILENAME)
	@echo "✅ Backup complete: $(BACKUP_DIR)/$(BACKUP_FILENAME)"

restore: ## Restore from most recent backup in ./backups (DANGER: overwrites data!)
	@LATEST=$$(ls -t $(BACKUP_DIR)/*.dump 2>/dev/null | head -n 1); \
	if [ -z "$$LATEST" ]; then echo "✖ No backups found in $(BACKUP_DIR). Aborting." >&2; exit 1; fi; \
	read -p "Restore from '$$LATEST'? This OVERWRITES existing data. Type 'yes' to confirm: " c && [ "$$c" = "yes" ] && \
	docker exec -i $(CONTAINER_NAME) pg_restore -U $(POSTGRES_USER) -d $(POSTGRES_DB) --clean --if-exists < "$$LATEST" && \
	echo "✅ Restore complete." || echo "Restore aborted or failed."

clean: down ## Stop container and DELETE volume (DANGER: data loss!)
	@read -p "Delete volume '$(VOLUME_NAME)'? This will PERMANENTLY delete all database data. Type 'yes' to confirm: " c && \
	if [ "$$c" = "yes" ]; then \
		docker volume rm $(VOLUME_NAME) && echo "✅ Volume '$(VOLUME_NAME)' deleted." || echo "✖ Failed to delete volume '$(VOLUME_NAME)'."; \
	else \
		echo "Aborted volume deletion."; \
	fi

systemd-install: _ensure_script_executables ## Install & enable systemd unit for auto-start on boot
	@echo "Installing systemd service for '$(CONTAINER_NAME)'..."
	sudo ./scripts/install_systemd_service.sh # Added sudo

systemd-remove: _ensure_script_executables ## Disable & remove systemd unit
	@echo "Removing systemd service for '$(CONTAINER_NAME)'..."
	sudo ./scripts/uninstall_systemd_service.sh # Added sudo

health: _ensure_script_executables ## Wait until container health=healthy
	@echo "Waiting for container '$(CONTAINER_NAME)' to be healthy..."
	sudo ./scripts/health_wait.sh $(CONTAINER_NAME) # Added sudo, Pass container name to script

verify: ## Show schema quick checks (tables, columns, indexes)
	@echo "Verifying database schema in '$(POSTGRES_DB)'..."
	# Ensure POSTGRES_USER and POSTGRES_DB are set in .env.db or environment
	docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\dt'
	docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\d+ entity'
	docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\d+ embedding_chunk'
	docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\d+ remote'

pgbouncer-up: _ensure_script_executables ## Start PgBouncer (optional connection pooling)
	@echo "Bringing up PgBouncer..."
	sudo ./scripts/run_pgbouncer.sh up # Added sudo

pgbouncer-down: _ensure_script_executables ## Stop PgBouncer
	@echo "Bringing down PgBouncer..."
	sudo ./scripts/run_pgbouncer.sh down # Added sudo

exporter-up: _ensure_script_executables ## Start Prometheus postgres_exporter (optional monitoring)
	@echo "Bringing up Prometheus postgres_exporter..."
	sudo ./scripts/run_exporter.sh up # Added sudo

exporter-down: _ensure_script_executables ## Stop postgres_exporter
	@echo "Bringing down Prometheus postgres_exporter..."
	sudo ./scripts/run_exporter.sh down # Added sudo

backup-now: _ensure_script_executables ## On-demand backup via helper script
	@echo "Performing on-demand backup..."
	sudo ./scripts/backup_now.sh # Added sudo

backup-install: ## Install systemd timer for nightly backups
	@echo "Installing systemd timer for nightly backups..."
	@# Ensure systemd/matrixhub-db-backup.service and .timer files exist
	sudo cp systemd/matrixhub-db-backup.service /etc/systemd/system/
	sudo cp systemd/matrixhub-db-backup.timer /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable --now matrixhub-db-backup.timer
	@echo "✅ Backup timer installed: To check status: systemctl list-timers | grep matrixhub-db-backup"

backup-remove: ## Remove backup timer
	@echo "Removing systemd backup timer..."
	sudo systemctl disable --now matrixhub-db-backup.timer || true # Disable first, ignore if not active
	sudo rm -f /etc/systemd/system/matrixhub-db-backup.service /etc/systemd/system/matrixhub-db-backup.timer || true # Remove files, ignore if missing
	sudo systemctl daemon-reload
	@echo "✅ Backup timer removed."
