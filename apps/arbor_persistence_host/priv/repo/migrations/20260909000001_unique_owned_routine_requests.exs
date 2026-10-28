defmodule Arbor.Persistence.Repo.Migrations.UniqueOwnedRoutineRequests do
  use Ecto.Migration

  @name :oban_owned_routine_request_key_unique
  @worker "Arbor.Scheduler.Workers.OwnedRoutineRunner"

  def up do
    expression =
      case repo().__adapter__() do
        Ecto.Adapters.SQLite3 -> "json_extract(args, '$.request_key')"
        Ecto.Adapters.Postgres -> "(args->>'request_key')"
      end

    # This partial index belongs only to the closed owner-signed routine lane.
    # Oban's ordinary unique option is not an atomic uniqueness guarantee on
    # SQLite. Existing rows are never deleted or merged by this migration.
    create(unique_index(:oban_jobs, [expression], name: @name, where: "worker = '#{@worker}'"))
  end

  def down, do: drop(index(:oban_jobs, [], name: @name))
end
