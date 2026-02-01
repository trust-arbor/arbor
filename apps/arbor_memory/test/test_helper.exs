# Exclude database tests by default (require postgres + pgvector)
# Run them with: mix test --include database
ExUnit.configure(exclude: [:database])
ExUnit.start()
