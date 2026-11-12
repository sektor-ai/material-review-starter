# Worktree Environments (tools/wt)

`wt` manages per-branch local development environments. One environment is a cohesive unit of a git
worktree, its own Postgres database and MinIO bucket, a local Go API and a local Vite dev server —
created together, updated on commit, listed, and destroyed together when the branch's pull request
merges.

It exists so several branches (and several agent sessions) can be built and verified end to end at
the same time, without fighting over one checkout, one set of ports and one database.

Adapted from the `wt` tool in the Hamlet project; behaviour that differs here is described below,
not in terms of the original.

## Commands

```
wt create <slug> [--type T] [--from R]  worktree + database + config, deps + API build, migrate + seed
wt create <slug> --adopt <branch>  same, but on an existing local branch instead of a new one
wt up <slug>                      start api and web (detached); waits until the API serves, and
                                  exits non-zero if it crashes, times out or is unhealthy
wt down <slug>                    stop them
wt restart <slug> [process]       restart one process (default: api)
wt rebase <slug>...               rebase each branch onto origin/main, force-push, restart API
wt list|ls [--refresh]            every environment, its URLs and its PR (state, number, link)
wt url <slug> [service]           print service URLs (api|web); bare URL if service given
wt path [slug]                    print a worktree's directory; the primary checkout if no slug
wt cd [slug]                      cd there — shell function only (see below)
wt logs <slug> [process]          follow a process log
wt rm <slug> [--force]            stop, drop database and bucket, remove worktree and branch;
                                  without --force, refuses uncommitted/untracked files or unpushed commits
wt merge <slug>                   merge the PR (or accept one already merged from the web), prune the
  [--no-advance] [--keep-branch]  remote branch, advance main, reap the env, delete the local branch
wt promote <slug>                 hand the branch to the primary checkout, to carry the work on by
                                  hand in the editor; the environment behind it is kept
wt demote [slug]                  the return leg: take the branch back and rebuild its worktree.
                                  Bare, it acts on whatever branch the primary is on, adopting one
                                  that has no environment yet
wt resume <slug>                  restart the agent session that last worked on the environment
wt recreate-config <slug>         re-render app.env + process-compose.yml (after a template/.env change)
wt reset-db <slug>                drop and recreate the database and bucket, migrate and seed —
                                  discards the environment's data; waits until the API serves again
wt gc [--dry-run]                 rm environments whose PR merged/closed (keeps ones with edits)
wt doctor                         check prerequisites
wt install-hooks                  install post-commit + post-merge hooks (chaining any existing ones)
wt uninstall-hooks                remove them, restoring the hooks they displaced
```

Every `<slug>` above also takes the environment's **branch** — `wt up feature/foo` and `wt up foo` name
the same environment. `wt create` is the exception: its argument names an environment that does not
exist yet. `resolve_env` (lib/common.sh) is the single guard that does this; a slug match is tried
before a branch match (`test_resolve.sh` pins that precedence).

Three ways to invoke, in order of preference:
- **`wt <args>`** — the shell function. `source tools/wt/shellrc` from your profile once. It is also the
  only way to run `wt cd`.
- **`tools/wt/wt.sh <args>`** — the script directly. Use this in scripts and agent shells (which won't
  have the function). Everything works except `wt cd`; use `cd "$(tools/wt/wt.sh path <slug>)"`.
- **`make wt <args>`** — the repo-root shortcut, but it **cannot forward `--flags`** (make parses them
  itself). Only for flagless invocations like `make wt up <slug>`.

The worktree branch is `<type>/<slug>`, following the `/mk-pr` naming convention. `--type` defaults to
`feature`; pass `--type bugfix|refactor|docs|chore|test|perf` for other work. The slug names the
worktree directory (`<primary>-<slug>`), the database (`<db>_wt_<slug>`) and the bucket
(`<bucket>-wt-<slug>`).

### Adopting an existing branch

`--adopt <branch>` builds the environment on an existing local branch, taken verbatim. `--type` and
`--from` are rejected alongside it. The branch must exist locally (one only on `origin` is refused —
check it out first) and must not be checked out anywhere, the primary included. Without `--adopt`, an
existing branch name is a hard error, so a routine `wt create` cannot land on someone else's work.

## Agent workflow

