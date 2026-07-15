defmodule Arbor.Orchestrator.RunLifecycle.Adapter do
  @moduledoc """
  Pure adapters between lifecycle shapes.

  Converts:
  - `RunState.Core` (+ optional recovery metadata) → `Record`
  - current lifecycle maps → `Record`
  - historical `JobRegistry.Entry` / maps → `Record`
  - `Record` → public JSON-clean map (runtime view)
  - `Record` → durable JSON-clean map (no PIDs)

  Identity and recovery-pointer fields (`run_id`, `pipeline_id`,
  `execution_principal`, `graph_hash`, `dot_source_path`, `logs_root`) are
  **invariants**: writers validate exact nonempty UTF-8 binaries + byte
  ceilings and reject rather than truncating, atom-coercing, or substituting
  `"unknown"`. Missing `run_id` is never filled from `pipeline_id`.

  Bound work is total: no full list walks, no `Tuple.to_list/1` on unbounded
  tuples, no large-integer encode/inspect paths. Diagnostic fields may be
  truncated; identity may not.
  """

  alias Arbor.Orchestrator.JobRegistry.Entry, as: JobEntry
  alias Arbor.Orchestrator.RunLifecycle.EffectEnvelope
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.RunState.Core, as: RunState

  # Diagnostic / structure bounds
  @max_string_bytes 1_024
  @max_depth 4
  @max_collection_items 32
  @max_failure_bytes 512
  @max_payload_bytes 8_192
  @max_completed_nodes 256
  @max_node_duration_entries 256
  # Signed 63-bit magnitude ceiling — compare only, never encode bignums.
  @max_int 9_223_372_036_854_775_807
  # JSON-safe generation ceiling (2^53 - 1) for effect_generation.
  @max_json_safe_int 9_007_199_254_740_991

  # Identity / recovery-pointer ceilings (exact preserve or reject)
  @max_id_bytes 256
  @max_hash_bytes 128
  @max_path_bytes 1_024
  @max_principal_bytes 256

  @public_keys [
    :run_id,
    :pipeline_id,
    :graph_id,
    :status,
    :total_nodes,
    :completed_count,
    :completed_nodes,
    :current_node,
    :node_durations,
    :started_at,
    :finished_at,
    :duration_ms,
    :failure_reason,
    :owner_node,
    :source_node,
    :origin_trust_zone,
    :last_heartbeat,
    :last_ets_sync,
    :graph_hash,
    :dot_source_path,
    :logs_root,
    :execution_principal,
    :effect_generation,
    :current_effect,
    :spawning_pid
  ]

  @doc "Build a Record from process-local RunState plus optional recovery metadata."
  @spec from_run_state(RunState.t(), map() | keyword()) :: Record.t()
  def from_run_state(%RunState{} = state, meta \\ %{}) do
    meta = normalize_meta(meta)
    entry = RunState.to_ets_entry(state)

    %Record{
      run_id: state.run_id,
      pipeline_id: state.pipeline_id || state.run_id,
      graph_id: state.graph_id,
      status: state.status,
      total_nodes: state.total_nodes,
      completed_count: state.completed_count,
      completed_nodes: Map.get(entry, :completed_nodes, []),
      current_node: state.current_node,
      node_durations: state.node_durations || %{},
      started_at: state.started_at,
      finished_at: state.finished_at,
      duration_ms: state.duration_ms,
      failure_reason: Map.get(entry, :failure_reason),
      owner_node: state.owner_node,
      source_node: state.source_node,
      origin_trust_zone: Map.get(meta, :origin_trust_zone),
      last_heartbeat: state.last_heartbeat,
      last_ets_sync: state.last_ets_sync,
      graph_hash: Map.get(meta, :graph_hash),
      dot_source_path: Map.get(meta, :dot_source_path),
      logs_root: Map.get(meta, :logs_root),
      execution_principal: Map.get(meta, :execution_principal),
      # Effect evidence is journal-owned; RunState never carries it.
      effect_generation: 0,
      current_effect: nil,
      spawning_pid: state.spawning_pid
    }
  end

  @doc "Build a Record from a current lifecycle map (ETS / public view)."
  @spec from_lifecycle_map(map()) :: Record.t()
  def from_lifecycle_map(data) when is_map(data) do
    # Do not substitute "unknown" or fall back pipeline_id → run_id.
    # Validation rejects empty/non-binary identity at write time.
    run_id = fetch_raw_binary(data, :run_id)
    pipeline_id = fetch_raw_binary(data, :pipeline_id)

    %Record{
      run_id: run_id || "",
      pipeline_id: pipeline_id || "",
      graph_id: fetch_raw_string(data, :graph_id),
      status: parse_status(fetch(data, :status)),
      total_nodes: fetch_non_neg(data, :total_nodes, 0),
      completed_count: fetch_non_neg(data, :completed_count, 0),
      completed_nodes: fetch_list(data, :completed_nodes),
      current_node: fetch_raw_string(data, :current_node),
      node_durations: fetch_map(data, :node_durations),
      started_at: parse_datetime(fetch(data, :started_at)),
      finished_at: parse_datetime(fetch(data, :finished_at)),
      duration_ms: fetch(data, :duration_ms),
      failure_reason: sanitize_failure_reason(fetch(data, :failure_reason)),
      owner_node: parse_node_name(fetch(data, :owner_node)),
      source_node: parse_node_name(fetch(data, :source_node)),
      origin_trust_zone: fetch(data, :origin_trust_zone),
      last_heartbeat: parse_datetime(fetch(data, :last_heartbeat)),
      last_ets_sync: parse_datetime(fetch(data, :last_ets_sync)),
      graph_hash: fetch_raw_binary(data, :graph_hash),
      dot_source_path: fetch_raw_binary(data, :dot_source_path),
      logs_root: fetch_raw_binary(data, :logs_root),
      execution_principal: fetch_raw_binary(data, :execution_principal),
      effect_generation: fetch_effect_generation(data),
      current_effect: fetch_current_effect(data),
      spawning_pid: fetch_pid(data, :spawning_pid)
    }
  end

  @doc "Build a Record from a historical JobRegistry.Entry or map."
  @spec from_job_entry(JobEntry.t() | map()) :: Record.t()
  def from_job_entry(%JobEntry{} = entry) do
    from_lifecycle_map(Map.from_struct(entry))
  end

  def from_job_entry(data) when is_map(data), do: from_lifecycle_map(data)

  @doc """
  Public/runtime view map including runtime-only `spawning_pid`.

  **Not JSON-clean / not necessarily Jason-encodable**: may contain
  `DateTime`, atom status/nodes, and `PID`. Durable serialization is
  separate (`to_durable_map/1`).
  """
  @spec to_public_map(Record.t()) :: map()
  def to_public_map(%Record{} = record) do
    record
    |> Map.from_struct()
    |> Map.take(@public_keys)
    |> Map.update!(:failure_reason, &sanitize_failure_reason/1)
    |> Map.update!(:owner_node, &node_to_public/1)
    |> Map.update!(:source_node, &node_to_public/1)
  end

  @doc """
  Durable payload: JSON-clean map **without** PIDs or non-serializable terms.

  Requires a previously validated/normalized record (identity already exact).
  Bounds diagnostic fields; re-checks final encoded size ≤ 8 KiB. Fallback
  drops progress/diagnostics only — never alters identity fields.
  """
  @spec to_durable_map(Record.t()) :: {:ok, map()} | {:error, term()}
  def to_durable_map(%Record{} = record) do
    with {:ok, record} <- validate_and_normalize_record(record) do
      payload = %{
        "run_id" => record.run_id,
        "pipeline_id" => record.pipeline_id,
        "graph_id" => diagnostic_string(record.graph_id),
        "status" => status_to_string(whitelist_status(record.status)),
        "total_nodes" => bound_non_neg_int(record.total_nodes, 0),
        "completed_count" => bound_non_neg_int(record.completed_count, 0),
        "completed_nodes" =>
          record.completed_nodes
          |> take_bounded(@max_completed_nodes)
          |> map_bounded(&json_scalar(&1, 0)),
        "current_node" => diagnostic_string(record.current_node),
        "node_durations" => durable_node_durations(record.node_durations || %{}),
        "started_at" => datetime_to_iso(record.started_at),
        "finished_at" => datetime_to_iso(record.finished_at),
        "duration_ms" => bound_optional_non_neg_int(record.duration_ms),
        "failure_reason" => durable_failure_reason(record.failure_reason),
        "owner_node" => diagnostic_string(node_to_string(record.owner_node)),
        "source_node" => diagnostic_string(node_to_string(record.source_node)),
        "origin_trust_zone" => durable_trust_zone(record.origin_trust_zone),
        "last_heartbeat" => datetime_to_iso(record.last_heartbeat),
        "last_ets_sync" => datetime_to_iso(record.last_ets_sync),
        "graph_hash" => record.graph_hash,
        "dot_source_path" => record.dot_source_path,
        "logs_root" => record.logs_root,
        "execution_principal" => record.execution_principal,
        "effect_generation" => record.effect_generation || 0,
        "current_effect" => record.current_effect
      }

      bound_final_payload(payload)
    end
  end

  @doc "Reconstruct a Record from a durable map (string or atom keys)."
  @spec from_durable_map(map()) :: Record.t()
  def from_durable_map(data) when is_map(data), do: from_lifecycle_map(data)

  @doc """
  Merge recovery metadata onto an existing record.

  **Nil values never erase** retained fields (`dot_source_path`, `graph_hash`,
  `logs_root`, `execution_principal`, owner/source metadata, etc.).
  """
  @spec merge_meta(Record.t(), map() | keyword()) :: Record.t()
  def merge_meta(%Record{} = record, meta) do
    meta = normalize_meta(meta)

    %Record{
      record
      | graph_hash: prefer_non_nil(Map.get(meta, :graph_hash), record.graph_hash),
        dot_source_path: prefer_non_nil(Map.get(meta, :dot_source_path), record.dot_source_path),
        logs_root: prefer_non_nil(Map.get(meta, :logs_root), record.logs_root),
        execution_principal:
          prefer_non_nil(Map.get(meta, :execution_principal), record.execution_principal),
        origin_trust_zone:
          prefer_non_nil(Map.get(meta, :origin_trust_zone), record.origin_trust_zone),
        spawning_pid: prefer_non_nil(Map.get(meta, :spawning_pid), record.spawning_pid),
        owner_node: prefer_non_nil(Map.get(meta, :owner_node), record.owner_node),
        source_node: prefer_non_nil(Map.get(meta, :source_node), record.source_node)
    }
  end

  @doc """
  Bound failure metadata for hot and durable storage.
  """
  @spec bound_failure_reason(term()) :: term()
  def bound_failure_reason(reason), do: sanitize_failure_reason(reason)

  @doc """
  Validate identity/recovery invariants and bound diagnostic fields.

  Returns `{:ok, record}` or `{:error, {:invalid_lifecycle_identity, reason}}`
  / `{:error, {:invalid_recovery_pointer, reason}}`. Never substitutes
  `"unknown"` for missing identity.
  """
  @spec validate_and_normalize_record(Record.t()) :: {:ok, Record.t()} | {:error, term()}
  def validate_and_normalize_record(%Record{} = record) do
    with {:ok, run_id} <- require_identity(record.run_id, :run_id, @max_id_bytes),
         {:ok, pipeline_id} <-
           require_identity(
             if(is_binary(record.pipeline_id) and record.pipeline_id != "",
               do: record.pipeline_id,
               else: run_id
             ),
             :pipeline_id,
             @max_id_bytes
           ),
         {:ok, graph_hash} <- optional_identity(record.graph_hash, :graph_hash, @max_hash_bytes),
         {:ok, dot_source_path} <-
           optional_identity(record.dot_source_path, :dot_source_path, @max_path_bytes),
         {:ok, logs_root} <- optional_identity(record.logs_root, :logs_root, @max_path_bytes),
         {:ok, execution_principal} <-
           optional_identity(
             record.execution_principal,
             :execution_principal,
             @max_principal_bytes
           ),
         {:ok, effect_generation, current_effect} <- validate_effect_fields(record) do
      {:ok,
       %Record{
         record
         | run_id: run_id,
           pipeline_id: pipeline_id,
           graph_id: diagnostic_string(record.graph_id),
           total_nodes: bound_non_neg_int(record.total_nodes, 0),
           completed_count: bound_non_neg_int(record.completed_count, 0),
           completed_nodes:
             record.completed_nodes
             |> take_bounded(@max_completed_nodes)
             |> map_bounded(&diagnostic_string/1)
             |> Enum.reject(&is_nil/1),
           current_node: diagnostic_string(record.current_node),
           node_durations: bound_hot_node_durations(record.node_durations || %{}),
           duration_ms: bound_optional_non_neg_int(record.duration_ms),
           failure_reason: sanitize_failure_reason(record.failure_reason),
           owner_node: bound_node_field(record.owner_node),
           source_node: bound_node_field(record.source_node),
           origin_trust_zone: bound_hot_trust_zone(record.origin_trust_zone),
           graph_hash: graph_hash,
           dot_source_path: dot_source_path,
           logs_root: logs_root,
           execution_principal: execution_principal,
           effect_generation: effect_generation,
           current_effect: current_effect
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize_meta(meta) when is_list(meta), do: Map.new(meta)
  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp prefer_non_nil(nil, preserved), do: preserved
  defp prefer_non_nil(value, _preserved), do: value

  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # Raw binary fetch for identity — exact binaries only, no atom coercion.
  defp fetch_raw_binary(map, key) do
    case fetch(map, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  # Diagnostic string fetch may still accept atoms (lossy display path only).
  defp fetch_raw_string(map, key) do
    case fetch(map, key) do
      v when is_binary(v) -> v
      v when is_atom(v) and not is_nil(v) -> Atom.to_string(v)
      _ -> nil
    end
  end

  defp fetch_non_neg(map, key, default) do
    case fetch(map, key) do
      n when is_integer(n) and n >= 0 -> bound_non_neg_int(n, default)
      _ -> default
    end
  end

  defp fetch_list(map, key) do
    case fetch(map, key) do
      list when is_list(list) -> take_bounded(list, @max_completed_nodes)
      _ -> []
    end
  end

  defp fetch_map(map, key) do
    case fetch(map, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp fetch_pid(map, key) do
    case fetch(map, key) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @known_statuses [
    :running,
    :completed,
    :failed,
    :interrupted,
    :abandoned,
    :recovering,
    :suspended,
    :delegated,
    :degraded,
    :unknown
  ]

  defp parse_status(s) when is_atom(s), do: whitelist_status(s)
  defp parse_status("running"), do: :running
  defp parse_status("completed"), do: :completed
  defp parse_status("failed"), do: :failed
  defp parse_status("interrupted"), do: :interrupted
  defp parse_status("abandoned"), do: :abandoned
  defp parse_status("recovering"), do: :recovering
  defp parse_status("suspended"), do: :suspended
  defp parse_status("delegated"), do: :delegated
  defp parse_status("degraded"), do: :degraded
  defp parse_status("unknown"), do: :unknown
  defp parse_status(_), do: :unknown

  defp whitelist_status(s) when s in @known_statuses, do: s
  defp whitelist_status(_), do: :unknown

  defp status_to_string(s) when is_atom(s), do: Atom.to_string(s)
  defp status_to_string(s) when is_binary(s), do: s
  defp status_to_string(_), do: "unknown"

  defp parse_node_name(nil), do: nil
  defp parse_node_name(n) when is_atom(n), do: n

  defp parse_node_name(n) when is_binary(n) do
    case Arbor.Common.SafeAtom.to_existing(n) do
      {:ok, atom} -> atom
      {:error, _} -> n
    end
  end

  defp parse_node_name(_), do: nil

  defp node_to_public(nil), do: nil
  defp node_to_public(n) when is_atom(n), do: n
  defp node_to_public(n) when is_binary(n), do: n
  defp node_to_public(_), do: nil

  defp node_to_string(nil), do: nil
  defp node_to_string(n) when is_atom(n), do: Atom.to_string(n)
  defp node_to_string(n) when is_binary(n), do: n
  defp node_to_string(_), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp datetime_to_iso(nil), do: nil
  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso(_), do: nil

  # ---- identity validation (exact or reject) ----

  defp require_identity(value, field, max_bytes) do
    case validate_identity_string(value, max_bytes) do
      {:ok, s} -> {:ok, s}
      {:error, reason} -> {:error, {:invalid_lifecycle_identity, field, reason}}
    end
  end

  defp optional_identity(nil, _field, _max), do: {:ok, nil}

  defp optional_identity(value, field, max_bytes) do
    case validate_identity_string(value, max_bytes) do
      {:ok, s} -> {:ok, s}
      {:error, reason} -> {:error, {:invalid_recovery_pointer, field, reason}}
    end
  end

  # Exact nonempty binaries only — never atom-coerce identity values.
  defp validate_identity_string(value, max_bytes) when is_binary(value) do
    cond do
      value == "" ->
        {:error, :empty}

      byte_size(value) > max_bytes ->
        {:error, :oversized}

      not String.valid?(value) ->
        {:error, :invalid_utf8}

      true ->
        {:ok, value}
    end
  end

  defp validate_identity_string(_, _), do: {:error, :invalid_type}

  # ---- diagnostic (lossy OK) ----

  defp diagnostic_string(nil), do: nil
  defp diagnostic_string(s) when is_binary(s), do: sanitize_utf8_bytes(s, @max_string_bytes)

  defp diagnostic_string(a) when is_atom(a),
    do: sanitize_utf8_bytes(Atom.to_string(a), @max_string_bytes)

  defp diagnostic_string(_), do: nil

  defp durable_node_durations(map) when is_map(map) do
    map
    |> take_map_entries(@max_node_duration_entries)
    |> Map.new(fn {k, v} ->
      {diagnostic_string(k) || "key", json_scalar(v, 0)}
    end)
  end

  defp durable_node_durations(_), do: %{}

  defp bound_hot_node_durations(map) when is_map(map) do
    map
    |> take_map_entries(@max_node_duration_entries)
    |> Map.new(fn {k, v} ->
      key =
        cond do
          is_binary(k) -> diagnostic_string(k)
          is_atom(k) -> Atom.to_string(k)
          true -> "key"
        end

      val =
        case v do
          n when is_integer(n) ->
            bound_non_neg_int(n, 0)

          n when is_float(n) and n >= 0 ->
            if finite_float?(n), do: trunc(min(n, @max_int * 1.0)), else: 0

          _ ->
            0
        end

      {key || "key", val}
    end)
  end

  defp bound_hot_node_durations(_), do: %{}

  defp bound_hot_trust_zone(nil), do: nil
  defp bound_hot_trust_zone(z) when is_integer(z), do: bound_int(z)
  defp bound_hot_trust_zone(z) when is_binary(z), do: diagnostic_string(z)
  defp bound_hot_trust_zone(z) when is_atom(z), do: z
  defp bound_hot_trust_zone(_), do: nil

  defp bound_node_field(nil), do: nil
  defp bound_node_field(n) when is_atom(n), do: n

  defp bound_node_field(n) when is_binary(n) do
    case diagnostic_string(n) do
      nil ->
        nil

      s ->
        case Arbor.Common.SafeAtom.to_existing(s) do
          {:ok, atom} -> atom
          {:error, _} -> s
        end
    end
  end

  defp bound_node_field(_), do: nil

  defp sanitize_failure_reason(nil), do: nil

  defp sanitize_failure_reason({:node_failed, node_id, _}),
    do: {:node_failed, diagnostic_string(node_id)}

  defp sanitize_failure_reason({:node_failed, node_id}),
    do: {:node_failed, diagnostic_string(node_id)}

  defp sanitize_failure_reason({:delegated_to, node}), do: {:delegated_to, node}
  defp sanitize_failure_reason(reason) when is_atom(reason), do: reason

  defp sanitize_failure_reason(reason) when is_binary(reason) do
    reason |> redact_pid_text() |> sanitize_utf8_bytes(@max_failure_bytes)
  end

  defp sanitize_failure_reason(reason) when is_tuple(reason) do
    size = tuple_size(reason)
    max = min(size, @max_collection_items)

    values =
      for i <- 0..(max - 1)//1 do
        sanitize_failure_reason(elem(reason, i))
      end

    List.to_tuple(values)
  end

  defp sanitize_failure_reason(_), do: :redacted

  defp durable_failure_reason(nil), do: nil
  defp durable_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp durable_failure_reason(reason) when is_binary(reason) do
    reason |> redact_pid_text() |> sanitize_utf8_bytes(@max_failure_bytes)
  end

  defp durable_failure_reason(reason) when is_integer(reason), do: bound_int(reason)
  defp durable_failure_reason(reason) when is_float(reason), do: bound_float(reason)
  defp durable_failure_reason(reason) when is_boolean(reason), do: reason

  defp durable_failure_reason({:node_failed, node_id}) when is_binary(node_id),
    do: %{"type" => "node_failed", "node_id" => sanitize_utf8_bytes(node_id, @max_string_bytes)}

  defp durable_failure_reason({:node_failed, node_id}),
    do: %{"type" => "node_failed", "node_id" => diagnostic_string(node_id)}

  defp durable_failure_reason({:delegated_to, node}),
    do: %{"type" => "delegated_to", "node" => node_to_string(node)}

  defp durable_failure_reason({:engine_exception, msg}) when is_binary(msg),
    do: %{
      "type" => "engine_exception",
      "message" => msg |> redact_pid_text() |> sanitize_utf8_bytes(@max_failure_bytes)
    }

  defp durable_failure_reason({:engine_exit, msg}),
    do: %{"type" => "engine_exit", "message" => json_scalar(msg, 0)}

  defp durable_failure_reason(reason) when is_tuple(reason) do
    size = tuple_size(reason)
    max = min(size, @max_collection_items)

    values =
      for i <- 0..(max - 1)//1 do
        json_scalar(elem(reason, i), 1)
      end

    %{"type" => "tuple", "value" => values}
  end

  defp durable_failure_reason(reason) when is_list(reason) do
    reason
    |> take_bounded(@max_collection_items)
    |> map_bounded(&json_scalar(&1, 1))
  end

  defp durable_failure_reason(reason) when is_map(reason) do
    reason
    |> take_map_entries(@max_collection_items)
    |> Map.new(fn {k, v} -> {diagnostic_string(k) || "key", json_scalar(v, 1)} end)
  end

  defp durable_failure_reason(_), do: "redacted"

  defp durable_trust_zone(nil), do: nil
  defp durable_trust_zone(z) when is_integer(z), do: bound_int(z)
  defp durable_trust_zone(z) when is_binary(z), do: diagnostic_string(z)
  defp durable_trust_zone(z) when is_atom(z), do: Atom.to_string(z)
  defp durable_trust_zone(z) when is_float(z), do: bound_float(z)
  defp durable_trust_zone(z) when is_boolean(z), do: z

  defp durable_trust_zone(z) when is_map(z) do
    z
    |> take_map_entries(@max_collection_items)
    |> Map.new(fn {k, v} -> {diagnostic_string(k) || "key", json_scalar(v, 0)} end)
  end

  defp durable_trust_zone(z), do: json_scalar(z, 0)

  defp json_scalar(_v, depth) when depth > @max_depth, do: "truncated_depth"

  defp json_scalar(nil, _depth), do: nil
  defp json_scalar(v, _depth) when is_binary(v), do: diagnostic_string(v)
  defp json_scalar(v, _depth) when is_atom(v), do: Atom.to_string(v)
  defp json_scalar(v, _depth) when is_integer(v), do: bound_int(v)
  defp json_scalar(v, _depth) when is_float(v), do: bound_float(v)
  defp json_scalar(v, _depth) when is_boolean(v), do: v
  defp json_scalar(%DateTime{} = dt, _depth), do: DateTime.to_iso8601(dt)
  defp json_scalar(v, _depth) when is_pid(v), do: nil
  defp json_scalar(v, _depth) when is_reference(v), do: nil
  defp json_scalar(v, _depth) when is_function(v), do: nil
  defp json_scalar(v, _depth) when is_port(v), do: nil

  defp json_scalar(v, depth) when is_tuple(v) do
    size = tuple_size(v)
    max = min(size, @max_collection_items)

    for i <- 0..(max - 1)//1 do
      json_scalar(elem(v, i), depth + 1)
    end
  end

  defp json_scalar(v, depth) when is_list(v) do
    case take_bounded_list(v, @max_collection_items) do
      {:ok, items} -> map_bounded(items, &json_scalar(&1, depth + 1))
      :improper -> "truncated_improper_list"
    end
  end

  defp json_scalar(v, depth) when is_map(v) do
    v
    |> take_map_entries(@max_collection_items)
    |> Map.new(fn {k, val} -> {diagnostic_string(k) || "key", json_scalar(val, depth + 1)} end)
  end

  # Never inspect adversarial terms — redacted only.
  defp json_scalar(_v, _depth), do: "redacted"

  # Bounded map over a short, already-taken list (no Enum on unbounded input).
  defp map_bounded(list, fun) when is_list(list) and is_function(fun, 1) do
    do_map_bounded(list, fun, [])
  end

  defp do_map_bounded([], _fun, acc), do: :lists.reverse(acc)
  defp do_map_bounded([h | t], fun, acc), do: do_map_bounded(t, fun, [fun.(h) | acc])

  # Take at most `max` elements with cons walking only (no is_list/1, no full Enum).
  defp take_bounded(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    case take_bounded_list(list, max) do
      {:ok, items} -> items
      :improper -> []
    end
  end

  defp take_bounded(_, _), do: []

  defp take_bounded_list(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    do_take_bounded(list, max, [])
  end

  defp take_bounded_list(_, _), do: :improper

  defp do_take_bounded(_rest, 0, acc), do: {:ok, :lists.reverse(acc)}
  defp do_take_bounded([], _n, acc), do: {:ok, :lists.reverse(acc)}

  defp do_take_bounded([h | t], n, acc) when is_integer(n) and n > 0 do
    case t do
      [] ->
        {:ok, :lists.reverse([h | acc])}

      [_ | _] = rest ->
        do_take_bounded(rest, n - 1, [h | acc])

      _improper ->
        :improper
    end
  end

  defp do_take_bounded(_, _, _), do: :improper

  defp take_map_entries(map, max) when is_map(map) and is_integer(max) and max >= 0 do
    map
    |> :maps.iterator()
    |> take_map_iter(max, [])
  end

  defp take_map_entries(_, _), do: []

  defp take_map_iter(_iter, 0, acc), do: :lists.reverse(acc)

  defp take_map_iter(iter, n, acc) do
    case :maps.next(iter) do
      {k, v, next} -> take_map_iter(next, n - 1, [{k, v} | acc])
      :none -> :lists.reverse(acc)
    end
  end

  # Magnitude comparison only — never encode or inspect large integers.
  defp bound_int(n) when is_integer(n) do
    cond do
      n > @max_int -> @max_int
      n < -@max_int -> -@max_int
      true -> n
    end
  end

  defp bound_int(_), do: 0

  defp bound_non_neg_int(n, _default) when is_integer(n) and n >= 0, do: bound_int(n)
  defp bound_non_neg_int(_n, default) when is_integer(default) and default >= 0, do: default
  defp bound_non_neg_int(_, _), do: 0

  defp bound_optional_non_neg_int(nil), do: nil
  defp bound_optional_non_neg_int(n) when is_integer(n) and n >= 0, do: bound_int(n)
  defp bound_optional_non_neg_int(_), do: nil

  defp bound_float(f) when is_float(f) do
    cond do
      not finite_float?(f) -> 0.0
      f > @max_int -> @max_int * 1.0
      f < -@max_int -> -@max_int * 1.0
      true -> f
    end
  end

  defp finite_float?(f) when is_float(f) do
    f == f and abs(f) <= 1.0e308
  end

  # Always produce valid UTF-8 within `max` bytes (including short invalid UTF-8).
  # Replacement marker never pushes past the byte limit.
  defp sanitize_utf8_bytes(nil, _max), do: nil

  defp sanitize_utf8_bytes(bin, max) when is_binary(bin) and is_integer(max) and max >= 0 do
    if max == 0 do
      ""
    else
      clipped =
        if byte_size(bin) <= max do
          bin
        else
          binary_part(bin, 0, max)
        end

      case :unicode.characters_to_binary(clipped, :utf8, :utf8) do
        out when is_binary(out) ->
          fit_bytes(out, max)

        {:error, good, _rest} when is_binary(good) ->
          # Replacement character is 3 UTF-8 bytes; only append if it fits.
          replacement = "�"
          rsize = byte_size(replacement)
          good = fit_bytes(good, max)

          if byte_size(good) + rsize <= max do
            good <> replacement
          else
            good
          end

        {:incomplete, good, _rest} when is_binary(good) ->
          fit_bytes(good, max)

        _ ->
          # Hex of a small prefix — ensure encoded size ≤ max.
          hex_src_max = div(max, 2)
          src = binary_part(bin, 0, min(byte_size(bin), hex_src_max))
          fit_bytes(Base.encode16(src, case: :lower), max)
      end
    end
  end

  defp sanitize_utf8_bytes(other, _max), do: other

  defp fit_bytes(bin, max) when is_binary(bin) and is_integer(max) do
    if byte_size(bin) <= max do
      bin
    else
      # Drop incomplete trailing UTF-8 from a hard cut.
      drop_partial_utf8(binary_part(bin, 0, max))
    end
  end

  defp drop_partial_utf8(<<>>), do: <<>>

  defp drop_partial_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      size = byte_size(bin)

      if size <= 1 do
        <<>>
      else
        drop_partial_utf8(binary_part(bin, 0, size - 1))
      end
    end
  end

  # Cap final durable JSON size. Fallback may drop diagnostics/progress only —
  # identity fields and effect evidence stay exact; never drop current_effect.
  defp bound_final_payload(payload) when is_map(payload) do
    case encode_if_within(payload) do
      {:ok, ok_payload} ->
        {:ok, ok_payload}

      :too_large ->
        compact =
          payload
          |> Map.put("failure_reason", compact_failure(payload["failure_reason"]))
          |> Map.put("node_durations", %{})
          |> Map.put("origin_trust_zone", nil)
          |> Map.put(
            "completed_nodes",
            take_bounded(List.wrap(payload["completed_nodes"]), 16)
          )
          |> Map.put("current_node", nil)
          |> Map.put("graph_id", nil)

        case encode_if_within(compact) do
          {:ok, ok_payload} ->
            {:ok, ok_payload}

          :too_large ->
            minimal_identity_payload(payload)
        end
    end
  end

  defp encode_if_within(payload) when is_map(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= @max_payload_bytes ->
        {:ok, payload}

      {:ok, _} ->
        :too_large

      {:error, _} ->
        :too_large
    end
  end

  # Minimal payload preserves identity + effect evidence exactly; never truncates them.
  defp minimal_identity_payload(payload) do
    base = %{
      "run_id" => payload["run_id"],
      "pipeline_id" => payload["pipeline_id"],
      "status" => payload["status"] || "unknown",
      "total_nodes" => bound_non_neg_int(payload["total_nodes"], 0),
      "completed_count" => bound_non_neg_int(payload["completed_count"], 0),
      "completed_nodes" => [],
      "current_node" => nil,
      "node_durations" => %{},
      "started_at" => nil,
      "finished_at" => nil,
      "duration_ms" => nil,
      "failure_reason" => "truncated_payload",
      "owner_node" => payload["owner_node"],
      "source_node" => payload["source_node"],
      "origin_trust_zone" => nil,
      "last_heartbeat" => nil,
      "last_ets_sync" => nil,
      "graph_hash" => payload["graph_hash"],
      "dot_source_path" => payload["dot_source_path"],
      "logs_root" => payload["logs_root"],
      "execution_principal" => payload["execution_principal"],
      "effect_generation" => payload["effect_generation"] || 0,
      "current_effect" => payload["current_effect"]
    }

    case encode_if_within(base) do
      {:ok, ok} ->
        {:ok, ok}

      :too_large ->
        # Identity + effect evidence exceed ceiling — fail closed rather than
        # drop effect evidence or corrupt identity.
        {:error, {:durable_payload_exceeds_bound, :identity_or_effect_too_large}}
    end
  end

  # ---- effect evidence (exact or reject; never truncate) ----

  # Strict dual-key decode for effect fields only. Generic `fetch/2` keeps
  # legacy `||` semantics for other lifecycle fields; effect fields must not
  # default over explicit null or silently pick one of two alias keys.
  defp fetch_effect_field(map, atom_key) when is_atom(atom_key) do
    string_key = Atom.to_string(atom_key)
    has_atom? = Map.has_key?(map, atom_key)
    has_string? = Map.has_key?(map, string_key)

    cond do
      has_atom? and has_string? ->
        :conflict

      has_atom? ->
        {:ok, Map.get(map, atom_key)}

      has_string? ->
        {:ok, Map.get(map, string_key)}

      true ->
        :absent
    end
  end

  defp fetch_effect_generation(data) do
    case fetch_effect_field(data, :effect_generation) do
      :absent ->
        0

      :conflict ->
        :invalid_effect_generation

      {:ok, n} when is_integer(n) and n >= 0 and n <= @max_json_safe_int ->
        n

      # Leave out-of-range integers for validate_and_normalize_record.
      {:ok, n} when is_integer(n) ->
        n

      # Explicit null/wrong type — never default to 0.
      {:ok, _} ->
        :invalid_effect_generation
    end
  end

  defp fetch_current_effect(data) do
    case fetch_effect_field(data, :current_effect) do
      :absent ->
        nil

      :conflict ->
        :invalid_current_effect

      {:ok, nil} ->
        nil

      {:ok, effect} when is_map(effect) ->
        effect

      # Sentinel so validate_and_normalize_record fails closed.
      {:ok, _} ->
        :invalid_current_effect
    end
  end

  defp validate_effect_fields(%Record{} = record) do
    gen = record.effect_generation
    effect = record.current_effect

    cond do
      gen == :invalid_effect_generation ->
        {:error, {:invalid_effect_generation, :invalid_type}}

      not is_integer(gen) ->
        {:error, {:invalid_effect_generation, :invalid_type}}

      gen < 0 or gen > @max_json_safe_int ->
        {:error, {:invalid_effect_generation, :out_of_range}}

      effect == :invalid_current_effect ->
        {:error, {:invalid_current_effect, :invalid_type}}

      # Valid legacy absence: generation 0 + nil evidence only.
      is_nil(effect) and gen == 0 ->
        {:ok, 0, nil}

      is_nil(effect) ->
        {:error, {:invalid_current_effect, :missing_for_generation}}

      is_map(effect) ->
        case EffectEnvelope.validate(effect) do
          {:ok, validated} ->
            cond do
              validated["generation"] != gen ->
                {:error, {:invalid_current_effect, :generation_mismatch}}

              validated["run_id"] != record.run_id ->
                {:error, {:invalid_current_effect, :run_id_mismatch}}

              true ->
                {:ok, gen, validated}
            end

          {:error, reason} ->
            {:error, {:invalid_current_effect, reason}}
        end

      true ->
        {:error, {:invalid_current_effect, :invalid_type}}
    end
  end

  defp compact_failure(nil), do: nil
  defp compact_failure(reason) when is_binary(reason), do: sanitize_utf8_bytes(reason, 128)

  defp compact_failure(reason) when is_map(reason),
    do: Map.take(reason, ["type", "node_id", "message"])

  defp compact_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp compact_failure(_), do: "truncated"

  defp redact_pid_text(text) when is_binary(text) do
    text
    |> String.replace(~r/#PID<[^>]+>/, "#PID<redacted>")
    |> String.replace(~r/#Port<[^>]+>/, "#Port<redacted>")
    |> String.replace(~r/#Reference<[^>]+>/, "#Reference<redacted>")
  end

  defp redact_pid_text(other), do: other
end
