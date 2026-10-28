defmodule Arbor.Persistence.Repo.Migrations.AddRecordsRevision do
  @moduledoc """
  Additive migration: monotonic backend-owned `revision` on `records`.

  Existing rows receive revision 0. Backends advance revision on every successful
  put/update and compare-and-swap; callers cannot roll it backward.
  """
  use Ecto.Migration

  def change do
    alter table(:records) do
      add(:revision, :bigint, null: false, default: 0)
    end
  end
end
