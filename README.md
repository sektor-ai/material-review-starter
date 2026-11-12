# Document Review

## The problem

Engineering teams review material submittals from contractors and check them against the project specification. Every item that does not comply is an issue that must be resolved before the material is approved and work proceeds.

We're building a system that combines an AI agent for reviewing material submittals with a shared table for managing its issues. The agent checks each submittal against the specification, identifies issues and adds them to the table, linking each issue to its submittal, its source document and the specification clause it breaks, and including a description, severity, status (open/close), and other metadata.

Several engineers may use the table at the same time to update issues. They should see each other's changes without refreshing.

We must maintain a clear record of who changed what.

## The specification: QCS 2014

**Submittals are checked against QCS 2014 (Qatar Construction Specifications).** It is the only specification. An issue is any place where a submittal does not meet a QCS 2014 clause, and every issue cites that clause (section, part, clause number).

For example, the S-001 mix design proposes a water/cementitious ratio of 0.55 for Grade C40 concrete. QCS 2014 Section 05 Part 06, Table 6.4 allows at most 0.50. That is one issue.

QCS 2014 is copyrighted, so it is not in this repo. Get your own copy and save it as `spec/QCS-2014.pdf`. Git ignores that folder's PDFs, so the copy stays on your machine.

The parts the sample submittals need are below. The page numbers are for the single 4,556-page PDF of the full QCS 2014. If your copy is split into one PDF per part, use the section and part names instead.

| Submittal                          | QCS 2014 part                                          | PDF pages |
|------------------------------------|--------------------------------------------------------|-----------|
| All                                | Section 01 Part 07 Submittals (7.11 Materials Approvals) | 29–47     |
| S-001 Concrete mix design          | Section 05 Part 02 Aggregates                          | 624–633   |
| S-001 Concrete mix design          | Section 05 Part 05 Admixtures                          | 644–648   |
| S-001 Concrete mix design          | Section 05 Part 06 Property Requirements               | 649–679   |
| S-001 Concrete mix design          | Section 05 Part 10 Curing                              | 719–724   |
| S-002 Fire-rated doors             | Section 18 Part 05 Joinery (5.3 Timber Door Types)     | 3549–3554 |
| S-002 Fire-rated doors             | Section 18 Part 07 Ironmongery                         | 3558–3564 |

The PDF's bookmarks list every section and part with its page range.

## Sample submittals

Each folder in `samples/` is one material submittal from the contractor. Each holds one document: the submittal itself, with the supplier's data. Each submittal states the requirements it was designed for (grade, exposure class, fire rating) in its "Design basis" line. Everything else comes from QCS 2014.

## Repository layout

One folder per language. See `CLAUDE.md` for the conventions in each.

| Folder       | What it holds                                                          |
|--------------|------------------------------------------------------------------------|
| `proto/`     | Protobuf API definitions (Connect RPC), the contract between Go and TS |
| `go/`        | Go backend: API server, migrations, seed and agent-setup commands      |
| `ts/`        | pnpm workspace: `apps/web` (React + Vite), `packages/api` (generated client) |
| `terraform/` | GCP infrastructure: Cloud Run, Artifact Registry, Secret Manager, GCS  |
| `samples/`   | Sample submittals                                                      |

## Prerequisites