`wt create <slug>` → edit, `git`, `go test` **inside** `<primary>-<slug>/` (the `wt` commands dispatch
by slug from anywhere; everything else needs the worktree path) → `wt up <slug>` →
`wt url <slug> web|api` → verify the flow in the browser or over the API → `/mk-pr` from the worktree
branch → `wt merge <slug>` (or `wt gc` reaps it after a merge elsewhere). The behavioural rules live in
the repo-root `CLAUDE.md`; this file is the tooling reference.

`wt merge` does what clicking "Merge" on GitHub plus a `gc` would: `gh pr merge` (squash by default),
fetch with `--prune` (deleting the remote branch if GitHub did not), fast-forward local `main` (skipped
with a warning when `main` is checked out somewhere dirty; `--no-advance` skips it), reap the
environment, delete the local branch (`--keep-branch` keeps it). A promoted environment's branch is in
the primary, so merge switches the primary to `main` before deleting it.

**`rebase` is the only command that takes a list; every other command takes at most one environment.**
The habitual line after something lands names every environment (`wt rebase a b c`); typed with
`merge` instead, a parser that kept the last positional would merge a pull request nobody chose.
`require_one_env` refuses a second environment — called directly by the commands with their own
flags (`merge`, `rm`, `reset-db`, `promote`, `demote`, `resume`; `create` has its own copy), and
through `take_args` by the rest (`up`, `down`, `recreate-config`, `path`, and `restart`/`logs`/`url`,
whose second argument is a process or service). A missing environment is a usage error.
`test_env_args.sh` pins all of it. The guard counts positionals (so `wt merge '' x` cannot slip
through) and is never called through `$( )`, because `die` there only exits the subshell.

Keep branches current with `wt rebase <slug>`: fetch, rebase onto `origin/main`, `--force-with-lease`
push (only if the branch is on origin), restart the API. A no-op when already current. A **conflict is
not a no-op**: it aborts to a clean state, pushes nothing, and exits `3` (`WT_EXIT_REBASE_CONFLICT`).
Escalate to the human — leave the branch un-rebased for now, or rebase by hand. With several slugs,
all are validated first and a conflict stops the run there.

`wt rebase` brings the *code* current; `wt reset-db <slug>` brings the *data* back to a clean slate:
drop the database and bucket, create fresh ones, run the worktree's migrations and seed, and wait for
the API to serve again. Run it after a rebase that brought in migrations rewritten on the branch, or
when test data has piled up. It discards everything in that environment's database and bucket without
prompting; that is the point.

## The promote cycle

The human's IDE watches the primary checkout, so work that needs hands-on attention has to come back
there. `wt promote <slug>` checks the branch out in the primary; `wt demote` takes it back and rebuilds
its worktree. A **cycle, not a one-way door**: only the worktree directory changes hands (git allows a
branch in one worktree at a time). Slot, ports, database, bucket, rendered config and binaries all
survive, so demote is a `git worktree add` plus a dependency install.

```
wt promote upload-form   # worktree -> primary; edit in the IDE
wt demote                # primary -> worktree; same ports, same data
```

Bare `demote` acts on whatever the primary holds (reading the *primary's* branch, wherever it is run
from), refuses `main`/`master` and a dirty primary, and when the branch has **no environment** falls
through to `wt create --adopt` (slug = last path component of the branch). Everything checkable is
checked before the primary is moved.

While promoted: `up`, `restart`, `reset-db` and `recreate-config` refuse (no directory); `rebase`
works against the primary; `rm` and `gc` drop the data and the record but **leave the branch** (it is
checked out where the human is working); a second `promote` refuses while the primary still holds the
first. `promote` refuses if the worktree has *anything* uncommitted, untracked files included, or the
primary has tracked changes — and has no `--force`, since that would exist only to destroy work.

## Recovering the agent session

Every environment records the Claude Code session that last touched it (from
`~/.claude/sessions/$CLAUDE_PID.json`, falling back to `CLAUDE_CODE_SESSION_ID`), latest touch wins,
via `resolve_env` — so every command records it by construction. `wt list` shows the name; `wt resume
<slug>` execs `claude --resume <id>` from the recorded cwd. Inside a Claude session it refuses to nest
and prints the command instead.

## Prerequisites

`git`, `jq`, `envsubst`, `gh` (authenticated), `process-compose`, `pnpm`, `go`, `curl`, `nc`, and the
docker-compose Postgres and MinIO running (`make setup`). The primary checkout's `.env` must exist —
every environment's settings are derived from it. Run `wt doctor`.

