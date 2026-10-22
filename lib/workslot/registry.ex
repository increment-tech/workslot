defmodule Workslot.Registry do
  @moduledoc """
  The record of which database-name suffixes each checkout of a repository derived — the read side.

  The vendored `config/worktree.exs` writes it: whenever `suffix/0` (dev names) or `test_suffix/0`
  (test names) runs, in every Mix env, it records the suffix it returned under the repository's shared
  git directory:

      <git-common-dir>/workslot/main/s-<hex suffix>             # the main checkout, a dev suffix
      <git-common-dir>/workslot/worktrees/<id>/t-<hex suffix>   # linked worktree <id>, a test suffix
      <git-common-dir>/workslot/worktrees/<id>/path             # where it was (informational)

  `<id>` is git's own name for the worktree — the last segment of its `.git/worktrees/<id>` admin
  directory, stable across `git worktree move`. Because the record lives in the repository's own git
  directory, another clone of the same app never shares it, and because it holds the suffixes the app
  actually derived, an edited `config/worktree.exs` is recorded as it really names databases. A worktree
  records only while git's admin directory for it points back at it (the same file, by inode), so a
  copied folder, a pointer left stale by moving the repository, a worktree moved with a plain `mv` until
  `git worktree repair`, and any worktree on a file system without inodes record nothing.

  A worktree's record is

    * `:live` while git still has its admin directory and the worktree is on disk — or is `locked`
      (git's mark for a worktree on a drive that is not always mounted);
    * `:held` while git still registers it but its folder is gone (`git worktree prune` would drop it,
      and `git gc` prunes such worktrees after `gc.worktreePruneExpire`, three months by default — a
      worktree on a removable drive should be `git worktree lock`ed, not left held);
    * `:gone` once git no longer registers it (`git worktree remove`, or a prune).

  The main checkout's record is always `:live`.

  Two more things live here, so a removed worktree's record can only claim what it could have derived:

      <git-common-dir>/workslot/bases/<key>                           # a sighting: generation, names
      <git-common-dir>/workslot/worktrees/<id>/b-<key>.<generation>   # may claim through it

  `mix workslot.clean` writes a sighting the first time it sees a base (a Repo's database name on its
  server) after the main checkout records, listing every database already under it — its
  `preexisting` names, which no record ever claims — and retires it once the base leaves the config. A
  record gets a sighting's `b-` mark when `config/worktree.exs` first records a suffix while that
  sighting exists, or when clean finds the record live. A base seen only after a worktree was gone, or
  seen again after leaving the config (a new generation), is therefore never one its record may claim
  through. No clocks are involved.
  """

  @type state :: :live | :held | :gone
  @type entry :: %{
          id: :main | String.t(),
          state: state(),
          path: String.t() | nil,
          suffixes: [String.t()],
          test_suffixes: [String.t()],
          bases: MapSet.t(String.t()),
          dir: Path.t()
        }
  @type sighting :: %{id: String.t(), preexisting: MapSet.t(String.t())}
  @type location :: %{common: Path.t(), main: Path.t()}

  @doc """
  The repository's shared git directory and its main checkout, found from any checkout `root`.

  `{:error, :bare}` when the repository has no main working tree (a bare repository with worktrees),
  `{:error, :not_git}` when `root` is not a git checkout.
  """
  @spec locate(Path.t()) :: {:ok, location()} | {:error, :bare | :not_git}
  def locate(root) do
    git = Path.join(root, ".git")

    cond do
      File.dir?(git) ->
        {:ok, %{common: Path.expand(git), main: Path.expand(root)}}

      Workslot.worktree?(root) ->
        common = root |> gitdir() |> common_dir()

        if Path.basename(common) == ".git",
          do: {:ok, %{common: common, main: Path.dirname(common)}},
          else: {:error, :bare}

      true ->
        {:error, :not_git}
    end
  end

  @doc "Every record under `common` (the shared git directory), the main checkout's first when present."
  @spec records(Path.t()) :: [entry()]
  def records(common) do
    main_dir = Path.join([common, "workslot", "main"])
    worktrees = Path.join([common, "workslot", "worktrees"])

    main =
      if File.dir?(main_dir),
        do: [entry(main_dir, %{id: :main, state: :live, path: Path.dirname(common)})],
        else: []

    ids =
      case File.ls(worktrees) do
        {:ok, ids} -> Enum.sort(ids)
        {:error, _} -> []
      end

    main ++
      for id <- ids, dir = Path.join(worktrees, id), File.dir?(dir) do
        entry(dir, %{id: id, state: state(common, id), path: read_path(dir)})
      end
  end

  @doc "Whether the main checkout has written its record (its `config/worktree.exs` registers)."
  @spec main_recorded?(Path.t()) :: boolean()
  def main_recorded?(common), do: File.dir?(Path.join([common, "workslot", "main"]))

  @doc "Mark that a live record may claim through every sighting in `ids` (best effort)."
  @spec mark_seen(entry(), [String.t()]) :: :ok
  def mark_seen(%{id: :main}, _ids), do: :ok

  def mark_seen(%{dir: dir, bases: bases}, ids) do
    for id <- ids,
        not MapSet.member?(bases, id),
        do: File.write(Path.join(dir, "b-" <> id), "", [:exclusive])

    :ok
  end

  @doc """
  Every base clean has seen, by its key: the sighting's `id` (`<key>.<generation>` — what records are
  marked with) and the names that were already there when clean first saw it.
  """
  @spec seen_bases(Path.t()) :: %{String.t() => sighting()}
  def seen_bases(common) do
    dir = Path.join([common, "workslot", "bases"])

    case File.ls(dir) do
      {:ok, files} ->
        for key <- files,
            not String.starts_with?(key, "."),
            {:ok, content} <- [File.read(Path.join(dir, key))],
            # an empty (unfinished or damaged) sighting is no sighting; see_base/3 replaces it
            [generation | names] <- [String.split(content, "\n", trim: true)],
            into: %{} do
          {key, %{id: key <> "." <> generation, preexisting: decode_names(names)}}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Record that clean has now seen base `key` with `names` already there. One file per key, holding a fresh
  generation and the names: written aside, then linked into place, which fails if another run got there
  first — so there is never more than one sighting of a key, and marks from an earlier one (before the
  key was retired) never match a later one.
  """
  @spec see_base(Path.t(), String.t(), [String.t()]) :: :ok
  def see_base(common, key, names) do
    dir = Path.join([common, "workslot", "bases"])
    file = Path.join(dir, key)

    unless Map.has_key?(seen_bases(common), key) do
      # an empty file left by an interrupted write is replaced, not trusted
      File.rm(file)
      File.mkdir_p!(dir)
      generation = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
      tmp = Path.join(dir, ".base-#{:os.getpid()}-#{System.unique_integer([:positive])}")
      lines = [generation | Enum.map(names, &Base.encode16(&1, case: :lower))]

      try do
        File.write!(tmp, Enum.map_join(lines, &(&1 <> "\n")), [:exclusive])
        link(tmp, file)
      after
        File.rm(tmp)
      end
    end

    :ok
  end

  defp link(tmp, file) do
    case File.ln(tmp, file) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      # no hard links on this file system (exFAT, some network shares): a plain rename, which in a race
      # can only replace one fresh generation with another — marks of the first then claim nothing
      {:error, _} ->
        unless File.exists?(file), do: File.rename(tmp, file)
        :ok
    end
  end

  @doc "Retire a base's sighting (the base left the config): if it returns, it is seen afresh."
  @spec forget_base(Path.t(), String.t()) :: :ok
  def forget_base(common, key) do
    File.rm(Path.join([common, "workslot", "bases", key]))
    :ok
  end

  defp decode_names(lines) do
    for line <- lines,
        {:ok, name} <- [Base.decode16(line, case: :lower)],
        into: MapSet.new(),
        do: name
  end

  @doc """
  Delete a `:gone` record — once nothing it names exists any more, so it can never claim a later
  database. Re-checked first: a record whose worktree git registers again is kept.
  """
  @spec forget(entry()) :: :ok
  def forget(%{id: :main}), do: :ok

  def forget(%{id: id, dir: dir}) do
    common = dir |> Path.dirname() |> Path.dirname() |> Path.dirname()
    if state(common, id) == :gone, do: File.rm_rf(dir)
    :ok
  end

  # `s-` files hold dev suffixes, `t-` files test suffixes, `b-` files the bases it may claim through;
  # the hex keeps any `MIX_TEST_PARTITION` value or base key file-name safe.
  defp entry(dir, fields) do
    files =
      case File.ls(dir) do
        {:ok, files} -> files
        {:error, _} -> []
      end

    Map.merge(fields, %{
      suffixes: decode(files, "s-"),
      test_suffixes: decode(files, "t-"),
      bases: for("b-" <> id <- files, into: MapSet.new(), do: id),
      dir: dir
    })
  end

  defp decode(files, prefix) do
    files
    |> Enum.flat_map(fn file ->
      with ^prefix <> hex <- file,
           {:ok, suffix} <- Base.decode16(hex, case: :lower) do
        [suffix]
      else
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp read_path(dir) do
    case File.read(Path.join(dir, "path")) do
      {:ok, path} -> String.trim(path)
      {:error, _} -> nil
    end
  end

  # Git's admin directory for a linked worktree holds `gitdir` (the path of the worktree's `.git` file)
  # and, when locked, `locked`. Anything unreadable counts as live: a false "gone" could drop data.
  defp state(common, id) do
    admin = Path.join([common, "worktrees", id])

    cond do
      not File.dir?(admin) -> :gone
      File.exists?(Path.join(admin, "locked")) -> :live
      true -> on_disk(admin)
    end
  end

  defp on_disk(admin) do
    case File.read(Path.join(admin, "gitdir")) do
      {:ok, dot_git} ->
        dot_git = dot_git |> String.trim() |> Path.expand(admin)
        if File.exists?(dot_git), do: :live, else: :held

      {:error, _} ->
        :live
    end
  end

  defp gitdir(root) do
    {:ok, "gitdir: " <> target} = File.read(Path.join(root, ".git"))
    target |> String.trim() |> Path.expand(root)
  end

  # `<gitdir>/commondir` names the shared directory (normally `../..`); fall back to the standard layout.
  defp common_dir(gitdir) do
    case File.read(Path.join(gitdir, "commondir")) do
      {:ok, rel} -> rel |> String.trim() |> Path.expand(gitdir)
      {:error, _} -> gitdir |> Path.dirname() |> Path.dirname()
    end
  end
end
