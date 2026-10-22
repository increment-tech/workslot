defmodule Workslot.ConfigReaderTest do
  use ExUnit.Case, async: true

  alias Workslot.ConfigReader

  @app_config [
    {MyApp.Repo, [username: "postgres", database: "my_app_dev_feature_x", pool_size: 10]},
    {MyAppWeb.Endpoint, [http: [ip: {127, 0, 0, 1}, port: 4271], code_reloader: true]}
  ]

  test "database/1 finds the :database entry by shape" do
    assert ConfigReader.database(@app_config) == "my_app_dev_feature_x"
  end

  test "http_port/1 finds the http port by shape" do
    assert ConfigReader.http_port(@app_config) == 4271
  end

  test "return nil for nil or shapeless config" do
    assert ConfigReader.database(nil) == nil
    assert ConfigReader.http_port(nil) == nil
    assert ConfigReader.database([{MyApp.Mailer, [adapter: Swoosh.Adapters.Local]}]) == nil
    assert ConfigReader.http_port([{MyApp.Repo, [database: "x"]}]) == nil
  end

  test "repo/1 returns the Repo's options, by :database or by a string url — never the Endpoint" do
    assert ConfigReader.repo(@app_config)[:pool_size] == 10

    url_only = [
      {MyAppWeb.Endpoint, [url: [host: "localhost"], http: [port: 4000]]},
      {MyApp.Repo, [url: "postgres://localhost/my_app_dev"]}
    ]

    assert ConfigReader.repo(url_only) == [url: "postgres://localhost/my_app_dev"]
    assert ConfigReader.repo([{MyAppWeb.Endpoint, [url: [host: "x"]]}]) == nil
  end

  test "repos/1 returns every Repo and skips a url: of another kind" do
    config = [
      {:redis, [url: "redis://localhost:6379"]},
      {MyApp.Api, [url: "https://api.example.com"]},
      {MyApp.Repo, [database: "my_app_dev"]},
      {MyApp.EventsRepo, [url: "ecto://u:p@localhost/my_app_events_dev"]},
      {:not_a_keyword, [1, 2]}
    ]

    assert ConfigReader.repos(config) == [
             [database: "my_app_dev"],
             [url: "ecto://u:p@localhost/my_app_events_dev"]
           ]

    assert ConfigReader.repo(config) == [database: "my_app_dev"]
  end
end
