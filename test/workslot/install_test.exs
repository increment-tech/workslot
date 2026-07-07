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
end
