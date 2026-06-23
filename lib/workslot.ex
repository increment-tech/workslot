defmodule Workslot do
  @moduledoc """
  Per-git-worktree isolation of the dev/test database names and the dev-server port,
  derived deterministically from the worktree itself — no generated files, no manifest,
  no manual port bookkeeping.

  ## How detection works

  Isolation applies only to a *linked* git worktree (one added with `git worktree add`).
  Such a worktree's `.git` is a **file** containing a `gitdir:` pointer into the shared
  repo's `.git/worktrees/` directory — that exact shape is what `worktree?/1` keys off, so
  detection is name- and location-agnostic. Every other layout — the main working tree
  (`.git` is a directory), a git submodule (`.git` points into `.git/modules/`), or a plain
  non-git directory — is treated as *not* a worktree and keeps the bare database names and
  port `4000`. The safe default is "don't isolate."

  ## What derives from what

  The two isolated resources key off deliberately different inputs:

    * the **database name** uses the worktree's folder name (`slug/1`), so it stays readable
      (`my_app_dev_feature_x`), survives moving the folder, and is naturally separated across
      apps by the app prefix; while
    * the **dev-server port** is a deterministic hash of the worktree's full path, because a
      port is a machine-global resource with no app namespacing — the full path is the only
      thing guaranteed unique across every checkout on the machine.

  Two worktrees with the *same folder name* in different locations therefore map to the same
  database. That is a folder-name collision; `verify!/1` detects it and fails loudly rather
  than letting them silently share data. (Postgres truncates identifiers at 63 bytes, so two
  very long slugs sharing a 63-byte prefix can still collide after truncation — keep worktree
  names short.)

  ## Build-time config caveat

  `config/dev.exs` and `config/test.exs` are evaluated *before* dependencies are guaranteed
  to be compiled, so do **not** call this module from there on a fresh clone. Instead use the
  self-contained `config/worktree.exs` that `mix workslot.install` vendors and that those
  files load via `Code.require_file/2`. That vendored `Workslot.Worktree` module mirrors the
  derivation functions here (`slug/1`, `suffix/1`, `test_suffix/1`, `dev_port/2`).

  This module is the same logic for **runtime** use — `config/runtime.exs`, IEx, scripts, and
  the `mix workslot` task — where the dependency is always loaded. `verify!/1` lives only here
  and is meant to be called from `config/runtime.exs`.

  All functions default their `root` argument to `File.cwd!/0`, which is the project root when
  Mix runs. Pass an explicit path for umbrella apps or tooling.
  """

  @doc """
  Sanitized worktree slug, or `nil` when `root` is not a linked git worktree.

  The slug is the worktree's folder name, downcased, with every run of non-alphanumeric
  characters collapsed to `_` and leading/trailing `_` trimmed. A folder name with no
  alphanumeric characters at all falls back to a short deterministic hash of the path, so it
  still isolates instead of collapsing to an empty suffix.
  """
  @spec slug(Path.t()) :: String.t() | nil
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

  @doc ~S'Database-name suffix: `""` outside a worktree, `"_<slug>"` in a linked worktree.'
  @spec suffix(Path.t()) :: String.t()
  def suffix(root \\ File.cwd!()) do
    case slug(root) do
      nil -> ""
      slug -> "_" <> slug
    end
  end

  @doc """
  Test-database suffix: the worktree `suffix/1` stacked with `MIX_TEST_PARTITION`, so a
  worktree never shares a test DB even with no partition set, while CI partitioning still
  composes inside any single checkout.
  """
  @spec test_suffix(Path.t()) :: String.t()
  def test_suffix(root \\ File.cwd!()) do
    suffix(root) <> (System.get_env("MIX_TEST_PARTITION") || "")
  end

  @doc """
  Stable dev-server port.

  `PORT` wins when set; otherwise `4000` outside a worktree and a deterministic `4001..4999`
  hashed from the worktree's full path (so a given worktree always boots on the same port, and
  distinct worktrees rarely collide). Raises if `PORT` is set but is not an integer in
  `1..65535`.
  """
  @spec dev_port(Path.t(), pos_integer()) :: pos_integer()
  def dev_port(root \\ File.cwd!(), default \\ 4000) do
    cond do
      port = System.get_env("PORT") -> parse_port!(port)
      slug(root) -> 4001 + :erlang.phash2(root, 999)
      true -> default
    end
  end

  @doc """
  True when `root` is a *linked* git worktree.

  A linked worktree's `.git` is a file holding a `gitdir:` pointer into the shared repo's
  `.git/worktrees/` directory. The main working tree (`.git` is a directory), a submodule
  (`.git` points into `.git/modules/`), and plain non-git directories all return `false`.
  """
  @spec worktree?(Path.t()) :: boolean()
  def worktree?(root \\ File.cwd!()) do
    case File.read(Path.join(root, ".git")) do
      {:ok, "gitdir: " <> target} ->
        # A linked worktree's gitdir is `<common>/worktrees/<id>`; a submodule's is
        # `<super>/modules/<name>`. Require the worktrees segment and reject any modules path, so
        # a submodule — even one under a directory literally named `worktrees` — is excluded.
        target = String.trim(target)
        String.contains?(target, "/worktrees/") and not String.contains?(target, "/modules/")

      _ ->
        false
    end
  end

  @doc """
  Assert this checkout's worktree isolation is sound, returning `:ok` or raising.

  Lists the repo's live git worktrees and raises a `RuntimeError` when another live worktree's
  folder name sanitizes to the same `slug/1` as this one (they would share a database), or when
  another live worktree's path hashes to the same `dev_port/2` (they can't both bind it). The
  port check is purely deterministic — it compares hashed ports across the live worktrees and
  never probes a socket, so it never trips over this worktree's own running server. An explicit
  `PORT` is treated as a deliberate, shared choice and is never flagged.

  The port pre-check hashes the full path, so it assumes the runtime path spelling matches the
  one `git` records for the worktree. If they differ only by a symlinked component (e.g. `/tmp`
  vs `/private/tmp`), a genuine port clash may not be pre-flagged — the OS still reports
  `address already in use` at server start as the backstop. The database/slug check is immune:
  it keys off the folder basename, not the full path, so the data-loss case is always caught.

  Safe to call from `config/runtime.exs`. Returns `:ok` without checking when `root` is not a
  linked worktree, is not inside a git repo, or when the `git` CLI is unavailable.
  """
  @spec verify!(Path.t()) :: :ok
  def verify!(root \\ File.cwd!()) do
    if worktree?(root) do
      case live_worktrees(root) do
        {:ok, worktrees} -> do_verify!(root, worktrees)
        :error -> :ok
      end
    else
      :ok
    end
  end

  # `do_verify!/2`, `slug_collision/2`, and `port_collision/2` are internal (`@doc false`) seams:
  # pure given the worktree list, so the collision logic is unit-testable without standing up a
  # real multi-worktree git repo. Not part of the public, semver-covered API.

  @doc false
  def do_verify!(root, worktrees) do
    if cohort = slug_collision(root, worktrees) do
      raise slug_collision_message(slug(root), cohort)
    end

    if cohort = port_collision(root, worktrees) do
      raise port_collision_message(dev_port(root), cohort)
    end

    :ok
  end

  @doc false
  def slug_collision(root, worktrees) do
    mine = slug(root)
    cohort = Enum.filter(worktrees, &(slug(&1) == mine))

    # `git worktree list` includes this checkout exactly once, so a cohort larger than one means
    # another live worktree shares this slug. Counting (rather than excluding self by path string)
    # is robust to symlinks — e.g. macOS reports `/private/tmp/...` where the caller passed
    # `/tmp/...`, which `Path.expand/1` does not resolve.
    if length(cohort) > 1, do: cohort, else: nil
  end

  @doc false
  def port_collision(root, worktrees) do
    # An explicit PORT is a deliberate, shared choice — never flag it.
    if System.get_env("PORT") do
      nil
    else
      mine = dev_port(root)
      cohort = Enum.filter(worktrees, &(worktree?(&1) and dev_port(&1) == mine))

      # Same count-based, symlink-robust reasoning as `slug_collision/2`.
      if length(cohort) > 1, do: cohort, else: nil
    end
  end

  defp slug_collision_message(slug, cohort) do
    listed = cohort |> Enum.map(&"        #{Path.expand(&1)}") |> Enum.join("\n")

    """
    workslot: worktree folder-name collision on slug #{inspect(slug)}

    These live worktrees map to the same database:
    #{listed}

    Their folder names differ only by characters the slug collapses (case, punctuation).
    Rename one (or `git worktree move` it) so the names differ after sanitizing, then retry.
    """
  end

  defp port_collision_message(port, cohort) do
    listed = cohort |> Enum.map(&"        #{Path.expand(&1)}") |> Enum.join("\n")

    """
    workslot: dev-port collision on port #{port}

    These live worktrees hash to the same dev port:
    #{listed}

    Two worktrees can't both bind it. Set `PORT` to a free port in one of them
    (e.g. `PORT=4600 mix phx.server`), or `git worktree move` one so its path re-hashes.
    """
  end

  defp live_worktrees(root) do
    case System.cmd("git", ["-C", root, "worktree", "list", "--porcelain"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        paths =
          out
          |> String.split("\n")
          |> Enum.flat_map(fn
            "worktree " <> path -> [path]
            _ -> []
          end)

        {:ok, paths}

      _ ->
        :error
    end
  rescue
    # System.cmd/3 raises only when the `git` executable is absent; let any other error surface.
    ErlangError -> :error
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
