# Workslot

**Two coding agents on the same app share one database by default — and the moment one
migrates, reseeds, or resets it, the other's data is corrupted underneath it, mid-task.**

The cruel part: the second agent never sees "another process changed my database." It sees tests
failing for no reason, or rows that don't match what it just wrote — and it burns tokens chasing a
bug that was never in its code. Two agents running `mix test` against the same `my_app_test` do
the same dance, each blaming itself (Ecto's sandbox isolates tests *within* one run, not across
two). And both want port 4000, so the second server won't even boot.

Workslot gives every git worktree its own dev and test databases and its own port, derived
automatically from the worktree itself — no manifest, no `.local.exs`, no port bookkeeping. Your
main checkout stays exactly as it is. Run as many agents as you like, each in its own worktree;
they never touch each other's state.

Built for Phoenix — the installer speaks `phx.new`'s config shapes — but the core is plain
Elixir/Mix with zero framework dependencies.

## One worktree per agent

With Claude Code, one flag spins up the worktree and drops you into it:

```bash
claude -w feature-1   # creates the `feature-1` worktree, session starts inside it
claude -w feature-2   # a second agent, its own worktree
```

Because Workslot is installed, each worktree already has its own dev/test databases and its own
port — so both agents can migrate, reseed, `mix ecto.reset`, run the suite, and boot a server at
the same time without touching each other's state. Run `mix workslot` in any of them to see where
it lives.

## Quick start

```bash
mix igniter.install workslot                       # one time — wires your config
git worktree add ../my-app-feature-x -b feature-x  # or: claude -w feature-x
cd ../my-app-feature-x
mix setup && mix phx.server                         # deps + create/migrate/seed + assets, then boot
# → boots on its own port, with its own database.
```

**Working with agents?** Drop this into your `CLAUDE.md` (or `AGENTS.md`) so an agent in a
worktree doesn't reach for `my_app_dev` or `localhost:4000` and trip:

> This app uses Workslot. Inside a git worktree the dev/test database names and the dev port
> are derived from the worktree — run `mix workslot` to see them.

## How it works

Isolation kicks in **only inside a linked git worktree** — one added with `git worktree add`,
whose `.git` is a *file* pointing into the shared repo's `.git/worktrees/`. The main working
tree (`.git` is a directory), submodules (`.git` points into `.git/modules/`), and plain
non-git folders are all left alone with the bare names and port 4000. Detection is name- and
location-agnostic, and the safe default is *don't isolate*.

| | Main checkout | Worktree `my-app-feature-x` |
|---|---|---|
| Dev DB | `my_app_dev` | `my_app_dev_my_app_feature_x` |
| Test DB | `my_app_test<PARTITION>` | `my_app_test_my_app_feature_x<PARTITION>` |
| Dev port | `4000` | stable `4001..4999` hashed from the path |

The test-DB suffix composes with `MIX_TEST_PARTITION`, so CI partitioning still works inside
any single checkout. `PORT` always wins for the dev port when set.

