defmodule Mix.Tasks.Workslot.Agents do
  @shortdoc "Point this worktree's coding agents at its own Tidewave dev MCP"

  @moduledoc """
  Registers this checkout's Tidewave dev MCP server (`/tidewave/mcp` on the worktree's dev-server port)
  with the coding-agent CLIs that are installed — **Claude Code** and **Codex** — so each git worktree's
  agents talk to *their own* running app, not a sibling worktree's.

  The port is read back from the evaluated `config/dev.exs` (exactly like `mix workslot`), so it always
  matches the server this worktree boots. Idempotent and safe to re-run — `mix workslot.install` adds it to
  your `mix setup` alias so every new worktree wires itself.

      $ mix workslot.agents
      workslot.agents: Tidewave → http://localhost:4271/tidewave/mcp
        claude ✓ (local scope — this project only)
        codex  ✓ (global config — see note)

  Nothing is wired if the app doesn't depend on `:tidewave`, or if neither CLI is on `PATH`.

  ## Per-worktree, per tool

    * **Claude Code** stores it at `local` scope — keyed by this project path in `~/.claude.json`, so each
      worktree is isolated automatically and privately (never committed).
    * **Codex** has only a single global `config.toml`, so its entry reflects whichever worktree ran this
      last. For true per-worktree Codex, pass the URL at call time
      (`codex -c mcp_servers.tidewave.url=<url> …`) — e.g. from a `bin/codex-review` wrapper that reads
      `mix workslot`'s port.
  """
  use Mix.Task

  @server "tidewave"

  @impl Mix.Task
  def run(_argv) do
    if tidewave_dep?() do
      url = "http://localhost:#{dev_port()}/tidewave/mcp"
      Mix.shell().info("workslot.agents: Tidewave → #{url}")
      wire_claude(url)
      wire_codex(url)
    else
      Mix.shell().info("workslot.agents: app has no :tidewave dependency — nothing to wire.")
    end
  end

  # The dev-server port, read back from the evaluated config (workslot's per-worktree port once installed;
  # the Phoenix default 4000 otherwise) — the same source `mix workslot` uses.
  defp dev_port do
    app = Mix.Project.config()[:app]

    with true <- File.exists?("config/dev.exs"),
         dev when is_list(dev) <-
           "config/dev.exs" |> Config.Reader.read!(env: :dev) |> Keyword.get(app),
         port when is_integer(port) <- Workslot.ConfigReader.http_port(dev) do
      port
    else
      _ -> 4000
    end
  end

  defp tidewave_dep?, do: List.keymember?(Mix.Project.config()[:deps] || [], :tidewave, 0)

  # Claude Code: `local` scope keys the server by this project path (per-worktree, private). Remove-then-add
  # so a stale port is replaced, not duplicated.
  defp wire_claude(url) do
    if exe = System.find_executable("claude") do
      _ = cmd(exe, ["mcp", "remove", @server, "--scope", "local"])

      case cmd(exe, ["mcp", "add", "--scope", "local", "--transport", "http", @server, url]) do
        {_, 0} -> Mix.shell().info("  claude ✓ (local scope — this project only)")
        {out, _} -> Mix.shell().error("  claude ✗ — #{String.trim(out)}")
      end
    end
  end

  # Codex: HTTP MCP via `--url`, but its config.toml is GLOBAL — a per-worktree `mcp add` would overwrite
  # sibling worktrees' entry (exactly the clobber workslot exists to prevent). So register globally only on
  # the main checkout; inside a worktree, emit the per-invocation override to use instead (e.g. from a
  # `bin/codex-review` wrapper). Claude has no such problem — its `local` scope is per-project-path.
  defp wire_codex(url) do
    if exe = System.find_executable("codex") do
      if Workslot.worktree?(File.cwd!()) do
        Mix.shell().info(
          "  codex  ↷ worktree — global config would clobber siblings; pass `-c mcp_servers.tidewave.url=#{url}` at call time"
        )
      else
        _ = cmd(exe, ["mcp", "remove", @server])

        case cmd(exe, ["mcp", "add", @server, "--url", url]) do
          {_, 0} -> Mix.shell().info("  codex  ✓ (global config, main checkout)")
          {out, _} -> Mix.shell().error("  codex  ✗ — #{String.trim(out)}")
        end
      end
    end
  end

  defp cmd(exe, args), do: System.cmd(exe, args, stderr_to_stdout: true)
end