Optional settings in `~/.material-review/wt.env` (see `wt.env.example`): `WT_BASE_REF`, `MR_WT_HOME`,
`MR_WT_SOURCE_ENV`. `MR_WT_HOME` set in the environment beats the one in `wt.env`, so a test aimed at a
throwaway state directory cannot land on the real environments.

Bash 3.2 compatible: macOS ships that, so no `mapfile`, `${var@Q}` or associative arrays.

## Ports — deterministic by slot

Slot 0 is the primary checkout (`make dev`). Worktrees take the lowest free slot in 1..9, reclaimed on
`wt rm`. Postgres (5433) and MinIO (9000) are shared; isolation is per database and per bucket.

| Service | Formula | Slot 1 | Slot 2 |
|---|---|---|---|
| API (`PORT`) | `8787 + slot*10` | 8797 | 8807 |
| Web (`WEB_PORT`) | `5180 + slot*10` | 5190 | 5200 |

Slots, not hashes: hashing collides and gives unstable ports across renames.

## State

Generated artefacts live outside the worktree, so nothing can be committed by accident:

```
~/.material-review/worktrees/
  .slot.lock/           the slot mutex, held only while a create allocates (owner: the creating pid)
  .slots/<slot>         a slot reserved by a create still building its environment (pid + slug)
  <slug>/
    env.json            slug, path, branch, slot, ports, database + bucket names, cached PR
                        state/number/URL, status (worktree|promoted) + promoted.primary_prev_branch,
                        and the last agent session {id, name, cwd, seen_at}
    app.env             the primary's .env rewritten for this environment, mode 600 — the only on-disk
                        copy of its DSN
    process-compose.yml
    pc.sock             process-compose Unix socket
    bin/{api,migrate}   the compiled binaries
    logs/{api,web,process-compose}.log
```

## Design notes

- **Slot allocation is locked, and the slot is reserved before the environment exists.** Two
  concurrent `wt create`s would otherwise both scan an unwritten state and take the same slot. A
  create allocates under a `mkdir` mutex (atomic on POSIX; macOS bash 3.2 has no `flock`) and drops a
  reservation file the scan also counts. Both record the owning pid, so a create killed hard leaves
  neither a wedged lock nor a burnt slot. `test_slots.sh` covers this, including concurrent creates.
- **Each environment's data is its own.** `go/cmd/devenv` creates `<db>_wt_<slug>` in the local
  Postgres and computes the bucket name; `cmd/seed` creates the bucket and demo users. `devenv`
  refuses any non-local `DATABASE_URL` or `S3_ENDPOINT`: it drops databases, and must never be able to
  reach a real one. Teardown (`rm`, `merge`, `gc`) never fails on a stopped Postgres — it warns and
  carries on, since `gc` runs unattended — while `reset-db` treats a failed drop as fatal, because
  carrying on would "reset" onto the old data.
- **Migrations run on every API start.** The api process is `go build` → `bin/migrate` → `exec bin/api`,
  so the post-commit restart applies a migration the commit added. The binaries are built and
  `exec`'d rather than `go run`, which does not forward SIGTERM and would orphan a server on the port.
- **Every Go command finds its settings through `ENV_FILE`.** `internal/config` reads `ENV_FILE` when
  set — and its values then override anything exported in the shell, so a stray `DATABASE_URL` cannot
  send an environment to the primary's database — else walks up for `.env` (which never overrides). A worktree has no `.env` of its own (it is gitignored), so the
  process-compose file, `resources_seed` and `devenv` all pass `ENV_FILE` explicitly. `app.env` is
  *copied* from the primary and rewritten (DATABASE_URL, S3_BUCKET, PORT, COOKIE_SECURE) rather than
  templated, so the API key it carries is never duplicated into a tracked file. The rewrite matches
  every line shape the loader accepts (`KEY=`, `KEY = `, `export KEY=`), and `render_env` then checks
  that every definition of DATABASE_URL and S3_BUCKET carries the environment's own value, refusing to
  render otherwise (`test_render.sh`).
- **`wt up` fails fast on a boot crash, and confirms the API actually serves.** It watches the api
  process (a crash surfaces its log tail in seconds) and, once the port opens, expects a 2xx from
  `/healthz` — which pings the database, so "up" means serving against its own DB. A crash, timeout
  or unhealthy API exits non-zero (processes are left running to inspect); `reset-db` likewise.
- **`process-compose` is always driven over a Unix socket, by relative path.** Its default is a TCP
  server on 8080. The socket is named relative to the state directory (process-compose runs from
  there) because macOS caps socket paths at 104 bytes; an absolute path under a long home or
  `MR_WT_HOME` fails with `bind: invalid argument`.
