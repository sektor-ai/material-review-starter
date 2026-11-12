# CLAUDE.md

Material submittal review: an AI agent checks contractor submittals against QCS 2014 and records issues in a shared table. Go backend, React frontend, Protobuf (Connect) API between them, deployed to GCP with Terraform. The backend calls the Anthropic API (Claude Managed Agents). Product context is in README.md.

## Layout

Each top-level folder is one language or toolchain. Do not mix languages inside a folder.

```
proto/          Protobuf API definitions: the single source of truth for backend/frontend contracts
  buf.yaml, buf.gen.yaml
  <domain>/v1/*.proto
go/             Go module (backend), one go.mod
  cmd/api/        HTTP server
  cmd/migrate/    applies DB migrations
  cmd/seed/       creates the storage bucket and demo users (idempotent)
  cmd/agent-setup/  creates/updates the Managed Agent, writes ids to .env
  cmd/devenv/     creates/drops a wt environment's local database and bucket
  internal/
    config/       env-based config; loads the repo-root .env locally
    server/       Connect handlers: decode, call service, encode. No business logic.
    service/      business logic
    store/        Postgres (pgx) + embedded goose migrations in store/migrations/
    storage/      S3-compatible object storage (MinIO locally, GCS interop on GCP)
    llm/          the only package that imports the Anthropic SDK
  gen/            generated from proto/. Do not edit.
  Dockerfile
ts/             pnpm workspace (frontend)
  apps/web/       React + Vite
  packages/api/   generated TS from proto/ (src/gen/, do not edit) re-exported as @app/api
terraform/
  modules/        reusable modules (api = Cloud Run service + SA + secret access)
  envs/dev/       one root module per environment, state in GCS
tools/wt/       bash: per-branch worktree environments (see tools/wt/CLAUDE.md)
samples/        sample submittals (input data, not code)
spec/           QCS 2014 PDF, local only (gitignored, copyrighted)
docker-compose.yml  local Postgres + MinIO
```

## Commands

Run from the repo root through `make` (`make help` lists everything):

```
make install      # pnpm install + go mod download
make setup        # docker compose up, migrate, seed (safe to re-run)
make agent-setup  # create/update the Managed Agent
make dev          # API on :8787, web on :5180 (Vite proxies /api to the API)
make gen          # buf generate: proto/ -> go/gen and ts/packages/api/src/gen
make lint         # buf lint, go vet, gofmt, tsc, terraform fmt
make test         # go test ./... and vitest
make breaking     # buf breaking against main
make tf-plan ENV=dev
make wt <cmd> <slug>   # worktree environments; tools/wt/wt.sh for anything with a --flag
make test-wt      # the wt tool's own test suites
```

Before finishing a change, run `make lint test`. If proto/ changed, run `make gen` and `make breaking` too.

## Behaviour: worktree-first development

Every task that changes repository files starts in an isolated `wt` environment by default — create
it BEFORE creating or editing any file, without being asked. The primary checkout is where the human's
IDE and dev server live; keep it clean. Exceptions only: the human opts out; the task is read-only
(investigation, Q&A, review); it touches no repository files; or `wt` itself is broken so that it
cannot create a worktree, in which case fixing `tools/wt` in the primary is allowed (say so). "It's
small" or "it's just docs" are not exceptions. When unsure, create the worktree.

1. `tools/wt/wt.sh create <slug> --type <type>` — kebab-case slug; branch `<type>/<slug>`
   (`type` ∈ feature|bugfix|refactor|docs|chore|test|perf, default feature). Use `tools/wt/wt.sh`, not
   `make wt`, for anything with a `--flag`.
2. Tell the human the slug and worktree path right after creation.
3. This is LOCAL ONLY: no push, no PR. A PR happens later, explicitly, via `/mk-pr` from the worktree.
4. Work in the worktree (`<primary>-<slug>/`), stand it up with `tools/wt/wt.sh up <slug>`, iterate
   there. Abandon with `tools/wt/wt.sh rm <slug>`; a merged PR's environment goes with
   `tools/wt/wt.sh merge <slug>` (or `wt gc` / the post-merge hook).
5. Keep the branch current with `tools/wt/wt.sh rebase <slug>` before opening the PR and when resuming
   a worktree that has sat. A rebase conflict exits non-zero (code 3) with nothing pushed — do NOT
   carry on; ask the human whether to leave it un-rebased or resolve by hand.

Your shell and file tools default to the primary checkout, so target the worktree explicitly: absolute
paths under `<primary>-<slug>/` for Read/Write/Edit/Grep/Glob, and run `git`, `go test`, `pnpm` there
(`cd`, or `git -C`). Only `wt` commands are location-agnostic. If `wt create` fails, run
`tools/wt/wt.sh doctor` and report — do not fall back to editing the primary checkout.

## Behaviour: verify changes in the running system

A change is done when you have seen it work, not when it compiles. Stand the environment up
(`tools/wt/wt.sh up <slug>`), get URLs with `tools/wt/wt.sh url <slug> web|api` (never compute
ports by hand), and drive the changed flow: in the browser for UI, over the API for backend changes.
Report what you observed, not "this should work". If a change has no runtime surface (a refactor
covered by tests, a build tweak), say so rather than inventing a verification.

