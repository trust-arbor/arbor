defmodule Arbor.Orchestrator.Engine.Checkpoint do
  @moduledoc """
  Pipeline checkpoint persistence with an honest write/durability contract.

  Checkpoints capture engine state (context, completed nodes, outcomes, retries)
  at each node completion. Persistence has two layers with distinct honesty
  guarantees:

  - **Injected store** (default: `Arbor.Persistence.BufferedStore` named
    `:arbor_orchestrator_checkpoints`) — optional process-lifetime cache for
    resume convenience. Not crash-durable by default. Use only the public
    `Arbor.Persistence` facade for put/get/delete/list/durability_class.
  - **Local `checkpoint.json`** — compatibility/debug artifact written with
    atomic same-directory temp-file replacement. Never counted as the durable
    effect journal.

  Prefer `persist/3`, which returns a bounded receipt or bounded error.
  `write/3` remains a compatibility wrapper that returns `:ok` only when every
  required/attempted write succeeded.

  HMAC signing uses expanded AAD: the secret is combined with `run_id`,
  `current_node`, and `graph_hash` to prevent checkpoint replay across
  different pipelines or modified graphs.

  Peer replication (when enabled) is best-effort only and is never treated as
  durable crash recovery.
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
          run_authorization: map() | nil,
          current_node: String.t(),
          completed_nodes: [String.t()],
          node_retries: map(),
          context_values: map(),
          context_taint: map(),
          node_outcomes: %{String.t() => Arbor.Orchestrator.Engine.Outcome.t()},
          context_lineage: map(),
          pipeline_started_at: DateTime.t() | nil,
          content_hashes: map(),
          pending_intents: %{String.t() => pending_intent()},
          execution_digests: %{String.t() => execution_digest()}
        }

  @type bounded_receipt :: %{
          required_key: :run_id | String.t() | nil,
          store: :ok | :skipped | :not_attempted,
          file: :ok | :not_attempted,
          durable: boolean(),
          durability_class: atom(),
          peer_replication: :not_requested | :best_effort_started | :skipped
        }

  require Logger

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @default_store_name :arbor_orchestrator_checkpoints
  @default_store Arbor.Persistence.BufferedStore
  @default_collection "orchestrator_checkpoints"
  @checkpoint_filename "checkpoint.json"
  @max_reason_bytes 256

  @durability_rank %{
    volatile: 0,
    process_lifetime: 1,
    application_restart: 2,
    node_restart: 3
  }

  defstruct timestamp: "",
            run_id: nil,
            graph_hash: nil,
            run_authorization: nil,
            current_node: "",
            completed_nodes: [],
            node_retries: %{},
            context_values: %{},
            context_taint: %{},
            node_outcomes: %{},
            context_lineage: %{},
            pipeline_started_at: nil,
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
      run_authorization: Keyword.get(opts, :run_authorization),
      current_node: current_node,
      completed_nodes: completed_nodes,
      node_retries: node_retries,
      context_values: Context.snapshot(context),
      context_taint: Keyword.get(opts, :context_taint, Context.taint_map(context)),
      node_outcomes: node_outcomes,
      context_lineage: Keyword.get(opts, :context_lineage, Context.lineage(context)),
      pipeline_started_at:
        Keyword.get(opts, :pipeline_started_at, Context.pipeline_started_at(context)),
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
  Persist a checkpoint with an honest bounded receipt.

  Writes the optional injected store (Record envelope) and the local
  compatibility `checkpoint.json` (atomic temp-file replace). Returns
  `{:ok, receipt}` only when every required/attempted write succeeded;
  otherwise `{:error, bounded_reason}` — never swallowed into `:ok`.

  ## Options

  - `:store` — backend module (default `BufferedStore`), or `nil` for file-only
  - `:store_name` — store name atom (default `:arbor_orchestrator_checkpoints`)
  - `:store_opts` — extra opts forwarded to `Arbor.Persistence.*`
  - `:durability_class` — ceiling/intersection only (never elevates backend)
  - `:hmac_secret` — optional HMAC secret
  - `:replicate` — best-effort peer copy; never counted as durable
  """
  @spec persist(t(), String.t(), keyword()) ::
          {:ok, bounded_receipt()} | {:error, term()}
  def persist(%__MODULE__{} = checkpoint, logs_root, opts \\ []) when is_binary(logs_root) do
    store_cfg = resolve_store_config(opts)
    durability = durability_status(opts)

    payload_map = build_payload(checkpoint, opts)

    store_result = maybe_put_store(checkpoint.run_id, payload_map, store_cfg)
    file_result = write_to_file(payload_map, logs_root)

    peer_result =
      if Keyword.get(opts, :replicate, false) do
        maybe_replicate_to_peer(checkpoint.run_id, payload_map, store_cfg)
      else
        :not_requested
      end

    receipt = %{
      run_id: checkpoint.run_id,
      store: store_result_tag(store_result),
      file: file_result_tag(file_result),
      durable: durability.durable == true,
      durability_class: durability.durability_class,
      peer_replication: peer_result
    }

    case {store_result, file_result} do
      {{:ok, _}, :ok} ->
        {:ok, receipt}

      {{:ok, :skipped}, :ok} ->
        {:ok, receipt}

      {{:error, reason}, _} ->
        {:error, bound_reason(reason)}

      {_, {:error, reason}} ->
        {:error, bound_reason(reason)}
    end
  end

  @doc """
  Compatibility write: returns `:ok` only when all required/attempted writes
  succeeded. Prefer `persist/3` for a bounded receipt.

  The local JSON file is a compatibility/debug artifact only — not a durable
  effect journal. Store writes go through `Arbor.Persistence` and surface
  failures rather than being rescued into `:ok`.
  """
  @spec write(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = checkpoint, logs_root, opts \\ []) do
    case persist(checkpoint, logs_root, opts) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load checkpoint, trying the configured store first then falling back to file.

  File fallback is allowed only for a genuine `{:error, :not_found}` from the
  store. Backend outages/errors are surfaced and never masquerade as missing.
  """
  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) do
    hmac_secret = Keyword.get(opts, :hmac_secret)
    store_cfg = resolve_store_config(opts)

    case Keyword.get(opts, :run_id) do
      nil ->
        load_from_file(path, hmac_secret)

      run_id when is_binary(run_id) ->
        case store_cfg do
          nil ->
            load_from_file(path, hmac_secret)

          cfg ->
            case load_from_store(run_id, hmac_secret, cfg) do
              {:ok, _} = result ->
                result

              {:error, :not_found} ->
                load_from_file(path, hmac_secret)

              {:error, reason} ->
                {:error, bound_reason(reason)}
            end
        end
    end
  end

  @doc """
  Report honest durability for the configured checkpoint store.

  - `durable` is true only for healthy `:application_restart` / `:node_restart`
    backends (code-owned via `Arbor.Persistence.durability_class/3`).
  - Default `BufferedStore` / process-lifetime and file-only modes are non-durable.
  - A caller-supplied `:durability_class` is a ceiling/intersection only and
    never elevates backend capability.
  - Peer replication is never counted as durable.
  """
  @spec durability_status(keyword()) :: map()
  def durability_status(opts \\ []) do
    store_cfg = resolve_store_config(opts)

    case store_cfg do
      nil ->
        %{
          mode: :file_only,
          durable: false,
          durability_class: :volatile,
          store: nil,
          store_name: nil,
          backend: nil,
          healthy: true,
          peer_replication_durable: false,
          last_error: nil
        }

      cfg ->
        class = resolve_durability_class(cfg, opts)
        healthy? = store_healthy?(cfg)
        durable? = durable_class?(class) and healthy?

        mode =
          cond do
            durable? -> :durable_declared
            true -> :store_nondurable
          end

        %{
          mode: mode,
          durable: durable?,
          durability_class: class,
          store: cfg.backend,
          store_name: cfg.name,
          backend: inspect(cfg.backend),
          healthy: healthy?,
          peer_replication_durable: false,
          last_error: nil
        }
    end
  end

  @doc """
  Delete checkpoint data from the configured store.

  Uses the public `Arbor.Persistence` facade. Missing keys are idempotent
  (`:ok`). Store outages are returned as bounded errors, not swallowed.
  """
  @spec cleanup(String.t(), keyword()) :: :ok | {:error, term()}
  def cleanup(run_id, opts \\ []) when is_binary(run_id) do
    case resolve_store_config(opts) do
      nil ->
        :ok

      cfg ->
        key = store_key(run_id)

        case store_delete(cfg, key) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> {:error, bound_reason(reason)}
        end
    end
  end

  @doc """
  Delete checkpoints older than the given duration from the configured store.

  Returns `{:ok, deleted_count}` or a bounded `{:error, reason}` on list/get
  outages. Does not swallow backend failures into a zero count.
  """
  @spec cleanup_older_than(non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_older_than(max_age_seconds, opts \\ [])
      when is_integer(max_age_seconds) and max_age_seconds >= 0 do
    case resolve_store_config(opts) do
      nil ->
        {:ok, 0}

      cfg ->
        cutoff = DateTime.add(DateTime.utc_now(), -max_age_seconds, :second)

        case do_cleanup_older_than(cfg, cutoff) do
          {:ok, count} -> {:ok, count}
          {:error, reason} -> {:error, bound_reason(reason)}
        end
    end
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
  # Private — payload / serialization
  # ---------------------------------------------------------------------------

  defp build_payload(%__MODULE__{} = checkpoint, opts) do
    payload_map = serialize(checkpoint)

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
  end

  defp serialize(%__MODULE__{} = checkpoint) do
    encoded_outcomes =
      checkpoint.node_outcomes
      |> Enum.map(fn {node_id, outcome} ->
        sanitized =
          outcome
          |> Map.from_struct()
          |> Map.update(:context_updates, %{}, &Map.drop(&1, @internal_keys))
          # taint_reductions is a list of {key, target, reason} tuples — transient
          # (applied immediately by the engine; its effect persists in
          # context_taint) and NOT reconstructed on deserialize. Drop it so the
          # checkpoint JSON/HMAC doesn't choke on tuples.
          |> Map.put(:taint_reductions, [])

        {node_id, sanitized}
      end)
      |> Map.new()

    lineage = serialize_lineage(checkpoint.context_lineage)

    checkpoint
    |> Map.from_struct()
    |> Map.put(:node_outcomes, encoded_outcomes)
    |> Map.update(:context_values, %{}, &Map.drop(&1, @internal_keys))
    |> Map.update(:context_taint, %{}, &serialize_taint/1)
    |> maybe_encode_pipeline_started_at()
    |> Map.put(:context_lineage, lineage)
  end

  # Provenance is a map of context-key -> %Taint{} struct. Persist each struct
  # via Signals.Taint.to_persistable (string-keyed map, deterministic for JSON +
  # HMAC). from_persistable fails closed (corrupt values -> most restrictive
  # defaults: :hostile level, :restricted sensitivity) on the way back in.
  defp serialize_taint(taint) when is_map(taint) do
    Map.new(taint, fn {key, struct} -> {key, Arbor.Signals.Taint.to_persistable(struct)} end)
  end

  defp serialize_taint(_), do: %{}

  defp deserialize_taint(taint) when is_map(taint) do
    Map.new(taint, fn {key, persisted} ->
      {key, Arbor.Signals.Taint.from_persistable(persisted)}
    end)
  end

  defp deserialize_taint(_), do: %{}

  defp serialize_lineage(lineage) when is_map(lineage) do
    Map.new(lineage, fn {key, entry} ->
      {key, serialize_lineage_entry(entry)}
    end)
  end

  defp serialize_lineage_entry(%Context.LineageEntry{} = e) do
    %{
      "node_id" => e.node_id,
      "step_timestamp" => DateTime.to_iso8601(e.step_timestamp),
      "pipeline_timestamp" => e.pipeline_timestamp && DateTime.to_iso8601(e.pipeline_timestamp),
      "operation" => e.operation
    }
  end

  # legacy map or string — pass through (we tolerate them on read)
  defp serialize_lineage_entry(other), do: other

  defp maybe_encode_pipeline_started_at(%{pipeline_started_at: %DateTime{} = dt} = map) do
    Map.put(map, :pipeline_started_at, DateTime.to_iso8601(dt))
  end

  defp maybe_encode_pipeline_started_at(map), do: map

  # ---------------------------------------------------------------------------
  # Private — store config / durability
  # ---------------------------------------------------------------------------

  defp resolve_store_config(opts) do
    backend =
      case Keyword.fetch(opts, :store) do
        :error -> @default_store
        {:ok, nil} -> nil
        {:ok, backend} when is_atom(backend) -> backend
        {:ok, _} -> nil
      end

    case backend do
      nil ->
        nil

      mod ->
        %{
          backend: mod,
          name: Keyword.get(opts, :store_name, @default_store_name),
          opts: Keyword.get(opts, :store_opts, [])
        }
    end
  end

  defp resolve_durability_class(nil, _opts), do: :volatile

  defp resolve_durability_class(cfg, opts) do
    capability = backend_durability_capability(cfg)
    ceiling = Keyword.get(opts, :durability_class)

    case ceiling do
      nil ->
        capability

      class when is_map_key(@durability_rank, class) ->
        intersect_durability_class(capability, class)

      _invalid ->
        # Invalid ceiling fails closed: cannot raise capability.
        intersect_durability_class(capability, :process_lifetime)
    end
  end

  defp backend_durability_capability(%{backend: backend, name: name, opts: store_opts}) do
    case Arbor.Persistence.durability_class(name, backend, store_opts) do
      {:ok, class} when is_map_key(@durability_rank, class) ->
        class

      {:ok, _invalid} ->
        :process_lifetime

      {:error, :unsupported} ->
        :process_lifetime

      {:error, _} ->
        :process_lifetime
    end
  rescue
    _ -> :process_lifetime
  catch
    :exit, _ -> :process_lifetime
  end

  defp intersect_durability_class(a, b) do
    rank_a = Map.fetch!(@durability_rank, a)
    rank_b = Map.fetch!(@durability_rank, b)

    if rank_a <= rank_b, do: a, else: b
  end

  defp durable_class?(class) when class in [:application_restart, :node_restart], do: true
  defp durable_class?(_), do: false

  defp store_healthy?(cfg) when is_map(cfg) do
    # Probe via the public facade list path so process-down and injected
    # backend outages report unhealthy (and therefore non-durable).
    case store_list(cfg) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp store_healthy?(_), do: false

  # ---------------------------------------------------------------------------
  # Private — store operations (public Persistence facade only)
  # ---------------------------------------------------------------------------

  defp maybe_put_store(nil, _payload_map, _cfg), do: {:ok, :skipped}
  defp maybe_put_store(_run_id, _payload_map, nil), do: {:ok, :skipped}

  defp maybe_put_store(run_id, payload_map, cfg) when is_binary(run_id) do
    key = store_key(run_id)

    record =
      PersistenceRecord.new(key, payload_map,
        metadata: %{
          "collection" => @default_collection,
          "type" => "engine_checkpoint"
        }
      )

    case store_put(cfg, key, record) do
      :ok -> {:ok, :written}
      {:error, reason} -> {:error, {:store_put_failed, reason}}
    end
  end

  defp store_put(%{backend: backend, name: name, opts: store_opts}, key, value) do
    case Arbor.Persistence.put(name, backend, key, value, store_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, bound_reason(reason)}
      other -> {:error, bound_reason({:unexpected_put_result, other})}
    end
  rescue
    e ->
      {:error, bound_exception(e)}
  catch
    :exit, reason ->
      {:error, bound_exit(reason)}
  end

  defp store_get(%{backend: backend, name: name, opts: store_opts}, key) do
    case Arbor.Persistence.get(name, backend, key, store_opts) do
      {:ok, value} ->
        {:ok, value}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:store_unavailable, bound_reason(reason)}}

      other ->
        {:error, {:store_unavailable, bound_reason({:unexpected_get_result, other})}}
    end
  rescue
    e ->
      {:error, {:store_unavailable, bound_exception(e)}}
  catch
    :exit, reason ->
      {:error, {:store_unavailable, bound_exit(reason)}}
  end

  defp store_delete(%{backend: backend, name: name, opts: store_opts}, key) do
    case Arbor.Persistence.delete(name, backend, key, store_opts) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:store_delete_failed, bound_reason(reason)}}
      other -> {:error, {:store_delete_failed, bound_reason(other)}}
    end
  rescue
    e ->
      {:error, {:store_delete_failed, bound_exception(e)}}
  catch
    :exit, reason ->
      {:error, {:store_delete_failed, bound_exit(reason)}}
  end

  defp store_list(%{backend: backend, name: name, opts: store_opts}) do
    case Arbor.Persistence.list(name, backend, store_opts) do
      {:ok, keys} when is_list(keys) ->
        {:ok, keys}

      {:error, reason} ->
        {:error, {:store_list_failed, bound_reason(reason)}}

      other ->
        {:error, {:store_list_failed, bound_reason(other)}}
    end
  rescue
    e ->
      {:error, {:store_list_failed, bound_exception(e)}}
  catch
    :exit, reason ->
      {:error, {:store_list_failed, bound_exit(reason)}}
  end

  defp load_from_store(run_id, hmac_secret, cfg) do
    key = store_key(run_id)

    case store_get(cfg, key) do
      {:ok, value} ->
        with {:ok, data} <- unwrap_store_value(value),
             decoded <- normalize_keys(data),
             {:ok, decoded} <- maybe_verify(decoded, hmac_secret) do
          deserialize(decoded)
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Postgres QueryableStore and Record-aware backends return %Record{}.
  # Legacy raw-map payloads remain readable for compatibility.
  defp unwrap_store_value(%PersistenceRecord{data: data}) when is_map(data), do: {:ok, data}

  defp unwrap_store_value(%{__struct__: mod, data: data}) when is_map(data) do
    if mod == PersistenceRecord do
      {:ok, data}
    else
      unwrap_legacy_map(%{data: data})
    end
  end

  defp unwrap_store_value(value) when is_map(value), do: unwrap_legacy_map(value)

  defp unwrap_store_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> unwrap_legacy_map(map)
      _ -> {:error, :invalid_checkpoint_payload}
    end
  end

  defp unwrap_store_value(_), do: {:error, :invalid_checkpoint_payload}

  defp unwrap_legacy_map(map) when is_map(map) do
    cond do
      # Serialized Record envelope (string keys)
      is_map(Map.get(map, "data")) and
          (Map.has_key?(map, "key") or Map.has_key?(map, "id") or Map.has_key?(map, "revision")) ->
        {:ok, Map.get(map, "data")}

      is_map(Map.get(map, :data)) and
          (Map.has_key?(map, :key) or Map.has_key?(map, :id) or Map.has_key?(map, :revision)) ->
        {:ok, Map.get(map, :data)}

      # Legacy raw checkpoint payload
      true ->
        {:ok, map}
    end
  end

  defp store_key(run_id), do: "checkpoint:#{run_id}"

  defp store_result_tag({:ok, :skipped}), do: :skipped
  defp store_result_tag({:ok, :written}), do: :ok
  defp store_result_tag({:error, _}), do: :error

  defp file_result_tag(:ok), do: :ok
  defp file_result_tag({:error, _}), do: :error

  # ---------------------------------------------------------------------------
  # Private — file operations (compat/debug only; not durable journal)
  # ---------------------------------------------------------------------------

  defp write_to_file(payload_map, logs_root) do
    path = Path.join(logs_root, @checkpoint_filename)
    tmp = Path.join(logs_root, tmp_checkpoint_name())

    try do
      with :ok <- File.mkdir_p(logs_root),
           {:ok, payload} <- Jason.encode(payload_map, pretty: true),
           :ok <- File.write(tmp, payload),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          cleanup_temp_file(tmp)
          cleanup_temp_globs(logs_root)
          {:error, {:file_write_failed, bound_reason(reason)}}
      end
    rescue
      e ->
        cleanup_temp_file(tmp)
        cleanup_temp_globs(logs_root)
        {:error, {:file_write_failed, bound_exception(e)}}
    end
  end

  defp tmp_checkpoint_name do
    "#{@checkpoint_filename}.#{System.unique_integer([:positive])}.#{:erlang.phash2(self())}.tmp"
  end

  defp cleanup_temp_file(tmp) when is_binary(tmp) do
    _ = File.rm(tmp)
    :ok
  end

  defp cleanup_temp_file(_), do: :ok

  defp cleanup_temp_globs(logs_root) when is_binary(logs_root) do
    pattern = Path.join(logs_root, "#{@checkpoint_filename}.*.tmp")

    for path <- Path.wildcard(pattern) do
      _ = File.rm(path)
    end

    :ok
  end

  defp load_from_file(path, hmac_secret) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, decoded} <- maybe_verify(decoded, hmac_secret) do
      deserialize(decoded)
    else
      {:error, reason} -> {:error, bound_reason(reason)}
      other -> {:error, bound_reason(other)}
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
       run_authorization: Map.get(decoded, "run_authorization"),
       current_node: Map.get(decoded, "current_node", ""),
       completed_nodes: Map.get(decoded, "completed_nodes", []),
       node_retries: Map.get(decoded, "node_retries", %{}),
       context_values: Map.get(decoded, "context_values", %{}),
       context_taint: deserialize_taint(Map.get(decoded, "context_taint", %{})),
       node_outcomes: outcomes,
       context_lineage: deserialize_lineage(Map.get(decoded, "context_lineage", %{})),
       pipeline_started_at: parse_optional_datetime(Map.get(decoded, "pipeline_started_at")),
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

  defp deserialize_lineage(lineage) when is_map(lineage) do
    Map.new(lineage, fn {key, entry} ->
      {key, deserialize_lineage_entry(entry)}
    end)
  end

  defp deserialize_lineage(_), do: %{}

  defp deserialize_lineage_entry(
         %{
           "node_id" => node_id,
           "step_timestamp" => step_str,
           "operation" => op
         } = m
       ) do
    %Context.LineageEntry{
      node_id: node_id,
      step_timestamp: parse_optional_datetime(step_str),
      pipeline_timestamp: parse_optional_datetime(Map.get(m, "pipeline_timestamp")),
      operation: parse_operation(op)
    }
  end

  # Legacy plain map or string — leave as-is for the accessors to tolerate
  defp deserialize_lineage_entry(other), do: other

  defp parse_operation("set"), do: :set
  defp parse_operation("merge"), do: :merge
  defp parse_operation(atom) when is_atom(atom), do: atom
  defp parse_operation(_), do: :set

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

  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_optional_datetime(%DateTime{} = dt), do: dt
  defp parse_optional_datetime(_), do: nil

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

  defp do_cleanup_older_than(cfg, cutoff) do
    case store_list(cfg) do
      {:ok, keys} ->
        checkpoint_keys = Enum.filter(keys, &String.starts_with?(&1, "checkpoint:"))

        result =
          Enum.reduce_while(checkpoint_keys, {:ok, 0}, fn key, {:ok, deleted} ->
            case maybe_delete_if_older(cfg, key, cutoff) do
              :deleted ->
                {:cont, {:ok, deleted + 1}}

              :kept ->
                {:cont, {:ok, deleted}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)

        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_delete_if_older(cfg, key, cutoff) do
    case store_get(cfg, key) do
      {:ok, value} ->
        case unwrap_store_value(value) do
          {:ok, data} when is_map(data) ->
            ts = Map.get(data, "timestamp") || Map.get(data, :timestamp)

            case parse_timestamp(ts) do
              {:ok, dt} ->
                if DateTime.compare(dt, cutoff) == :lt do
                  case store_delete(cfg, key) do
                    :ok -> :deleted
                    {:error, :not_found} -> :deleted
                    {:error, reason} -> {:error, reason}
                  end
                else
                  :kept
                end

              _ ->
                :kept
            end

          _ ->
            :kept
        end

      {:error, :not_found} ->
        :kept

      {:error, reason} ->
        {:error, reason}
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

  # ---------------------------------------------------------------------------
  # Private — best-effort peer replication (never durable)
  # ---------------------------------------------------------------------------

  # Best-effort peer copy for multi-node convenience only. Failures are logged
  # and never counted toward durable status or persist success.
  defp maybe_replicate_to_peer(nil, _payload_map, _cfg), do: :skipped
  defp maybe_replicate_to_peer(_run_id, _payload_map, nil), do: :skipped

  defp maybe_replicate_to_peer(run_id, payload_map, cfg) do
    peers = Node.list()

    if peers == [] do
      :skipped
    else
      peer = select_replication_peer(peers)
      key = store_key(run_id)

      record =
        PersistenceRecord.new(key, payload_map,
          metadata: %{
            "collection" => @default_collection,
            "type" => "engine_checkpoint"
          }
        )

      name = cfg.name
      backend = cfg.backend
      store_opts = cfg.opts

      Task.start(fn ->
        try do
          :erpc.call(
            peer,
            Arbor.Persistence,
            :put,
            [name, backend, key, record, store_opts],
            5_000
          )
        catch
          kind, reason ->
            Logger.debug(
              "[Checkpoint] Peer replication to #{peer} failed (best-effort, non-durable): #{inspect(kind)}: #{inspect(reason, limit: 50)}"
            )
        end
      end)

      :best_effort_started
    end
  end

  # Select a peer for checkpoint replication, preferring same trust zone.
  defp select_replication_peer(peers) do
    mod = Arbor.Cartographer.ClusterKeeper

    if Code.ensure_loaded?(mod) and function_exported?(mod, :trust_zone, 1) do
      my_zone = apply(mod, :trust_zone, [Kernel.node()])

      # Try same-zone peer first
      same_zone =
        Enum.find(peers, fn peer ->
          try do
            apply(mod, :trust_zone, [peer]) == my_zone
          rescue
            _ -> false
          end
        end)

      same_zone || List.first(peers)
    else
      List.first(peers)
    end
  rescue
    _ -> List.first(peers)
  end

  # ---------------------------------------------------------------------------
  # Private — bounded public error terms
  # ---------------------------------------------------------------------------

  defp bound_reason(reason) when is_atom(reason), do: reason

  defp bound_reason(reason) when is_binary(reason) do
    truncate_bytes(reason)
  end

  defp bound_reason(reason) when is_integer(reason) or is_float(reason) or is_boolean(reason) do
    reason
  end

  defp bound_reason(%{__exception__: true} = exception) do
    {:exception, truncate_bytes(Exception.message(exception))}
  end

  defp bound_reason({tag, inner}) when is_atom(tag) do
    {tag, bound_reason(inner)}
  end

  defp bound_reason(other) do
    truncate_bytes(inspect(other, limit: 20, printable_limit: 64))
  end

  defp bound_exception(exception) do
    {:exception, truncate_bytes(Exception.message(exception))}
  end

  defp bound_exit({:noproc, _}) do
    :store_unavailable
  end

  defp bound_exit(reason) do
    {:exit, truncate_bytes(inspect(reason, limit: 20, printable_limit: 64))}
  end

  defp truncate_bytes(bin) when is_binary(bin) do
    if byte_size(bin) <= @max_reason_bytes do
      bin
    else
      binary_part(bin, 0, @max_reason_bytes)
    end
  end

  defp truncate_bytes(other), do: truncate_bytes(inspect(other, limit: 20))
end
