.PHONY: help gen-keys verify-keys env-check setup up down logs logs-user logs-bookmark logs-db logs-redis ps restart restart-user restart-bookmark health status shell-user-db shell-bookmark-db shell-redis backup-db clean purge validate pull version \
        vm-keys vm-setup vm-up vm-down vm-logs vm-status vm-shell vm-restart vm-health

# Variables
DOCKER_COMPOSE := docker compose
KEY_DIR := ./keys
PRIVATE_KEY := $(KEY_DIR)/private.pem
PUBLIC_KEY := $(KEY_DIR)/public.pem
VM_USER ?= root
VM_HOST ?= 103.118.29.77
VM_PATH ?= /home/$(VM_USER)/bookmark-deployment
SSH := ssh $(VM_USER)@$(VM_HOST)
SCP := scp -r

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m

help: ## Display this help message
	@echo "$(BLUE)Bookmark Microservices - Deployment Makefile$(NC)"
	@echo "$(BLUE)============================================$(NC)"
	@echo ""
	@echo "$(GREEN)Local Development:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -v 'vm-' | awk 'BEGIN {FS = ":.*?## "} {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)VM Deployment:$(NC)"
	@grep -E '^vm-[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'

# ==================== KEY GENERATION ====================
# user-service signs JWTs; bookmark-service validates. The shared provider loads
# both keys, so the SAME keypair is mounted into both services.

gen-keys: ## Generate the shared RSA JWT keypair
	@echo "$(BLUE)Generating shared RSA keypair...$(NC)"
	@mkdir -p $(KEY_DIR)
	@if [ -f $(PRIVATE_KEY) ]; then \
		echo "$(YELLOW)⚠️  Keys already exist at $(KEY_DIR)$(NC)"; \
		read -p "Regenerate? (y/N) " -n 1 -r; echo; \
		if [[ ! $$REPLY =~ ^[Yy]$$ ]]; then echo "$(YELLOW)Cancelled.$(NC)"; exit 1; fi; \
	fi
	@openssl genrsa -out $(PRIVATE_KEY) 2048
	@openssl rsa -in $(PRIVATE_KEY) -pubout -out $(PUBLIC_KEY)
	@chmod 600 $(PRIVATE_KEY); chmod 644 $(PUBLIC_KEY)
	@echo "$(GREEN)✓ Keys generated at $(KEY_DIR)$(NC)"

verify-keys: ## Verify the RSA keypair is valid
	@if [ ! -f $(PRIVATE_KEY) ] || [ ! -f $(PUBLIC_KEY) ]; then echo "$(RED)✗ Keys not found!$(NC)"; exit 1; fi
	@openssl pkey -in $(PRIVATE_KEY) -text -noout | head -1
	@echo "$(GREEN)✓ Keys are valid!$(NC)"

# ==================== ENVIRONMENT ====================

env-check: ## Check that all env files exist
	@echo "$(BLUE)Checking environment files...$(NC)"
	@missing=0; \
	for f in postgres/.env user-service/.env bookmark-service/.env config/cloudflared.env; do \
		if [ -f $$f ]; then echo "$(GREEN)✓$(NC) $$f"; else echo "$(YELLOW)⚠$(NC) $$f (missing)"; missing=1; fi; \
	done; \
	if [ $$missing -eq 1 ]; then echo "$(YELLOW)Run 'make setup' to create them$(NC)"; fi

setup: ## Create env files from examples and generate keys
	@echo "$(BLUE)Setting up deployment...$(NC)"
	@for d in postgres/user-db postgres/bookmark-db user-service/.env bookmark-service/.env config/cloudflared; do true; done
	@[ -f postgres/.env ] || cp postgres/.env.example postgres/.env
	@[ -f user-service/.env ] || cp user-service/.env.example user-service/.env
	@[ -f bookmark-service/.env ] || cp bookmark-service/.env.example bookmark-service/.env
	@[ -f config/cloudflared.env ] || cp config/cloudflared.env.example config/cloudflared.env
	@$(MAKE) gen-keys
	@echo "$(GREEN)✓ Setup complete!$(NC)"

# ==================== DOCKER COMPOSE ====================

up: ## Start all services
	@$(DOCKER_COMPOSE) up -d
	@echo "$(GREEN)✓ Services started!$(NC)"
	@sleep 3
	@$(MAKE) ps

down: ## Stop all services
	@$(DOCKER_COMPOSE) down
	@echo "$(GREEN)✓ Services stopped!$(NC)"

logs: ## Tail all logs
	@$(DOCKER_COMPOSE) logs -f

logs-user: ## Tail user-service logs
	@$(DOCKER_COMPOSE) logs -f user-service

logs-bookmark: ## Tail bookmark-service logs
	@$(DOCKER_COMPOSE) logs -f bookmark-service

logs-db: ## Tail both database logs
	@$(DOCKER_COMPOSE) logs -f user-db bookmark-db

