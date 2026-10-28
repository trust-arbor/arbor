import Config

config :arbor_persistence_sql, ecto_repos: [Arbor.Persistence.SQL.Repo]

if config_env() == :test, do: import_config("test.exs")