- Go 1.27+
- Node.js 22+ and pnpm 9
- Docker
- [buf](https://buf.build/docs/installation) (only to regenerate code from `proto/`)
- Terraform 1.5+ (only for GCP)
- An Anthropic API key

## Quick start

```bash
make install
cp .env.example .env        # then set ANTHROPIC_API_KEY
make setup                  # starts Postgres + MinIO, runs migrations, seeds users
make agent-setup            # creates the agent + environment, writes their ids to .env
make dev                    # API on :8787, web on :5180
```

Open http://localhost:5180 and sign in:

| User  | Email             | Password    |
|-------|-------------------|-------------|
| Alice | alice@example.com | password123 |
| Bob   | bob@example.com   | password123 |

App tables are yours to design. Login tables live in the `auth` schema (`auth.users`, `auth.sessions`). Add a migration in `go/internal/store/migrations/`.

`make setup` is safe to re-run. If the database gets reset, run it again to restore Alice and Bob.

If you ran the earlier TypeScript version of this starter, its Better Auth tables (`auth.user`, `auth.session`, ...) are still in your Postgres volume. They are unused; `docker compose down -v` clears them.

## Parallel environments (`wt`)

`tools/wt` runs several branches side by side, each in its own git worktree with its own database,
bucket and ports, so they can be built and checked end to end at the same time:

```bash
source tools/wt/shellrc          # once, from your shell profile: gives you `wt`
wt doctor                        # check prerequisites (needs make setup and a .env)
wt create upload-form            # worktree ../material-review-starter-upload-form on feature/upload-form
wt up upload-form                # API on :8797, web on :5190 (slot 1)
wt list                          # every environment, its URLs and its PR
wt merge upload-form             # merge the PR, advance main, tear the environment down
wt install-hooks                 # optional: restart the API on commit, reap merged envs on pull
```

`tools/wt/CLAUDE.md` is the full reference.

## Make targets

| Target             | What it does                                              |
|--------------------|-----------------------------------------------------------|
| `make setup`       | `docker compose up`, then migrate and seed                |
| `make dev`         | Runs the API and the web app together                     |
| `make gen`         | Regenerates Go and TS code from `proto/`                  |
| `make lint`        | buf lint, go vet, gofmt, tsc, terraform fmt               |
| `make test`        | Go and TS tests                                           |
| `make agent-setup` | Creates or updates the agent and environment              |
| `make tf-plan`     | `terraform plan` for `ENV` (default `dev`)                |
| `make wt …`        | Worktree environments (flagless; use `tools/wt/wt.sh` for flags) |
| `make test-wt`     | The `wt` tool's own test suites                           |

## Ports

| Service        | URL                                                  |
|----------------|------------------------------------------------------|
| Web (Vite)     | http://localhost:5180 (proxies `/api` to the API)    |
| API (Go)       | http://localhost:8787 (`/healthz`, Connect under `/api`) |
| Postgres 16    | localhost:5433, user `postgres`, password `postgres` |
| MinIO (S3 API) | http://localhost:9000                                |
| MinIO console  | http://localhost:9001, `minioadmin` / `minioadmin`   |

## Agent

The agent runs on Claude Managed Agents: Anthropic hosts the agent loop and a sandbox per session. The backend calls it with the Go SDK (`github.com/anthropics/anthropic-sdk-go/v2`) under `client.Beta`, only from `go/internal/llm`.

1. **Ids.** `make agent-setup` (`go/cmd/agent-setup`) creates the agent and its environment once and writes `AGENT_ID` and `ENVIRONMENT_ID` to `.env`. Re-running it updates the same agent instead of creating a new one.
2. **Instructions.** The agent starts with a placeholder system prompt and the built-in toolset (read, write, bash and so on; web tools off). To change it, edit `llm.ReviewerAgent` / `toolset()` in `go/internal/llm/agent.go` and re-run `make agent-setup`. Each change creates a new agent version.
3. **Upload a file.** Upload `spec/QCS-2014.pdf` once with the Files API and reuse its file id in every session.
4. **Start a session.** `client.Beta.Sessions.New` with the agent id, `ENVIRONMENT_ID`, and file resources for the spec and the submittal (e.g. mount paths `/qcs-2014.pdf`, `/submittal.md`). Mounted files appear under `/mnt/session/uploads/`.
5. **Follow it.** Open `client.Beta.Sessions.Events.StreamEvents` first, then send the prompt with `client.Beta.Sessions.Events.Send` (a `user.message` event). The session is done when you get `session.status_idle` with a stop reason other than `requires_action`, or `session.status_terminated`.
6. **Get results back.** Pick one:
   - the text of the last `agent.message` event;
   - files the agent writes to `/mnt/session/outputs/`, listed through the Files API scoped to the session and downloaded by id. Output files can take a few seconds to appear after the session goes idle, so retry the list briefly;
   - a custom tool (`{ type: "custom", name, description, input_schema }` in the agent's tools): the agent emits `agent.custom_tool_use`, your code handles it and replies with `user.custom_tool_result`.

Every session also shows up in the Claude Console under Managed Agents → Sessions, with the full transcript.

Docs:
[Overview](https://platform.claude.com/docs/en/managed-agents/overview) ·
[Quickstart](https://platform.claude.com/docs/en/managed-agents/quickstart) ·
[Agent setup](https://platform.claude.com/docs/en/managed-agents/agent-setup) ·
[Sessions](https://platform.claude.com/docs/en/managed-agents/sessions) ·
[Events and streaming](https://platform.claude.com/docs/en/managed-agents/events-and-streaming) ·
[Files](https://platform.claude.com/docs/en/managed-agents/files) ·
[Tools](https://platform.claude.com/docs/en/managed-agents/tools)

## Deploying to GCP

`terraform/envs/dev` creates the Cloud Run service, its service account, an Artifact Registry repo, the documents bucket and empty Secret Manager secrets. It does not yet create Postgres (point the `database-url` secret at a Cloud SQL or other instance), the HTTPS load balancer that serves the web bundle and routes `/api` to Cloud Run, or the Cloud Run invoker binding.

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars   # fill in
terraform -chdir=terraform/envs/dev init -backend-config="bucket=<your-state-bucket>"
make tf-plan ENV=dev
```

Add secret values with `gcloud secrets versions add mr-dev-anthropic-api-key --data-file=-` (and the same for the others). The documents bucket is reached through GCS's S3 interoperability API, so the S3 secrets hold an HMAC key for the API's service account.

### Deploying a new image

Migrations run as a Cloud Run job (`mr-<env>-migrate`) from the same image, before the service moves to it:

```bash
# 1. build and push the image as $TAG (CI passes the git SHA)
# 2. point only the migrate job at the new image
terraform -chdir=terraform/envs/dev apply -var api_image_tag=$TAG -target=module.api.google_cloud_run_v2_job.migrate
# 3. run it and wait
make cloud-migrate ENV=dev
# 4. roll the service
terraform -chdir=terraform/envs/dev apply -var api_image_tag=$TAG
```

`/healthz` fails while the database is behind the build's migrations, and it is the service's startup probe, so a revision rolled out before step 3 never takes traffic: the previous revision keeps serving. Migrations must stay compatible with the revision that is still serving while they run.
