import Config

# Production config should be provided via runtime.exs or environment variables
# This file just documents the expected configuration shape

# config :arbor_persistence_ecto, Arbor.Persistence.Ecto.EventStore,
#   username: System.fetch_env!("DATABASE_USER"),
#   password: System.fetch_env!("DATABASE_PASSWORD"),
#   database: System.fetch_env!("DATABASE_NAME"),
#   hostname: System.fetch_env!("DATABASE_HOST"),
#   port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
#   pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE", "10")),
#   ssl: true
