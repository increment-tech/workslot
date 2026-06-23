defmodule Workslot.Install do
  @moduledoc """
  Pure helpers behind `mix workslot.install`.

  Kept free of any Igniter dependency so the file content (the vendored `config/worktree.exs`)
  and the `config/dev.exs` / `config/test.exs` / `config/runtime.exs` text transforms are
  unit-testable on their own. The Igniter task is a thin shell that wires file IO to these
  functions.
  """

  @worktree_exs ~S'''
  # Vendored by workslot — https://github.com/increment-tech/workslot
  #
  # Self-contained ON PURPOSE: build config (config/dev.exs, config/test.exs) loads this via
  # `Code.require_file/2`, which can run BEFORE deps are compiled on a fresh clone — so it must
  # not depend on the workslot package. Safe to edit; the installer never overwrites it.
  #
  # Each linked git worktree auto-isolates its dev/test databases (named from the worktree's
  # folder name) and its dev-server port (hashed from the worktree's full path). Anything that
  # is not a linked worktree — the main working tree, a submodule, a plain directory — keeps the
  # bare names and port 4000. Detection is name-agnostic: a linked worktree's `.git` is a FILE
  # holding a `gitdir:` pointer into the shared repo's `.git/worktrees/` directory.
  #
  # This mirrors the derivation in the Workslot module; a parity test keeps them in sync.
  defmodule Workslot.Worktree do
    @moduledoc false

    @doc "Sanitized worktree slug, or nil when not a linked git worktree."
    def slug(root \\ File.cwd!()) do
      if worktree?(root) do
        cleaned =
          root
          |> Path.basename()
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.trim("_")

        if cleaned == "", do: "wt" <> hash36(root), else: cleaned
      end
    end

    @doc ~S'Database-name suffix: "" outside a worktree, "_<slug>" in a linked worktree.'
    def suffix(root \\ File.cwd!()) do
      case slug(root) do
        nil -> ""
        slug -> "_" <> slug
      end
    end

    @doc "Test-DB suffix: the worktree suffix stacked with MIX_TEST_PARTITION."
    def test_suffix(root \\ File.cwd!()) do
      suffix(root) <> (System.get_env("MIX_TEST_PARTITION") || "")
    end

    @doc "Stable dev port: PORT wins; else 4000 outside a worktree, 4001..4999 hashed from the path."
    def dev_port(root \\ File.cwd!(), default \\ 4000) do
      cond do
        port = System.get_env("PORT") -> parse_port!(port)
        slug(root) -> 4001 + :erlang.phash2(root, 999)
        true -> default
      end
    end

    # A linked worktree's gitdir is `<common>/worktrees/<id>`; a submodule's is
    # `<super>/modules/<name>`, the main tree's `.git` is a directory. Require the worktrees
    # segment and reject any modules path so only a linked worktree isolates.
    defp worktree?(root) do
      case File.read(Path.join(root, ".git")) do
        {:ok, "gitdir: " <> target} ->
          target = String.trim(target)
          String.contains?(target, "/worktrees/") and not String.contains?(target, "/modules/")

        _ ->
          false
      end
    end

    defp hash36(root) do
      :erlang.phash2(root) |> Integer.to_string(36) |> String.downcase()
    end

    defp parse_port!(value) do
      case Integer.parse(value) do
        {port, ""} when port in 1..65535 ->
          port

        _ ->
          raise "workslot: PORT=#{inspect(value)} must be an integer in 1..65535. " <>
                  "Unset it, or set PORT to a valid port (e.g. PORT=4500)."
      end
    end
  end
  '''

  @require_line ~s|Code.require_file("worktree.exs", __DIR__)|

  @verify_block ~S'''
  if config_env() == :dev do
    # workslot: fail fast if another live worktree would share this checkout's DB/port.
    Workslot.verify!()
  end
  '''

  @doc "The self-contained `config/worktree.exs` contents the installer vendors."
  @spec worktree_exs() :: String.t()
  def worktree_exs, do: @worktree_exs

  @doc """
  Ensure `config/dev.exs`/`test.exs` loads the vendored helper. Inserts the
  `Code.require_file/2` line right after `import Config`, idempotently.
  """
  @spec ensure_require(String.t()) :: String.t()
  def ensure_require(content) do
    cond do
      String.contains?(content, ~s|require_file("worktree.exs"|) ->
        content

      String.contains?(content, "import Config") ->
        String.replace(content, "import Config", "import Config\n\n#{@require_line}",
          global: false
        )

      true ->
        "#{@require_line}\n\n" <> content
    end
  end

  @doc """
  Rewrite `config/dev.exs` to isolate the dev DB name and port per worktree.

  Returns `{new_content, manual_edits}` where `manual_edits` is a list of human-readable
  instructions for anchors that could not be found (left for the user to apply by hand).
  """
  @spec patch_dev(String.t(), String.t()) :: {String.t(), [String.t()]}
  def patch_dev(content, app) do
    content
    |> ensure_require()
    |> step(
      ~s|database: "#{app}_dev"|,
      ~s|database: "#{app}_dev\#{Workslot.Worktree.suffix()}"|,
      "Workslot.Worktree.suffix",
      ~s|config/dev.exs: set the Repo `database:` to "#{app}_dev\#{Workslot.Worktree.suffix()}"|
    )
    # Anchor on the full phx.new Endpoint http shape, not a bare `port: 4000`, so nothing else can
    # be rewritten by accident. Any other shape degrades to the manual note below.
    |> step(
      "http: [ip: {127, 0, 0, 1}, port: 4000]",
      "http: [ip: {127, 0, 0, 1}, port: Workslot.Worktree.dev_port()]",
      "Workslot.Worktree.dev_port",
      "config/dev.exs: set the Endpoint http `port:` to Workslot.Worktree.dev_port()"
    )
  end

  @doc """
  Rewrite `config/test.exs` to isolate the test DB name per worktree (composing with
  `MIX_TEST_PARTITION`). Returns `{new_content, manual_edits}` as `patch_dev/2`.
  """
  @spec patch_test(String.t(), String.t()) :: {String.t(), [String.t()]}
  def patch_test(content, app) do
    manual =
      ~s|config/test.exs: set the Repo `database:` to "#{app}_test\#{Workslot.Worktree.test_suffix()}"|

    with_require = ensure_require(content)

    cond do
      String.contains?(with_require, "Workslot.Worktree.test_suffix") ->
        {with_require, []}

      # phx.new default: database already composes MIX_TEST_PARTITION — fold it into test_suffix.
      String.contains?(with_require, ~s|_test\#{System.get_env("MIX_TEST_PARTITION")}|) ->
        {String.replace(
           with_require,
           ~s|_test\#{System.get_env("MIX_TEST_PARTITION")}|,
           ~s|_test\#{Workslot.Worktree.test_suffix()}|
         ), []}

      # Plain `"<app>_test"` with no partition interpolation.
      String.contains?(with_require, ~s|database: "#{app}_test"|) ->
        {String.replace(
           with_require,
           ~s|database: "#{app}_test"|,
           ~s|database: "#{app}_test\#{Workslot.Worktree.test_suffix()}"|,
           global: false
         ), []}

      true ->
        {with_require, [manual]}
    end
  end

  @doc """
  Ensure `config/runtime.exs` calls `Workslot.verify!()` so a folder-name or port
  collision fails fast at dev boot. Inserts a `config_env() == :dev`-guarded call right after
  `import Config`, idempotently. Returns `{new_content, manual_edits}` as `patch_dev/2`.
  """
  @spec patch_runtime(String.t()) :: {String.t(), [String.t()]}
  def patch_runtime(content) do
    cond do
      String.contains?(content, "Workslot.verify!") ->
        {content, []}

      String.contains?(content, "import Config") ->
        {String.replace(
           content,
           "import Config",
           "import Config\n\n" <> String.trim_trailing(@verify_block),
           global: false
         ), []}

      true ->
        {content,
         [
           "config/runtime.exs: call `Workslot.verify!()` (guarded by `config_env() == :dev`) after `import Config`"
         ]}
    end
  end

  # Apply `pattern -> replacement` once, unless already migrated (marker present). Threads a
  # `{content, manual_edits}` accumulator and records a manual-edit note when the anchor is gone.
  defp step({content, manual}, pattern, replacement, marker, manual_note) do
    cond do
      String.contains?(content, marker) ->
        {content, manual}

      String.contains?(content, pattern) ->
        {String.replace(content, pattern, replacement, global: false), manual}

      true ->
        {content, manual ++ [manual_note]}
    end
  end

  defp step(content, pattern, replacement, marker, manual_note) when is_binary(content) do
    step({content, []}, pattern, replacement, marker, manual_note)
  end
end
