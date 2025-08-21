# Makefile for MatrixHub Database (OCI / Oracle Linux 9)

-include .env.db
export

IMAGE_NAME       ?= $(or $(IMAGE_NAME),matrixhub-postgres)
IMAGE_TAG        ?= $(or $(IMAGE_TAG),16-matrixhub)
FULL_IMAGE       := $(IMAGE_NAME):$(IMAGE_TAG)
CONTAINER_NAME   ?= $(or $(CONTAINER_NAME),matrixhub-db)
NETWORK_NAME     ?= $(or $(NETWORK_NAME),matrixhub-net)
NETWORK_ALIAS    ?= $(or $(NETWORK_ALIAS),db)
VOLUME_NAME      ?= $(or $(VOLUME_NAME),matrixhub-pgdata)
PG_HOST_PORT     ?= $(or $(PG_HOST_PORT),5432)

BACKUP_DIR       ?= $(shell pwd)/backups
BACKUP_FILENAME  := matrixhub-$(shell date +%F-%H%M%S).dump

.PHONY: help init install-docker firewall-open firewall-close build up down start stop restart logs psql backup restore clean systemd-install systemd-remove health verify \
        pgbouncer-up pgbouncer-down exporter-up exporter-down backup-now backup-install backup-remove

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

init: ## Full bootstrap on OCI: docker, firewall, build+run DB, systemd, wait healthy
	./scripts/bootstrap_host_oci.sh

install-docker: ## Install Docker CE on Oracle Linux 9
	./scripts/install_docker_ol9.sh

firewall-open: ## Open port 5432/tcp (firewalld)
	./scripts/open_firewall_ol9.sh

firewall-close: ## Close port 5432/tcp (firewalld)
	./scripts/close_firewall_ol9.sh

build: ## Build the custom postgres DB image with schema init
	./scripts/build_db_image.sh

up: ## Start the DB container (creates network/volume if missing)
	./scripts/run_db_prod.sh

down: ## Stop & remove the DB container
	-docker stop $(CONTAINER_NAME)
	-docker rm $(CONTAINER_NAME)

start: ## Start an existing container
	docker start $(CONTAINER_NAME)

stop: ## Stop the running container
	docker stop $(CONTAINER_NAME)

restart: stop start ## Restart container

logs: ## Follow logs
	docker logs -f $(CONTAINER_NAME)

psql: ## Open interactive psql shell to $(POSTGRES_DB)
	./scripts/psql_shell.sh

backup: ## Create backup (custom format) into ./backups/
	@mkdir -p $(BACKUP_DIR)
	@echo "▶ Backing up '$(POSTGRES_DB)' to $(BACKUP_DIR)/$(BACKUP_FILENAME)..."
	@docker exec $(CONTAINER_NAME) pg_dump -U $(POSTGRES_USER) -d $(POSTGRES_DB) -Fc > $(BACKUP_DIR)/$(BACKUP_FILENAME)
	@echo "✅ Backup complete: $(BACKUP_DIR)/$(BACKUP_FILENAME)"

restore: ## Restore from most recent backup in ./backups (DANGER: overwrites data)
	@LATEST=$$(ls -t $(BACKUP_DIR)/*.dump 2>/dev/null | head -n 1); \
	if [ -z "$$LATEST" ]; then echo "✖ No backups in $(BACKUP_DIR)"; exit 1; fi; \
	read -p "Restore from '$$LATEST'? This OVERWRITES data. [y/N] " c && [ "$$c" = "y" ] && \
	docker exec -i $(CONTAINER_NAME) pg_restore -U $(POSTGRES_USER) -d $(POSTGRES_DB) --clean --if-exists < $$LATEST && \
	echo "✅ Restore complete." || echo "Aborted."

clean: down ## Stop container and DELETE volume (DANGER)
	@read -p "Delete volume '$(VOLUME_NAME)'? [y/N] " c && if [ "$$c" = "y" ]; then docker volume rm $(VOLUME_NAME); else echo "Aborted."; fi

systemd-install: ## Install & enable systemd unit for auto-start on boot
	./scripts/install_systemd_service.sh

systemd-remove: ## Disable & remove systemd unit
	./scripts/uninstall_systemd_service.sh

health: ## Wait until container health=healthy
	./scripts/health_wait.sh

verify: ## Show schema quick checks (tables, columns, indexes)
	@docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\dt'
	@docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\d+ entity'
	@docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\d+ embedding_chunk'
	@docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c '\\d+ remote'

pgbouncer-up: ## Start PgBouncer (optional connection pooling)
	./scripts/run_pgbouncer.sh up

pgbouncer-down: ## Stop PgBouncer
	./scripts/run_pgbouncer.sh down

exporter-up: ## Start Prometheus postgres_exporter (optional monitoring)
	./scripts/run_exporter.sh up

exporter-down: ## Stop postgres_exporter
	./scripts/run_exporter.sh down

backup-now: ## On-demand backup via helper script
	./scripts/backup_now.sh

backup-install: ## Install systemd timer for nightly backups
	sudo cp systemd/matrixhub-db-backup.service /etc/systemd/system/
	sudo cp systemd/matrixhub-db-backup.timer /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable --now matrixhub-db-backup.timer
	@echo "✅ Backup timer installed: systemctl list-timers | grep matrixhub-db-backup"

backup-remove: ## Remove backup timer
	sudo systemctl disable --now matrixhub-db-backup.timer || true
	sudo rm -f /etc/systemd/system/matrixhub-db-backup.service /etc/systemd/system/matrixhub-db-backup.timer || true
	sudo systemctl daemon-reload
	@echo "✅ Backup timer removed"
