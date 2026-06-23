defmodule Workslot.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/increment-tech/workslot"

  def project do
    [
      app: :workslot,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Workslot",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Optional: only needed for `mix workslot.install`. Consumers that wire config by
      # hand don't need it. The installer task is guarded by `Code.ensure_loaded?(Igniter)`.
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Deterministic per-git-worktree isolation of an app's dev/test databases and " <>
      "dev-server port — no generated manifest, no manual port bookkeeping."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Website" => "https://www.increment.tech", "GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