logs-redis: ## Tail Redis logs
	@$(DOCKER_COMPOSE) logs -f redis

ps: ## Show running containers
	@$(DOCKER_COMPOSE) ps

restart: ## Restart all services
	@$(DOCKER_COMPOSE) restart
	@$(MAKE) ps

restart-user: ## Restart user-service
	@$(DOCKER_COMPOSE) restart user-service

restart-bookmark: ## Restart bookmark-service
	@$(DOCKER_COMPOSE) restart bookmark-service

# ==================== HEALTH & DIAGNOSTICS ====================

health: ## Check both services' health via the gateway
	@echo "$(YELLOW)user-service:$(NC)"
	@curl -s http://localhost/api/user_service/health-check || echo "$(RED)✗ user-service unavailable$(NC)"
	@echo ""
	@echo "$(YELLOW)bookmark-service:$(NC)"
	@curl -s http://localhost/api/bookmark_service/health-check || echo "$(RED)✗ bookmark-service unavailable$(NC)"
	@echo ""
	@$(DOCKER_COMPOSE) ps

status: ## Show containers, volumes, networks
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E 'user|bookmark|redis|nginx|portal' || echo "No running containers"

# ==================== DATABASE & CACHE ====================

shell-user-db: ## Open psql on the user database
	@$(DOCKER_COMPOSE) exec user-db psql -U $${POSTGRES_USER:-admin} -d $${POSTGRES_DB:-user_db}

shell-bookmark-db: ## Open psql on the bookmark database
	@$(DOCKER_COMPOSE) exec bookmark-db psql -U $${POSTGRES_USER:-admin} -d $${POSTGRES_DB:-bookmark_db}

shell-redis: ## Open the Redis CLI
	@$(DOCKER_COMPOSE) exec redis redis-cli

# ==================== CLEANUP ====================

clean: ## Stop and remove containers
	@$(DOCKER_COMPOSE) down --remove-orphans
	@echo "$(GREEN)✓ Containers removed!$(NC)"

purge: ## Remove containers, volumes, and keys (⚠️  DESTRUCTIVE)
	@echo "$(RED)⚠️  This deletes all data, volumes, and keys!$(NC)"
	@read -p "Are you sure? (yes/no) " -r; \
	if [ "$$REPLY" = "yes" ]; then \
		$(DOCKER_COMPOSE) down -v; rm -rf $(KEY_DIR); \
		echo "$(GREEN)✓ Purge complete!$(NC)"; \
	else echo "$(YELLOW)Cancelled.$(NC)"; fi

# ==================== UTILITIES ====================

validate: ## Validate docker-compose configuration
	@$(DOCKER_COMPOSE) config --quiet && echo "$(GREEN)✓ Configuration is valid!$(NC)" || echo "$(RED)✗ Configuration has errors!$(NC)"

pull: ## Pull the latest images
	@$(DOCKER_COMPOSE) pull
	@echo "$(GREEN)✓ Images updated!$(NC)"

version: ## Show tool versions
	@docker --version
	@$(DOCKER_COMPOSE) version
	@openssl version

# ==================== VM DEPLOYMENT ====================

vm-keys: ## Generate the keypair on the VM
	@$(SSH) "mkdir -p $(VM_PATH)/$(KEY_DIR) && \
		openssl genrsa -out $(VM_PATH)/$(PRIVATE_KEY) 2048 && \
		openssl rsa -in $(VM_PATH)/$(PRIVATE_KEY) -pubout -out $(VM_PATH)/$(PUBLIC_KEY) && \
		chmod 600 $(VM_PATH)/$(PRIVATE_KEY) && chmod 644 $(VM_PATH)/$(PUBLIC_KEY)"
	@echo "$(GREEN)✓ Keys generated on VM!$(NC)"

vm-setup: ## Upload deployment to the VM and set it up
	@$(SSH) "mkdir -p $(VM_PATH)"
	@$(SCP) . $(VM_USER)@$(VM_HOST):$(VM_PATH)
	@$(SSH) "cd $(VM_PATH) && make setup"
	@echo "$(GREEN)✓ VM setup complete! Run 'make vm-up'.$(NC)"

vm-up: ## Start services on the VM
	@$(SSH) "cd $(VM_PATH) && docker compose up -d"

vm-down: ## Stop services on the VM
	@$(SSH) "cd $(VM_PATH) && docker compose down"

vm-logs: ## View logs from the VM
	@$(SSH) "cd $(VM_PATH) && docker compose logs --tail=50"

vm-status: ## Check status on the VM
	@$(SSH) "cd $(VM_PATH) && docker compose ps"

vm-shell: ## SSH into the VM
	@$(SSH)

vm-restart: ## Restart services on the VM
	@$(SSH) "cd $(VM_PATH) && docker compose restart"

vm-health: ## Check health on the VM
	@$(SSH) "curl -s http://localhost/api/user_service/health-check; echo; curl -s http://localhost/api/bookmark_service/health-check"

.DEFAULT_GOAL := help
