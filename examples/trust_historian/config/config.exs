import Config
config :logger, level: :error
# Consumer-owned compile-time selection; public SQL package source is unchanged.
config :arbor_persistence_sql,
  repo: Arbor.Persistence.SQL.Repo,
  repo_adapter: Ecto.Adapters.SQLite3,
  ecto_repos: [Arbor.Persistence.SQL.Repo]

# Fresh bundled amalgamation/NIF build. Never download a precompiled artifact.
config :exqlite, force_build: true
config :elixir_make, :force_build, exqlite: true
