defmodule Workslot.Postgres do
  @moduledoc false
  # The only place workslot touches a database. It talks through the *app's* Postgrex — every Ecto
  # Postgres app already depends on it — called dynamically, so workslot itself keeps zero runtime
  # dependencies (see docs/deferred.md). It lists and drops from the server's `postgres` maintenance
  # database and never opens an app database.

  # Connection keys copied from the app's Repo config; everything else (pool, sandbox, timeouts the
  # app tuned for its own workload) is irrelevant to a one-off maintenance connection.
  @conn_keys [
    :hostname,
    :endpoints,
    :port,
    :socket_dir,
    :socket,
    :socket_options,
    :username,
    :password,
    :ssl,
    :parameters
  ]

  @doc false
  # The Repo config as Ecto would use it: `url:` values take precedence over the discrete keys.
  def effective(repo_opts) do
    case repo_opts[:url] do
      url when is_binary(url) -> Keyword.merge(repo_opts, parse_url(url))
      _ -> repo_opts
    end
  end

  @doc false
  # Which server a Repo config reaches: Repos that share it share one maintenance connection.
  def server(repo_opts), do: repo_opts |> Keyword.take(@conn_keys) |> Enum.sort()

  @doc false
  # Every option that decides which server a connection reaches, as one stable string (no credentials):
  # two Unix sockets, or two endpoint lists, on the same "localhost:5432" are different destinations.
  def destination(repo_opts) do
    [
      hostname: repo_opts[:hostname],
      port: repo_opts[:port] || 5432,
      socket_dir: repo_opts[:socket_dir],
      socket: repo_opts[:socket],
      endpoints: repo_opts[:endpoints]
    ]
    |> inspect(limit: :infinity, printable_limit: :infinity)
  end

  @doc false
  # `host:port` for messages — never the options themselves, which carry the password.
  def describe(repo_opts) do
    "#{repo_opts[:hostname] || repo_opts[:socket_dir] || "localhost"}:#{repo_opts[:port] || 5432}"
  end

  @doc false
  def connect(repo_opts) do
    unless Code.ensure_loaded?(Postgrex) do
      Mix.raise(
        "workslot.clean needs Postgrex (an Ecto Postgres app has it) — run `mix deps.get`."
      )
    end

    {:ok, _} = Application.ensure_all_started(:postgrex)

    opts =
      repo_opts
      |> Keyword.take(@conn_keys)
      |> Keyword.merge(database: "postgres", pool_size: 1, backoff_type: :stop)

    with {:ok, conn} <- start(opts),
         {:ok, _} <- query(conn, "SELECT 1", []) |> stop_on_error(conn) do
      {:ok, conn}
    else
      {:error, reason} -> {:error, "#{describe(repo_opts)} — #{reason}"}
    end
  end

  # A bad option makes start_link fail (or raise) with the options in the reason; report it without them.
  defp start(opts) do
    case apply(Postgrex, :start_link, [opts]) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, "could not start a connection (check the Repo's options)"}
    end
  rescue
    _ -> {:error, "could not start a connection (check the Repo's options)"}
  end

  defp stop_on_error({:ok, _} = ok, _conn), do: ok

  defp stop_on_error(error, conn) do
    stop(conn)
    error
  end

  @doc false
  def stop(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  # Every non-template database whose name starts with `prefix`, with its size and live connections.
  # The size of a database this role may not connect to is reported as 0 rather than failing the query.
  def list(conn, prefix) do
    sql = """
    SELECT d.datname,
           CASE WHEN has_database_privilege(d.datname, 'CONNECT')
                THEN pg_database_size(d.datname) ELSE 0 END,
           (SELECT count(*) FROM pg_stat_activity a WHERE a.datname = d.datname)
    FROM pg_database d
    WHERE NOT d.datistemplate AND d.datname LIKE $1
    """

    case query(conn, sql, [like_prefix(prefix)]) do
      {:ok, rows} -> {:ok, Map.new(rows, fn [name, size, conns] -> {name, {size, conns}} end)}
      error -> error
    end
  end

  @doc false
  # Plain DROP DATABASE, deliberately without WITH (FORCE): a database someone is connected to — a
  # running suite, an iex session — makes Postgres refuse, and that refusal is the safety we want.
  def drop(conn, name) do
    case query(conn, drop_sql(name), []) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  # The statement `drop/2` sends: the name as a quoted identifier (`"` doubled), and no WITH (FORCE).
  def drop_sql(name), do: ~s|DROP DATABASE "#{String.replace(name, ~s|"|, ~s|""|)}"|

  defp query(conn, sql, params) do
    case apply(Postgrex, :query, [conn, sql, params]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, %{postgres: %{message: message}}} -> {:error, message}
      {:error, %{message: message}} when is_binary(message) -> {:error, message}
      {:error, error} -> {:error, Exception.message(error)}
    end
  catch
    :exit, _reason ->
      {:error, "could not connect (refused, timed out, or the login was rejected)"}
  end

  # LIKE treats `_` and `%` as wildcards and every app name has underscores — escape them so
  # `my_app_dev` cannot match `myXappXdev`.
  @doc false
  def like_prefix(prefix) do
    String.replace(prefix, ["\\", "_", "%"], fn ch -> "\\" <> ch end) <> "%"
  end

  # The subset of Ecto's URL format that decides which server and database are meant.
  defp parse_url(url) do
    uri = URI.parse(url)
    {user, pass} = userinfo(uri.userinfo)
    query = URI.decode_query(uri.query || "")

    [
      hostname: uri.host,
      port: uri.port,
      username: user,
      password: pass,
      database: uri.path && uri.path |> String.trim_leading("/") |> URI.decode(),
      ssl: query["ssl"] && query["ssl"] == "true",
      # query parameters that change which server is reached (Ecto passes them through)
      socket_dir: query["socket_dir"],
      socket: query["socket"]
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  defp userinfo(nil), do: {nil, nil}

  defp userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user, pass] -> {URI.decode(user), URI.decode(pass)}
      [user] -> {URI.decode(user), nil}
    end
  end
end
