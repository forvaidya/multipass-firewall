.PHONY: help install uninstall status test clean reload logs

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
NC := \033[0m # No Color

help:
	@echo "$(GREEN)Falco Firewall Management$(NC)"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Installation & Setup:"
	@echo "  install        Install Falco firewall (requires sudo)"
	@echo "  uninstall      Remove all firewall components (requires sudo)"
	@echo ""
	@echo "Operations:"
	@echo "  status         Show firewall status and rules"
	@echo "  reload         Reload firewall policy"
	@echo "  test           Run firewall tests"
	@echo "  logs           Tail firewall logs"
	@echo ""
	@echo "Development:"
	@echo "  validate       Validate policy.yaml syntax"
	@echo "  docker-test    Run tests in Docker"
	@echo "  docker-clean   Clean Docker test environment"
	@echo "  clean          Clean build artifacts"
	@echo ""

install:
	@echo "$(YELLOW)Installing Falco Firewall...$(NC)"
	sudo chmod +x scripts/setup.sh
	sudo scripts/setup.sh
	@echo "$(GREEN)Installation complete!$(NC)"

uninstall:
	@echo "$(RED)Removing Falco Firewall...$(NC)"
	sudo chmod +x scripts/cleanup.sh
	sudo scripts/cleanup.sh
	@echo "$(GREEN)Cleanup complete!$(NC)"

status:
	@echo "$(YELLOW)Checking Falco Firewall Status...$(NC)"
	@chmod +x scripts/status.sh
	@scripts/status.sh

reload:
	@echo "$(YELLOW)Reloading policy...$(NC)"
	@sudo python3 src/enforce.py reload
	@echo "$(GREEN)Policy reloaded!$(NC)"

test:
	@echo "$(YELLOW)Running firewall tests...$(NC)"
	@chmod +x scripts/test.sh
	@sudo scripts/test.sh

logs:
	@echo "$(YELLOW)Tailing firewall logs...$(NC)"
	@tail -f /var/log/falco-firewall/*.log

validate:
	@echo "$(YELLOW)Validating policy...$(NC)"
	@python3 -c "import yaml; yaml.safe_load(open('config/policy.yaml'))" && \
		echo "$(GREEN)Policy syntax valid!$(NC)" || echo "$(RED)Invalid syntax!$(NC)"

docker-test:
	@echo "$(YELLOW)Starting Docker test environment...$(NC)"
	docker-compose up -d
	@echo "$(GREEN)Test environment running!$(NC)"
	@echo "Run: docker-compose exec test-app bash"

docker-clean:
	@echo "$(YELLOW)Cleaning Docker environment...$(NC)"
	docker-compose down -v
	@echo "$(GREEN)Docker environment cleaned!$(NC)"

clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	rm -rf build dist *.egg-info
	@echo "$(GREEN)Clean complete!$(NC)"

.DEFAULT_GOAL := help
