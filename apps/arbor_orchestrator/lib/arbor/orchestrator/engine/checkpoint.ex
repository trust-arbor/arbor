defmodule Arbor.Orchestrator.Engine.Checkpoint do
  @moduledoc """
  Pipeline checkpoint persistence for crash recovery.

  Checkpoints capture the full engine state (context, completed nodes, outcomes,
  retries) at each node completion. Written to both BufferedStore (durable,
  queryable) and local JSON files (backward compat, human-readable debugging).

  HMAC signing uses expanded AAD: the secret is combined with `run_id`,
  `current_node`, and `graph_hash` to prevent checkpoint replay across
  different pipelines or modified graphs.
  """

  @type pending_intent :: %{
          handler: String.t(),
          input_hash: String.t(),
          started_at: String.t(),
          execution_id: String.t()
        }

  @type execution_digest :: %{
          input_hash: String.t(),
          outcome_status: atom(),
          completed_at: String.t(),
          execution_id: String.t()
        }

  @type t :: %__MODULE__{
          timestamp: String.t(),
          run_id: String.t() | nil,
          graph_hash: String.t() | nil,
          current_node: String.t(),
          completed_nodes: [String.t()],
          node_retries: map(),
          context_values: map(),
          node_outcomes: %{String.t() => Arbor.Orchestrator.Engine.Outcome.t()},
          context_lineage: map(),
          content_hashes: map(),
          pending_intents: %{String.t() => pending_intent()},
          execution_digests: %{String.t() => execution_digest()}
        }

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @store_name :arbor_orchestrator_checkpoints

  defstruct timestamp: "",
            run_id: nil,
            graph_hash: nil,
            current_node: "",
            completed_nodes: [],
            node_retries: %{},
            context_values: %{},
            node_outcomes: %{},
            context_lineage: %{},
            content_hashes: %{},
            pending_intents: %{},
            execution_digests: %{}

  @spec from_state(
          String.t(),
          [String.t()],
          map(),
          Arbor.Orchestrator.Engine.Context.t(),
          map(),
          keyword()
        ) :: t()
  def from_state(current_node, completed_nodes, node_retries, context, node_outcomes, opts \\ []) do
    %__MODULE__{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      run_id: Keyword.get(opts, :run_id),
      graph_hash: Keyword.get(opts, :graph_hash),
      current_node: current_node,
      completed_nodes: completed_nodes,
      node_retries: node_retries,
      context_values: Context.snapshot(context),
      node_outcomes: node_outcomes,
      context_lineage: Keyword.get(opts, :context_lineage, Context.lineage(context)),
      content_hashes: Keyword.get(opts, :content_hashes, %{}),
      pending_intents: Keyword.get(opts, :pending_intents, %{}),
      execution_digests: Keyword.get(opts, :execution_digests, %{})
    }
  end

  @doc """
  Signs checkpoint data with HMAC-SHA256 using expanded AAD.

  The HMAC secret is derived from the base secret combined with run_id,
  current_node, and graph_hash. This prevents checkpoint replay: a checkpoint
  from pipeline A cannot be loaded by pipeline B, and a checkpoint signed
  against graph version 1 cannot be loaded after the graph changes.
  """
  @spec sign(map(), binary(), keyword()) :: map()
  def sign(data, secret, aad_opts \\ [])

  def sign(data, secret, aad_opts) when is_map(data) and is_binary(secret) do
    clean = Map.delete(data, "__hmac") |> Map.delete("__hmac")
    derived_key = derive_key(secret, aad_opts)
    canonical = canonical_json(clean)
    hmac = :crypto.mac(:hmac, :sha256, derived_key, canonical) |> Base.encode16(case: :lower)
    Map.put(clean, "__hmac", hmac)
  end

  @doc """
  Verifies HMAC integrity of checkpoint data.

  Uses the same AAD derivation as `sign/3` for verification.
  Returns `{:ok, data_without_hmac}` or `{:error, :tampered}`.
  """
  @spec verify(map(), binary(), keyword()) :: {:ok, map()} | {:error, :tampered}
  def verify(data, secret, aad_opts \\ [])

  def verify(data, secret, aad_opts) when is_map(data) and is_binary(secret) do
    case Map.pop(data, "__hmac") do
      {nil, _} ->
        {:error, :tampered}

      {stored_hmac, clean} ->
        derived_key = derive_key(secret, aad_opts)
        canonical = canonical_json(clean)

        computed =
          :crypto.mac(:hmac, :sha256, derived_key, canonical) |> Base.encode16(case: :lower)

        if :crypto.hash_equals(stored_hmac, computed) do
          {:ok, clean}
        else
          {:error, :tampered}
        end
    end
  end

  # Keys that contain non-serializable structs (e.g., %Graph{}) and must be
  # stripped before JSON encoding.
  @internal_keys ~w(__adapted_graph__ __completed_nodes__)

  @doc """
  Write checkpoint to both BufferedStore and local JSON file.

  The BufferedStore write provides durability across restarts.
  The file write preserves backward compatibility and human-readable debugging.
  """
  @spec write(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = checkpoint, logs_root, opts \\ []) do
    payload_map = serialize(checkpoint)

    payload_map =
      case Keyword.get(opts, :hmac_secret) do
        nil ->
          payload_map

        secret ->
          aad_opts = [
            run_id: checkpoint.run_id,
            current_node: checkpoint.current_node,
            graph_hash: checkpoint.graph_hash
          ]

          sign(payload_map, secret, aad_opts)
      end

    # Write to BufferedStore for durable persistence
    write_to_store(checkpoint.run_id, payload_map)

    # Write to file for backward compat and debugging
    write_to_file(payload_map, logs_root)
  end

  @doc """
  Load checkpoint, trying BufferedStore first then falling back to file.
  """
  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) do
    hmac_secret = Keyword.get(opts, :hmac_secret)

    # If a run_id is provided, try BufferedStore first
    case Keyword.get(opts, :run_id) do
      nil ->
        load_from_file(path, hmac_secret)

      run_id ->
        case load_from_store(run_id, hmac_secret) do
          {:ok, _} = result -> result
          {:error, _} -> load_from_file(path, hmac_secret)
        end
    end
  end

  @doc """
  Delete checkpoint data from BufferedStore.
  Called after pipeline completion for retention management.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(run_id) when is_binary(run_id) do
    key = store_key(run_id)

    if store_available?() do
      Arbor.Persistence.BufferedStore.delete(key, name: @store_name)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Delete checkpoints older than the given duration.
  """
  @spec cleanup_older_than(non_neg_integer()) :: {:ok, non_neg_integer()}
  def cleanup_older_than(max_age_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_seconds, :second)
    deleted = do_cleanup_older_than(cutoff)
    {:ok, deleted}
  rescue
    _ -> {:ok, 0}
  end

  @doc """
  Generate a deterministic execution ID for a node execution.

  Format: `exec_{run_id}_{node_id}_{input_hash_prefix}`

  This can be used by side-effecting handlers as an external idempotency key
  (e.g., Stripe Idempotency-Key, HTTP If-Match).
  """
  @spec generate_execution_id(String.t() | nil, String.t(), String.t()) :: String.t()
  def generate_execution_id(run_id, node_id, input_hash) do
    prefix = String.slice(input_hash, 0, 12)
    "exec_#{run_id || "unknown"}_#{node_id}_#{prefix}"
  end

  @doc """
  Build a PendingIntent map for a node about to execute.
  """
  @spec build_pending_intent(String.t(), String.t(), String.t()) :: pending_intent()
  def build_pending_intent(handler_name, input_hash, execution_id) do
    %{
      handler: handler_name,
      input_hash: input_hash,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      execution_id: execution_id
    }
  end

  @doc """
  Build an ExecutionDigest map for a completed node execution.
  """
  @spec build_execution_digest(String.t(), atom(), String.t()) :: execution_digest()
  def build_execution_digest(input_hash, outcome_status, execution_id) do
    %{
      input_hash: input_hash,
      outcome_status: outcome_status,
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      execution_id: execution_id
    }
  end

  @doc """
  Check for orphaned PendingIntents (intents without matching execution digests).

  Returns a list of `{node_id, pending_intent}` tuples for nodes that started
  executing but never completed — indicating indeterminate state.
  """
  @spec orphaned_intents(t()) :: [{String.t(), pending_intent()}]
  def orphaned_intents(%__MODULE__{} = checkpoint) do
    Enum.filter(checkpoint.pending_intents, fn {node_id, _intent} ->
      not Map.has_key?(checkpoint.execution_digests, node_id)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — serialization
  # ---------------------------------------------------------------------------

  defp serialize(%__MODULE__{} = checkpoint) do
    encoded_outcomes =
      checkpoint.node_outcomes
      |> Enum.map(fn {node_id, outcome} ->
        sanitized =
          outcome
          |> Map.from_struct()
          |> Map.update(:context_updates, %{}, &Map.drop(&1, @internal_keys))

        {node_id, sanitized}
      end)
      |> Map.new()

    checkpoint
    |> Map.from_struct()
    |> Map.put(:node_outcomes, encoded_outcomes)
    |> Map.update(:context_values, %{}, &Map.drop(&1, @internal_keys))
  end

  # ---------------------------------------------------------------------------
  # Private — store operations
  # ---------------------------------------------------------------------------

  defp write_to_store(nil, _payload_map), do: :ok

  defp write_to_store(run_id, payload_map) do
    if store_available?() do
      key = store_key(run_id)
      Arbor.Persistence.BufferedStore.put(key, payload_map, name: @store_name)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp load_from_store(run_id, hmac_secret) do
    key = store_key(run_id)

    if store_available?() do
      case Arbor.Persistence.BufferedStore.get(key, name: @store_name) do
        {:ok, data} when is_map(data) ->
          # Data from store may have atom or string keys
          decoded = normalize_keys(data)

          with {:ok, decoded} <- maybe_verify(decoded, hmac_secret) do
            deserialize(decoded)
          end

        _ ->
          {:error, :not_found}
      end
    else
      {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  end

  defp store_key(run_id), do: "checkpoint:#{run_id}"

  defp store_available? do
    Process.whereis(@store_name) != nil
  end

  # ---------------------------------------------------------------------------
  # Private — file operations
  # ---------------------------------------------------------------------------

  defp write_to_file(payload_map, logs_root) do
    with :ok <- File.mkdir_p(logs_root),
         {:ok, payload} <- Jason.encode(payload_map, pretty: true) do
      File.write(Path.join(logs_root, "checkpoint.json"), payload)
    end
  end

  defp load_from_file(path, hmac_secret) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, decoded} <- maybe_verify(decoded, hmac_secret) do
      deserialize(decoded)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — deserialization
  # ---------------------------------------------------------------------------

  defp deserialize(decoded) do
    outcomes =
      decoded
      |> Map.get("node_outcomes", %{})
      |> Enum.map(fn {node_id, outcome_map} ->
        {node_id,
         %Outcome{
           status: parse_status(Map.get(outcome_map, "status", "success")),
           preferred_label: Map.get(outcome_map, "preferred_label"),
           suggested_next_ids: Map.get(outcome_map, "suggested_next_ids", []),
           context_updates: Map.get(outcome_map, "context_updates", %{}),
           notes: Map.get(outcome_map, "notes"),
           failure_reason: Map.get(outcome_map, "failure_reason")
         }}
      end)
      |> Map.new()

    {:ok,
     %__MODULE__{
       timestamp: Map.get(decoded, "timestamp", ""),
       run_id: Map.get(decoded, "run_id"),
       graph_hash: Map.get(decoded, "graph_hash"),
       current_node: Map.get(decoded, "current_node", ""),
       completed_nodes: Map.get(decoded, "completed_nodes", []),
       node_retries: Map.get(decoded, "node_retries", %{}),
       context_values: Map.get(decoded, "context_values", %{}),
       node_outcomes: outcomes,
       context_lineage: Map.get(decoded, "context_lineage", %{}),
       content_hashes: Map.get(decoded, "content_hashes", %{}),
       pending_intents: deserialize_intents(Map.get(decoded, "pending_intents", %{})),
       execution_digests: deserialize_digests(Map.get(decoded, "execution_digests", %{}))
     }}
  end

  # Deserialize pending_intents — atomize known keys within each intent map
  defp deserialize_intents(intents) when is_map(intents) do
    Map.new(intents, fn {node_id, intent} ->
      {node_id,
       %{
         handler: Map.get(intent, "handler") || Map.get(intent, :handler),
         input_hash: Map.get(intent, "input_hash") || Map.get(intent, :input_hash),
         started_at: Map.get(intent, "started_at") || Map.get(intent, :started_at),
         execution_id: Map.get(intent, "execution_id") || Map.get(intent, :execution_id)
       }}
    end)
  end

  defp deserialize_intents(_), do: %{}

  # Deserialize execution_digests — atomize known keys within each digest map
  defp deserialize_digests(digests) when is_map(digests) do
    Map.new(digests, fn {node_id, digest} ->
      {node_id,
       %{
         input_hash: Map.get(digest, "input_hash") || Map.get(digest, :input_hash),
         outcome_status:
           parse_status(
             to_string(
               Map.get(digest, "outcome_status") || Map.get(digest, :outcome_status, "success")
             )
           ),
         completed_at: Map.get(digest, "completed_at") || Map.get(digest, :completed_at),
         execution_id: Map.get(digest, "execution_id") || Map.get(digest, :execution_id)
       }}
    end)
  end

  defp deserialize_digests(_), do: %{}

  defp normalize_keys(data) when is_map(data) do
    data
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_keys(v)}
      {k, v} -> {k, normalize_keys(v)}
    end)
    |> Map.new()
  end

  defp normalize_keys(data), do: data

  defp maybe_verify(decoded, nil), do: {:ok, decoded}

  defp maybe_verify(decoded, secret) do
    # Extract AAD from the checkpoint data itself
    aad_opts = [
      run_id: Map.get(decoded, "run_id"),
      current_node: Map.get(decoded, "current_node"),
      graph_hash: Map.get(decoded, "graph_hash")
    ]

    verify(decoded, secret, aad_opts)
  end

  defp parse_status("success"), do: :success
  defp parse_status("partial_success"), do: :partial_success
  defp parse_status("retry"), do: :retry
  defp parse_status("fail"), do: :fail
  defp parse_status("skipped"), do: :skipped
  defp parse_status(_), do: :success

  # ---------------------------------------------------------------------------
  # Private — HMAC AAD derivation
  # ---------------------------------------------------------------------------

  # Produce deterministic JSON regardless of atom vs string keys.
  # Normalizes all keys to strings and sorts them for stable ordering.
  defp canonical_json(data) do
    data
    |> stringify_keys()
    |> Jason.encode!(pretty: true)
  end

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp derive_key(secret, aad_opts) do
    aad_parts =
      [:run_id, :current_node, :graph_hash]
      |> Enum.map(fn key -> Keyword.get(aad_opts, key, "") || "" end)

    aad = Enum.join(aad_parts, "|")
    :crypto.hash(:sha256, secret <> aad)
  end

  # ---------------------------------------------------------------------------
  # Private — TTL cleanup
  # ---------------------------------------------------------------------------

  defp do_cleanup_older_than(cutoff) do
    if store_available?() do
      case Arbor.Persistence.BufferedStore.list(name: @store_name) do
        {:ok, keys} ->
          checkpoint_keys = Enum.filter(keys, &String.starts_with?(&1, "checkpoint:"))

          Enum.count(checkpoint_keys, fn key ->
            case Arbor.Persistence.BufferedStore.get(key, name: @store_name) do
              {:ok, data} when is_map(data) ->
                ts = Map.get(data, "timestamp") || Map.get(data, :timestamp)

                case parse_timestamp(ts) do
                  {:ok, dt} ->
                    if DateTime.compare(dt, cutoff) == :lt do
                      Arbor.Persistence.BufferedStore.delete(key, name: @store_name)
                      true
                    else
                      false
                    end

                  _ ->
                    false
                end

              _ ->
                false
            end
          end)

        _ ->
          0
      end
    else
      0
    end
  end

  defp parse_timestamp(nil), do: {:error, nil}
  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp parse_timestamp(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid}
    end
  end

  defp parse_timestamp(_), do: {:error, :invalid}
end
