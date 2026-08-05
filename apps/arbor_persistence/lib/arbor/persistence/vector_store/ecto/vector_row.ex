defmodule Arbor.Persistence.VectorStore.Ecto.VectorRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @vector_type (case Application.compile_env(
                       :arbor_persistence,
                       :repo_adapter,
                       Ecto.Adapters.Postgres
                     ) do
                  Ecto.Adapters.Postgres -> Pgvector.Ecto.Vector
                  _other -> :string
                end)

  schema "memory_embeddings" do
    field(:agent_id, :string)

    # Legacy columns remain dual-written until the operator-approved cutover.
    field(:content, :string)
    field(:content_hash, :string)
    field(:embedding, @vector_type)
    field(:memory_type, :string)
    field(:source, :string)
    field(:metadata, :map, default: %{})

    # C3G1A staged authority columns. Null source_namespace marks a legacy row.
    field(:source_namespace, :string)
    field(:source_key, :string)
    field(:canonical_payload, :string)
    field(:payload_digest, :string)
    field(:vector_768, @vector_type)
    field(:vector_bytes, :binary)
    field(:vector_digest, :string)
    field(:model_id, :string)
    field(:dimensions, :integer)
    field(:encoding, :string)
    field(:category, :string)
    field(:generation, :integer)
    field(:revision, :integer)
    field(:tombstone, :boolean)

    timestamps()
  end
end
