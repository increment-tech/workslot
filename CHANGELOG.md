# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

[0.1.0]: https://github.com/increment-tech/workslot/releases/tag/v0.1.0
