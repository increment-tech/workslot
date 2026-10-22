defmodule Mix.Tasks.Workslot.Clean do
  @shortdoc "List (or drop) databases left behind by removed git worktrees"

  @moduledoc """
  Finds the dev/test databases that removed git worktrees of this repository left behind and — only
  when asked — drops them.

  Every checkout records the database-name suffixes it derives: the vendored `config/worktree.exs`
  writes them under `.git/workslot/` whenever the app's config is evaluated (see `Workslot.Registry`).
  A worktree that `git worktree remove` (or `git worktree prune`) removed leaves its record behind, and
  the databases it derived are what this task reports — but only through a base (a Repo's database
  name on its server) this task had already seen when the worktree recorded, or seen it live, and
  never one that was already there when it first saw that base (a worktree's own databases from before
  then included). Every run notes the bases and marks the live records, so run it (the `SessionStart`
  hook does, every session) while worktrees come and go. Ownership is never guessed from a name.

      $ mix workslot.clean                       # list; drops nothing
      $ mix workslot.clean --drop                # drop the orphans, after a confirmation prompt
      $ mix workslot.clean --drop NAME...        # drop exactly these, after a prompt
      $ mix workslot.clean --drop --yes NAME...  # the same without the prompt (scripts, agents)

  ## What it reports

    * **Orphans** — databases only removed worktrees derived. `--drop` drops them.
    * **Held** — databases of a worktree whose folder is gone but which git still registers (deleted
      by hand instead of with `git worktree remove`). They stay until `git worktree prune`, so a
      worktree on a drive that is merely unmounted keeps its data; a `git worktree lock`ed one is live.
    * **Unregistered** — named like this app's worktree databases (`<base>_...`) but recorded by no
      checkout: left by a workslot older than 0.2.0, copied by hand, or another clone's. Dropped only
      when named.

  A live checkout's databases (of this repository — see the limit below), every Repo's own database, and
  a database named the way workslot names one for a worktree git currently lists, recorded or not, are
  never reported.

  ## Options

    * `--drop` — drop. With no names, the orphans; with names, exactly those — each must be an orphan
      or unregistered, or nothing is dropped. Prompts first (default no).
    * `--yes` — skip the prompt. Only with `--drop` and the names, so an unattended run says what it
      drops.
    * `--only dev|test` — restrict to one kind.
    * `--summary` — one line for a coding agent's session-start context, or nothing below `--min-size`
      (or when anything goes wrong). Never drops.
    * `--min-size SIZE` — threshold for `--summary`, e.g. `500MB`, `2GB` (default `1GB`).

  ## Safety

    * What will be dropped is printed first, with `--yes` too.
    * Right before each `DROP`, the records are read again: a worktree re-created meanwhile keeps its
      databases.
    * Drops use a plain `DROP DATABASE` (never `WITH (FORCE)`), which Postgres refuses while anyone is
      connected.

  Until the main checkout's own `config/worktree.exs` records (it predates 0.2.0 until
  `mix workslot.install` upgrades it), this task does not start watching bases and `--drop` drops only
  databases named on the command line. A base that leaves the config is forgotten; if it returns, it is
  watched afresh, and no record made before claims through it.

  Base names and servers come from every Repo in the **main checkout's** evaluated config (with
  `MIX_TEST_PARTITION` unset), so the result is the same from the main checkout or any worktree.

  ## Limits

    * Records are per clone. Two clones of one app on one Postgres server whose worktrees share a folder
      name already share that database; when one clone removes its worktree, `clean` there reports the
      database as left behind, and only an open connection stops the drop.
    * A worktree re-created in the instant between the last check and its `DROP` loses that database
      (it has not connected yet, so Postgres does not refuse).
    * Only the main checkout's Repos are known: a Repo that only a worktree's branch configures is never
      reported, and a removed worktree's record is retired once nothing the main checkout's Repos would
      name for it exists.
  """

  use Mix.Task

  alias Workslot.{Clean, ConfigReader, Postgres, Registry}

  @switches [drop: :boolean, yes: :boolean, only: :string, summary: :boolean, min_size: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, names} = OptionParser.parse!(argv, strict: @switches)
    validate!(opts, names)
    kinds = kinds(opts[:only])

    # Connecting can fail noisily (the driver logs a crash report and exits the linked pool); this is a
    # one-off CLI that reports failures itself, so quiet both for the run and restore them afterwards.
    logger_level = Logger.level()
    trap_exit = Process.flag(:trap_exit, true)
    Logger.configure(level: :none)

    try do
      if opts[:summary] do
        # Runs from a session-start hook: an unreachable server or a stray git state must not print an
        # error into every new session. Report nothing instead; a manual run shows the real error.
        try do
          clean(opts, names, kinds)
        rescue
          # anything at all — an unevaluable config, a stray git state — is for a manual run to show
          _ -> :ok
        end
      else
        clean(opts, names, kinds)
      end
    after
      Logger.configure(level: logger_level)
      Process.flag(:trap_exit, trap_exit)
    end
  end

  defp validate!(opts, names) do
    # parsed here, outside --summary's silence, so a bad WORKSLOT_CLEAN_MIN_SIZE shows on a manual run
    if opts[:min_size], do: parse_size!(opts[:min_size])

    cond do
      opts[:summary] && (opts[:drop] || names != []) ->
        Mix.raise("workslot.clean: --summary never drops — leave out --drop and the names.")

      names != [] && !opts[:drop] ->
        Mix.raise("workslot.clean: database names are only taken with --drop.")

      opts[:min_size] && !opts[:summary] ->
        Mix.raise("workslot.clean: --min-size only applies to --summary.")

      opts[:yes] && names == [] ->
        Mix.raise(
          "workslot.clean: --yes needs the databases named — `mix workslot.clean` lists them, " <>
            "then `mix workslot.clean --drop --yes NAME...`."
        )

      true ->
        :ok
    end
  end

  defp clean(opts, names, kinds) do
    state = state!(kinds)

    try do
      existing = list!(state)
      state = watch(state, existing)
      plan = plan(state, existing)

      cond do
        opts[:summary] ->
          summary(plan, parse_size!(opts[:min_size] || "1GB"))

        opts[:drop] ->
          drop(plan, names, opts[:yes] == true, state, existing)

        true ->
          list(plan, state)
      end

      # Retire spent records, so a record can never claim a database made later under its old name.
      # Only after a full listing: with --only, the other kind's databases were not looked at.
      unless opts[:summary] || opts[:only], do: forget_spent(state)
    after
      Enum.each(state.conns, fn {_server, conn} -> postgres().stop(conn) end)
    end
  end

  defp kinds(nil), do: [:dev, :test]
  defp kinds("dev"), do: [:dev]
  defp kinds("test"), do: [:test]

  defp kinds(other),
    do: Mix.raise("workslot.clean: --only must be dev or test, got #{inspect(other)}")

  # The repository's location, every Repo's bases of both kinds (all of them decide what is live), and
  # one maintenance connection per server the requested kinds live on.
  defp state!(kinds) do
    location =
      case Registry.locate(File.cwd!()) do
        {:ok, location} ->
          location

        {:error, :bare} ->
          Mix.raise(
            "workslot.clean: this repository has no main checkout to read the base database names " <>
              "from (a bare repository, or one cloned with --separate-git-dir) — not supported."
          )

        {:error, :not_git} ->
          Mix.raise(
            "workslot.clean: #{File.cwd!()} is neither a git repository's main checkout nor one of " <>
              "its worktrees (a submodule or a --separate-git-dir clone is not supported)."
          )
      end

    unless File.dir?(location.main) do
      Mix.raise(
        "workslot.clean: this worktree's .git points at #{location.main}, which no longer exists " <>
          "(the repository moved?) — run `git worktree repair` from the repository."
      )
    end

    app = Mix.Project.config()[:app]

    bases =
      for kind <- [:dev, :test],
          repo <- main_repos(location.main, app, kind),
          is_binary(repo[:database]) do
        %{kind: kind, name: repo[:database], server: Postgres.server(repo), opts: repo}
      end

    if Enum.all?(bases, &(&1.kind not in kinds)),
      do: Mix.raise("workslot.clean: no Repo with a :database in #{location.main}/config.")

    %{
      location: location,
      bases: bases,
      kinds: kinds,
      conns: connect!(Enum.filter(bases, &(&1.kind in kinds)))
    }
  end

  defp connect!(bases) do
    bases
    |> Enum.uniq_by(& &1.server)
    |> Enum.reduce(%{}, fn base, conns ->
      case postgres().connect(base.opts) do
        {:ok, conn} ->
          Map.put(conns, base.server, conn)

        {:error, reason} ->
          Enum.each(conns, fn {_server, conn} -> postgres().stop(conn) end)
          Mix.raise("workslot.clean: cannot reach the #{base.kind} database server: #{reason}")
      end
    end)
  end

  # Read the Repo config as the main checkout evaluates it: from its own directory (the vendored
  # worktree.exs derives the suffix from the cwd) and with no partition, so each database name IS a
  # base — nothing has to be stripped. Evaluating it also writes the main checkout's own record.
  defp main_repos(main, app, env) do
    partition = System.get_env("MIX_TEST_PARTITION")
    System.delete_env("MIX_TEST_PARTITION")
    # The main checkout's config requires its own copy of config/worktree.exs, redefining the
    # Workslot.Worktree module this checkout already loaded — expected here, so don't warn about it.
    conflicts = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      File.cd!(main, fn ->
        case Enum.find(["config/config.exs", "config/#{env}.exs"], &File.exists?/1) do
          nil ->
            []

          path ->
            path
            |> read_config!(env, main)
            |> Keyword.get(app)
            |> ConfigReader.repos()
            |> Enum.map(&Postgres.effective/1)
        end
      end)
    after
      if partition, do: System.put_env("MIX_TEST_PARTITION", partition)
      Code.put_compiler_option(:ignore_module_conflict, conflicts)
    end
  end

  defp read_config!(path, env, main) do
    Config.Reader.read!(path, env: env)
  rescue
    error ->
      Mix.raise(
        "workslot.clean: cannot evaluate #{Path.join(main, path)} for #{env}: " <>
          Exception.message(error)
      )
  end

  # server => %{name => {size, connections}}, for every base of the requested kinds.
  defp list!(state) do
    for base <- state.bases, base.kind in state.kinds, reduce: %{} do
      acc ->
        case postgres().list(state.conns[base.server], base.name) do
          {:ok, found} ->
            Map.update(acc, base.server, found, &Map.merge(&1, found))

          {:error, reason} ->
            Mix.raise(
              "workslot.clean: cannot list the databases on #{Postgres.describe(base.opts)}: #{reason}"
            )
        end
    end
  end

  # What lets a removed worktree's record claim anything later. Once the main checkout records (before
  # that, its own partition copies are not known), each base is seen the first time with every database
  # already under it — those stay unclaimable, since a matching suffix does not prove whose they are; a
  # base that left the config has its sighting retired; then every live record is marked for every
  # sighting.
  defp watch(state, existing) do
    common = state.location.common
    current = MapSet.new(state.bases, &key/1)

    for {key, _sighting} <- Registry.seen_bases(common),
        not MapSet.member?(current, key),
        do: Registry.forget_base(common, key)

    if Registry.main_recorded?(common) do
      seen = Registry.seen_bases(common)

      for base <- state.bases, base.kind in state.kinds, not Map.has_key?(seen, key(base)) do
        names =
          for {name, _} <- Map.get(existing, base.server, %{}),
              String.starts_with?(name, base.name),
              do: name

        Registry.see_base(common, key(base), names)
      end
    end

    seen = Registry.seen_bases(common)
    ids = Enum.map(seen, fn {_key, %{id: id}} -> id end)
    for %{state: :live} = record <- Registry.records(common), do: Registry.mark_seen(record, ids)

    bases =
      Enum.map(state.bases, fn base ->
        sighting = seen[key(base)]

        Map.merge(base, %{
          key: sighting && sighting.id,
          preexisting: sighting && sighting.preexisting
        })
      end)

    %{state | bases: bases}
  end

  # A base is its kind, its name and where it lives — renaming or moving it makes a new one. Hashed, so
  # the files named after it stay short whatever the name and socket path.
  defp key(base) do
    description = Enum.join([base.kind, base.name, Postgres.destination(base.opts)], "\t")
    :sha256 |> :crypto.hash(description) |> Base.encode16(case: :lower)
  end

  # Read fresh every time — records and git's worktree list both — since a drop re-checks with it.
  defp plan(state, existing) do
    Clean.plan(state.bases, Registry.records(state.location.common), existing,
      kinds: state.kinds,
      live_slugs: live_slugs!(state.location.main)
    )
  end

  defp live_slugs!(main) do
    case Workslot.live_worktrees(main) do
      {:ok, [_main | worktrees]} ->
        Enum.map(worktrees, &Workslot.folder_slug/1)

      _ ->
        Mix.raise(
          "workslot.clean: `git worktree list` failed — refusing to guess which worktrees are live."
        )
    end
  end

  defp list(plan, state) do
    {orphans, held, unregistered} = groups(plan)

    if orphans == [] do
      Mix.shell().info("workslot.clean: no databases left behind by removed worktrees.")
    else
      Mix.shell().info(
        "workslot.clean: #{count(orphans)} left behind by removed worktrees (#{size(orphans)}):"
      )

      Enum.each(orphans, &Mix.shell().info("  " <> line(&1)))
    end

    held_and_unregistered(held, unregistered)
    unrecorded_main_checkout(state)

    if plan != [] do
      Mix.shell().info("""

      Nothing dropped. `mix workslot.clean --drop` drops the first list (after a prompt);
      `mix workslot.clean --drop NAME...` drops the databases you name from the first or last list.\
      """)
    end
  end

  defp held_and_unregistered(held, unregistered) do
    if held != [] do
      Mix.shell().info("""

      Held — their worktree folders are gone, but git still registers the worktrees. They are kept
      (a drive may just be unmounted); `git worktree prune` releases them:\
      """)

      Enum.each(held, &Mix.shell().info("  " <> line(&1)))
    end

    if unregistered != [] do
      Mix.shell().info("""

      Unregistered — named like this app's worktree databases, but no removed worktree's record
      claims them (there before clean first watched, a workslot older than 0.2.0, a hand-made copy,
      another clone's worktree). Dropped only when named:\
      """)

      Enum.each(unregistered, &Mix.shell().info("  " <> line(&1)))
    end
  end

  defp unrecorded_main_checkout(state) do
    unless Registry.main_recorded?(state.location.common) do
      Mix.shell().info("""

      Note: the main checkout's config/worktree.exs does not record the database names it derives
      (it predates workslot 0.2.0), so worktree databases show as unregistered. Re-run
      `mix workslot.install` to upgrade it.\
      """)
    end
  end

  defp drop(plan, names, yes?, state, existing) do
    targets = if names == [], do: orphans!(plan, state), else: named!(plan, names)

    if targets == [] do
      Mix.shell().info("workslot.clean: nothing to drop.")
      {_orphans, held, unregistered} = groups(plan)
      held_and_unregistered(held, unregistered)
    else
      Mix.shell().info("workslot.clean: will drop #{count(targets)} (#{size(targets)}):")
      Enum.each(targets, &Mix.shell().info("  " <> line(&1)))

      if yes? or Mix.shell().yes?("Drop these #{count(targets)}?", default: :no) do
        dropped = for target <- targets, drop_one(target, state, existing) == :ok, do: target
        Mix.shell().info("workslot.clean: dropped #{count(dropped)}, freed #{size(dropped)}.")
      else
        Mix.shell().info("workslot.clean: nothing dropped.")
      end
    end
  end

  # Until the main checkout records what it derives, its own databases (an old non-numeric partition
  # copy, say) are not known, so nothing is dropped without being named.
  defp orphans!(plan, state) do
    if Registry.main_recorded?(state.location.common) do
      Enum.filter(plan, &(&1.group == :orphan))
    else
      Mix.raise(
        "workslot.clean: the main checkout's config/worktree.exs does not record its databases yet " <>
          "(re-run `mix workslot.install` to upgrade it), so nothing is dropped unless named: " <>
          "`mix workslot.clean --drop NAME...`."
      )
    end
  end

  # Each named database must be droppable on at least one server, or the whole run stops before dropping.
  defp named!(plan, names) do
    names = Enum.uniq(names)
    droppable = Enum.filter(plan, &(&1.name in names and &1.group in [:orphan, :unregistered]))

    case Enum.reject(names, fn name -> Enum.any?(droppable, &(&1.name == name)) end) do
      [] ->
        Enum.map(droppable, &Map.put(&1, :named, true))

      refused ->
        reasons = Enum.map_join(refused, "\n", &"  #{display(&1)} — #{refusal(&1, plan)}")
        Mix.raise("workslot.clean: nothing dropped; these cannot be dropped:\n#{reasons}")
    end
  end

  defp refusal(name, plan) do
    if Enum.any?(plan, &(&1.name == name and &1.group == :held)),
      do: "its worktree folder is gone but git still registers it (`git worktree prune` first)",
      else: "not a database this task may drop (a live checkout's, or not one of this app's)"
  end

  # Read the records again right before dropping: the target must still be droppable.
  defp drop_one(target, state, existing) do
    now =
      Enum.find(plan(state, existing), &(&1.server == target.server and &1.name == target.name))

    result =
      cond do
        now && now.group == :orphan ->
          postgres().drop(state.conns[target.server], target.name)

        now && now.group == :unregistered && target[:named] ->
          postgres().drop(state.conns[target.server], target.name)

        true ->
          {:error, "a live checkout claims it now"}
      end

    case result do
      :ok -> Mix.shell().info("  dropped #{display(target.name)}")
      {:error, reason} -> Mix.shell().error("  skipped #{display(target.name)} — #{reason}")
    end

    result
  end

  defp forget_spent(state) do
    existing = list!(state)

    for %{state: :gone} = record <- Registry.records(state.location.common),
        not Enum.any?(Clean.derived_names(state.bases, record), fn {server, name} ->
          Map.has_key?(Map.get(existing, server, %{}), name)
        end) do
      Registry.forget(record)
    end
  end

  # One line, silent below the threshold so a clean repo costs a coding agent zero context tokens. Only
  # what the agent may act on counts towards it: unregistered databases need the user's judgement, so a
  # large backup alone never prints, and their names never reach the agent's context.
  defp summary(plan, min_size) do
    {orphans, held, unregistered} = groups(plan)
    actionable = orphans ++ held

    if actionable != [] and total(actionable) >= min_size do
      sentences =
        [
          orphans != [] &&
            "removed git worktrees of this repo left #{count(orphans)} behind (#{size(orphans)}): " <>
              names(orphans) <> ".",
          held != [] &&
            "Held until the user runs `git worktree prune` (worktree folders deleted by hand): " <>
              "#{count(held)} (#{size(held)}): #{names(held)}.",
          unregistered != [] &&
            "Also unregistered (named like this app's worktree databases, recorded by no checkout): " <>
              "#{count(unregistered)} (#{size(unregistered)}).",
          "Before dropping anything, show the user the list from `mix workslot.clean` and drop only " <>
            "the databases they approve, by name: `mix workslot.clean --drop --yes NAME...`."
        ]
        |> Enum.filter(& &1)
        |> Enum.join(" ")

      Mix.shell().info("workslot: " <> sentences)
    end
  end

  defp groups(plan) do
    {Enum.filter(plan, &(&1.group == :orphan)), Enum.filter(plan, &(&1.group == :held)),
     Enum.filter(plan, &(&1.group == :unregistered))}
  end

  # Quoted and escaped: a database name is data, and one holding a newline must not start a line of its own.
  defp names(dbs) do
    shown = dbs |> Enum.take(8) |> Enum.map_join(", ", &inspect(&1.name))
    if length(dbs) > 8, do: shown <> " (+#{length(dbs) - 8} more)", else: shown
  end

  # A plain identifier as is; anything else (spaces, control characters) quoted and escaped.
  defp display(name) do
    if name =~ ~r/\A[A-Za-z0-9_$-]+\z/, do: name, else: inspect(name)
  end

  defp line(%{name: name, size: size, conns: conns} = db) do
    name = display(name)
    worktree = if db.worktree, do: "  worktree #{display(db.worktree)}", else: ""
    in_use = if conns > 0, do: "  (in use — will be skipped)", else: ""

    String.pad_trailing(name, 50) <>
      " " <> String.pad_leading(human(size), 9) <> worktree <> in_use
  end

  defp count([_]), do: "1 database"
  defp count(dbs), do: "#{length(dbs)} databases"

  defp size(dbs), do: dbs |> total() |> human()

  defp total(dbs), do: dbs |> Enum.map(& &1.size) |> Enum.sum()

  defp postgres, do: Application.get_env(:workslot, :postgres, Postgres)

  @doc false
  def human(bytes) when bytes >= 1_000_000_000,
    do: :erlang.float_to_binary(bytes / 1.0e9, decimals: 1) <> " GB"

  def human(bytes) when bytes >= 1_000_000, do: "#{div(bytes, 1_000_000)} MB"
  def human(bytes), do: "#{div(bytes, 1000)} kB"

  @doc false
  def parse_size!(text) do
    case Regex.run(~r/\A\s*(\d+(?:\.\d+)?)\s*(kb|mb|gb|b)?\s*\z/i, text) do
      [_, n | unit] ->
        {n, _} = Float.parse(n)
        mult = %{"" => 1, "b" => 1, "kb" => 1.0e3, "mb" => 1.0e6, "gb" => 1.0e9}
        round(n * mult[String.downcase(List.first(unit) || "")])

      _ ->
        Mix.raise("workslot.clean: --min-size must look like 500MB or 2GB, got #{inspect(text)}")
    end
  end
end
