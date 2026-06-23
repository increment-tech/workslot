defmodule Mix.Tasks.Workslot.Install.Docs do
  @moduledoc false

  def short_doc, do: "Wire per-worktree DB + port isolation into a Phoenix app."

  def example, do: "mix workslot.install"

  def long_doc do
    """
    #{short_doc()}

    Vendors a self-contained `config/worktree.exs` and patches `config/dev.exs` /
    `config/test.exs` so each linked git worktree gets its own dev/test databases and a
    stable dev-server port — derived from the worktree, with no generated manifest.

    ## Example

    ```bash
    #{example()}
    ```

    Anything the installer can't safely auto-edit (a non-default config shape) is reported as
    a precise manual step rather than guessed at.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Workslot.Install do
    @shortdoc __MODULE__.Docs.short_doc()
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Workslot.Install

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :workslot,
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = to_string(Igniter.Project.Application.app_name(igniter))

      igniter
      |> Igniter.create_new_file("config/worktree.exs", Install.worktree_exs(), on_exists: :skip)
      |> patch("config/dev.exs", &Install.patch_dev(&1, app))
      |> patch("config/test.exs", &Install.patch_test(&1, app))
      |> patch("config/runtime.exs", &Install.patch_runtime/1)
      |> Igniter.add_notice("""
      workslot wired in. Each linked git worktree now gets its own dev/test databases
      and a stable dev port; the main checkout keeps the bare names and port 4000.

      config/runtime.exs now calls Workslot.verify!() in :dev, so a folder-name or port
      collision with another live worktree fails fast instead of silently sharing data.

      Run `mix workslot` in any checkout to see its database names and URL.
      """)
    end

    # Run a pure {content, manual_edits} transform over an existing config file. Missing files
    # or unmatched anchors degrade to a warning with the exact manual edit, never a crash.
    # These config files aren't touched earlier in the run, so on-disk == the source content.
    defp patch(igniter, path, fun) do
      if Igniter.exists?(igniter, path) do
        {new_content, manual} = fun.(File.read!(path))

        igniter
        |> Igniter.update_file(path, fn source ->
          Rewrite.Source.update(source, :content, new_content)
        end)
        |> then(fn igniter ->
          Enum.reduce(manual, igniter, fn note, acc ->
            Igniter.add_warning(acc, "workslot — manual edit needed: #{note}")
          end)
        end)
      else
        Igniter.add_warning(
          igniter,
          "workslot: #{path} not found; skipped its DB/port patch."
        )
      end
    end
  end
else
  defmodule Mix.Tasks.Workslot.Install do
    @shortdoc __MODULE__.Docs.short_doc()
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The workslot installer requires Igniter.

      Add it as a dev dependency and re-run:

          {:igniter, "~> 0.6", only: [:dev], runtime: false}

      Then: mix deps.get && mix workslot.install

      Or wire it manually — see the README "Manual install" section.
      """)

      exit({:shutdown, 1})
    end
  end
end
