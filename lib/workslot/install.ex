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
  # not depend on the workslot package. Safe to edit: `mix workslot.install` replaces it only while
  # it still matches a version workslot shipped, and reports an edited copy instead.
  #
  # Each linked git worktree auto-isolates its dev/test databases (named from the worktree's
  # folder name) and its dev-server port (hashed from the worktree's full path). Anything that
  # is not a linked worktree — the main working tree, a submodule, a plain directory — keeps the
  # bare names and port 4000. Detection is name-agnostic: a linked worktree's `.git` is a FILE
  # holding a `gitdir:` pointer into the shared repo's `.git/worktrees/` directory.
  #
  # Every suffix handed out is also recorded under the repository's `.git/workslot/`, so
  # `mix workslot.clean` can tell a removed worktree's databases from anyone else's. Recording is
  # best effort: it never fails or prints during config evaluation.
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
      suffix =
        case slug(root) do
          nil -> ""
          slug -> "_" <> slug
        end

      register("s-", suffix, root)
    end

    @doc "Test-DB suffix: the worktree suffix stacked with MIX_TEST_PARTITION."
    def test_suffix(root \\ File.cwd!()) do
      register("t-", suffix(root) <> (System.get_env("MIX_TEST_PARTITION") || ""), root)
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

    # Record that this checkout derived `suffix` — `kind` is "s-" for suffix/1 (dev names), "t-" for
    # test_suffix/1 (test names): one empty file per suffix in this checkout's record directory, created
    # once and never through an existing link. A worktree's record also gets a `b-` mark for every base
    # `mix workslot.clean` has already seen — the bases it may later claim databases through. Returns
    # `suffix` whatever happens.
    defp register(kind, suffix, root) do
      with {:ok, dir} <- record_dir(root),
           file = Path.join(dir, kind <> Base.encode16(suffix, case: :lower)),
           false <- File.exists?(file) do
        File.mkdir_p!(dir)
        File.write(file, "", [:exclusive])
        # where it was, for the listing: written aside and renamed, so a link is replaced, not followed
        tmp = Path.join(dir, ".path-#{:os.getpid()}-#{System.unique_integer([:positive])}")
        File.write!(tmp, Path.expand(root), [:exclusive])
        File.rename!(tmp, Path.join(dir, "path"))
        mark_seen_bases(dir)
      end

      suffix
    rescue
      _ -> suffix
    end

    # Each sighting file starts with its generation; the mark names key and generation.
    defp mark_seen_bases(dir) do
      bases = dir |> Path.dirname() |> Path.dirname() |> Path.join("bases")

      with "worktrees" <- dir |> Path.dirname() |> Path.basename(),
           {:ok, keys} <- File.ls(bases) do
        for key <- keys,
            not String.starts_with?(key, "."),
            {:ok, content} <- [File.read(Path.join(bases, key))],
            [generation | _names] <- [String.split(content, "\n", trim: true)] do
          File.write(Path.join(dir, "b-" <> key <> "." <> generation), "", [:exclusive])
        end
      end
    end

    # `<common>/workslot/main` for the main checkout (its `.git` is a directory) and
    # `<common>/workslot/worktrees/<id>` for a linked worktree, `<id>` being git's own name for it —
    # but only while git's admin directory for it exists and points back at this very checkout, so a
    # stale pointer (the repository moved) or a copied folder never records anything.
    defp record_dir(root) do
      git = Path.join(root, ".git")

      cond do
        File.dir?(git) ->
          {:ok, Path.join([git, "workslot", "main"])}

        worktree?(root) ->
          {:ok, "gitdir: " <> target} = File.read(git)
          gitdir = target |> String.trim() |> Path.expand(root)

          common =
            case File.read(Path.join(gitdir, "commondir")) do
              {:ok, rel} -> rel |> String.trim() |> Path.expand(gitdir)
              _ -> gitdir |> Path.dirname() |> Path.dirname()
            end

          if File.dir?(common) and points_back?(gitdir, git),
            do: {:ok, Path.join([common, "workslot", "worktrees", Path.basename(gitdir)])},
            else: :error

        true ->
          :error
      end
    end

    # git's `<gitdir>/gitdir` names the worktree's `.git` file. Compare the files, not the spellings, so a
    # symlinked path still matches and a copy of the folder does not. A file system that reports no inode
    # (they read 0) or a hard-linked `.git` file cannot tell them apart, so neither records.
    defp points_back?(gitdir, dot_git) do
      with {:ok, back} <- File.read(Path.join(gitdir, "gitdir")),
           {:ok, recorded} <- back |> String.trim() |> Path.expand(gitdir) |> File.stat(),
           {:ok, mine} <- File.stat(dot_git) do
        mine.inode != 0 and mine.links == 1 and
          {recorded.major_device, recorded.inode} == {mine.major_device, mine.inode}
      else
        _ -> false
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
  How an existing `config/worktree.exs` relates to what this version vendors: `:current`, `:outdated`
  (an unedited copy an earlier release vendored — safe to replace) or `:edited`. Compared as code, not
  bytes, so a copy the app's formatter rewrote (pipes, number separators, layout) still counts as
  unedited.
  """
  @spec worktree_exs_status(String.t()) :: :current | :outdated | :edited
  def worktree_exs_status(existing) do
    code = normalize(existing)

    cond do
      code == :error -> :edited
      code == normalize(@worktree_exs) -> :current
      code in Enum.map(Workslot.Install.Shipped.worktree_exs(), &normalize/1) -> :outdated
      true -> :edited
    end
  end

  # The code as an AST with positions and `@doc`/`@moduledoc` dropped and pipes expanded, so neither
  # formatting nor documentation (the README's copy has none) can tell copies apart.
  defp normalize(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> Macro.postwalk(ast, &unpipe_and_strip/1)
      {:error, _} -> :error
    end
  rescue
    # Macro.pipe/3 refuses a pipe it cannot expand (`1 |> 2`): not a copy workslot shipped
    ArgumentError -> :error
  end

  defp unpipe_and_strip({:|>, _, [left, right]}), do: left |> Macro.pipe(right, 0) |> strip()

  defp unpipe_and_strip({:__block__, meta, exprs}),
    do: strip({:__block__, meta, Enum.reject(exprs, &doc?/1)})

  defp unpipe_and_strip(node), do: strip(node)

  defp doc?({:@, _, [{attr, _, _}]}) when attr in [:doc, :moduledoc], do: true
  defp doc?(_node), do: false

  defp strip({form, _meta, args}), do: {form, [], args}
  defp strip(node), do: node

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
    # Every Repo on the dev database (an app may have several), not just the first match.
    |> step(
      ~s|database: "#{app}_dev"|,
      ~s|database: "#{app}_dev\#{Workslot.Worktree.suffix()}"|,
      "Workslot.Worktree.suffix",
      ~s|config/dev.exs: set the Repo `database:` to "#{app}_dev\#{Workslot.Worktree.suffix()}"|,
      global: true
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

    # Both shapes, every occurrence — even when another Repo is already patched (an install from before
    # every Repo was isolated), so re-running the installer finishes the job.
    patched =
      content
      |> ensure_require()
      # phx.new default: database already composes MIX_TEST_PARTITION — fold it into test_suffix.
      |> String.replace(
        ~s|_test\#{System.get_env("MIX_TEST_PARTITION")}|,
        ~s|_test\#{Workslot.Worktree.test_suffix()}|
      )
      # Plain `"<app>_test"` with no partition interpolation.
      |> String.replace(
        ~s|database: "#{app}_test"|,
        ~s|database: "#{app}_test\#{Workslot.Worktree.test_suffix()}"|
      )

    if String.contains?(patched, "Workslot.Worktree.test_suffix"),
      do: {patched, []},
      else: {patched, [manual]}
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

  # The per-worktree agent-browser env, keyed on the checkout's folder name — mise resolves
  # `{{config_root | basename}}` per worktree, so every worktree (and every repo) gets its own Chrome
  # profile and two parallel coding agents never share one browser. Tool-agnostic: no app name, no
  # company. Just the three `AGENT_BROWSER_*` keys agent-browser reads.
  @browser_marker "AGENT_BROWSER_PROFILE"
  @mise_env_lines ~S'''
  # workslot: per-worktree browser isolation — each git worktree/repo gets its own agent-browser profile.
  AGENT_BROWSER_PROFILE = "{{env.HOME}}/.agent-browser/profiles/{{config_root | basename}}"
  AGENT_BROWSER_SESSION = "{{config_root | basename}}"
  AGENT_BROWSER_SCREENSHOT_DIR = "{{env.HOME}}/AgentRuns/{{config_root | basename}}/screenshots"
  '''

  @doc """
  Add the per-worktree agent-browser env to `mise.toml`, idempotently. If an `[env]` table already exists
  the keys are inserted into it; otherwise a new `[env]` block is appended. A no-op once
  `AGENT_BROWSER_PROFILE` is present. Returns `{new_content, manual_edits}` like `patch_dev/2`.
  """
  @spec patch_mise(String.t()) :: {String.t(), [String.t()]}
  def patch_mise(content) do
    lines = String.trim_trailing(@mise_env_lines)

    cond do
      String.contains?(content, @browser_marker) ->
        {content, []}

      # Insert into an existing [env] table, right after its header line (TOML forbids a second [env]).
      Regex.match?(~r/^\[env\][^\n]*\n/m, content) ->
        {Regex.replace(~r/^\[env\][^\n]*\n/m, content, "\\0#{lines}\n", global: false), []}

      true ->
        {String.trim_trailing(content) <> "\n\n[env]\n" <> @mise_env_lines, []}
    end
  end

  # The SessionStart hook that tells a coding agent about databases left behind by removed worktrees.
  # It runs `mix workslot.clean --summary` from the project root (where `$CLAUDE_PROJECT_DIR` points
  # even in a worktree session) and prints nothing below the threshold, so a clean repo costs zero
  # context tokens. It never compiles and never drops anything; the line it prints tells the agent to
  # show the user the list and drop only what the user approves, by name.
  @hook_path ".claude/hooks/workslot-clean.sh"
  @hook_command ~s|sh "$CLAUDE_PROJECT_DIR/.claude/hooks/workslot-clean.sh"|
  @hook_script ~S'''
  #!/bin/sh
  # Vendored by workslot (`mix workslot.agents.install`) — https://github.com/increment-tech/workslot
  #
  # Claude Code SessionStart hook. When databases left behind by removed git worktrees add up to more
  # than WORKSLOT_CLEAN_MIN_SIZE (default 1GB), print one line telling the agent to show the user
  # `mix workslot.clean`'s list before anything is dropped. Silent otherwise. Never drops anything,
  # never compiles: it only runs when this checkout already has a compiled workslot that ships the task.
  cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
  [ -f _build/dev/lib/workslot/ebin/Elixir.Mix.Tasks.Workslot.Clean.beam ] || exit 0
  if command -v mise >/dev/null 2>&1; then set -- mise exec --; else set --; fi
  # --no-deps-check: a checkout whose deps are merely stale must still answer, not refuse.
  MIX_ENV=dev "$@" mix do deps.loadpaths --no-deps-check + \
    workslot.clean --summary --min-size "${WORKSLOT_CLEAN_MIN_SIZE:-1GB}" 2>/dev/null |
    grep '^workslot:'
  exit 0
  '''

  @doc "Where the installer vendors the SessionStart hook script, relative to the project root."
  @spec hook_path() :: String.t()
  def hook_path, do: @hook_path

  @doc "The SessionStart hook script the installer vendors."
  @spec hook_script() :: String.t()
  def hook_script, do: @hook_script

  @doc """
  Register the SessionStart hook in a `.claude/settings.json` body (`nil` when the file doesn't
  exist yet), idempotently. Every existing setting, hook and key order is kept; the workslot entry is
  appended to `hooks.SessionStart` with the `startup` matcher (not resume/clear/compact) unless a
  `SessionStart` group that covers `startup` already runs the script.

  Returns `{:ok, json}` (the input unchanged when the hook is already registered), or
  `{:error, reason}` when the file is not JSON or `hooks` / `hooks.SessionStart` have an unexpected
  shape — the caller reports that instead of rewriting a file it does not understand.
  """
  @spec patch_claude_settings(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def patch_claude_settings(content) do
    # Jason arrives with Igniter, which the installer requires. The module name is built at runtime
    # so an app that has Jason only in :dev still compiles workslot warning-free in :test (Elixir's
    # type checker sees through a plain `json = Jason` binding).
    json = Module.concat(["Jason"])

    with {:ok, settings} <- decode_object(json, content),
         {:ok, hooks} <- object_at(settings, "hooks"),
         {:ok, session_start} <- list_at(hooks, "SessionStart") do
      if Enum.any?(session_start, &startup_hook?/1) do
        {:ok, content}
      else
        entry =
          ordered([
            {"matcher", "startup"},
            {"hooks",
             [ordered([{"type", "command"}, {"command", @hook_command}, {"timeout", 30}])]}
          ])

        settings
        |> put("hooks", put(hooks, "SessionStart", session_start ++ [entry]))
        |> json.encode!(pretty: true)
        |> Kernel.<>("\n")
        |> then(&{:ok, &1})
      end
    end
  end

  @doc "The JSON a user adds by hand when `patch_claude_settings/1` cannot."
  @spec hook_settings_entry() :: String.t()
  def hook_settings_entry do
    ~s|"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": #{inspect(@hook_command)}, "timeout": 30}]}]}|
  end

  defp decode_object(json, content) do
    if content == nil or String.trim(content) == "" do
      {:ok, ordered([])}
    else
      case json.decode(content, objects: :ordered_objects) do
        {:ok, %{values: _} = settings} -> {:ok, settings}
        {:ok, _} -> {:error, "is not a JSON object"}
        {:error, error} -> {:error, "is not valid JSON (#{Exception.message(error)})"}
      end
    end
  end

  defp object_at(object, key) do
    case get(object, key) do
      nil -> {:ok, ordered([])}
      %{values: _} = value -> {:ok, value}
      _ -> {:error, ~s|has a "#{key}" that is not an object|}
    end
  end

  defp list_at(object, key) do
    case get(object, key) do
      nil -> {:ok, []}
      value when is_list(value) -> {:ok, value}
      _ -> {:error, ~s|has a "hooks.#{key}" that is not a list|}
    end
  end

  # A SessionStart group that runs on `startup` (no matcher, "", "*", or a `|` list naming it) and runs
  # the vendored script — this exact command, not merely one that mentions it.
  defp startup_hook?(%{values: _} = group) do
    matcher = get(group, "matcher")

    startup? =
      matcher in [nil, "", "*"] or
        (is_binary(matcher) and "startup" in String.split(matcher, "|"))

    commands =
      case get(group, "hooks") do
        hooks when is_list(hooks) -> for %{values: _} = hook <- hooks, do: get(hook, "command")
        _ -> []
      end

    startup? and @hook_command in commands
  end

  defp startup_hook?(_group), do: false

  # Jason.OrderedObject, built and read through its `values` keyword-ish list so key order survives.
  defp ordered(pairs), do: struct(Module.concat(["Jason", "OrderedObject"]), values: pairs)

  defp get(%{values: values}, key),
    do: Enum.find_value(values, fn {k, v} -> if k == key, do: v end)

  defp put(%{values: values} = object, key, value) do
    if List.keymember?(values, key, 0),
      do: %{object | values: List.keyreplace(values, key, 0, {key, value})},
      else: %{object | values: values ++ [{key, value}]}
  end

  # Apply `pattern -> replacement` wherever the unpatched anchor remains (so a half-migrated file is
  # finished, not skipped); otherwise the marker means done and its absence a manual note. Threads a
  # `{content, manual_edits}` accumulator and records a manual-edit note when the anchor is gone.
  defp step(acc, pattern, replacement, marker, manual_note, opts \\ [])

  defp step({content, manual}, pattern, replacement, marker, manual_note, opts) do
    cond do
      String.contains?(content, pattern) ->
        {String.replace(content, pattern, replacement, global: Keyword.get(opts, :global, false)),
         manual}

      String.contains?(content, marker) ->
        {content, manual}

      true ->
        {content, manual ++ [manual_note]}
    end
  end

  defp step(content, pattern, replacement, marker, manual_note, opts) when is_binary(content) do
    step({content, []}, pattern, replacement, marker, manual_note, opts)
  end
end
