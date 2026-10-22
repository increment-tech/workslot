defmodule Workslot.CleanTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Workslot.Clean, as: Task
  alias Workslot.Clean

  # every base key below: a record made by the helper may claim through any of them
  @every_base MapSet.new([
                "dev foo a",
                "dev my_app_dev a",
                "dev my_app_dev_events a",
                "test foo_test a",
                "test foo_test b",
                "test my_app_test a",
                "test my_app_test b"
              ])

  @bases [
    %{
      kind: :dev,
      name: "my_app_dev",
      server: :a,
      key: "dev my_app_dev a",
      preexisting: MapSet.new()
    },
    %{
      kind: :test,
      name: "my_app_test",
      server: :a,
      key: "test my_app_test a",
      preexisting: MapSet.new()
    }
  ]

  # `dev` suffixes as suffix/1 records them, `test` as test_suffix/1 does (by default the same ones).
  defp record(id, state, dev, test \\ nil),
    do: %{
      id: id,
      state: state,
      path: "/w/#{id}",
      suffixes: dev,
      test_suffixes: test || dev,
      bases: @every_base,
      dir: "/r/#{id}"
    }

  defp main(test \\ [""]), do: %{record(:main, :live, [""], test) | path: "/w/main"}

  defp existing(names, server \\ :a), do: %{server => Map.new(names, &{&1, {1_000, 0}})}

  defp groups(plan), do: Map.new(plan, &{&1.name, &1.group})

  describe "plan/4" do
    test "a removed worktree's databases — every recorded partition copy — are orphans" do
      records = [main(), record("gone", :gone, ["_gone"], ["_gone", "_gone2"])]
      names = ~w(my_app_dev_gone my_app_test_gone my_app_test_gone2)

      assert groups(Clean.plan(@bases, records, existing(names))) == %{
               "my_app_dev_gone" => :orphan,
               "my_app_test_gone" => :orphan,
               "my_app_test_gone2" => :orphan
             }
    end

    test "a live checkout's databases and the bases themselves are never reported" do
      records = [main(["", "1", "_shard"]), record("feat", :live, ["_feat"], ["_feat", "_feat3"])]

      names =
        ~w(my_app_dev my_app_test my_app_test1 my_app_test_shard my_app_dev_feat my_app_test_feat3)

      assert Clean.plan(@bases, records, existing(names)) == []
    end

    test "a name no record derived is unregistered, however it looks" do
      records = [main(), record("feat", :live, ["_feat"])]

      # a hand-made copy, another clone's worktree, a pre-0.2.0 orphan — no record names any of them
      names = ~w(my_app_dev_backup my_app_dev_feat_old my_app_test_e2e)

      assert groups(Clean.plan(@bases, records, existing(names))) == %{
               "my_app_dev_backup" => :unregistered,
               "my_app_dev_feat_old" => :unregistered,
               "my_app_test_e2e" => :unregistered
             }
    end

    test "names outside the <base>_ shape are left out entirely" do
      names = ~w(my_app_devtools my_app_test1 my_app_testing other_dev)
      assert Clean.plan(@bases, [main()], existing(names)) == []
    end

    test "live wins over gone, and held over gone, when two records derive one name" do
      records = [
        main(),
        record("old", :gone, ["_feat", "_spike"]),
        record("feat", :live, ["_feat"]),
        record("spike", :held, ["_spike"])
      ]

      plan = Clean.plan(@bases, records, existing(~w(my_app_dev_feat my_app_dev_spike)))
      assert groups(plan) == %{"my_app_dev_spike" => :held}
    end

    test "every Repo's base is protected, so a second Repo's own database is never a worktree's" do
      bases =
        @bases ++
          [
            %{
              kind: :dev,
              name: "my_app_dev_events",
              server: :a,
              key: "dev my_app_dev_events a",
              preexisting: MapSet.new()
            }
          ]

      records = [main(), record("events", :gone, ["_events"])]

      # `my_app_dev` + `_events` is the second Repo's main database, not worktree `events`'s
      assert Clean.plan(bases, records, existing(~w(my_app_dev_events))) == []

      # ...even when the main checkout recorded nothing (its config/worktree.exs predates recording)
      without_main = [record("events", :gone, ["_events"])]
      assert Clean.plan(bases, without_main, existing(~w(my_app_dev_events))) == []
    end

    test "a database is matched on its own base's server only" do
      bases = [
        %{
          kind: :dev,
          name: "my_app_dev",
          server: :a,
          key: "dev my_app_dev a",
          preexisting: MapSet.new()
        },
        %{
          kind: :test,
          name: "my_app_test",
          server: :b,
          key: "test my_app_test b",
          preexisting: MapSet.new()
        }
      ]

      records = [main(), record("gone", :gone, ["_gone"])]
      existing = Map.merge(existing(~w(my_app_dev_gone)), existing(~w(my_app_test_gone), :b))

      assert [%{name: "my_app_dev_gone", server: :a}, %{name: "my_app_test_gone", server: :b}] =
               Clean.plan(bases, records, existing)
    end

    test "a suffix derives only its own kind's names, and only on that base's server" do
      # a test partition suffix (`_gone2`) never derives a dev database
      records = [main(), record("gone", :gone, ["_gone"], ["_gone", "_gone2"])]

      assert groups(Clean.plan(@bases, records, existing(~w(my_app_dev_gone2)))) == %{
               "my_app_dev_gone2" => :unregistered
             }

      # dev base `foo` on :a, test base `foo_test` on :b: another app's `foo_test_gone` on :a is not
      # worktree gone's test database, which would live on :b
      bases = [
        %{kind: :dev, name: "foo", server: :a, key: "dev foo a", preexisting: MapSet.new()},
        %{
          kind: :test,
          name: "foo_test",
          server: :b,
          key: "test foo_test b",
          preexisting: MapSet.new()
        }
      ]

      plan =
        Clean.plan(bases, [main(), record("gone", :gone, ["_gone"])], existing(~w(foo_test_gone)))

      assert [%{name: "foo_test_gone", server: :a, kind: :dev, group: :unregistered}] = plan
    end

    test "names are cut at Postgres's 63-byte identifier limit, as Postgres stores them" do
      slug = "_" <> String.duplicate("a", 60)
      stored = binary_part("my_app_dev" <> slug, 0, 63)

      gone = [main(), record("long", :gone, [slug])]
      assert groups(Clean.plan(@bases, gone, existing([stored]))) == %{stored => :orphan}

      live = [main(), record("long", :live, [slug])]
      assert Clean.plan(@bases, live, existing([stored])) == []
    end

    test "kinds restricts what is reported, while every base still decides what is live" do
      # dev base `foo`, test base `foo_test`: `foo_test_feat` is live worktree feat's test database
      bases = [
        %{kind: :dev, name: "foo", server: :a, key: "dev foo a", preexisting: MapSet.new()},
        %{
          kind: :test,
          name: "foo_test",
          server: :a,
          key: "test foo_test a",
          preexisting: MapSet.new()
        }
      ]

      records = [main(), record("feat", :live, ["_feat"]), record("gone", :gone, ["_gone"])]
      existing = existing(~w(foo_test_feat foo_gone foo_test_gone))

      # `foo_test_gone` is worktree gone's TEST database, so --only dev never offers it
      assert groups(Clean.plan(bases, records, existing, kinds: [:dev])) == %{
               "foo_gone" => :orphan
             }

      assert [%{name: "foo_test_gone", kind: :test}] =
               Clean.plan(bases, records, existing, kinds: [:test])

      # an unregistered name goes to the longest base it starts with, so --only test finds it
      backup = existing(~w(foo_test_backup))
      assert [%{kind: :test}] = Clean.plan(bases, [main()], backup, kinds: [:test])
      assert Clean.plan(bases, [main()], backup, kinds: [:dev]) == []
    end

    test "a worktree git lists keeps its default-named databases even without a record" do
      # an un-upgraded config/worktree.exs: nothing recorded, so these would be unregistered
      names =
        ~w(my_app_dev_feat my_app_dev_feat_old my_app_test_feat my_app_test_feat2 my_app_test_feat_old
           my_app_dev_x)

      plan = Clean.plan(@bases, [], existing(names), live_slugs: ["feat"])

      # dev names exactly, test names exactly or with a numeric partition; nothing else
      assert groups(plan) == %{
               "my_app_dev_feat_old" => :unregistered,
               "my_app_test_feat_old" => :unregistered,
               "my_app_dev_x" => :unregistered
             }

      # it outranks a stale record of a removed worktree with the same folder name...
      gone = [record("feat", :gone, ["_feat"])]
      assert Clean.plan(@bases, gone, existing(~w(my_app_dev_feat)), live_slugs: ["feat"]) == []

      # ...but never hides a removed worktree whose name merely starts with a live one's
      gone_old = [main(), record("feat_old", :gone, ["_feat_old"])]
      existing = existing(~w(my_app_dev_feat_old my_app_test_feat_old))

      assert groups(Clean.plan(@bases, gone_old, existing, live_slugs: ["feat"])) == %{
               "my_app_dev_feat_old" => :orphan,
               "my_app_test_feat_old" => :orphan
             }
    end

    test "a removed worktree's record claims only through bases it is marked for, never a snapshot name" do
      names = ~w(my_app_dev_gone my_app_test_gone)

      # marked for the dev base only: its test database is not its to claim
      only_dev = %{record("gone", :gone, ["_gone"]) | bases: MapSet.new(["dev my_app_dev a"])}

      assert groups(Clean.plan(@bases, [main(), only_dev], existing(names))) == %{
               "my_app_dev_gone" => :orphan,
               "my_app_test_gone" => :unregistered
             }

      # a name that was already there when clean first saw the base is never claimed
      [dev, test] = @bases
      snapshot = [%{dev | preexisting: MapSet.new(["my_app_dev_gone"])}, test]
      plan = Clean.plan(snapshot, [main(), record("gone", :gone, ["_gone"])], existing(names))
      assert groups(plan) == %{"my_app_dev_gone" => :unregistered, "my_app_test_gone" => :orphan}

      # a base clean has not seen yet claims nothing
      unseen = Enum.map(@bases, &%{&1 | preexisting: nil})
      plan = Clean.plan(unseen, [main(), record("gone", :gone, ["_gone"])], existing(names))
      assert Enum.all?(plan, &(&1.group == :unregistered))
    end

    test "orphans come first, then held, then unregistered, each sorted by name" do
      records = [
        main(),
        record("b", :gone, ["_b"]),
        record("a", :gone, ["_a"]),
        record("h", :held, ["_h"])
      ]

      names = ~w(my_app_dev_zz my_app_dev_h my_app_dev_b my_app_dev_a)

      assert Enum.map(Clean.plan(@bases, records, existing(names)), & &1.name) ==
               ~w(my_app_dev_a my_app_dev_b my_app_dev_h my_app_dev_zz)
    end

    test "an orphan is labelled with the folder its worktree had" do
      records = [main(), record("feat1", :gone, ["_feat"])]
      assert [%{worktree: "feat1"}] = Clean.plan(@bases, records, existing(~w(my_app_dev_feat)))
    end
  end

  describe "derived_names/2" do
    test "every base with every suffix of either kind (broad, so a record is kept while in doubt)" do
      assert Clean.derived_names(@bases, record("x", :gone, ["_x"], ["_x2"])) == [
               {:a, "my_app_dev_x"},
               {:a, "my_app_dev_x2"},
               {:a, "my_app_test_x"},
               {:a, "my_app_test_x2"}
             ]
    end
  end

  describe "the task's size helpers" do
    test "parse_size!/1 reads human sizes" do
      assert Task.parse_size!("2GB") == 2_000_000_000
      assert Task.parse_size!("500mb") == 500_000_000
      assert Task.parse_size!("1.5 GB") == 1_500_000_000
      assert Task.parse_size!("1024") == 1024
      assert_raise Mix.Error, fn -> Task.parse_size!("lots") end
    end

    test "human/1 formats bytes" do
      assert Task.human(3_400_000_000) == "3.4 GB"
      assert Task.human(91_000_000) == "91 MB"
      assert Task.human(8192) == "8 kB"
    end
  end
end
