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
end
