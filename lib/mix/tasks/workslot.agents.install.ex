defmodule Mix.Tasks.Workslot.Agents.Install.Docs do
  @moduledoc false

  def short_doc, do: "Wire per-worktree coding-agent isolation (browser + Tidewave MCP)."

  def example, do: "mix workslot.agents.install"

  def long_doc do
    """
    #{short_doc()}

    Layers per-worktree **coding-agent** isolation on top of `mix workslot.install`'s DB + port
    isolation, so parallel agents (Claude Code / Codex) never step on each other:

      * **browser** — appends an `[env]` block to `mise.toml` giving each worktree its own
        agent-browser Chrome profile (keyed on the worktree's folder name);
      * **tidewave** — adds a `workslot.agents` step to your `mix setup` alias; that runtime task
        points this worktree's Claude/Codex at its own Tidewave dev MCP (see `mix help workslot.agents`).

    This task only edits files (idempotent, dry-run-able, composes with `mix igniter.install`); the
    port-dependent MCP registration happens later, per worktree, in the `workslot.agents` task it wires in.

    ## Example

    ```bash
    #{example()}          # both
    #{example()} --no-tidewave   # browser only
    #{example()} --no-browser    # tidewave only
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
        schema: [browser: :boolean, tidewave: :boolean],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      browser? = Keyword.get(igniter.args.options, :browser, true)
      tidewave? = Keyword.get(igniter.args.options, :tidewave, true)

      igniter
      |> then(&if(browser?, do: patch_mise(&1), else: &1))
      |> then(&if(tidewave?, do: wire_setup(&1), else: &1))
      |> Igniter.add_notice(notice(browser?, tidewave?))
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

    defp notice(browser?, tidewave?) do
      lines =
        [
          browser? && "  • mise.toml [env]: a per-worktree agent-browser profile.",
          tidewave? &&
            "  • mix setup: a `workslot.agents` step (per-worktree Claude/Codex Tidewave MCP)."
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
