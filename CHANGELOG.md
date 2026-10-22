# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-22

### Added

- **`mix workslot.clean`** — lists the dev/test databases that removed git worktrees left behind (every
  `MIX_TEST_PARTITION` copy included) and, with `--drop`, drops them after a prompt that defaults to no.
  It never judges ownership from a name:
  - the vendored `config/worktree.exs` now records every suffix it hands out, dev and test apart, under
    the repository's `.git/workslot/` — only while git's admin directory points back at that checkout,
    so a copied folder or a stale pointer records nothing;
  - a removed worktree's record claims a database only from its own kind's base on that base's server,
    only through a base `clean` had already seen when the worktree recorded (or seen it live), and
    never one that was already there when `clean` first saw the base (which it does only once the main
    checkout records) — so nothing from before `clean` first watched, and nothing under a base renamed,
    moved, or renamed away and back since, is claimed;
  - a moved, `git worktree lock`ed or detached worktree keeps its databases, as does one named the way
    workslot names one for a worktree git lists; one deleted by hand is *held* until
    `git worktree prune`; databases nothing claims (an older workslot's, hand-made copies, another
    clone's) are *unregistered* and dropped only by name; until the main checkout records, `--drop`
    drops only named databases.

  `--drop NAME...` drops exactly the named databases; `--yes` skips the prompt and requires the names.
  The list is printed before anything is dropped, each database is re-checked right before its `DROP`,
  and plain `DROP DATABASE` (never `WITH (FORCE)`) skips one in use. Every Repo's own database is
  protected. `--only dev|test` restricts it, and `--summary [--min-size SIZE]` prints one line for a
  coding agent, or nothing below the threshold (which only removed and held worktrees' databases count
  towards; names are escaped). Known limits (per-clone records, the instant before a `DROP`) are
  documented. Talks to Postgres through the app's own Postgrex, so workslot keeps zero runtime
  dependencies.
- `mix workslot.agents.install` now also vendors `.claude/hooks/workslot-clean.sh` and registers it as a
  Claude Code `SessionStart` hook (`startup` only) in `.claude/settings.json`, keeping every existing
  setting. Its line tells the agent to show the user the list and drop only what the user approves, by
  name. A settings file it cannot parse is reported with the entry to add by hand, never rewritten.
  `--no-hooks` skips it.
- `mix workslot.install` upgrades an unedited `config/worktree.exs` from an earlier release (compared as
  code, so a copy the app's formatter rewrote still counts) and reports an edited one instead.
- `Workslot.Registry` (the record's read side) and `Workslot.Clean.plan/4` (the pure planning behind the
  task).

- **`mix workslot.agents.install`** — opt-in, per-worktree **coding-agent** isolation layered on top of the
  core DB/port install (`mix workslot.install` stays unchanged and agent-agnostic). Two file patches
  (`--no-browser` / `--no-tidewave` to pick):
  - a per-worktree **agent-browser** profile in `mise.toml` `[env]` (keyed on `{{config_root | basename}}`),
    so parallel agents never share one Chrome profile;
  - a `workslot.agents` step added to the app's `mix setup` alias.
- **`mix workslot.agents`** — the runtime step the installer wires in: points this worktree's **Claude Code**
  and **Codex** at its own Tidewave dev MCP (`/tidewave/mcp` on the worktree's port). Claude uses `local`
  scope (per-project-path, private); Codex's config is global, so it registers only on the main checkout and
  prints the per-invocation `-c` override to use inside a worktree. Skips cleanly when a CLI/dep is absent.
- `Workslot.Install.patch_mise/1` — the pure, idempotent `mise.toml` transform behind the browser wiring.

### Fixed

- `mix workslot.install` isolated only the first Repo on the `<app>_dev` / `<app>_test` database; an app
  with several Repos (e.g. an events repo) left the rest on the shared database. Every match is patched
  now, and re-running the installer finishes an install that patched only the first.
- `Workslot.verify!/1` works on git older than 2.36 (no `worktree list -z`) instead of silently skipping
  its collision check, and git's error output no longer reaches the terminal at dev boot.
- `mix workslot` no longer mistakes a non-database `url:` (Redis, an API) for the Repo.
- Compiling workslot in an env where Jason is absent (an app with Igniter only in `:dev`) no longer warns.

- `mix workslot.install` aborted with `Code.LoadError … config/worktree.exs … enoent` on real apps: Igniter
  validates the patched config by **evaluating** it (which runs the newly-added `Code.require_file`) before
  the staged `config/worktree.exs` is flushed to disk. The installer now writes `config/worktree.exs`
  eagerly (idempotent; never clobbers) before the config patches, so validation resolves the require.

## [0.1.0] - 2026-06-23

### Added

- `Workslot` — deterministic, name-agnostic per-worktree derivation of the DB-name
  suffix, the test-DB suffix (composing with `MIX_TEST_PARTITION`), and a stable dev port.
- `mix workslot` — print the current checkout's dev/test database names and dev-server URL,
  read back from the evaluated config (app- and module-name-agnostic).
- `Workslot.verify!/1` — collision guard for `config/runtime.exs`. Raises when another
  live git worktree's folder name maps to the same database as this checkout, or when another
  live worktree hashes to the same dev port (naming the folders that clash). The port check is
  purely deterministic — it never probes a socket, so it never trips over this worktree's own
  running server. A no-op outside a linked worktree; degrades to `:ok` without `git`.
- `mix workslot.install` — Igniter installer that vendors a self-contained
  `config/worktree.exs`, patches `config/dev.exs` / `config/test.exs`, and wires
  `Workslot.verify!()` into `config/runtime.exs`, degrading any non-default config shape
  to a precise manual-edit notice.

### Behavior

- Isolation applies only to a *linked* git worktree (its `.git` is a `gitdir:` pointer file
  into `.git/worktrees/`). The main working tree, submodules, and plain non-git directories
  keep the bare database names and port 4000 — the safe default is "don't isolate."
- The dev/test database name is derived from the worktree folder name (readable, move-stable);
  the dev port is hashed from the full path (machine-global, so the path is the unique key).
- A folder name with no alphanumeric characters falls back to a short deterministic hash slug,
  rather than collapsing to an empty suffix.
- `dev_port/2` raises a clear error when `PORT` is set but is not an integer in `1..65535`.

[0.2.0]: https://github.com/increment-tech/workslot/releases/tag/v0.2.0
[0.1.0]: https://github.com/increment-tech/workslot/releases/tag/v0.1.0
