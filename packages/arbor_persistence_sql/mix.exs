defmodule Arbor.Persistence.SQL.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_persistence_sql,
      version: "0.1.0-dev",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "SQL backends for Arbor Persistence's Store and EventLog protocols",
      package: [licenses: ["MIT"], files: ~w(lib priv mix.exs README.md LICENSE)]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:arbor_persistence, "~> 0.1.0-dev", path: "../arbor_persistence", env: Mix.env()},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.18"},
      {:ecto_sqlite3, "~> 0.18"},
      {:jason, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