Each environment is seeded with the demo users (`alice@example.com` / `bob@example.com`, password
`password123`). Do not type passwords into a browser login form. Authenticate over the API instead
(`POST {web}/api/auth.v1.AuthService/SignIn` with a cookie jar), and for browser checks behind login,
stop and ask the human to sign in. Data in an environment is throwaway: `wt reset-db <slug>` restores
a clean seed, and teardown drops it.

## API contract (proto/)

- Connect RPC: `connectrpc.com/connect` (v1) in Go, `@connectrpc/connect` + `connect-web` in TS. It works from the browser over plain HTTP, so no gRPC-Web proxy.
- Connect services are mounted under `/api` (e.g. `POST /api/auth.v1.AuthService/SignIn`). `/healthz` is plain HTTP.
- Packages are versioned: `proto/<domain>/v1/*.proto`, package `<domain>.v1`.
- Change the contract in proto/ first, then `make gen`, then implement. Never hand-write Go or TS types that duplicate a proto message.
- Generated code is committed; `make check-gen` fails if it is stale.
- buf plugins are pinned in buf.gen.yaml. The Connect Go plugin stays on v1.x to match `connectrpc.com/connect` v1. Moving to connect-go v2 is a deliberate migration, not a version bump.
- No breaking changes to a published `v1` service: add fields; never renumber or reuse field numbers; `reserved` removed ones.

## Go backend (go/)

- Wrap errors with `fmt.Errorf("doing x: %w", err)`. Map to Connect codes only in `internal/server`; internal errors are logged and returned as a generic `CodeInternal`.
- Pass `context.Context` first through every layer.
- Log with `log/slog` (JSON on Cloud Run). Never log request bodies, prompts with user data, passwords, or tokens.
- Config comes only from environment variables. Locally `config.Load` reads the repo-root `.env` without overriding already-set vars.
- Schema changes: add a new numbered file in `internal/store/migrations/` (goose format). Never edit an applied migration.
- Tests: table-driven, next to the code. Services depend on small interfaces (e.g. `service.UserStore`) so tests use fakes. Tests never call the real Anthropic API.

### Auth

Email/password with bcrypt. Sessions are random tokens in an HttpOnly `session` cookie, and only their SHA-256 is stored (`auth.sessions`). `COOKIE_SECURE=true` behind HTTPS. Demo users come from `cmd/seed`.

## Anthropic API

- Only the backend calls Anthropic. The API key never reaches the browser, and the frontend never imports an Anthropic SDK.
- Go SDK: `github.com/anthropics/anthropic-sdk-go/v2`, used only in `internal/llm`.
- The agent runs on Claude Managed Agents (`client.Beta.Agents/Environments/Sessions`). Agents are persistent: create them in `cmd/agent-setup`, never in the request path; the API uses `AGENT_ID` / `ENVIRONMENT_ID` from config.
- Agent definition (name, model, system prompt, tools) lives in `llm.ReviewerAgent`. Change it there and re-run `make agent-setup`.
  Run it from the primary checkout: the ids are shared by every checkout and live in the primary's
  `.env` (it refuses under `ENV_FILE`); `wt recreate-config <slug>` passes them on to an environment.
- Default model `claude-opus-5-5` (`llm.DefaultModel`, overridable with `ANTHROPIC_MODEL`). Don't hardcode model IDs elsewhere or add date suffixes.
- For direct Messages API calls: use adaptive thinking and `output_config.effort` (`budget_tokens` and disabled thinking are rejected on current models); stream long requests; check `stop_reason` (`max_tokens`, `tool_use`, `refusal`) before reading content; keep system prompt and tools stable and first for prompt caching; handle SDK errors by type, not by message text.
- Don't guess SDK names. Check the SDK source or docs, and let the compiler confirm.

## TypeScript frontend (ts/)

- pnpm workspace; Node version in `ts/.nvmrc`. Strict TS; no `any` without a comment saying why.
- Import API types and service descriptors from `@app/api` only.
- Server state goes through TanStack Query hooks wrapping the Connect client (see `src/session.ts`). Components don't call the client directly.
- Tests: vitest next to the component.
- Dev mock: `src/mock/` serves every Connect service from an in-browser store, for UI work ahead of the
  backend. Turn it on with `?mock=1` (off with `?mock=0`; remembered per browser) or `VITE_MOCK_API=1`;
  `&as=bob` signs that tab in as Bob, and tabs share state live. Dev only, never in a production build.

## Terraform (terraform/)

- Cloud Run (API), Artifact Registry (images), Secret Manager (`ANTHROPIC_API_KEY`, `DATABASE_URL`, S3 HMAC keys), and a GCS documents bucket reached through the S3 interop endpoint.
- Terraform creates secret containers only. Values are added with `gcloud secrets versions add`, never through tfvars or state.
- State lives in a GCS bucket (`-backend-config="bucket=..."`), one prefix per env.
- CI authenticates with Workload Identity Federation. No service account keys anywhere.
- Never run `terraform apply`. Run `make tf-plan` and show the output; a person applies.
- Every resource gets `labels` with `app` and `env`.

## Rules

- Never commit `.env`, credentials, keys, or `spec/*.pdf`.
- Ask before adding a top-level folder or a new language. (`tools/` holds repo tooling, starting with
  `tools/wt`.)
- Keep this file current when a command, folder, or convention changes.
