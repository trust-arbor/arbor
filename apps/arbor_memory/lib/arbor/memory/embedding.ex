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

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Memory.EmbeddingCodec
  alias Arbor.Memory.IndexSupervisor
  alias Arbor.Persistence

  @behaviour Arbor.Memory.Index.PersistentWriter

  @default_timeout_ms 5_000
  @max_timeout_ms 30_000
  @cleanup_opt_keys [:repo, :process_evidence, :timeout_ms]

  @type content_cleanup_error ::
          :invalid_agent_id
          | :invalid_options
          | :backend_failure
          | :indeterminate
          | :delete_failed
          | :absence_uncertain
          | :registry_unavailable
          | :supervisor_unavailable
          | :conflict
          | :timeout
          | :outcome_unknown

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
  # Content-only cleanup (VP-05D2C3I0C3)
  #
  # Composes exact-agent legacy embedding destruction with live Index
  # ownership termination at the Embedding/Index boundary. Not exposed as a
  # cross-domain coordinator on Arbor.Memory. C3I1B mutation lease/drain is a
  # future caller-owned precondition — these primitives do not stop concurrent
  # writers.
  # ---------------------------------------------------------------

  @doc """
  Idempotent content-only deletion for exact-agent legacy embeddings and live Index.

  Destroys durable legacy rows (confirming zero), then terminates the exact
  registered Index child and proves Registry/supervisor absence under a
  mandatory inventory/supervisor bijection. Does not delete provenance, strict
  V1 vectors, receipts, or emit a global cleaned/destroyed signal.
  """
  @spec delete_agent_content(String.t(), keyword()) ::
          :ok | {:error, content_cleanup_error()}
  def delete_agent_content(agent_id, opts \\ []) do
    with :ok <- validate_cleanup_agent_id(agent_id),
         {:ok, normalized} <- normalize_cleanup_opts(opts) do
      # One absolute deadline from admission through durable cleanup, terminate,
      # every evidence wait, and final composed absence. Never remint timeout.
      deadline = absolute_deadline(normalized.timeout_ms)
      delete_agent_content_until(agent_id, normalized, deadline)
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  @doc """
  Authoritative absence across durable legacy embeddings and live Index ownership.

  Returns `{:ok, true}` only when legacy rows are authoritatively zero and Index
  ownership is absent under inventory/supervisor bijection proof.
  """
  @spec agent_content_absent?(String.t(), keyword()) ::
          {:ok, boolean()} | {:error, content_cleanup_error()}
  def agent_content_absent?(agent_id, opts \\ []) do
    with :ok <- validate_cleanup_agent_id(agent_id),
         {:ok, normalized} <- normalize_cleanup_opts(opts) do
      deadline = absolute_deadline(normalized.timeout_ms)
      do_agent_content_absent?(agent_id, normalized, deadline)
    end
  rescue
    _ -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  defp delete_agent_content_until(agent_id, normalized, deadline) do
    if remaining_ms(deadline) <= 0 do
      {:error, :timeout}
    else
      case destroy_legacy(agent_id, normalized.repo_opts) do
        {:error, reason} ->
          # Durable failure must not attempt Index process cleanup.
          {:error, normalize_delete_error(reason)}

        :ok ->
          if remaining_ms(deadline) <= 0 do
            {:error, :timeout}
          else
            case IndexSupervisor.terminate_index_ownership_until(
                   agent_id,
                   normalized.evidence_opts,
                   deadline
                 ) do
              :ok ->
                # Ownership termination already succeeded (or proved pre-absent).
                # Any final confirmation other than exact {:ok, true} is post-effect
                # outcome ambiguity — never leak conflict/unavailable as distinct success paths.
                case do_agent_content_absent?(agent_id, normalized, deadline) do
                  {:ok, true} -> :ok
                  {:ok, false} -> {:error, :outcome_unknown}
                  {:error, _any} -> {:error, :outcome_unknown}
                end

              {:error, reason} ->
                {:error, normalize_delete_error(reason)}
            end
          end
      end
    end
  end

  # Private absence helper that preserves an exact absolute deadline (no remint).
  defp do_agent_content_absent?(agent_id, normalized, deadline) do
    with {:ok, legacy_gone?} <- legacy_absent(agent_id, normalized.repo_opts),
         {:ok, index_gone?} <-
           IndexSupervisor.index_ownership_absent_until?(
             agent_id,
             normalized.evidence_opts,
             deadline
           ) do
      {:ok, legacy_gone? and index_gone?}
    else
      {:error, reason} ->
        {:error, normalize_absence_error(reason)}
    end
  end

  defp destroy_legacy(agent_id, repo_opts) do
    case Persistence.destroy_legacy_embeddings(agent_id, repo_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :backend_failure}
    end
  end

  defp legacy_absent(agent_id, repo_opts) do
    case Persistence.legacy_embeddings_absent?(agent_id, repo_opts) do
      {:ok, present?} when is_boolean(present?) -> {:ok, present?}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :backend_failure}
    end
  end

  defp validate_cleanup_agent_id(agent_id) do
    case VectorRecord.validate_identity(agent_id, "legacy", "legacy") do
      {:ok, _identity} -> :ok
      {:error, :invalid_vector_identity} -> {:error, :invalid_agent_id}
    end
  end

  defp normalize_cleanup_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        keys != Enum.uniq(keys) ->
          {:error, :invalid_options}

        Enum.any?(keys, &(&1 not in @cleanup_opt_keys)) ->
          {:error, :invalid_options}

        true ->
          with {:ok, repo_opts} <- normalize_repo_opts(Keyword.get(opts, :repo)),
               {:ok, timeout_ms} <- normalize_timeout(Keyword.get(opts, :timeout_ms)),
               {:ok, evidence} <- normalize_evidence(Keyword.get(opts, :process_evidence)) do
            evidence_opts = maybe_put([], :process_evidence, evidence)

            {:ok,
             %{
               repo_opts: repo_opts,
               timeout_ms: timeout_ms,
               evidence_opts: evidence_opts
             }}
          end
      end
    else
      {:error, :invalid_options}
    end
  end

  defp normalize_cleanup_opts(_opts), do: {:error, :invalid_options}

  defp normalize_repo_opts(nil), do: {:ok, []}
  defp normalize_repo_opts(repo) when is_atom(repo), do: {:ok, [repo: repo]}
  defp normalize_repo_opts(_), do: {:error, :invalid_options}

  defp normalize_timeout(nil), do: {:ok, @default_timeout_ms}

  defp normalize_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms,
       do: {:ok, timeout_ms}

  defp normalize_timeout(_), do: {:error, :invalid_options}

  defp normalize_evidence(nil), do: {:ok, nil}
  defp normalize_evidence(module) when is_atom(module), do: {:ok, module}
  defp normalize_evidence(_), do: {:error, :invalid_options}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp absolute_deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining_ms(deadline) do
    max(0, deadline - System.monotonic_time(:millisecond))
  end

  defp normalize_delete_error(reason)
       when reason in [
              :invalid_agent_id,
              :invalid_options,
              :backend_failure,
              :indeterminate,
              :delete_failed,
              :absence_uncertain,
              :registry_unavailable,
              :supervisor_unavailable,
              :conflict,
              :timeout,
              :outcome_unknown
            ],
       do: reason

  defp normalize_delete_error(:invalid_request), do: :invalid_agent_id
  defp normalize_delete_error(_), do: :delete_failed

  defp normalize_absence_error(reason)
       when reason in [
              :invalid_agent_id,
              :invalid_options,
              :backend_failure,
              :absence_uncertain,
              :registry_unavailable,
              :supervisor_unavailable,
              :conflict,
              :timeout
            ],
       do: reason

  defp normalize_absence_error(:invalid_request), do: :invalid_agent_id
  defp normalize_absence_error(:indeterminate), do: :backend_failure
  defp normalize_absence_error(:outcome_unknown), do: :absence_uncertain
  defp normalize_absence_error(:delete_failed), do: :absence_uncertain
  defp normalize_absence_error(_), do: :absence_uncertain

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

  @doc """
  Destroy exact-agent strict vector rows and operation receipts through the
  public Persistence facade.
  """
  @spec destroy_strict(String.t(), keyword()) :: :ok | {:error, term()}
  def destroy_strict(agent_id, opts \\ []),
    do: Persistence.destroy_vector_agent(agent_id, opts)

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
