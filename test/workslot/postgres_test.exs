defmodule Workslot.PostgresTest do
  use ExUnit.Case, async: true

  alias Workslot.Postgres

  test "drop_sql/1 quotes the name as an identifier and never forces" do
    assert Postgres.drop_sql("my_app_dev_x") == ~s|DROP DATABASE "my_app_dev_x"|
    assert Postgres.drop_sql(~s|a"b|) == ~s|DROP DATABASE "a""b"|
    refute Postgres.drop_sql("x") =~ "FORCE"
  end

  test "like_prefix/1 escapes LIKE's wildcards, so `_` matches only `_`" do
    assert Postgres.like_prefix("my_app_dev") == ~S"my\_app\_dev%"
    assert Postgres.like_prefix(~S"50%\x") == ~S"50\%\\x%"
  end

  test "effective/1 lets a url: win over discrete keys, as Ecto does" do
    opts =
      Postgres.effective(
        hostname: "ignored",
        url: "ecto://u%40x:p%3Aw@db.local:6543/my_app_dev?ssl=true"
      )

    assert opts[:hostname] == "db.local"
    assert opts[:port] == 6543
    assert opts[:username] == "u@x"
    assert opts[:password] == "p:w"
    assert opts[:database] == "my_app_dev"
    assert opts[:ssl] == true
  end

  test "describe/1 names the server without the options (no password), and server/1 ignores pool tuning" do
    opts = [hostname: "db.local", port: 6543, password: "secret", pool_size: 10]
    refute Postgres.describe(opts) =~ "secret"
    assert Postgres.describe(opts) == "db.local:6543"
    assert Postgres.server(opts) == Postgres.server(Keyword.put(opts, :pool_size, 2))
  end
end
