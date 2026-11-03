# Front door for local checks. Each target is one or two lines; logic longer than that lives in
# scripts/. CI calls the same targets, so local and CI results match.
# No apply/destroy targets on purpose: a human runs those at the checkpoint (NFR-9, ADR 0001 D8).
# Works with the GNU Make 3.81 that ships with macOS.

SHELL := /bin/bash
PYTHON ?= python3.13
GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo local)

FULL_SHA := $(shell git rev-parse HEAD 2>/dev/null || echo local)
IMAGE := $(shell scripts/names.sh image $(FULL_SHA))

.DEFAULT_GOAL := help
.PHONY: help up down test image smoke scan verify venv lint tf-check docs new-env set-prefix check

help: ## List targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

app/.env: ## Create app/.env from the example (fake key, local only)
	cp app/.env.example $@

up: app/.env ## Run the app locally on http://localhost:8080
	GIT_SHA=$(GIT_SHA) docker compose -f app/compose.yaml up --build

down: ## Stop the local app
	docker compose -f app/compose.yaml down

test: ## App unit tests
	cd app && $(PYTHON) -m unittest discover -s tests

image: ## Build the app image the way CI does (single platform, tests run inside)
	scripts/image/build.sh $(FULL_SHA) $(IMAGE)

smoke: ## Run the built image like Fargate and check it (run make image first)
	scripts/image/smoke.sh $(IMAGE) $(FULL_SHA)

scan: ## Scan the built image with trivy; fixable HIGH or CRITICAL fails (run make image first)
	scripts/image/scan.sh $(IMAGE) "$$(mktemp -d)"

verify: ## Build, smoke test and scan in one go (what app-ci runs)
	scripts/image/verify.sh $(FULL_SHA) "$$(mktemp -d)"

# Built once and reused; rebuilt when the hash-locked requirements change. lint needs it for the YAML trigger check.
# A stamp file, because the venv interpreter is a symlink that touch must not follow.
.venv-ci/.installed: scripts/ci/requirements.txt
	PYTHON=$(PYTHON) scripts/ci/venv.sh .venv-ci
	@touch $@

venv: .venv-ci/.installed ## Hash-locked CI venv (.venv-ci) for pre-commit and the YAML trigger check

lint: .venv-ci/.installed ## pre-commit hooks on all files, plus hadolint, shellcheck, actionlint, the prefix and env parity guards and the CI helper self-tests
	pre-commit run --all-files
	hadolint app/Dockerfile
	shellcheck -x $$(find scripts -name '*.sh' | sort)
	scripts/project.sh check
	scripts/guard/env-parity.sh
	scripts/ci/selftest.sh
	$(if $(wildcard .github/workflows/*.yml),actionlint,@echo "no workflows yet, skipping actionlint")

tf-check: ## Offline Terraform policy rules (tf/policy.sh), README check, fmt, validate and test (no AWS)
	scripts/tf/policy-selftest.sh
	scripts/tf/check.sh

docs: ## Regenerate terraform-docs tables in every Terraform README
	pre-commit run terraform_docs --all-files

# ENV must come from the command line: make imports the shell environment, and an exported ENV must not pick the name.
new-env: ## Clone an environment: make new-env ENV=qa [FROM=dev] [CIDR=10.N.0.0/16] [DRY_RUN=1]
	@$(if $(filter command line,$(origin STRATEGY)),echo "STRATEGY was removed by ADR 0008 amendment S" >&2; exit 2,:)
	@$(if $(filter command line,$(origin ENV)),:,echo "usage: make new-env ENV=<name> [FROM=dev] [CIDR=...] [DRY_RUN=1]" >&2; exit 2)
	scripts/tf/new-env.sh "$(ENV)" $(if $(FROM),--from "$(FROM)") $(if $(CIDR),--cidr "$(CIDR)") $(if $(DRY_RUN),--dry-run)

# Like ENV above, PREFIX must come from the command line.
set-prefix: ## Rename the project for a fork, before its first bootstrap: make set-prefix PREFIX=acme
	@$(if $(filter command line,$(origin PREFIX)),:,echo "usage: make set-prefix PREFIX=<2 to 10 lowercase letters or digits>" >&2; exit 2)
	scripts/project.sh set "$(PREFIX)"

check: lint test tf-check ## Everything a PR must pass