- **`--disable-dotenv`** is passed to `process-compose up`, so it never loads a stray `.env`.
- **`wt create` does the slow setup in parallel.** `pnpm install` and the API build run concurrently,
  so `wt up` starts from a warm cache and ready binaries.
- **Hooks go where git runs them from** — `git rev-parse --git-path hooks`, which honours
  `core.hooksPath` and is otherwise the common `.git/hooks` every worktree shares — so one symlink per
  hook serves every environment. A `core.hooksPath` outside the repository (a global hooks directory)
  is refused rather than written to. `post-commit` restarts the committing worktree's API (rebuild + migrate); `post-merge`
  runs `wt gc`. An existing hook of either name is moved to `<hook>.pre-wt` and chain-called first.
  `hook_is_ours` compares by inode (`-ef`), so it recognises the hook via a symlinked path.
- **`wt gc` is safe to run unattended.** It reaps environments whose PR merged or closed, but keeps
  (and flags) any worktree with uncommitted changes or untracked files.
- **Nothing destructive loses work that exists nowhere else.** `rm`, `gc` and `merge` check
  `git status --porcelain` (untracked files included, ignored ones not), the same check `promote`
  uses. `rm` without `--force` also refuses while the branch has commits on no remote branch, since
  its `branch -D` (needed because squash-merged branches never look merged) would drop them. The
  `rm -rf` fallback in `worktree_remove` runs only under `--force`.
- **An environment's PR is pinned by number.** `gc` and `merge` act on PR state, and branch names get
  reused. The first time a PR is seen its number is recorded and followed from then on; before that,
  a non-open PR created before the environment is ignored as belonging to an earlier use of the name
  (an open one is always current, so `--adopt` of a branch with a PR works). `test_pr.sh` pins this.
- **`promote` marks the record before checking out, and records what the primary was on**, so a failed
  checkout still leaves `demote` able to rebuild, and `demote` returns the primary to where it was
  (detaching HEAD rather than guessing when nothing usable was recorded).
- **`wt list` renders differently to a terminal than to a pipe**: OSC 8 hyperlinks behind short labels
  on a tty, verbatim `name=url` text when piped (so `wt list | grep github.com` works). Long session
  names are elided with ASCII dots on a tty only, since `printf` pads by bytes.
- **`wt cd` lives in `shellrc`**, because only a shell can change its own directory.

## Files

`make test-wt` runs all six test scripts; each also runs standalone. They are kept out of `make test`
(`test_promote.sh` drives real `git worktree` operations). Nothing runs them automatically: there is no
CI yet.

- `wt.sh` — dispatcher and all commands except `wt cd`
- `shellrc` — the `wt` shell function: forwards to `wt.sh`, and implements `wt cd` itself
- `test_slots.sh` — slot allocation and state-root resolution (throwaway `MR_WT_HOME`; no services)
- `test_resolve.sh` — slug-vs-branch resolution and misses (throwaway `MR_WT_HOME`)
- `test_promote.sh` — the promote/demote cycle, its guards, bare demote and its adopt fallback, the
  `rm`/`promote` branch contract, that adopt renders `app.env` onto the environment's own database,
  and that `rm`/`gc` keep untracked files and unpushed commits. Throwaway repo + bare `origin`; `pnpm`, `go` (including `go run ./cmd/devenv`),
  `process-compose` and `gh` are stubbed on `PATH`, so no database is touched
- `test_env_args.sh` — the one-environment guard across every command that carries it
- `test_pr.sh` — PR identity: stale PRs from a reused branch name are ignored, the number is pinned
  once seen, adopted branches keep their open PR (`gh` stubbed)
- `test_render.sh` — `app.env` rewriting across dotenv line shapes, and the check that backs it up
- `lib/common.sh` — constants, logging, repo layout, validation
- `lib/state.sh` — slot allocation and its lock, `env.json`, cached PR record, session recording
- `lib/resources.sh` — `go/cmd/devenv` wrapper: database/bucket create, drop, migrate + seed
- `lib/render.sh` — `app.env` rendering and the process-compose template
- `templates/process-compose.yml.tpl`
- `hooks/post-commit` — restarts the committing worktree's API in the background, via the internal
  `wt on-commit <worktree-root>` verb
- `hooks/post-merge` — runs `wt gc` in the background after a merge/pull
- `go/cmd/devenv` (outside this folder) — the Go side of `lib/resources.sh`
