defmodule Arbor.Persistence.Repo do
  @moduledoc """
  Ecto Repo for Arbor persistence.

  Supports both PostgreSQL and SQLite3 adapters. The adapter is selected at
  compile time via the `:repo_adapter` config key:

      # PostgreSQL (default for existing setups):
      config :arbor_persistence, repo_adapter: Ecto.Adapters.Postgres

      # SQLite3 (zero-config for new developers):
      # Set ARBOR_DB=sqlite before compiling
      config :arbor_persistence, repo_adapter: Ecto.Adapters.SQLite3

  ## PostgreSQL config

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_dev",
        username: System.get_env("DB_USER", "postgres"),
        password: System.get_env("DB_PASS", "postgres"),
        hostname: "localhost",
        pool_size: 10

  ## SQLite3 config

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: Path.expand("~/.arbor/arbor_dev.db")
  """

  use Ecto.Repo,
    otp_app: :arbor_persistence,
    adapter:
      Application.compile_env(
        :arbor_persistence,
        :repo_adapter,
        Ecto.Adapters.Postgres
      )
end
