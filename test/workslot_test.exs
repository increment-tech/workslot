defmodule WorkslotTest do
  use ExUnit.Case, async: false

  # Build a fake checkout dir whose `.git` is a directory (main) or a linked-worktree pointer
  # file (`gitdir: .../worktrees/<name>`, the shape `worktree?/1` keys off), with a unique name.
  defp main_dir(name) do
    dir = Path.join(System.tmp_dir!(), "pwt-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".git"))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp worktree_dir(name) do
    dir = Path.join(System.tmp_dir!(), "pwt-#{name}-#{System.unique_integer([:positive])}")
    make_worktree(dir, name)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A checkout with a *controlled* basename, under a unique parent — so two of them can share a
  # folder name (to exercise collisions and parity across name shapes).
  defp worktree_with_base(base), do: with_base(base, :worktree)
  defp main_with_base(base), do: with_base(base, :main)

  defp with_base(base, kind) do
    parent = Path.join(System.tmp_dir!(), "pwt-#{System.unique_integer([:positive])}")
    dir = Path.join(parent, base)

    case kind do
      :worktree -> make_worktree(dir, base)
      :main -> File.mkdir_p!(Path.join(dir, ".git"))
    end

    on_exit(fn -> File.rm_rf!(parent) end)
    dir
  end

  defp make_worktree(dir, name) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".git"), "gitdir: /repo/.git/worktrees/#{name}\n")
    dir
  end

  # Two real worktree dirs whose *paths* hash to the same `dev_port`. `phash2(path, 999)` has only
  # 999 buckets, so a colliding pair of basenames must exist within 1000 candidates (pigeonhole).
  defp port_colliding_worktrees do
    parent = Path.join(System.tmp_dir!(), "pwtport-#{System.unique_integer([:positive])}")
    {a, b} = colliding_basenames(parent)
    on_exit(fn -> File.rm_rf!(parent) end)
    {make_worktree(Path.join(parent, a), a), make_worktree(Path.join(parent, b), b)}
  end

  defp colliding_basenames(parent) do
    Enum.reduce_while(0..2000, %{}, fn i, seen ->
      name = "wtp#{i}"
      bucket = :erlang.phash2(Path.join(parent, name), 999)

      case seen do
        %{^bucket => prev} -> {:halt, {prev, name}}
        _ -> {:cont, Map.put(seen, bucket, name)}
      end
    end)
  end

  # Compile the vendored `config/worktree.exs` once for the whole run and hand its module to
  # every test via context, so there is no per-test recompile (no "redefining module" warning).
  setup_all do
    [{vendored, _}] = Code.compile_string(Workslot.Install.worktree_exs())
    on_exit(fn -> :code.purge(vendored) && :code.delete(vendored) end)
    %{vendored: vendored}
  end

  # Compare the vendored `Workslot.Worktree` (compiled at runtime) against `Workslot` via apply/3,
  # so the compiler doesn't warn about a module it can't see at compile time.
  defp assert_parity(vendored, fun, arg) do
    assert apply(vendored, fun, [arg]) == apply(Workslot, fun, [arg]),
           "#{fun} mismatch for #{inspect(arg)}"
  end

  describe "detection" do
    test "a linked-worktree .git pointer is a worktree; a .git directory is not" do
      assert Workslot.worktree?(worktree_dir("wt"))
      refute Workslot.worktree?(main_dir("main"))
    end

    test "a submodule (.git points into /modules/) is not treated as a worktree" do
      dir = Path.join(System.tmp_dir!(), "pwt-sub-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".git"), "gitdir: /repo/.git/modules/sub\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      refute Workslot.worktree?(dir)
      assert Workslot.slug(dir) == nil
    end

    test "a submodule located under a dir named 'worktrees' is still not a worktree" do
      dir = Path.join(System.tmp_dir!(), "pwt-subwt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".git"), "gitdir: /repo/.git/modules/worktrees/foo\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      refute Workslot.worktree?(dir)
    end

    test "a plain non-git directory is not treated as a worktree" do
      dir = Path.join(System.tmp_dir!(), "pwt-plain-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      refute Workslot.worktree?(dir)
      assert Workslot.slug(dir) == nil
      assert Workslot.suffix(dir) == ""
      assert Workslot.dev_port(dir) == 4000
    end
  end

  describe "main checkout" do
    test "has no slug, empty suffix, port 4000" do
      dir = main_dir("Main")
      refute Workslot.worktree?(dir)
      assert Workslot.slug(dir) == nil
      assert Workslot.suffix(dir) == ""
      assert Workslot.dev_port(dir) == 4000
    end
  end

  describe "linked worktree" do
    test "derives a sanitized slug from the folder name" do
      dir = worktree_dir("Feature-X.2")
      assert Workslot.worktree?(dir)
      # "pwt-Feature-X.2-<n>" downcased, non-alnum -> "_", trimmed
      assert Workslot.slug(dir) =~ ~r/^pwt_feature_x_2_\d+$/
      assert Workslot.suffix(dir) == "_" <> Workslot.slug(dir)
    end

    test "an all-symbol folder name falls back to a stable hash slug, not empty" do
      dir = worktree_with_base("---")
      slug = Workslot.slug(dir)
      assert slug =~ ~r/^wt[a-z0-9]+$/
      assert Workslot.suffix(dir) == "_" <> slug
      # deterministic for the same path
      assert Workslot.slug(dir) == slug
    end

    test "dev_port is stable in 4001..4999 and deterministic per path" do
      dir = worktree_dir("port")
      p = Workslot.dev_port(dir)
      assert p in 4001..4999
      assert Workslot.dev_port(dir) == p
    end

    test "PORT env overrides everything" do
      dir = worktree_dir("override")
      System.put_env("PORT", "4555")
      on_exit(fn -> System.delete_env("PORT") end)
      assert Workslot.dev_port(dir) == 4555
      assert Workslot.dev_port(main_dir("override2")) == 4555
    end

    test "dev_port raises a clear error when PORT is set but not an integer" do
      dir = worktree_dir("badport")
      System.put_env("PORT", "nope")
      on_exit(fn -> System.delete_env("PORT") end)

      assert_raise RuntimeError, ~r/PORT="nope" must be an integer in 1\.\.65535/, fn ->
        Workslot.dev_port(dir)
      end
    end

    test "dev_port raises when PORT is out of range" do
      dir = worktree_dir("rangeport")
      System.put_env("PORT", "70000")
      on_exit(fn -> System.delete_env("PORT") end)

      assert_raise RuntimeError, ~r/must be an integer in 1\.\.65535/, fn ->
        Workslot.dev_port(dir)
      end
    end
  end

  describe "dev_port WORKSLOT_PORT_RANGE band" do
    test "places the worktree port inside the configured inclusive range" do
      dir = worktree_dir("banded")
      System.put_env("WORKSLOT_PORT_RANGE", "10000-10999")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)

      p = Workslot.dev_port(dir)
      assert p in 10000..10999
      # deterministic for the same path
      assert Workslot.dev_port(dir) == p
    end

    test "a one-port range pins every worktree to that single port" do
      dir = worktree_dir("single")
      System.put_env("WORKSLOT_PORT_RANGE", "12345-12345")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)
      assert Workslot.dev_port(dir) == 12345
    end

    test "the main checkout ignores the range and stays on 4000" do
      dir = main_dir("mainband")
      System.put_env("WORKSLOT_PORT_RANGE", "10000-10999")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)
      assert Workslot.dev_port(dir) == 4000
    end

    test "PORT still wins over the range" do
      dir = worktree_dir("portwins")
      System.put_env("WORKSLOT_PORT_RANGE", "10000-10999")
      System.put_env("PORT", "4555")

      on_exit(fn ->
        System.delete_env("WORKSLOT_PORT_RANGE")
        System.delete_env("PORT")
      end)

      assert Workslot.dev_port(dir) == 4555
    end

    test "raises a clear error on a malformed range" do
      dir = worktree_dir("badrange")
      System.put_env("WORKSLOT_PORT_RANGE", "10000..10999")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)

      assert_raise RuntimeError, ~r/WORKSLOT_PORT_RANGE=.* must be/, fn ->
        Workslot.dev_port(dir)
      end
    end

    test "raises when from > to" do
      dir = worktree_dir("inverted")
      System.put_env("WORKSLOT_PORT_RANGE", "10999-10000")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)

      assert_raise RuntimeError, ~r/1 <= from <= to/, fn -> Workslot.dev_port(dir) end
    end

    test "raises when an endpoint is out of the 1..65535 range" do
      dir = worktree_dir("oob")
      System.put_env("WORKSLOT_PORT_RANGE", "10000-70000")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)

      assert_raise RuntimeError, ~r/WORKSLOT_PORT_RANGE/, fn -> Workslot.dev_port(dir) end
    end
  end

  describe "test_suffix" do
    test "composes the worktree suffix with MIX_TEST_PARTITION" do
      dir = worktree_dir("part")
      prev = System.get_env("MIX_TEST_PARTITION")
      System.put_env("MIX_TEST_PARTITION", "3")

      on_exit(fn ->
        if prev,
          do: System.put_env("MIX_TEST_PARTITION", prev),
          else: System.delete_env("MIX_TEST_PARTITION")
      end)

      assert Workslot.test_suffix(dir) == Workslot.suffix(dir) <> "3"
    end
  end

  describe "verify! folder-name collision detection" do
    test "slug_collision returns the cohort when >1 live worktree shares the slug" do
      a = worktree_with_base("feature-x")
      b = worktree_with_base("feature-x")

      assert Workslot.slug_collision(a, [a, b]) == [a, b]
      assert Workslot.slug_collision(a, [a]) == nil
    end

    test "slug_collision is symlink-safe: one self-entry under a different path string is not a collision" do
      # git reports the canonical path; the caller may hold a symlinked spelling of the same dir.
      # Counting (not excluding self by string) means that single worktree is not a false collision.
      real = worktree_with_base("feature-x")
      link_parent = Path.join(System.tmp_dir!(), "pwtlink-#{System.unique_integer([:positive])}")
      File.ln_s!(Path.dirname(real), link_parent)
      on_exit(fn -> File.rm_rf!(link_parent) end)
      aliased = Path.join(link_parent, "feature-x")

      assert Workslot.slug_collision(aliased, [real]) == nil
    end

    test "slug_collision flags names differing only by characters the slug collapses" do
      # git permits worktree ids "feature-x" and "feature_x"; both sanitize to slug "feature_x".
      a = worktree_with_base("feature-x")
      b = worktree_with_base("feature_x")
      assert Workslot.slug_collision(a, [a, b]) == [a, b]
    end

    test "do_verify! raises loudly on a folder-name collision" do
      a = worktree_with_base("dupe")
      b = worktree_with_base("dupe")

      assert_raise RuntimeError, ~r/folder-name collision/, fn ->
        Workslot.do_verify!(a, [a, b])
      end
    end

    test "do_verify! is a no-op when nothing collides" do
      main = main_with_base("app")
      assert Workslot.do_verify!(main, [main]) == :ok
    end

    test "verify! degrades to :ok outside a real git repo" do
      # `.git` is a fake pointer file, so `git -C <dir> worktree list` fails -> :ok, no crash.
      assert Workslot.verify!(worktree_with_base("nogit")) == :ok
    end

    test "verify! is a no-op when root is not a linked worktree" do
      assert Workslot.verify!(main_dir("plainmain")) == :ok
    end
  end

  describe "verify! dev-port collision (deterministic, no socket probe)" do
    test "port_collision returns the cohort when two live worktrees hash to the same port" do
      {a, b} = port_colliding_worktrees()
      assert Workslot.dev_port(a) == Workslot.dev_port(b)
      assert Workslot.port_collision(a, [a, b]) == [a, b]
      assert Workslot.port_collision(a, [a]) == nil
    end

    test "do_verify! raises on a real dev-port collision" do
      {a, b} = port_colliding_worktrees()

      assert_raise RuntimeError, ~r/dev-port collision/, fn ->
        Workslot.do_verify!(a, [a, b])
      end
    end

    test "an explicit PORT is a deliberate shared choice and is never flagged" do
      {a, b} = port_colliding_worktrees()
      System.put_env("PORT", "4600")
      on_exit(fn -> System.delete_env("PORT") end)
      assert Workslot.port_collision(a, [a, b]) == nil
    end

    test "a bound dev port alone does NOT trip verify! — no socket is ever probed" do
      # Regression guard: verify! must not raise just because this worktree's own server (or any
      # other dev mix task) is bound to the port. Only a *different* live worktree on the same
      # hashed port is a real conflict.
      dir = worktree_dir("solo")
      port = Workslot.dev_port(dir)
      {:ok, sock} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(sock) end)

      assert Workslot.do_verify!(dir, [dir]) == :ok
    end
  end

  describe "vendored config/worktree.exs parity" do
    test "compiles to a Workslot.Worktree module matching Workslot for every function and name shape",
         %{vendored: vendored} do
      assert vendored == Workslot.Worktree

      for base <- [
            "Feature-X",
            "ALLCAPS",
            "with.dots",
            "weird!!!chars",
            "---",
            "a.b.c",
            "ünïcode"
          ] do
        wt = worktree_with_base(base)
        main = main_with_base(base)

        for fun <- [:slug, :suffix, :test_suffix, :dev_port] do
          assert_parity(vendored, fun, wt)
          assert_parity(vendored, fun, main)
        end
      end
    end

    test "both raise on a non-integer PORT", %{vendored: vendored} do
      dir = worktree_with_base("badport")
      System.put_env("PORT", "xyz")
      on_exit(fn -> System.delete_env("PORT") end)

      assert_raise RuntimeError, fn -> Workslot.dev_port(dir) end
      assert_raise RuntimeError, fn -> apply(vendored, :dev_port, [dir]) end
    end

    test "both honor WORKSLOT_PORT_RANGE identically", %{vendored: vendored} do
      dir = worktree_with_base("bandparity")
      System.put_env("WORKSLOT_PORT_RANGE", "20000-20999")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)

      assert apply(vendored, :dev_port, [dir]) == Workslot.dev_port(dir)
      assert Workslot.dev_port(dir) in 20000..20999
    end

    test "both raise on a malformed WORKSLOT_PORT_RANGE", %{vendored: vendored} do
      dir = worktree_with_base("badrangeparity")
      System.put_env("WORKSLOT_PORT_RANGE", "nope")
      on_exit(fn -> System.delete_env("WORKSLOT_PORT_RANGE") end)

      assert_raise RuntimeError, fn -> Workslot.dev_port(dir) end
      assert_raise RuntimeError, fn -> apply(vendored, :dev_port, [dir]) end
    end
  end

  describe "install patches (phx.new default shapes)" do
    @dev """
    import Config

    config :my_app, MyApp.Repo,
      username: "postgres",
      database: "my_app_dev",
      pool_size: 10

    config :my_app, MyAppWeb.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: 4000],
      code_reloader: true
    """

    @test """
    import Config

    config :my_app, MyApp.Repo,
      username: "postgres",
      database: "my_app_test\#{System.get_env("MIX_TEST_PARTITION")}",
      pool: Ecto.Adapters.SQL.Sandbox
    """

    test "patch_dev rewrites database + port and adds the require, no manual edits" do
      {out, manual} = Workslot.Install.patch_dev(@dev, "my_app")
      assert manual == []
      assert out =~ ~s|Code.require_file("worktree.exs", __DIR__)|
      assert out =~ ~s|database: "my_app_dev\#{Workslot.Worktree.suffix()}"|
      assert out =~ "port: Workslot.Worktree.dev_port()"
      refute out =~ "port: 4000"
    end

    test "patch_test folds MIX_TEST_PARTITION into test_suffix" do
      {out, manual} = Workslot.Install.patch_test(@test, "my_app")
      assert manual == []
      assert out =~ ~s|database: "my_app_test\#{Workslot.Worktree.test_suffix()}"|
      refute out =~ ~s|System.get_env("MIX_TEST_PARTITION")|
    end

    test "patch_test handles a plain _test database with no partition interpolation" do
      plain = ~s|import Config\n\nconfig :my_app, MyApp.Repo, database: "my_app_test"\n|
      {out, manual} = Workslot.Install.patch_test(plain, "my_app")
      assert manual == []
      assert out =~ ~s|database: "my_app_test\#{Workslot.Worktree.test_suffix()}"|
    end

    test "patches are idempotent" do
      {once, []} = Workslot.Install.patch_dev(@dev, "my_app")
      {twice, manual} = Workslot.Install.patch_dev(once, "my_app")
      assert manual == []
      assert once == twice
    end

    test "an unfamiliar shape degrades to a manual-edit note instead of guessing" do
      weird = "import Config\nconfig :my_app, MyApp.Repo, database: \"custom_name\"\n"
      {out, manual} = Workslot.Install.patch_dev(weird, "my_app")
      assert out =~ ~s|Code.require_file("worktree.exs", __DIR__)|
      assert Enum.any?(manual, &(&1 =~ "config/dev.exs"))
    end

    test "a non-Endpoint list ending in `port: 4000]` is left alone (anchored on the full http shape)" do
      # Only the exact phx.new Endpoint http shape is rewritten; any other `port: 4000` — even one
      # ending a keyword list — is left alone and degrades to a manual note.
      weird = ~s|import Config\nconfig :my_app, :some_listener, opts: [host: "x", port: 4000]\n|
      {out, manual} = Workslot.Install.patch_dev(weird, "my_app")
      assert out =~ "port: 4000]"
      refute out =~ "Workslot.Worktree.dev_port"
      assert Enum.any?(manual, &(&1 =~ "Endpoint http"))
    end
  end

  describe "install: runtime.exs verify! wiring" do
    @runtime "import Config\n\nconfig :my_app, MyAppWeb.Endpoint, server: true\n"

    test "patch_runtime inserts a dev-guarded verify! call after import Config" do
      {out, manual} = Workslot.Install.patch_runtime(@runtime)
      assert manual == []
      assert out =~ "Workslot.verify!()"
      assert out =~ "config_env() == :dev"

      [before, _after] = String.split(out, "Workslot.verify!()", parts: 2)
      assert before =~ "import Config"
    end

    test "patch_runtime is idempotent" do
      {once, []} = Workslot.Install.patch_runtime(@runtime)
      {twice, manual} = Workslot.Install.patch_runtime(once)
      assert manual == []
      assert once == twice
    end

    test "patch_runtime degrades to a manual note when there is no import Config" do
      {out, manual} = Workslot.Install.patch_runtime("# weird runtime\n")
      assert out == "# weird runtime\n"
      assert Enum.any?(manual, &(&1 =~ "runtime.exs"))
    end
  end
end
