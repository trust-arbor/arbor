defmodule Arbor.Persistence.VectorStore.Ecto.OperationReceiptRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:operation_fingerprint, :string, autogenerate: false}

  schema "vector_operation_receipts" do
    field(:agent_id, :string)
    field(:operation_kind, :string)
    field(:operation_json, :string)
    field(:operation_digest, :string)
    field(:receipt_json, :string)
    field(:receipt_digest, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
