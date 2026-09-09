# Local equivalents of what CI runs. If these pass, CI passes.
SHELL := /bin/bash
VENV  := .venv
PY    := $(VENV)/bin/python
ENVS  := dev stage prod

.DEFAULT_GOAL := help
.PHONY: help install fmt validate scan secrets demo clean all

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n",$$1,$$2}'

install: ## Create the venv and install tooling + pre-commit hooks
	python3 -m venv $(VENV)
	$(PY) -m pip install --quiet --upgrade pip
	$(PY) -m pip install --quiet checkov anthropic pre-commit
	$(VENV)/bin/pre-commit install
	@echo "Installed. Pre-commit hooks active."

fmt: ## Format and check Terraform
	terraform fmt -recursive terraform/
	terraform fmt -check -recursive terraform/

validate: ## terraform validate every environment
	@for e in $(ENVS); do \
	  printf "  %-6s " $$e; \
	  (cd terraform/envs/$$e && terraform init -backend=false -input=false >/dev/null 2>&1 \
	    && terraform validate -no-color | tail -1); \
	done

scan: ## Checkov + AI triage for every environment (the CI gate, locally)
	@mkdir -p .scan
	@rc=0; for e in $(ENVS); do \
	  $(VENV)/bin/checkov -d terraform/envs/$$e -o json --quiet \
	    > .scan/$$e.json 2>/dev/null || true; \
	  printf "\n=== %s ===\n" $$e; \
	  $(PY) scripts/ai_triage.py --input .scan/$$e.json \
	    --environment $$e --fail-on-blocking || rc=1; \
	done; exit $$rc

scan-insecure: ## Prove the gate blocks: scan the deliberately vulnerable tree
	@mkdir -p .scan
	@$(VENV)/bin/checkov -d terraform/insecure -o json --quiet > .scan/insecure.json 2>/dev/null || true
	@for e in $(ENVS); do \
	  printf "  %-6s " $$e; \
	  $(PY) scripts/ai_triage.py --input .scan/insecure.json --environment $$e \
	    --fail-on-blocking >/dev/null 2>.scan/err-$$e; \
	  printf "exit=%s  %s\n" $$? "$$(grep -o 'blocking=[0-9]*' .scan/err-$$e)"; \
	done
	@echo "  (non-zero exit is the expected, correct result here)"

secrets: ## gitleaks across the full history
	gitleaks detect --config .gitleaks.toml --redact -v

demo: ## The live demo: why deleting a secret does not remove it
	@./scripts/demo_secret_persistence.sh

all: fmt validate scan secrets ## Everything CI runs

clean: ## Remove local scan and terraform state
	rm -rf .scan checkov-report results.sarif triage-*.md
	find terraform -type d -name .terraform -exec rm -rf {} + 2>/dev/null || true
