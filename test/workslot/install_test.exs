defmodule Workslot.InstallTest do
  use ExUnit.Case, async: true

  alias Workslot.Install

  describe "patch_mise/1 — per-worktree agent-browser env" do
    test "appends a new [env] block when the file has none" do
      {out, manual} = Install.patch_mise("[tools]\nelixir = \"1.18\"\n")

      assert manual == []
      assert out =~ "[tools]"
      assert out =~ "[env]"

      assert out =~
               "AGENT_BROWSER_PROFILE = \"{{env.HOME}}/.agent-browser/profiles/{{config_root | basename}}\""

      assert out =~ "AGENT_BROWSER_SESSION"
      assert out =~ "AGENT_BROWSER_SCREENSHOT_DIR"
    end

    test "inserts into an existing [env] table without creating a second one" do
      {out, manual} = Install.patch_mise("[env]\nFOO = \"bar\"\n")

      assert manual == []
      # exactly one [env] header (TOML forbids two)
      assert length(String.split(out, "[env]")) == 2
      assert out =~ "FOO = \"bar\""
      assert out =~ "AGENT_BROWSER_PROFILE"
    end

    test "is idempotent — a second pass is a no-op" do
      {once, []} = Install.patch_mise("[tools]\nelixir = \"1.18\"\n")
      {twice, []} = Install.patch_mise(once)

      assert once == twice
      assert length(String.split(twice, "AGENT_BROWSER_PROFILE")) == 2
    end

    test "keys on the worktree folder name (config_root basename), no app name baked in" do
      {out, []} = Install.patch_mise("")
      assert out =~ "{{config_root | basename}}"
      refute out =~ "increment"
    end
  end

  describe "patch_claude_settings/1 — the SessionStart cleanup hook" do
    test "creates settings with just the hook when the file doesn't exist" do
      {:ok, out} = Install.patch_claude_settings(nil)
      settings = Jason.decode!(out)

      assert [%{"matcher" => "startup", "hooks" => [hook]}] = settings["hooks"]["SessionStart"]
      assert hook["type"] == "command"
      assert hook["command"] =~ "$CLAUDE_PROJECT_DIR/.claude/hooks/workslot-clean.sh"
    end

    test "an empty file is treated as empty settings" do
      assert {:ok, out} = Install.patch_claude_settings("  \n")
      assert out =~ "workslot-clean.sh"
    end

    test "appends beside existing hooks and keeps every other setting and the key order" do
      existing = """
      {
        "enabledPlugins": {"b@m": true, "a@m": true},
        "hooks": {
          "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "bd prime"}]}],
          "Stop": [{"hooks": [{"type": "command", "command": "bin/gate"}]}]
        }
      }
      """

      {:ok, out} = Install.patch_claude_settings(existing)
      settings = Jason.decode!(out)

      assert [%{"hooks" => [%{"command" => "bd prime"}]}, %{"matcher" => "startup"}] =
               settings["hooks"]["SessionStart"]

      assert settings["hooks"]["Stop"] == [
               %{"hooks" => [%{"type" => "command", "command" => "bin/gate"}]}
             ]

      # key order survives: b@m still before a@m, enabledPlugins still before hooks
      assert :binary.match(out, "b@m") < :binary.match(out, "a@m")
      assert :binary.match(out, "enabledPlugins") < :binary.match(out, "\"hooks\"")
    end

    test "is idempotent — a second pass is a no-op" do
      {:ok, once} = Install.patch_claude_settings(~s({"hooks": {}}))
      assert Install.patch_claude_settings(once) == {:ok, once}
      assert length(String.split(once, "workslot-clean.sh")) == 2
    end

    test "a mention of the script anywhere but a startup SessionStart hook still registers it" do
      existing = """
      {
        "permissions": {"allow": ["Bash(sh .claude/hooks/workslot-clean.sh)"]},
        "hooks": {
          "SessionStart": [{"matcher": "resume", "hooks": [{"type": "command", "command": "sh workslot-clean.sh"}]}],
          "Stop": [{"hooks": [{"type": "command", "command": "sh workslot-clean.sh"}]}]
        }
      }
      """

      {:ok, out} = Install.patch_claude_settings(existing)

      assert [%{"matcher" => "resume"}, %{"matcher" => "startup"}] =
               Jason.decode!(out)["hooks"]["SessionStart"]
    end

    test "a SessionStart group that covers startup and runs the script is left alone" do
      command = ~s|sh "$CLAUDE_PROJECT_DIR/.claude/hooks/workslot-clean.sh"|

      for matcher <- [nil, "", "*", "startup|resume"] do
        group = %{"hooks" => [%{"type" => "command", "command" => command}]}
        group = if matcher, do: Map.put(group, "matcher", matcher), else: group
        existing = Jason.encode!(%{"hooks" => %{"SessionStart" => [group]}})

        assert Install.patch_claude_settings(existing) == {:ok, existing}
      end
    end

    test "a command that merely mentions the script, or a matcher that only contains startup, does not count" do
      for {matcher, command} <- [
            {"startup", "echo workslot-clean.sh"},
            {"startup-extra", ~s|sh "$CLAUDE_PROJECT_DIR/.claude/hooks/workslot-clean.sh"|}
          ] do
        group = %{"matcher" => matcher, "hooks" => [%{"type" => "command", "command" => command}]}

        {:ok, out} =
          Install.patch_claude_settings(Jason.encode!(%{"hooks" => %{"SessionStart" => [group]}}))

        assert [_, %{"matcher" => "startup"}] = Jason.decode!(out)["hooks"]["SessionStart"]
      end
    end

    test "a file it does not understand is reported, not rewritten" do
      assert {:error, "is not valid JSON" <> _} = Install.patch_claude_settings(~s({"a": 1,}))
      assert {:error, "is not a JSON object"} = Install.patch_claude_settings("[]")

      assert {:error, ~s|has a "hooks" that is not an object|} =
               Install.patch_claude_settings(~s({"hooks": []}))

      assert {:error, ~s|has a "hooks.SessionStart" that is not a list|} =
               Install.patch_claude_settings(~s({"hooks": {"SessionStart": {}}}))

      assert Install.hook_settings_entry() =~ ~s|"matcher": "startup"|
    end

    test "the vendored script only reads, never drops or compiles" do
      # commands only — the header comment does mention the --drop command the agent may offer
      script =
        Install.hook_script()
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.join("\n")

      assert script =~ "workslot.clean --summary"
      assert script =~ "--no-deps-check"
      refute script =~ "--drop"
      refute script =~ ~r/\b(compile|deps\.get)\b/
    end
  end

  test "the README's manual-install copy of config/worktree.exs is the vendored template" do
    [_, block] =
      "README.md"
      |> File.read!()
      |> String.split("<code>config/worktree.exs</code></summary>", parts: 2)

    [_, code | _] = String.split(block, ["```elixir\n", "   ```\n"], parts: 3)

    readme =
      code |> String.split("\n") |> Enum.map_join("\n", &String.replace_prefix(&1, "   ", ""))

    assert readme == Install.worktree_exs()
  end

  describe "worktree_exs_status/1 — upgrading the vendored config/worktree.exs" do
    test "the current template is current" do
      assert Install.worktree_exs_status(Install.worktree_exs()) == :current
    end

    test "an unedited copy from an earlier release is outdated, even after a formatter rewrote it" do
      [v0_1_0] = Workslot.Install.Shipped.worktree_exs()
      assert Install.worktree_exs_status(v0_1_0) == :outdated

      # what Styler makes of it (pipe-first, digit separators) — still the same code
      styled =
        v0_1_0
        |> String.replace(
          ":erlang.phash2(root) |> Integer.to_string(36)",
          "root |> :erlang.phash2() |> Integer.to_string(36)"
        )
        |> String.replace("port in 1..65535 ->", "port in 1..65_535 ->")
        |> String.replace("# Vendored by workslot", "# vendored by workslot")

      assert styled != v0_1_0
      assert Install.worktree_exs_status(styled) == :outdated
    end

    test "the 0.1.0 README's hand-install copy (no @doc lines) is outdated too" do
      readme_copy = File.read!("test/fixtures/worktree_0_1_0_readme.txt")
      assert Install.worktree_exs_status(readme_copy) == :outdated
    end

    test "a copy with a real edit, or one that does not parse, is edited" do
      [v0_1_0] = Workslot.Install.Shipped.worktree_exs()
      edited = String.replace(v0_1_0, ~s|"wt" <> hash36(root)|, ~s|"tree" <> hash36(root)|)

      assert Install.worktree_exs_status(edited) == :edited
      assert Install.worktree_exs_status("defmodule (") == :edited
      # a pipe Macro.pipe/3 cannot expand
      assert Install.worktree_exs_status("x = 1 |> 2") == :edited
    end
  end
end
