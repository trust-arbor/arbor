# Exclude database tests by default (require PostgreSQL setup)
# Run with: mix test --include database
ExUnit.start(exclude: [:database])
