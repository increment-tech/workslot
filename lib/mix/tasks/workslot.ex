defmodule Mix.Tasks.Workslot do
  @shortdoc "Show this checkout's dev/test DB names and dev-server port"

  @moduledoc """
  Prints the database names and dev-server port for the current git checkout.

  Each linked git worktree auto-isolates its dev/test databases (named from the worktree's
  folder name) and its dev-server port (hashed from the worktree's full path) — see
  `config/worktree.exs`, vendored by `workslot` — so the values differ per worktree. Run this
  to find where a worktree's app and databases live:

      $ mix workslot
      worktree feature-x
        dev   db=my_app_dev_feature_x  url=http://localhost:4271
        test  db=my_app_test_feature_x

  `PORT` and `MIX_TEST_PARTITION` overrides are reflected when set.

  The DB name and port are read back from the evaluated `config/dev.exs` / `config/test.exs`,
  so this shows exactly what the app will use — it does not re-derive them.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    root = File.cwd!()
    app = Mix.Project.config()[:app]
    worktree? = Workslot.worktree?(root)

    dev = read_app_config("config/dev.exs", :dev, app)
    test = read_app_config("config/test.exs", :test, app)

    label = if worktree?, do: "worktree #{Path.basename(root)}", else: "main checkout"

    alias Workslot.ConfigReader

    Mix.shell().info("""
    #{label}
      dev   db=#{dev && ConfigReader.database(dev)}  url=http://localhost:#{dev && ConfigReader.http_port(dev)}
      test  db=#{test && ConfigReader.database(test)}
    """)
  end

  defp read_app_config(path, env, app) do
    if File.exists?(path) do
      path
      |> Config.Reader.read!(env: env)
      |> Keyword.get(app)
    end
  end
end
