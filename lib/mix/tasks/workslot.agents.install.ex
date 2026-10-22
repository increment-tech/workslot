defmodule Mix.Tasks.Workslot.Agents.Install.Docs do
  @moduledoc false

  def short_doc,
    do: "Wire per-worktree coding-agent isolation (browser, Tidewave MCP, DB cleanup hook)."

  def example, do: "mix workslot.agents.install"

  def long_doc do
    """
    #{short_doc()}

    Layers per-worktree **coding-agent** isolation on top of `mix workslot.install`'s DB + port
    isolation, so parallel agents (Claude Code / Codex) never step on each other:

      * **browser** — appends an `[env]` block to `mise.toml` giving each worktree its own
        agent-browser Chrome profile (keyed on the worktree's folder name);
      * **tidewave** — adds a `workslot.agents` step to your `mix setup` alias; that runtime task
        points this worktree's Claude/Codex at its own Tidewave dev MCP (see `mix help workslot.agents`);
      * **hooks** — vendors `.claude/hooks/workslot-clean.sh` and registers it as a Claude Code
        `SessionStart` hook in `.claude/settings.json`: when databases left behind by removed worktrees
        pass 1 GB (`WORKSLOT_CLEAN_MIN_SIZE`), the agent is told to show you `mix workslot.clean`'s
        list and drop only what you approve (see `mix help workslot.clean`). Silent otherwise; it never
        drops anything itself.

    This task only edits files (idempotent, dry-run-able, composes with `mix igniter.install`); the
    port-dependent MCP registration happens later, per worktree, in the `workslot.agents` task it wires in.

    ## Example

    ```bash
    #{example()}                 # all three
    #{example()} --no-tidewave   # skip the Tidewave MCP step
    #{example()} --no-hooks      # skip the Claude Code cleanup hook
    ```
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Workslot.Agents.Install do
    @shortdoc __MODULE__.Docs.short_doc()
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Workslot.Install

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :workslot,
        schema: [browser: :boolean, tidewave: :boolean, hooks: :boolean],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      browser? = Keyword.get(igniter.args.options, :browser, true)
      tidewave? = Keyword.get(igniter.args.options, :tidewave, true)
      hooks? = Keyword.get(igniter.args.options, :hooks, true)

      igniter
      |> then(&if(browser?, do: patch_mise(&1), else: &1))
      |> then(&if(tidewave?, do: wire_setup(&1), else: &1))
      |> then(&if(hooks?, do: wire_hooks(&1), else: &1))
      |> Igniter.add_notice(notice(browser?, tidewave?, hooks?))
    end

    # A per-worktree agent-browser profile in mise.toml (only if the app uses mise; silent skip otherwise).
    defp patch_mise(igniter) do
      if Igniter.exists?(igniter, "mise.toml") do
        {content, _manual} = Install.patch_mise(File.read!("mise.toml"))

        Igniter.update_file(igniter, "mise.toml", fn source ->
          Rewrite.Source.update(source, :content, content)
        end)
      else
        Igniter.add_warning(
          igniter,
          "workslot.agents: no mise.toml — skipped the browser [env] block."
        )
      end
    end

    # Add the port-reading runtime task to `mix setup`, so every new worktree registers its own Tidewave MCP.
    defp wire_setup(igniter) do
      Igniter.Project.TaskAliases.add_alias(igniter, "setup", "workslot.agents",
        if_exists: :append
      )
    end

    # Vendor the SessionStart script (never clobbering a local edit, like config/worktree.exs) and
    # register it in the project's Claude Code settings, keeping every existing setting and hook.
    defp wire_hooks(igniter) do
      settings = ".claude/settings.json"

      igniter
      |> Igniter.create_new_file(Install.hook_path(), Install.hook_script(), on_exists: :skip)
      |> then(fn igniter ->
        if Igniter.exists?(igniter, settings) do
          Igniter.update_file(igniter, settings, fn source ->
            # the in-memory source, so edits an earlier composed installer staged are kept
            case Install.patch_claude_settings(Rewrite.Source.get(source, :content)) do
              {:ok, content} ->
                Rewrite.Source.update(source, :content, content)

              {:error, reason} ->
                {:warning,
                 "workslot.agents: #{settings} #{reason}, so the cleanup hook was not registered. " <>
                   "Add it by hand: #{Install.hook_settings_entry()}"}
            end
          end)
        else
          {:ok, content} = Install.patch_claude_settings(nil)
          Igniter.create_new_file(igniter, settings, content)
        end
      end)
    end

    defp notice(browser?, tidewave?, hooks?) do
      lines =
        [
          browser? && "  • mise.toml [env]: a per-worktree agent-browser profile.",
          tidewave? &&
            "  • mix setup: a `workslot.agents` step (per-worktree Claude/Codex Tidewave MCP).",
          hooks? &&
            "  • .claude/settings.json: a SessionStart hook reporting databases left by removed worktrees."
        ]
        |> Enum.filter(& &1)
        |> Enum.join("\n")

      """
      workslot agent isolation wired:
      #{lines}

      Run `mix workslot.agents` to wire THIS checkout now (new worktrees do it on `mix setup`).
      """
    end
  end
else
  defmodule Mix.Tasks.Workslot.Agents.Install do
    @shortdoc __MODULE__.Docs.short_doc()
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error(
        "mix workslot.agents.install requires Igniter (see mix workslot.install)."
      )

      exit({:shutdown, 1})
    end
  end
end
