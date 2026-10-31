defmodule Arbor.Persistence.SQL.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_persistence_sql,
      version: "0.1.0-dev",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "SQL backends for Arbor Persistence's Store and EventLog protocols",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib priv mix.exs README.md LICENSE)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      persistence_dependency(),
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.18"},
      {:ecto_sqlite3, "~> 0.18"},
      {:jason, "~> 1.4"}
    ]
  end

  defp persistence_dependency do
    case System.get_env("ARBOR_PERSISTENCE_PATH") do
      nil ->
        {:arbor_persistence, "~> 0.1.0-dev", env: Mix.env()}

      path ->
        {:arbor_persistence, "~> 0.1.0-dev", path: path, override: true, env: Mix.env()}
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
