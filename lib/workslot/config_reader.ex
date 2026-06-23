defmodule Workslot.ConfigReader do
  @moduledoc """
  Reads the database name and HTTP port back out of an *evaluated* app config, by shape — so it
  stays app- and module-name-agnostic. Used by `mix workslot` to show exactly what the app will
  use rather than re-deriving the values.

  The Repo entry is the one config value carrying a `:database`; the Endpoint is the one carrying
  `http: [port: _]`. Both are found by shape, never by module name.
  """

  @doc "The `:database` from whichever config entry carries one (the Repo), or `nil`."
  @spec database(keyword() | nil) :: String.t() | nil
  def database(app_config) when is_list(app_config) do
    find_value(app_config, & &1[:database])
  end

  def database(_), do: nil

  @doc "The `http: [port: _]` from whichever config entry carries one (the Endpoint), or `nil`."
  @spec http_port(keyword() | nil) :: pos_integer() | nil
  def http_port(app_config) when is_list(app_config) do
    find_value(app_config, &get_in(&1, [:http, :port]))
  end

  def http_port(_), do: nil

  defp find_value(app_config, getter) do
    Enum.find_value(app_config, fn
      {_mod, opts} when is_list(opts) -> getter.(opts)
      _ -> nil
    end)
  end
end
