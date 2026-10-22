defmodule Workslot.FakePostgres do
  @moduledoc false
  # Stands in for `Workslot.Postgres` in the task's tests: one Agent holds the server's databases
  # (name => {size, connections}) and the names dropped so far.
  use Agent

  def start_link(dbs),
    do: Agent.start_link(fn -> %{dbs: dbs, dropped: [], on_drop: nil} end, name: __MODULE__)

  def put(dbs), do: Agent.update(__MODULE__, &%{&1 | dbs: dbs})
  def names, do: Agent.get(__MODULE__, &(&1.dbs |> Map.keys() |> Enum.sort()))
  def dropped, do: Agent.get(__MODULE__, &Enum.reverse(&1.dropped))

  # Runs once, right before the next drop reaches the "server".
  def on_next_drop(fun), do: Agent.update(__MODULE__, &%{&1 | on_drop: fun})

  def connect(_opts), do: {:ok, :fake}
  def stop(_conn), do: :ok

  def list(_conn, prefix) do
    {:ok,
     Agent.get(__MODULE__, fn %{dbs: dbs} ->
       Map.filter(dbs, fn {name, _} -> String.starts_with?(name, prefix) end)
     end)}
  end

  def drop(_conn, name) do
    hook = Agent.get_and_update(__MODULE__, &{&1.on_drop, %{&1 | on_drop: nil}})
    if hook, do: hook.()

    Agent.get_and_update(__MODULE__, fn state ->
      case state.dbs[name] do
        nil -> {{:error, "does not exist"}, state}
        {_size, conns} when conns > 0 -> {{:error, "is being accessed by other users"}, state}
        _ -> {:ok, %{state | dbs: Map.delete(state.dbs, name), dropped: [name | state.dropped]}}
      end
    end)
  end
end