The **database name** comes from the worktree's folder name — readable, survives moving the
folder, and naturally separated across apps by the app prefix. The **dev port** is hashed from
the full path instead, because a port is a machine-global resource with no app namespacing, so
the path is the only thing guaranteed unique. The consequence: two worktrees with the *same
folder name* (in different directories) would derive the same database — see
[Collision detection](#collision-detection).

## Install

Add the dependency to `mix.exs` — from Hex, or straight from GitHub if you'd rather not pull it
from Hex:

```elixir
# from Hex
{:workslot, "~> 0.1", only: [:dev, :test], runtime: false}

# or from GitHub (pin a tag; no Hex required)
{:workslot, github: "increment-tech/workslot", tag: "v0.1.0", only: [:dev, :test], runtime: false}
```

### Automatic (Igniter)

If you have [Igniter](https://hex.pm/packages/igniter), it adds the dependency *and* wires the
config in one step:

```bash
# from Hex
mix igniter.install workslot

# or from GitHub
mix igniter.install workslot@github:increment-tech/workslot
```

That vendors a self-contained `config/worktree.exs`, patches `config/dev.exs` /
`config/test.exs`, and wires the collision guard into `config/runtime.exs` for you. Any
non-default config shape is reported as a precise manual step rather than guessed at.

### Manual

1. Create **`config/worktree.exs`** with the contents below. It defines a small
   `Workslot.Worktree` module and is intentionally dependency-free — build config loads it
   before deps are compiled. (`mix workslot.install` generates this same file for you.)

   <details><summary><code>config/worktree.exs</code></summary>

   ```elixir
   # Self-contained ON PURPOSE: build config (config/dev.exs, config/test.exs) loads this via
   # Code.require_file/2, which can run BEFORE deps are compiled on a fresh clone — so it must
   # not depend on the workslot package. Safe to edit.
   defmodule Workslot.Worktree do
     @moduledoc false

     def slug(root \\ File.cwd!()) do
       if worktree?(root) do
         cleaned =
           root
           |> Path.basename()
           |> String.downcase()
           |> String.replace(~r/[^a-z0-9]+/, "_")
           |> String.trim("_")

         if cleaned == "", do: "wt" <> hash36(root), else: cleaned
       end
     end

     def suffix(root \\ File.cwd!()) do
       case slug(root) do
         nil -> ""
         slug -> "_" <> slug
       end
     end

     def test_suffix(root \\ File.cwd!()) do
       suffix(root) <> (System.get_env("MIX_TEST_PARTITION") || "")
     end

     def dev_port(root \\ File.cwd!(), default \\ 4000) do
       cond do
         port = System.get_env("PORT") -> parse_port!(port)
         slug(root) -> 4001 + :erlang.phash2(root, 999)
         true -> default
       end
     end

     # A linked worktree's gitdir is `<common>/worktrees/<id>`; a submodule's is
     # `<super>/modules/<name>`. Require the worktrees segment and reject any modules path.
     defp worktree?(root) do
       case File.read(Path.join(root, ".git")) do
         {:ok, "gitdir: " <> target} ->
           target = String.trim(target)
           String.contains?(target, "/worktrees/") and not String.contains?(target, "/modules/")

         _ ->
           false
       end
     end

     defp hash36(root) do
       :erlang.phash2(root) |> Integer.to_string(36) |> String.downcase()
     end

     defp parse_port!(value) do
       case Integer.parse(value) do
         {port, ""} when port in 1..65535 ->
           port

         _ ->
           raise "workslot: PORT=#{inspect(value)} must be an integer in 1..65535. " <>
                   "Unset it, or set PORT to a valid port (e.g. PORT=4500)."
       end
     end
   end
   ```

   </details>

2. In **`config/dev.exs`**, just under `import Config`:

   ```elixir
   Code.require_file("worktree.exs", __DIR__)
   ```

   then make the Repo and Endpoint per-worktree:

   ```elixir
   config :my_app, MyApp.Repo,
     database: "my_app_dev#{Workslot.Worktree.suffix()}"

   config :my_app, MyAppWeb.Endpoint,
     http: [ip: {127, 0, 0, 1}, port: Workslot.Worktree.dev_port()]
   ```

3. In **`config/test.exs`**, same require line, then:

   ```elixir
   config :my_app, MyApp.Repo,
     database: "my_app_test#{Workslot.Worktree.test_suffix()}"
   ```

4. In **`config/runtime.exs`**, fail fast on a worktree collision at dev boot:

   ```elixir
   if config_env() == :dev do
     Workslot.verify!()
   end
   ```

   Here the package is always loaded, so call it directly — no vendored file needed.

> **Why a vendored file instead of calling the package from config?** `config/dev.exs` and
> `config/test.exs` are evaluated before dependencies are guaranteed compiled, so calling a dep
> there can break a fresh clone. The vendored `config/worktree.exs` (the `Workslot.Worktree`
> module) has zero dependencies. The `Workslot` module ships the same functions for **runtime**
> use (`config/runtime.exs`, IEx, scripts).

## `mix workslot`

Print where the current checkout's app and databases live:

```text
$ mix workslot
worktree my-app-feature-x
  dev   db=my_app_dev_my_app_feature_x  url=http://localhost:4271
  test  db=my_app_test_my_app_feature_x
```

It reads the values back from the evaluated config, so it shows exactly what the app will use.

## Collision detection

Because the database name is derived from the folder name, two live worktrees whose names
*sanitize to the same slug* derive the same database and would silently share data. git refuses
two worktrees with the identical basename, but it allows names that differ only by case or
punctuation — `feature-x` and `feature_x` both become slug `feature_x`.
`Workslot.verify!/0` — wired into `config/runtime.exs` — lists the repo's live worktrees and
**raises before the app boots** when more than one maps to your slug (naming the folders that
clash), or when two live worktrees hash to the same dev port. The port check is purely
deterministic: it compares the hashed ports of the live worktrees and **never probes a socket**,
so it never trips over this worktree's own running server. It's a no-op outside a linked
worktree and degrades to `:ok` when `git` is unavailable.

> The port pre-check hashes the full path, so if your runtime path spelling differs from the one
> `git` records (a symlinked component like `/tmp` vs `/private/tmp`), a real port clash may not
> be pre-flagged — the OS still reports `address already in use` at boot as the backstop. The
> database check is immune: it keys off the folder basename, so the data-loss case is always
> caught.

```text
** (RuntimeError) workslot: worktree folder-name collision on slug "feature_x"

These live worktrees map to the same database:
        /Users/you/projects/feature-x
        /Users/you/projects/feature_x

Their folder names differ only by characters the slug collapses (case, punctuation).
Rename one (or `git worktree move` it) so the names differ after sanitizing, then retry.
```

> Postgres truncates identifiers at 63 bytes, so two *very long* slugs sharing a 63-byte prefix
> can still collide after truncation. Keep worktree folder names short.

## Tearing down

When you're done with a worktree, drop its suffixed databases and remove it:

```bash
cd ../my-app-feature-x
mix ecto.drop                          # drops my_app_dev_my_app_feature_x
MIX_ENV=test mix ecto.drop             # drops my_app_test_my_app_feature_x
cd -
git worktree remove ../my-app-feature-x
```

## License

MIT © 2026 [Increment TECH](https://www.increment.tech). See [LICENSE](https://github.com/increment-tech/workslot/blob/main/LICENSE).
