defmodule Arbor.Persistence.Repo.Migrations.WidenVectorAgentIds do
  @moduledoc """
  Widens PostgreSQL tenant columns to the Contracts 256-byte agent-id ceiling.

  PostgreSQL `varchar` limits characters rather than bytes. A 256-character
  column therefore admits every valid UTF-8 identifier accepted by the
  256-byte Contracts bound. SQLite stores these fields as unbounded text.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  def up do
    if postgres?() do
      execute("ALTER TABLE memory_embeddings ALTER COLUMN agent_id TYPE varchar(256)")

      execute(
        "ALTER TABLE vector_operation_receipts " <>
          "ALTER COLUMN agent_id TYPE varchar(256)"
      )
    end
  end

  def down do
    raise """
    irreversible migration: 256-character vector tenant identifiers may have
    committed; use a separately approved narrowing migration after an operator audit
    """
  end
end