defmodule Mix.Tasks.Workslot.CleanTest do
  # Real git repositories and worktrees, the real vendored config/worktree.exs, a fake Postgres.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workslot.Clean
  alias Workslot.{FakePostgres, Install, Registry}

  @dev_exs ~S'''
  import Config
  Code.require_file("worktree.exs", __DIR__)

  config :workslot, Fixture.Repo,
    hostname: "localhost",
    database: "my_app_dev#{Workslot.Worktree.suffix()}"

  config :workslot, Fixture.EventsRepo,
    hostname: "localhost",
    database: "my_app_events_dev#{Workslot.Worktree.suffix()}"
  '''

  @test_exs ~S'''
  import Config
  Code.require_file("worktree.exs", __DIR__)

  config :workslot, Fixture.Repo,
    hostname: "localhost",
    database: "my_app_test#{Workslot.Worktree.test_suffix()}"
  '''

  setup context do
    root = Path.join(System.tmp_dir!(), "wsclean-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    # git records real paths; resolve macOS's /var -> /private/var so paths compare equal
    {real, 0} = System.cmd("pwd", ["-P"], cd: root)
    root = String.trim(real)
    main = Path.join(root, "app")
    File.mkdir_p!(Path.join(main, "config"))

    File.write!(
      Path.join(main, "config/config.exs"),
      ~s|import Config\nimport_config "\#{config_env()}.exs"\n|
    )

    File.write!(Path.join(main, "config/dev.exs"), @dev_exs)
    File.write!(Path.join(main, "config/test.exs"), @test_exs)

    File.write!(
      Path.join(main, "config/worktree.exs"),
      context[:worktree_exs] || Install.worktree_exs()
    )

    git!(main, ["init", "-q"])
    git!(main, ["add", "."])
    git!(main, ["commit", "-q", "-m", "init"])

    start_supervised!({FakePostgres, %{}})
    Application.put_env(:workslot, :postgres, FakePostgres)
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Application.delete_env(:workslot, :postgres)
      Mix.shell(shell)
      :code.purge(Workslot.Worktree)
      :code.delete(Workslot.Worktree)
      File.rm_rf!(root)
    end)

    %{root: root, main: main}
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t" | args],
        stderr_to_stdout: true
      )

    out
  end

  # Detached, so any folder name works (a branch name cannot hold a space).
  defp add_worktree(%{root: root, main: main}, name) do
    path = Path.join(root, name)
    git!(main, ["worktree", "add", "-q", "--detach", path])
    path
  end

  # What any `mix` run in that checkout does to config: evaluate it, recording its suffixes.
  defp evaluate(path, env, partition \\ nil) do
    new_process()
    if partition, do: System.put_env("MIX_TEST_PARTITION", partition)
    conflicts = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      File.cd!(path, fn -> Config.Reader.read!("config/config.exs", env: env) end)
    after
      System.delete_env("MIX_TEST_PARTITION")
      Code.put_compiler_option(:ignore_module_conflict, conflicts)
    end
  end

  defp databases(names), do: FakePostgres.put(Map.new(names, &{&1, {1_000, 0}}))

  defp run(cwd, args) do
    new_process()
    File.cd!(cwd, fn -> Clean.run(args) end)
    output()
  end

  # Each real `mix` run is a fresh VM; here every "run" shares one, and Code.require_file/2 loads a path
  # only once — so forget the vendored files, and each checkout's config loads its own copy again.
  defp new_process do
    Code.required_files()
    |> Enum.filter(&String.ends_with?(&1, "config/worktree.exs"))
    |> Code.unrequire_files()
  end

  defp output(acc \\ []) do
    receive do
      {:mix_shell, kind, [message]} when kind in [:info, :error, :yes?] -> output([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp answer(yes?), do: send(self(), {:mix_shell_input, :yes?, yes?})

  # The first list of a listing: what removed worktrees left behind (before Held / Unregistered / Note).
  defp left_behind(out) do
    if out =~ "left behind by removed worktrees (",
      do: out |> String.split(~r/\n\n(Held|Unregistered|Note|Nothing)/) |> hd(),
      else: ""
  end

  # What the SessionStart hook does at every session: clean runs (here silently), seeing the bases and
  # marking live records for them.
  defp watch(context) do
    run(context.main, [])
    :ok
  end

  # An app whose clean has watched from the start: only `names` exist when it first sees the bases.
  defp fresh(context, names \\ ~w(my_app_dev my_app_test my_app_events_dev)) do
    databases(names)
    watch(context)
  end

  # A removed worktree `gone` (dev + test partition 2), a live worktree `feat`, a hand-made copy.
  # The worktrees are added after clean first watched, and record its bases as they evaluate config.
  defp scenario(context) do
    fresh(context, ~w(my_app_dev my_app_test my_app_events_dev my_app_dev_backup))
    feat = add_worktree(context, "feat")
    gone = add_worktree(context, "gone")
    evaluate(feat, :dev)
    evaluate(feat, :test)
    evaluate(gone, :dev)
    evaluate(gone, :test, "2")

    databases(~w(
      my_app_dev my_app_test my_app_events_dev
      my_app_dev_feat my_app_events_dev_feat my_app_test_feat
      my_app_dev_gone my_app_events_dev_gone my_app_test_gone2
      my_app_dev_backup
    ))

    git!(context.main, ["worktree", "remove", gone])

    %{feat: feat, gone: gone}
  end

  @orphans ~w(my_app_dev_gone my_app_events_dev_gone my_app_test_gone2)

  describe "listing" do
    test "reports a removed worktree's databases, apart from unregistered ones, and drops nothing",
         context do
      %{feat: feat} = scenario(context)

      for cwd <- [context.main, feat] do
        out = run(cwd, [])

        [orphans, rest] = String.split(out, "Unregistered")
        for name <- @orphans, do: assert(orphans =~ name)
        assert orphans =~ "worktree gone"
        assert rest =~ "my_app_dev_backup"

        # live and main databases, every Repo's included, are never reported
        for name <- ~w(my_app_dev_feat my_app_test_feat my_app_events_dev_feat),
            do: refute(out =~ name)

        refute out =~ ~r/my_app_events_dev\s/
        assert out =~ "Nothing dropped."
      end

      assert FakePostgres.dropped() == []
    end

    test "--only restricts the report", context do
      scenario(context)
      out = run(context.main, ["--only", "test"])
      assert out =~ "my_app_test_gone2"
      refute out =~ "my_app_dev_gone"
    end

    @tag worktree_exs: hd(Workslot.Install.Shipped.worktree_exs())
    test "under an older config/worktree.exs nothing is recorded: all unregistered, with a note",
         context do
      gone = add_worktree(context, "gone")
      evaluate(gone, :dev)
      git!(context.main, ["worktree", "remove", gone])
      databases(~w(my_app_dev my_app_dev_gone))

      out = run(context.main, [])
      assert out =~ "no databases left behind"
      assert out =~ ~r/Unregistered.*my_app_dev_gone/s
      assert out =~ "predates workslot 0.2.0"
    end

    test "a worktree created and removed before clean ever watched leaves only unregistered names",
         context do
      gone = add_worktree(context, "gone")
      evaluate(gone, :dev)
      databases(~w(my_app_dev my_app_dev_gone))
      git!(context.main, ["worktree", "remove", gone])

      out = run(context.main, [])
      assert out =~ "no databases left behind"
      assert out =~ ~r/Unregistered.*my_app_dev_gone/s
    end

    test "a worktree older than clean's first run is claimable once clean has seen it live",
         context do
      # it recorded before any base was seen, so only clean's own mark makes it eligible
      early = add_worktree(context, "early")
      evaluate(early, :dev)
      fresh(context, ~w(my_app_dev))
      databases(~w(my_app_dev my_app_dev_early))
      git!(context.main, ["worktree", "remove", early])

      assert context.main |> run([]) |> left_behind() =~ "my_app_dev_early"
    end

    test "a database already there when clean first saw its base is never claimed", context do
      # the main checkout once ran tests with MIX_TEST_PARTITION=_shard, before it recorded anything
      databases(~w(my_app_dev my_app_test my_app_test_shard))
      watch(context)

      shard = add_worktree(context, "shard")
      evaluate(shard, :test)
      watch(context)
      git!(context.main, ["worktree", "remove", shard])

      out = run(context.main, [])
      assert out =~ "no databases left behind"
      assert out =~ ~r/Unregistered.*my_app_test_shard/s
    end

    test "...even when a live worktree's suffix matches it at that first sighting", context do
      # worktree `shard` is live and recorded when clean first runs; the main checkout's old
      # `_shard` partition copy matches its suffix, which proves nothing about whose it is
      shard = add_worktree(context, "shard")
      evaluate(shard, :test)
      databases(~w(my_app_dev my_app_test my_app_test_shard))
      watch(context)
      git!(context.main, ["worktree", "remove", shard])

      out = run(context.main, [])
      assert out =~ "no databases left behind"
      assert out =~ ~r/Unregistered.*my_app_test_shard/s
    end

    test "an old record never claims a database under a base configured after its worktree was gone",
         context do
      fresh(context, ~w(my_app_dev my_app_events_dev))
      gone = add_worktree(context, "gone")
      evaluate(gone, :dev)
      # its events database stays, so the record is kept (it still names something that exists)
      databases(~w(my_app_dev my_app_events_dev my_app_dev_gone my_app_events_dev_gone))
      git!(context.main, ["worktree", "remove", gone])

      # then the app's dev database is renamed, and clean sees the new base (no clock involved)
      dev = Path.join(context.main, "config/dev.exs")

      File.write!(
        dev,
        dev |> File.read!() |> String.replace(~s|"my_app_dev\#{|, ~s|"my_app2_dev\#{|)
      )

      databases(~w(my_app2_dev my_app_events_dev my_app_events_dev_gone))
      watch(context)

      # only now does a database carrying the old worktree's suffix appear under the new name
      databases(~w(my_app2_dev my_app_events_dev my_app_events_dev_gone my_app2_dev_gone))
      out = run(context.main, [])
      [orphans, unregistered] = String.split(out, "Unregistered")
      assert orphans =~ "my_app_events_dev_gone"
      refute orphans =~ "my_app2_dev_gone"
      assert unregistered =~ "my_app2_dev_gone"
    end

    test "...nor under a base renamed away and back again (a new sighting)", context do
      fresh(context, ~w(my_app_dev my_app_events_dev))
      gone = add_worktree(context, "gone")
      evaluate(gone, :dev)
      # its events database stays, so the record is kept
      databases(~w(my_app_dev my_app_events_dev my_app_dev_gone my_app_events_dev_gone))
      git!(context.main, ["worktree", "remove", gone])

      dev = Path.join(context.main, "config/dev.exs")
      original = File.read!(dev)
      File.write!(dev, String.replace(original, ~s|"my_app_dev\#{|, ~s|"my_app2_dev\#{|))
      databases(~w(my_app2_dev my_app_events_dev my_app_events_dev_gone))
      watch(context)

      # back to the old name: seen afresh, with what is there now
      File.write!(dev, original)
      databases(~w(my_app_dev my_app_events_dev my_app_events_dev_gone))
      watch(context)
      databases(~w(my_app_dev my_app_events_dev my_app_events_dev_gone my_app_dev_gone))

      out = run(context.main, [])
      assert left_behind(out) =~ "my_app_events_dev_gone"
      refute left_behind(out) =~ "my_app_dev_gone "
      assert out =~ ~r/Unregistered.*my_app_dev_gone/s
    end

    test "...nor under the same name moved to another server, however alike the two look",
         context do
      fresh(context, ~w(my_app_dev my_app_events_dev))
      gone = add_worktree(context, "gone")
      evaluate(gone, :dev)
      databases(~w(my_app_dev my_app_events_dev my_app_dev_gone my_app_events_dev_gone))
      git!(context.main, ["worktree", "remove", gone])

      # the same "localhost:5432", but over another Unix socket: a different server
      dev = Path.join(context.main, "config/dev.exs")

      File.write!(
        dev,
        String.replace(
          File.read!(dev),
          ~s|hostname: "localhost",|,
          ~s|hostname: "localhost", socket_dir: "/tmp/other",|,
          global: false
        )
      )

      databases(~w(my_app_dev my_app_events_dev my_app_events_dev_gone))
      watch(context)
      databases(~w(my_app_dev my_app_events_dev my_app_events_dev_gone my_app_dev_gone))

      out = run(context.main, [])
      [orphans, unregistered] = String.split(out, "Unregistered")
      assert orphans =~ "my_app_events_dev_gone"
      refute orphans =~ "my_app_dev_gone"
      assert unregistered =~ "my_app_dev_gone"
    end

    test "a worktree copied by hand records nothing, so its databases are never the original's",
         context do
      fresh(context)
      feat = add_worktree(context, "feat")
      copy = Path.join(context.root, "feat-copy")
      File.cp_r!(feat, copy)
      evaluate(feat, :dev)
      evaluate(copy, :dev)
      databases(~w(my_app_dev my_app_dev_feat my_app_dev_feat_copy))
      git!(context.main, ["worktree", "remove", "--force", feat])

      out = run(context.main, [])
      [orphans, unregistered] = String.split(out, "Unregistered")
      assert orphans =~ "my_app_dev_feat "
      refute orphans =~ "my_app_dev_feat_copy"
      assert unregistered =~ "my_app_dev_feat_copy"
    end

    test "a copy whose .git is a hard link of the original's: neither records", context do
      feat = add_worktree(context, "feat")
      copy = Path.join(context.root, "feat-hl")
      File.mkdir_p!(copy)
      File.cp_r!(Path.join(feat, "config"), Path.join(copy, "config"))
      File.ln!(Path.join(feat, ".git"), Path.join(copy, ".git"))

      evaluate(copy, :dev)
      evaluate(feat, :dev)

      # once linked, the two files are one: neither the copy nor the original can be told apart, so
      # neither records (both databases stay unregistered rather than one being the other's)
      assert context.main
             |> Path.join(".git")
             |> Registry.records()
             |> Enum.reject(&(&1.id == :main)) ==
               []
    end

    test "a worktree whose repository moved away writes nothing at the old location", context do
      feat = add_worktree(context, "feat")
      moved = Path.join(context.root, "app-moved")
      File.rename!(context.main, moved)

      evaluate(feat, :dev)
      refute File.exists?(Path.join(context.main, ".git"))
      refute File.exists?(context.main)
    end
  end

  describe "dropping" do
    @tag worktree_exs: hd(Workslot.Install.Shipped.worktree_exs())
    test "until the main checkout records, nothing is dropped without being named", context do
      # the worktree branch has the new template, the main checkout still the old one
      fresh(context, ~w(my_app_dev))
      gone = add_worktree(context, "gone")
      File.write!(Path.join(gone, "config/worktree.exs"), Install.worktree_exs())
      evaluate(gone, :dev)
      databases(~w(my_app_dev my_app_dev_gone))
      git!(context.main, ["worktree", "remove", "--force", gone])

      # no base is seen before the main checkout records, so nothing is claimed yet
      out = run(context.main, [])
      assert left_behind(out) == ""
      assert out =~ ~r/Unregistered.*my_app_dev_gone/s

      assert_raise Mix.Error, ~r/does not record its databases yet/, fn ->
        run(context.main, ["--drop"])
      end

      run(context.main, ["--drop", "--yes", "my_app_dev_gone"])
      assert FakePostgres.dropped() == ["my_app_dev_gone"]
    end

    @tag worktree_exs: hd(Workslot.Install.Shipped.worktree_exs())
    test "a main-checkout partition copy made before it recorded is never claimed after it upgrades",
         context do
      # clean already runs, but the main checkout's template is still the old one
      fresh(context, ~w(my_app_dev my_app_test))

      # main runs a `_shard` partition (unrecorded); a worktree `shard` on the new template records it
      databases(~w(my_app_dev my_app_test my_app_test_shard))
      shard = add_worktree(context, "shard")
      File.write!(Path.join(shard, "config/worktree.exs"), Install.worktree_exs())
      evaluate(shard, :test)
      git!(context.main, ["worktree", "remove", "--force", shard])

      # the main checkout upgrades: clean's first sighting now holds the partition copy
      File.write!(Path.join(context.main, "config/worktree.exs"), Install.worktree_exs())
      out = run(context.main, [])
      assert left_behind(out) == ""
      assert out =~ ~r/Unregistered.*my_app_test_shard/s
    end

    test "--drop asks first and defaults to no", context do
      scenario(context)
      answer(false)
      out = run(context.main, ["--drop"])

      assert out =~ "will drop 3 databases"
      assert out =~ "nothing dropped"
      assert FakePostgres.dropped() == []
    end

    test "--drop drops the orphans — never an unregistered database — and retires the spent record",
         context do
      scenario(context)
      common = Path.join(context.main, ".git")
      assert Enum.any?(Registry.records(common), &(&1.id == "gone"))

      answer(true)
      run(context.main, ["--drop"])

      assert Enum.sort(FakePostgres.dropped()) == Enum.sort(@orphans)
      assert "my_app_dev_backup" in FakePostgres.names()
      refute Enum.any?(Registry.records(common), &(&1.id == "gone"))
    end

    test "--yes needs the names, and with them drops exactly those after listing them", context do
      scenario(context)

      assert_raise Mix.Error, ~r/--yes needs the databases named/, fn ->
        run(context.main, ["--drop", "--yes"])
      end

      out = run(context.main, ["--drop", "--yes", "my_app_dev_backup", "my_app_test_gone2"])

      # orphans first, then unregistered
      assert FakePostgres.dropped() == ["my_app_test_gone2", "my_app_dev_backup"]
      [listing, _] = String.split(out, "dropped my_app_test_gone2", parts: 2)
      assert listing =~ "will drop 2 databases"
    end

    test "a name that may not be dropped stops the run before anything is dropped", context do
      scenario(context)

      for name <- ~w(my_app_dev_feat my_app_dev my_app_events_dev other_db) do
        assert_raise Mix.Error, ~r/nothing dropped.*#{name} — not a database/s, fn ->
          run(context.main, ["--drop", "--yes", "my_app_dev_gone", name])
        end
      end

      assert FakePostgres.dropped() == []
    end

    # Not every database: the one whose DROP is already on its way goes (see the moduledoc's Limits).
    test "a worktree re-created while dropping keeps every database not yet dropped", context do
      %{gone: gone} = scenario(context)
      # right before the first drop, `git worktree add` brings worktree `gone` back
      FakePostgres.on_next_drop(fn -> add_worktree(context, "gone") end)

      out = run(context.main, ["--drop", "--yes" | @orphans])

      assert FakePostgres.dropped() == ["my_app_dev_gone"]
      assert out =~ "skipped my_app_events_dev_gone — a live checkout claims it now"
      assert File.dir?(gone)
    end

    test "a database in use is skipped, not forced", context do
      scenario(context)

      FakePostgres.put(
        Map.put(Map.new(@orphans, &{&1, {1_000, 0}}), "my_app_dev_gone", {1_000, 1})
      )

      answer(true)
      out = run(context.main, ["--drop"])

      assert out =~ "(in use — will be skipped)"
      assert out =~ "skipped my_app_dev_gone — is being accessed by other users"
      assert "my_app_dev_gone" in FakePostgres.names()
    end
  end

  describe "worktrees git still registers" do
    test "a locked worktree whose folder is gone stays live", context do
      usb = add_worktree(context, "usb")
      evaluate(usb, :dev)
      git!(context.main, ["worktree", "lock", "--reason", "external drive", usb])
      File.rm_rf!(usb)
      databases(~w(my_app_dev my_app_dev_usb))

      refute run(context.main, []) =~ "my_app_dev_usb"
    end

    test "an unlocked one deleted by hand is held until `git worktree prune`", context do
      fresh(context, ~w(my_app_dev))
      lost = add_worktree(context, "lost")
      evaluate(lost, :dev)
      databases(~w(my_app_dev my_app_dev_lost))
      File.rm_rf!(lost)

      assert run(context.main, []) =~ ~r/Held.*my_app_dev_lost/s

      assert_raise Mix.Error, ~r/git worktree prune/, fn ->
        run(context.main, ["--drop", "--yes", "my_app_dev_lost"])
      end

      git!(context.main, ["worktree", "prune"])
      run(context.main, ["--drop", "--yes", "my_app_dev_lost"])
      assert FakePostgres.dropped() == ["my_app_dev_lost"]
    end

    test "a moved worktree keeps every name it ever derived live", context do
      before = add_worktree(context, "spike")
      evaluate(before, :dev)
      moved = Path.join(context.root, "spike two")
      git!(context.main, ["worktree", "move", before, moved])
      evaluate(moved, :dev)
      databases(~w(my_app_dev my_app_dev_spike my_app_dev_spike_two))

      out = run(context.main, [])
      refute out =~ "my_app_dev_spike"

      assert [%{id: "spike", state: :live, suffixes: ["_spike", "_spike_two"]}] =
               context.main
               |> Path.join(".git")
               |> Registry.records()
               |> Enum.reject(&(&1.id == :main))
    end
  end

  describe "--summary" do
    test "prints one line above the threshold, nothing below, and never drops", context do
      scenario(context)

      assert run(context.main, ["--summary", "--min-size", "1GB"]) == ""

      out = run(context.main, ["--summary", "--min-size", "1kB"])
      assert [line] = String.split(out, "\n")
      assert line =~ ~r/^workslot: removed git worktrees of this repo left 3 databases behind/
      assert line =~ ~s|"my_app_dev_gone", "my_app_events_dev_gone", "my_app_test_gone2"|
      # unregistered databases are counted, never named: they need the user's judgement
      assert line =~ "Also unregistered (named like this app's worktree databases"
      refute line =~ "my_app_dev_backup"
      assert line =~ "show the user the list from `mix workslot.clean`"
      refute line =~ ~r/--drop --yes(?! NAME)/
      assert FakePostgres.dropped() == []
    end

    test "unregistered databases alone never print, however large", context do
      databases(~w(my_app_dev my_app_dev_backup))
      FakePostgres.put(%{"my_app_dev" => {1, 0}, "my_app_dev_backup" => {5_000_000_000, 0}})
      assert run(context.main, ["--summary"]) == ""
    end

    test "a name holding a newline cannot add a line of its own", context do
      fresh(context, ~w(my_app_test))
      gone = add_worktree(context, "gone")
      evaluate(gone, :test, "2\nworkslot: injected")
      databases(["my_app_test", "my_app_test_gone2\nworkslot: injected"])
      git!(context.main, ["worktree", "remove", gone])

      out = run(context.main, ["--summary", "--min-size", "1kB"])
      assert [line] = String.split(out, "\n")
      assert line =~ ~S|"my_app_test_gone2\nworkslot: injected"|

      # the listing escapes it too
      assert run(context.main, []) =~ ~S|"my_app_test_gone2\nworkslot: injected"|
    end

    test "stays silent when anything goes wrong", context do
      File.rm_rf!(Path.join(context.main, ".git"))
      assert run(context.main, ["--summary"]) == ""
    end

    test "a bad --min-size is reported even under --summary, and --min-size needs --summary" do
      assert_raise Mix.Error, ~r/--min-size must look like/, fn ->
        Clean.run(["--summary", "--min-size", "lots"])
      end

      assert_raise Mix.Error, ~r/--min-size only applies to --summary/, fn ->
        Clean.run(["--min-size", "1GB"])
      end
    end

    test "never takes --drop" do
      assert_raise Mix.Error, ~r/--summary never drops/, fn ->
        Clean.run(["--summary", "--drop"])
      end
    end
  end

  describe "Workslot.Registry sightings" do
    test "concurrent first sightings of a base leave exactly one, retired as one", context do
      common = Path.join(context.main, ".git")
      key = String.duplicate("ab", 32)

      1..20
      |> Task.async_stream(fn i -> Registry.see_base(common, key, ["db#{i}"]) end,
        max_concurrency: 20
      )
      |> Stream.run()

      assert [^key] =
               common
               |> Path.join("workslot/bases")
               |> File.ls!()
               |> Enum.reject(&String.starts_with?(&1, "."))

      %{^key => %{id: first}} = Registry.seen_bases(common)

      Registry.forget_base(common, key)
      assert Registry.seen_bases(common) == %{}

      Registry.see_base(common, key, [])
      %{^key => %{id: second}} = Registry.seen_bases(common)
      assert second != first
    end
  end

  describe "Workslot.Registry sightings, damaged" do
    test "an empty sighting file is no sighting, and seeing the base replaces it", context do
      common = Path.join(context.main, ".git")
      key = String.duplicate("cd", 32)
      File.mkdir_p!(Path.join(common, "workslot/bases"))
      File.write!(Path.join(common, "workslot/bases/#{key}"), "")

      assert Registry.seen_bases(common) == %{}

      Registry.see_base(common, key, ["x"])
      assert %{^key => %{preexisting: preexisting}} = Registry.seen_bases(common)
      assert MapSet.to_list(preexisting) == ["x"]
      assert common |> Path.join("workslot/bases") |> File.ls!() == [key]
    end
  end

  describe "Workslot.Registry.forget/1" do
    test "keeps a record whose worktree git registers again since it was read as gone", context do
      feat = add_worktree(context, "feat")
      evaluate(feat, :dev)
      git!(context.main, ["worktree", "remove", feat])
      common = Path.join(context.main, ".git")

      [stale] = common |> Registry.records() |> Enum.filter(&(&1.state == :gone))
      add_worktree(context, "feat")

      Registry.forget(stale)
      assert File.dir?(stale.dir)

      git!(context.main, ["worktree", "remove", feat])
      Registry.forget(stale)
      refute File.dir?(stale.dir)
    end
  end

  describe "Workslot.Registry.locate/1" do
    test "finds the main checkout from a worktree, and refuses a bare repository", context do
      feat = add_worktree(context, "with space")
      common = Path.join(context.main, ".git")

      assert Registry.locate(feat) == {:ok, %{common: common, main: context.main}}
      assert Registry.locate(context.main) == {:ok, %{common: common, main: context.main}}

      bare = Path.join(context.root, "bare.git")
      git!(context.main, ["clone", "-q", "--bare", context.main, bare])
      linked = Path.join(context.root, "from-bare")
      git!(bare, ["worktree", "add", "-q", linked])

      assert Registry.locate(linked) == {:error, :bare}
      assert Registry.locate(context.root) == {:error, :not_git}
    end

    test "a worktree left pointing at a repository that moved gets a clear message", context do
      feat = add_worktree(context, "feat")
      File.rename!(context.main, Path.join(context.root, "app-moved"))

      assert_raise Mix.Error, ~r/no longer exists.*git worktree repair/, fn -> run(feat, []) end
    end
  end
end
