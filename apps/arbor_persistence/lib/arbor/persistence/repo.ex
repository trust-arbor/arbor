defmodule Arbor.Persistence.Repo do
  @moduledoc """
  Ecto Repo for Arbor persistence.

  Configure in your application:

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_dev",
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        pool_size: 10

  For tests:

      config :arbor_persistence, Arbor.Persistence.Repo,
        pool: Ecto.Adapters.SQL.Sandbox
  """

  use Ecto.Repo,
    otp_app: :arbor_persistence,
    adapter: Ecto.Adapters.Postgres
end
