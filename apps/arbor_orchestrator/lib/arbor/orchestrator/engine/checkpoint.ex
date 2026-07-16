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
          run_id: String.t() | nil,
          store: :ok | :skipped | :error | :not_attempted,
          file: :ok | :error | :not_attempted,
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
  @max_reason_depth 4

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
    with :ok <- validate_checkpoint_run_id(checkpoint.run_id),
         {:ok, store_cfg} <- resolve_store_config(opts) do
      durability = durability_status(opts)
      payload_map = build_payload(checkpoint, opts)

      store_result = maybe_put_store(checkpoint.run_id, payload_map, store_cfg)
      file_result = write_to_file(payload_map, logs_root)

      case {store_result, file_result} do
        {{:ok, _}, :ok} ->
          # Best-effort peer replication only after both required local writes
          # succeed. Never replicate a failed store or file attempt.
          peer_result =
            if Keyword.get(opts, :replicate, false) do
              maybe_replicate_to_peer(checkpoint.run_id, payload_map, store_cfg)
            else
              :not_requested
            end

          {:ok,
           %{
             run_id: checkpoint.run_id,
             store: store_result_tag(store_result),
             file: :ok,
             durable: durability.durable == true,
             durability_class: durability.durability_class,
             peer_replication: peer_result
           }}

        {{:error, reason}, _} ->
          {:error, bound_reason(reason)}

        {_, {:error, reason}} ->
          {:error, bound_reason(reason)}
      end
    else
      {:error, reason} ->
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
    with {:ok, store_cfg} <- resolve_store_config(opts) do
      hmac_secret = Keyword.get(opts, :hmac_secret)

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

        _invalid ->
          {:error, bound_reason({:invalid_option, :run_id_not_binary})}
      end
    else
      {:error, reason} ->
        {:error, bound_reason(reason)}
    end
  end

  @doc """
  Fetch the authenticated serialized checkpoint payload from the configured store.

  Owner primitive for L4 application/node recovery. Unlike `load/2`, this:

  - never falls back to a local `checkpoint.json`
  - returns the unwrapped checkpoint **payload map** (not `%__MODULE__{}` and
    not a `PersistenceRecord` wrapper)
  - treats explicit `store: nil` as not configured (`:store_not_configured`)
    rather than file-only success

  Uses the same store config resolution, exact `"checkpoint:<run_id>"` key,
  public `Arbor.Persistence` facade, and envelope-unwrapping path as
  `persist/3` / `load/2`. Does not accept arbitrary keys or expose backend
  internals.

  ## Options

  - `:store` / `:store_name` / `:store_opts` — same as `persist/3`
  - `:hmac_secret` — optional HMAC verification of the payload

  ## Errors (bounded, fail-closed)

  - `{:invalid_option, :run_id_not_binary}` — non-binary run_id
  - `{:invalid_store_config, _}` — malformed opts
  - `:store_not_configured` — explicit file-only (`store: nil`)
  - `:not_found` — missing exact prefixed key
  - `{:store_unavailable, _}` — backend outage / raise / throw / exit / bad shape
  - `:checkpoint_key_mismatch` — Record envelope key does not match store key
  - `:checkpoint_run_id_mismatch` — payload `run_id` missing/nonbinary/not equal
    to the requested run_id (after unwrap + optional HMAC verification)
  - `:invalid_checkpoint_payload` — non-map / corrupt / unreadable payload
  - `:tampered` — HMAC verification failed (when secret provided)
  """
  @spec fetch_persisted(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_persisted(run_id, opts \\ [])

  def fetch_persisted(run_id, opts) when is_binary(run_id) do
    with {:ok, store_cfg} <- resolve_store_config(opts),
         {:ok, cfg} <- require_configured_store(store_cfg) do
      hmac_secret = Keyword.get(opts, :hmac_secret)
      fetch_persisted_from_store(run_id, hmac_secret, cfg)
    else
      {:error, reason} ->
        {:error, bound_reason(reason)}
    end
  end

  def fetch_persisted(_run_id, _opts) do
    {:error, bound_reason({:invalid_option, :run_id_not_binary})}
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
    case resolve_store_config(opts) do
      {:error, reason} ->
        %{
          mode: :invalid_configuration,
          durable: false,
          durability_class: :volatile,
          store: nil,
          store_name: nil,
          backend: nil,
          healthy: false,
          peer_replication_durable: false,
          last_error: bound_reason(reason)
        }

      {:ok, nil} ->
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

      {:ok, cfg} ->
        class = resolve_durability_class(cfg, opts)
        {healthy?, probe_error} = store_health_probe(cfg)
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
          last_error: if(healthy?, do: nil, else: probe_error)
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
      {:error, reason} ->
        {:error, bound_reason(reason)}

      {:ok, nil} ->
        :ok

      {:ok, cfg} ->
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

  Non-binary keys returned by a backend are safely skipped (never raise).
  """
  @spec cleanup_older_than(non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_older_than(max_age_seconds, opts \\ [])
      when is_integer(max_age_seconds) and max_age_seconds >= 0 do
    case resolve_store_config(opts) do
      {:error, reason} ->
        {:error, bound_reason(reason)}

      {:ok, nil} ->
        {:ok, 0}

      {:ok, cfg} ->
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
  Check for orphaned PendingIntents (intents without a matching current-visit digest).

  A legacy pending_intent is resolved only when `execution_digests[node_id]`
  carries the **same nonblank** `execution_id` and matching `input_hash`
  (atom or string map keys). A later/different visit marker for the same
  `node_id` must not mask an older indeterminate intent — that would bypass
  the legacy side-effect gate on resume. Malformed digests also leave the
  intent orphaned.
  """
  @spec orphaned_intents(t()) :: [{String.t(), pending_intent()}]
  def orphaned_intents(%__MODULE__{} = checkpoint) do
    digests = checkpoint.execution_digests || %{}

    Enum.filter(checkpoint.pending_intents, fn {node_id, intent} ->
      not matching_execution_digest?(Map.get(digests, node_id), intent)
    end)
  end

  # Resolve a legacy intent only against an exact visit identity. Presence of
  # any digest for the node_id is insufficient once L3C writes current-visit
  # markers into the same map.
  defp matching_execution_digest?(digest, intent) when is_map(digest) and is_map(intent) do
    digest_exec = digest_field(digest, :execution_id)
    digest_hash = digest_field(digest, :input_hash)
    intent_exec = digest_field(intent, :execution_id)
    intent_hash = digest_field(intent, :input_hash)

    nonblank_binary?(digest_exec) and nonblank_binary?(digest_hash) and
      nonblank_binary?(intent_exec) and nonblank_binary?(intent_hash) and
      digest_exec == intent_exec and digest_hash == intent_hash
  end

  defp matching_execution_digest?(_digest, _intent), do: false

  defp digest_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp nonblank_binary?(value) when is_binary(value), do: value != ""
  defp nonblank_binary?(_), do: false

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

  # Returns {:ok, nil} for intentional file-only, {:ok, cfg} for a store, or
  # {:error, {:invalid_store_config, reason}} when options are malformed.
  # Invalid :store must never silently weaken to file-only.
  defp resolve_store_config(opts) do
    cond do
      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, {:invalid_store_config, :opts_not_keyword}}

      true ->
        case Keyword.fetch(opts, :store) do
          :error ->
            build_store_config(@default_store, opts)

          {:ok, nil} ->
            # Explicit file-only mode.
            {:ok, nil}

          {:ok, backend} when is_atom(backend) ->
            build_store_config(backend, opts)

          {:ok, _} ->
            {:error, {:invalid_store_config, :store_not_atom_or_nil}}
        end
    end
  end

  defp build_store_config(backend, opts) when is_atom(backend) do
    name = Keyword.get(opts, :store_name, @default_store_name)
    store_opts = Keyword.get(opts, :store_opts, [])

    cond do
      not is_atom(name) ->
        {:error, {:invalid_store_config, :store_name_not_atom}}

      not is_list(store_opts) or not Keyword.keyword?(store_opts) ->
        {:error, {:invalid_store_config, :store_opts_not_keyword}}

      true ->
        {:ok, %{backend: backend, name: name, opts: store_opts}}
    end
  end

  defp validate_checkpoint_run_id(nil), do: :ok
  defp validate_checkpoint_run_id(run_id) when is_binary(run_id), do: :ok

  defp validate_checkpoint_run_id(_run_id),
    do: {:error, {:invalid_checkpoint, :run_id_not_binary_or_nil}}

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
    _kind, _reason -> :process_lifetime
  end

  defp intersect_durability_class(a, b) do
    rank_a = Map.fetch!(@durability_rank, a)
    rank_b = Map.fetch!(@durability_rank, b)

    if rank_a <= rank_b, do: a, else: b
  end

  defp durable_class?(class) when class in [:application_restart, :node_restart], do: true
  defp durable_class?(_), do: false

  # Probe via the public facade list path so process-down and injected
  # backend outages report unhealthy (and therefore non-durable).
  defp store_health_probe(cfg) when is_map(cfg) do
    case store_list(cfg) do
      {:ok, _} -> {true, nil}
      {:error, reason} -> {false, bound_reason(reason)}
      other -> {false, bound_reason({:unexpected_health_probe, other})}
    end
  end

  defp store_health_probe(_), do: {false, :store_unavailable}

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

  defp maybe_put_store(_run_id, _payload_map, _cfg),
    do: {:error, {:invalid_option, :run_id_not_binary}}

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
    kind, reason ->
      {:error, bound_catch(kind, reason)}
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
    kind, reason ->
      {:error, {:store_unavailable, bound_catch(kind, reason)}}
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
    kind, reason ->
      {:error, {:store_delete_failed, bound_catch(kind, reason)}}
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
    kind, reason ->
      {:error, {:store_list_failed, bound_catch(kind, reason)}}
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

  # Explicit file-only config is unavailable for store-backed recovery fetch.
  defp require_configured_store(nil), do: {:error, :store_not_configured}
  defp require_configured_store(cfg) when is_map(cfg), do: {:ok, cfg}

  defp fetch_persisted_from_store(requested_run_id, hmac_secret, cfg)
       when is_binary(requested_run_id) do
    # Bind all three identities: lookup key, envelope key (when present), and
    # authenticated payload run_id. HMAC verifies payload integrity under the
    # payload's own AAD and does not alone prove lookup-key binding.
    key = store_key(requested_run_id)

    case store_get(cfg, key) do
      {:ok, value} ->
        with :ok <- validate_persisted_record_key(value, key),
             {:ok, data} <- unwrap_store_value(value),
             {:ok, data} <- ensure_checkpoint_payload_map(data),
             decoded <- normalize_keys(data),
             {:ok, decoded} <- maybe_verify(decoded, hmac_secret),
             {:ok, decoded} <- ensure_checkpoint_payload_map(decoded),
             :ok <- validate_payload_run_id(decoded, requested_run_id) do
          {:ok, decoded}
        else
          {:error, reason} ->
            {:error, bound_reason(reason)}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, bound_reason(reason)}
    end
  end

  # After unwrap + key normalization + optional HMAC, payload run_id must be an
  # exact binary match to the requested run. Missing/nonbinary/different fail closed.
  defp validate_payload_run_id(payload, requested_run_id)
       when is_map(payload) and is_binary(requested_run_id) do
    case Map.get(payload, "run_id") do
      ^requested_run_id ->
        :ok

      _mismatch ->
        {:error, :checkpoint_run_id_mismatch}
    end
  end

  defp validate_payload_run_id(_payload, _requested_run_id),
    do: {:error, :checkpoint_run_id_mismatch}

  # Record envelopes must bind the exact store key; mismatches fail closed so a
  # swapped or mis-keyed PersistenceRecord cannot be accepted as this run_id.
  defp validate_persisted_record_key(%PersistenceRecord{key: record_key}, expected_key)
       when is_binary(record_key) and is_binary(expected_key) do
    if record_key == expected_key do
      :ok
    else
      {:error, :checkpoint_key_mismatch}
    end
  end

  defp validate_persisted_record_key(%PersistenceRecord{}, _expected_key) do
    {:error, :checkpoint_key_mismatch}
  end

  defp validate_persisted_record_key(%{__struct__: mod, key: record_key}, expected_key)
       when is_atom(mod) and is_binary(record_key) and is_binary(expected_key) do
    if mod == PersistenceRecord do
      if record_key == expected_key, do: :ok, else: {:error, :checkpoint_key_mismatch}
    else
      :ok
    end
  end

  defp validate_persisted_record_key(map, expected_key)
       when is_map(map) and not is_map_key(map, :__struct__) and is_binary(expected_key) do
    # Serialized Record-shaped envelopes carry an explicit key + data map.
    data = Map.get(map, "data") || Map.get(map, :data)
    key = Map.get(map, "key") || Map.get(map, :key)

    envelope? =
      is_map(data) and
        (Map.has_key?(map, "key") or Map.has_key?(map, :key) or Map.has_key?(map, "id") or
           Map.has_key?(map, :id) or Map.has_key?(map, "revision") or
           Map.has_key?(map, :revision))

    cond do
      not envelope? ->
        :ok

      is_binary(key) and key == expected_key ->
        :ok

      true ->
        {:error, :checkpoint_key_mismatch}
    end
  end

  defp validate_persisted_record_key(_value, _expected_key), do: :ok

  defp ensure_checkpoint_payload_map(data) when is_map(data) do
    if Map.has_key?(data, :__struct__) do
      {:error, :invalid_checkpoint_payload}
    else
      {:ok, data}
    end
  end

  defp ensure_checkpoint_payload_map(_), do: {:error, :invalid_checkpoint_payload}

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

  # ---------------------------------------------------------------------------
  # Private — file operations (compat/debug only; not durable journal)
  # ---------------------------------------------------------------------------

  # Atomic same-directory replacement following CodingPlan.ArtifactStore:
  # exclusive create, chmod 0600 before payload write, rename, exact-path
  # cleanup only (never wildcard-delete sibling temps).
  defp write_to_file(payload_map, logs_root) do
    path = Path.join(logs_root, @checkpoint_filename)
    tmp = temporary_checkpoint_path(path)

    try do
      with :ok <- File.mkdir_p(logs_root),
           {:ok, payload} <- Jason.encode(payload_map, pretty: true),
           :ok <- write_secure_temp(tmp, payload),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          {:error, {:file_write_failed, bound_reason(reason)}}
      end
    rescue
      e ->
        {:error, {:file_write_failed, bound_exception(e)}}
    after
      # Remove only this call's exact temp path if it still exists.
      _ = File.rm(tmp)
    end
  end

  defp write_secure_temp(path, content) when is_binary(path) and is_binary(content) do
    # Empty exclusive file first; set restrictive mode before payload bytes.
    case File.open(path, [:write, :binary, :exclusive], fn device ->
           with :ok <- File.chmod(path, 0o600),
                :ok <- IO.binwrite(device, content) do
             :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp temporary_checkpoint_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")
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

  defp parse_status(status)
       when status in [:success, :partial_success, :retry, :fail, :skipped],
       do: status

  defp parse_status("success"), do: :success
  defp parse_status("partial_success"), do: :partial_success
  defp parse_status("retry"), do: :retry
  defp parse_status("fail"), do: :fail
  defp parse_status("skipped"), do: :skipped
  defp parse_status(_unknown), do: :fail

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
      {:ok, keys} when is_list(keys) ->
        # Safely skip non-binary keys; never raise on String.starts_with?/2.
        checkpoint_keys =
          Enum.filter(keys, fn
            key when is_binary(key) -> String.starts_with?(key, "checkpoint:")
            _malformed -> false
          end)

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

      {:ok, _other} ->
        {:error, {:store_list_failed, :keys_not_list}}

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
  # Private — bounded public error terms (JSON-safe, depth-limited)
  # ---------------------------------------------------------------------------

  defp bound_reason(reason), do: bound_reason(reason, 0)

  defp bound_reason(_reason, depth) when depth >= @max_reason_depth do
    :error_depth_exceeded
  end

  defp bound_reason(reason, _depth) when is_atom(reason), do: reason

  defp bound_reason(reason, _depth) when is_binary(reason) do
    truncate_utf8_safe(reason)
  end

  defp bound_reason(reason, _depth)
       when is_integer(reason) or is_float(reason) or is_boolean(reason) do
    reason
  end

  defp bound_reason(%{__exception__: true} = exception, _depth) do
    {:exception, truncate_utf8_safe(Exception.message(exception))}
  end

  defp bound_reason({tag, inner}, depth) when is_atom(tag) do
    {tag, bound_reason(inner, depth + 1)}
  end

  defp bound_reason([head | tail], depth) do
    bound_list(tail, depth + 1, 7, [bound_reason(head, depth + 1)])
  end

  defp bound_reason(other, _depth) do
    truncate_utf8_safe(inspect(other, limit: 20, printable_limit: 64))
  end

  defp bound_list([], _depth, _remaining, acc), do: Enum.reverse(acc)

  defp bound_list([head | tail], depth, remaining, acc) when remaining > 0 do
    bound_list(tail, depth, remaining - 1, [bound_reason(head, depth) | acc])
  end

  defp bound_list(_tail, _depth, 0, acc), do: Enum.reverse([:truncated | acc])

  defp bound_list(improper_tail, depth, _remaining, acc) do
    Enum.reverse([bound_reason(improper_tail, depth) | acc])
  end

  defp bound_exception(exception) do
    {:exception, truncate_utf8_safe(Exception.message(exception))}
  end

  defp bound_exit({:noproc, _}) do
    :store_unavailable
  end

  defp bound_exit(reason) do
    {:exit, truncate_utf8_safe(inspect(reason, limit: 20, printable_limit: 64))}
  end

  defp bound_catch(:exit, reason), do: bound_exit(reason)
  defp bound_catch(kind, reason), do: {kind, bound_reason(reason, 1)}

  # Truncate on a valid UTF-8 boundary so public errors stay JSON-safe.
  defp truncate_utf8_safe(bin) when is_binary(bin) do
    candidate =
      if byte_size(bin) <= @max_reason_bytes do
        bin
      else
        binary_part(bin, 0, @max_reason_bytes)
      end

    if String.valid?(candidate) do
      candidate
    else
      trim_to_valid_utf8(candidate)
    end
  end

  defp truncate_utf8_safe(other), do: truncate_utf8_safe(inspect(other, limit: 20))

  defp trim_to_valid_utf8(bin) when is_binary(bin) do
    size = byte_size(bin)
    do_trim_utf8(bin, size)
  end

  defp do_trim_utf8(_bin, size) when size <= 0, do: ""

  defp do_trim_utf8(bin, size) do
    part = binary_part(bin, 0, size)

    if String.valid?(part) do
      part
    else
      do_trim_utf8(bin, size - 1)
    end
  end
end
