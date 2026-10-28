defmodule Arbor.Persistence.Repo.Migrations.AddObanJobs do
  @moduledoc """
  Creates the `oban_jobs`, `oban_peers` (and related) tables Oban needs.

  Oban v12+ ships a self-contained migration helper that handles the
  schema across Postgres and SQLite. We just call up/0 and down/0.

  Tables created in the public schema by default; if Arbor ever wants
  Oban tables in a separate schema, pass `prefix: "scheduler"`.

  See: https://hexdocs.pm/oban/Oban.Migration.html
  """
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end
