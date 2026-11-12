# Single entry point for the monorepo. Run from the repo root.
.DEFAULT_GOAL := help
ENV ?= dev
REGION ?= europe-west1

.PHONY: help
help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

.PHONY: install
install: ## Install TS dependencies and Go modules
	cd ts && pnpm install
	cd go && go mod download

.PHONY: setup
setup: ## Start Postgres + MinIO, migrate, seed users (safe to re-run)
	docker compose up -d --wait
	cd go && go run ./cmd/migrate
	cd go && go run ./cmd/seed

.PHONY: agent-setup
agent-setup: ## Create/update the Managed Agent and write its ids to .env
	cd go && go run ./cmd/agent-setup

.PHONY: gen
gen: ## Generate Go and TS code from proto/
	cd proto && buf generate

.PHONY: dev
dev: ## Run API (:8787) and web (:5180) together
	@trap 'kill 0' INT TERM EXIT; \
	(cd go && go run ./cmd/api) & \
	(cd ts && pnpm dev) & \
	wait

.PHONY: lint
lint: ## Lint proto, Go, TS and Terraform
	cd proto && buf lint
	cd go && go vet ./...
	@test -z "$$(cd go && gofmt -l cmd internal)" || (echo "gofmt needed:"; cd go && gofmt -l cmd internal; exit 1)
	cd ts && pnpm typecheck
	terraform -chdir=terraform fmt -check -recursive
	bash -n tools/wt/wt.sh tools/wt/lib/*.sh tools/wt/hooks/* tools/wt/test_*.sh

.PHONY: breaking
breaking: ## Check proto/ for breaking changes against main
	cd proto && buf breaking --against '../.git#branch=main,subdir=proto'

.PHONY: test
test: ## Run Go and TS tests
	cd go && go test ./...
	cd ts && pnpm test

.PHONY: build
build: ## Build the API binary and the web bundle
	cd go && go build -o bin/api ./cmd/api
	cd ts && pnpm build

.PHONY: check-gen
check-gen: gen ## Fail if generated code is out of date (CI)
	git diff --exit-code -- go/gen ts/packages/api/src/gen

.PHONY: wt
wt: ## Worktree environments: make wt <cmd> <slug> (no --flags; use tools/wt/wt.sh for those)
	@./tools/wt/wt.sh $(filter-out $@,$(MAKECMDGOALS))

.PHONY: test-wt
test-wt: ## Run the wt tool's own test suites (slow; not part of make test)
	./tools/wt/test_slots.sh
	./tools/wt/test_resolve.sh
	./tools/wt/test_pr.sh
	./tools/wt/test_render.sh
	./tools/wt/test_env_args.sh
	./tools/wt/test_promote.sh

.PHONY: cloud-migrate
cloud-migrate: ## Run the Cloud Run migrate job for ENV and wait for it (before rolling the service)
	gcloud run jobs execute mr-$(ENV)-migrate --region $(REGION) --wait

.PHONY: tf-plan
tf-plan: ## terraform plan for ENV (default dev). Never apply from here.
	terraform -chdir=terraform/envs/$(ENV) init
	terraform -chdir=terraform/envs/$(ENV) plan

# `make wt up smoke` passes `up` and `smoke` as extra goals; this rule swallows them so make does not
# try to build them. Only applies when `wt` is the first goal.
ifeq (wt,$(firstword $(MAKECMDGOALS)))
%:
	@:
endif
