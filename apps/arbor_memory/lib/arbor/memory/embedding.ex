defmodule Arbor.Memory.Embedding do
  @moduledoc """
  Memory embedding boundary: legacy PostgreSQL/pgvector compatibility API plus
  the strict vector codec and public Persistence vector-facade operations.

  Database ownership stays behind the `Arbor.Persistence` facade. This module
  preserves the established legacy Memory API without importing persistence
  schemas, repositories, query builders, or adapter-specific vector types.

  Strict operations construct and decode Memory-owned provenance through
  `Arbor.Memory.EmbeddingCodec` and call only the public Persistence vector API.

  ## Strict closed input

  Encode and mutate paths accept an exact closed map or keyword with **all** of
  these atom keys and no others:

  - `:kind` — `:insert | :update | :delete | :reinsert`
  - `:id`, `:agent_id`, `:source_namespace`, `:source_key`
  - `:payload` — JSON-shaped map body (ordinary data; not provenance authority)
  - `:vector`, `:category`, `:generation`, `:revision`, `:tombstone`
  - `:expected_generation`, `:expected_revision`
  - `:model_evidence` — one of:
    - `:absent` → durable model id `legacy:unspecified`
    - `{:provider_model, provider, model}` non-empty UTF-8 binaries → `"provider/model"`
    - `{:model_id, model_id}` non-empty UTF-8 binary within contract byte limits
  - `:taint` — source-owned authoritative `Arbor.Contracts.Security.Taint` (or
    canonical map form) supplied by the trusted Memory caller / source owner

  Top-level `:taint` is **source-owner evidence** for the Memory boundary: it is
  not payload metadata and not an agent-controlled tool argument. Payload keys
  named `taint`, `provenance`, `model`, `provider`, or `digest` remain ordinary
  body data and never become model or taint authority.

  Raw `%VectorOperation{}` admission preserves the exact validated operation for
  reconcile and requires every record (including each batch member) to decode as
  a verified strict wrapper. Mixed-provenance batches are rejected before
  Persistence dispatch. Caller/record `agent_id` mismatch is enforced by the
  Persistence tenant boundary (`:tenant_mismatch`).

  List and search are fail-closed: any single decode failure fails the whole read.
  """

  alias Arbor.Contracts.Persistence.VectorOperation
  alias Arbor.Memory.EmbeddingCodec
  alias Arbor.Persistence

  @behaviour Arbor.Memory.Index.PersistentWriter

  @doc "Validate and normalize one durable legacy embedding without dispatching a write."
  @spec validate(String.t(), String.t(), term(), term()) ::
          {:ok, [float()]} | {:error, {:invalid_legacy_embedding, atom()}}
  def validate(agent_id, content, embedding, metadata),
    do: Persistence.validate_legacy_embedding(agent_id, content, embedding, metadata)

  @doc "Store or deduplicate one embedding."
  @impl true
  @spec store(String.t(), String.t(), [float()], map()) ::
          {:ok, String.t()} | {:error, term()}
  def store(agent_id, content, embedding, metadata \\ %{}),
    do: Persistence.store_legacy_embedding(agent_id, content, embedding, metadata)

  @doc "Search legacy embeddings using cosine similarity."
  @spec search(String.t(), [float()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(agent_id, query_embedding, opts \\ []),
    do: Persistence.search_legacy_embeddings(agent_id, query_embedding, opts)

  @doc "Delete an embedding by its durable row ID."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent_id, embedding_id),
    do: Persistence.delete_legacy_embedding(agent_id, embedding_id)

  @doc "Count embeddings for an agent."
  @spec count(String.t()) :: non_neg_integer()
  def count(agent_id), do: Persistence.count_legacy_embeddings(agent_id)

  @doc "Return aggregate embedding statistics for an agent."
  @spec stats(String.t()) :: map()
  def stats(agent_id), do: Persistence.legacy_embedding_stats(agent_id)

  @doc "Store or deduplicate a batch of embeddings."
  @spec store_batch(String.t(), [{String.t(), [float()], map()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def store_batch(agent_id, entries),
    do: Persistence.store_legacy_embedding_batch(agent_id, entries)

  @doc false
  @impl true
  @spec store_batch_with_ids(String.t(), [{String.t(), [float()], map()}]) ::
          {:ok, [String.t()]} | {:error, term()}
  def store_batch_with_ids(agent_id, entries),
    do: Persistence.store_legacy_embedding_batch_with_ids(agent_id, entries)

  @doc "Fetch one embedding by its durable row ID."
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(agent_id, embedding_id),
    do: Persistence.fetch_legacy_embedding(agent_id, embedding_id)

  @doc "Delete all legacy embeddings for an agent."
  @spec delete_all(String.t()) :: {:ok, non_neg_integer()}
  def delete_all(agent_id), do: Persistence.delete_all_legacy_embeddings(agent_id)

  # ---------------------------------------------------------------
  # Strict codec + public Persistence vector-facade boundary
  # ---------------------------------------------------------------

  @doc """
  Encode one strict Memory semantic embedding input into a `VectorOperation`.

  Accepts only the closed input shape documented in the moduledoc. Model identity
  comes solely from top-level `:model_evidence`; top-level `:taint` is source-owned
  authority and is bound into durable provenance by the codec.
  """
  @spec encode_strict_operation(term()) ::
          {:ok, VectorOperation.t(), EmbeddingCodec.decoded_view()} | {:error, atom()}
  def encode_strict_operation(input), do: EmbeddingCodec.encode_operation(input)

  @doc """
  Encode a bounded batch of strict Memory semantic embedding inputs.

  Enforces the contract batch ceiling
  (`VectorOperation.max_batch_operations/0`, currently 100) incrementally without
  materializing `length/1` over the full input.
  """
  @spec encode_strict_batch(term()) ::
          {:ok, VectorOperation.t(), [EmbeddingCodec.decoded_view()]} | {:error, atom()}
  def encode_strict_batch(inputs), do: EmbeddingCodec.encode_batch(inputs)

  @doc "Decode one validated VectorRecord into a Memory embedding view."
  @spec decode_strict_record(term()) ::
          {:ok, EmbeddingCodec.decoded_view()} | {:error, atom()}
  def decode_strict_record(record), do: EmbeddingCodec.decode_record(record)

  @doc "Decode one validated VectorMatch into a Memory embedding view plus similarity."
  @spec decode_strict_match(term()) ::
          {:ok, %{match: EmbeddingCodec.decoded_view(), similarity: float()}}
          | {:error, atom()}
  def decode_strict_match(match), do: EmbeddingCodec.decode_match(match)

  @doc """
  Execute one strict vector mutation through the public Persistence facade.

  Closed inputs are encoded first. Raw `%VectorOperation{}` values are validated
  and admitted only when every member decodes with verified provenance; the exact
  operation is preserved (never re-encoded) for downstream reconcile. Tenant
  mismatch is returned by Persistence when the caller `agent_id` does not match
  the operation's bound tenant.
  """
  @spec execute_strict(String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_strict(agent_id, input_or_operation, opts \\ []) do
    with {:ok, operation} <- coerce_operation(input_or_operation) do
      Persistence.execute_vector_operation(agent_id, operation, opts)
    end
  end

  @doc """
  Reconcile one strict vector mutation through the public Persistence facade.

  Same closed-input encoding, verified raw-operation admission, and exact-operation
  preservation rules as `execute_strict/3`.
  """
  @spec reconcile_strict(String.t(), term(), keyword()) ::
          {:ok, term()} | {:ok, :absent} | {:error, term()}
  def reconcile_strict(agent_id, input_or_operation, opts \\ []) do
    with {:ok, operation} <- coerce_operation(input_or_operation) do
      Persistence.reconcile_vector_operation(agent_id, operation, opts)
    end
  end

  @doc "Fetch and decode one strict vector row by logical identity."
  @spec fetch_strict(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, EmbeddingCodec.decoded_view()} | {:error, term()}
  def fetch_strict(agent_id, source_namespace, source_key, opts \\ []) do
    with {:ok, record} <-
           Persistence.fetch_vector_record(agent_id, source_namespace, source_key, opts) do
      decode_strict_record(record)
    end
  end

  @doc """
  List and decode tenant-owned strict vector rows.

  Fail-closed: any single record decode failure fails the whole list.
  """
  @spec list_strict(String.t(), keyword()) ::
          {:ok, [EmbeddingCodec.decoded_view()]} | {:error, term()}
  def list_strict(agent_id, opts \\ []) do
    with {:ok, records} <- Persistence.list_vector_records(agent_id, opts) do
      decode_record_list(records, [])
    end
  end

  @doc """
  Search and decode strict vector matches through the public Persistence facade.

  Fail-closed: any single match decode failure fails the whole search result.
  """
  @spec search_strict(String.t(), term(), keyword()) ::
          {:ok, [%{match: EmbeddingCodec.decoded_view(), similarity: float()}]}
          | {:error, term()}
  def search_strict(agent_id, vector, opts \\ []) do
    with {:ok, matches} <- Persistence.search_vector_records(agent_id, vector, opts) do
      decode_match_list(matches, [])
    end
  end

  # Raw VectorOperation admission requires every record (including batch members) to
  # decode as a strict wrapper with verified provenance. The exact validated
  # operation is preserved for reconcile; we never re-encode it.
  defp coerce_operation(%VectorOperation{} = operation) do
    with {:ok, operation} <- VectorOperation.validate(operation),
         :ok <- admit_verified_strict_operation(operation) do
      {:ok, operation}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp coerce_operation(input) do
    case encode_strict_operation(input) do
      {:ok, operation, _view} -> {:ok, operation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_verified_strict_operation(%VectorOperation{kind: :batch, operations: operations}) do
    admit_verified_strict_members(operations)
  end

  defp admit_verified_strict_operation(%VectorOperation{} = operation) do
    admit_verified_strict_record(operation.record)
  end

  defp admit_verified_strict_members([]), do: :ok

  defp admit_verified_strict_members([%VectorOperation{} = operation | rest]) do
    case admit_verified_strict_record(operation.record) do
      :ok -> admit_verified_strict_members(rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_verified_strict_members(_improper), do: {:error, :invalid_vector_operation}

  defp admit_verified_strict_record(record) do
    case decode_strict_record(record) do
      {:ok, %{provenance_status: :verified}} ->
        :ok

      {:ok, %{provenance_status: status}}
      when status in [:legacy_unlabeled, :invalid_durable_provenance] ->
        {:error, :unverified_strict_provenance}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_record_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_record_list([record | rest], acc) do
    case decode_strict_record(record) do
      {:ok, view} -> decode_record_list(rest, [view | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_match_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_match_list([match | rest], acc) do
    case decode_strict_match(match) do
      {:ok, decoded} -> decode_match_list(rest, [decoded | acc])
      {:error, reason} -> {:error, reason}
    end
  end
end
