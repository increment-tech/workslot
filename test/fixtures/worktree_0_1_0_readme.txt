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
