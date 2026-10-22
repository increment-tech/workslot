defmodule Workslot.Install.Shipped do
  @moduledoc false
  # Every `config/worktree.exs` an earlier workslot release vendored, verbatim and oldest first. The
  # installer upgrades a copy that still matches one of these — compared as code, so a formatter's
  # rewrite still matches — and leaves an edited copy alone. Add the outgoing template here whenever
  # `Workslot.Install.worktree_exs/0` changes.

  # 0.1.0 (unchanged until 0.2.0)
  @v0_1_0 ~S'''
  # Vendored by workslot — https://github.com/increment-tech/workslot
  #
  # Self-contained ON PURPOSE: build config (config/dev.exs, config/test.exs) loads this via
  # `Code.require_file/2`, which can run BEFORE deps are compiled on a fresh clone — so it must
  # not depend on the workslot package. Safe to edit; the installer never overwrites it.
  #
  # Each linked git worktree auto-isolates its dev/test databases (named from the worktree's
  # folder name) and its dev-server port (hashed from the worktree's full path). Anything that
  # is not a linked worktree — the main working tree, a submodule, a plain directory — keeps the
  # bare names and port 4000. Detection is name-agnostic: a linked worktree's `.git` is a FILE
  # holding a `gitdir:` pointer into the shared repo's `.git/worktrees/` directory.
  #
  # This mirrors the derivation in the Workslot module; a parity test keeps them in sync.
  defmodule Workslot.Worktree do
    @moduledoc false

    @doc "Sanitized worktree slug, or nil when not a linked git worktree."
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

    @doc ~S'Database-name suffix: "" outside a worktree, "_<slug>" in a linked worktree.'
    def suffix(root \\ File.cwd!()) do
      case slug(root) do
        nil -> ""
        slug -> "_" <> slug
      end
    end

    @doc "Test-DB suffix: the worktree suffix stacked with MIX_TEST_PARTITION."
    def test_suffix(root \\ File.cwd!()) do
      suffix(root) <> (System.get_env("MIX_TEST_PARTITION") || "")
    end

    @doc "Stable dev port: PORT wins; else 4000 outside a worktree, 4001..4999 hashed from the path."
    def dev_port(root \\ File.cwd!(), default \\ 4000) do
      cond do
        port = System.get_env("PORT") -> parse_port!(port)
        slug(root) -> 4001 + :erlang.phash2(root, 999)
        true -> default
      end
    end

    # A linked worktree's gitdir is `<common>/worktrees/<id>`; a submodule's is
    # `<super>/modules/<name>`, the main tree's `.git` is a directory. Require the worktrees
    # segment and reject any modules path so only a linked worktree isolates.
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
  '''

  @doc false
  def worktree_exs, do: [@v0_1_0]
end
