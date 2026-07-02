# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `WORKSLOT_PORT_RANGE="<from>-<to>"` — band the worktree dev port into a custom inclusive range
  instead of the default `4001..4999`. Set it per project or company folder (e.g. via direnv) so
  each folder's worktrees hash into their own slice — `10000-10999`, `20000-20999`, … — and pick a
  slice that avoids fixed service ports in the wider band (a Postgres on `15432` stays clear of
  `10000-10999`). The main checkout still stays on `4000` and an explicit `PORT` still wins; a
  malformed range fails fast with a clear message. Honored identically by the runtime `Workslot`
  module and the vendored `config/worktree.exs`.

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
