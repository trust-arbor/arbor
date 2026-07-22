defmodule Arbor.Orchestrator.CodingPlan.Reconciliation do
  @moduledoc """
  Imperative shell for authorized, read-only coding-resource reconciliation.

  This module collects bounded public projections, rejects incomplete evidence,
  delegates the task/resource decision to `ReconciliationCore`, and archives a
  redacted immutable envelope. It has no lifecycle or resource mutation path.
  """

  alias Arbor.Contracts.Coding.ReconciliationManifest
  alias Arbor.Orchestrator.CodingPlan.ReconciliationCore
  alias Arbor.Orchestrator.Config

  @read_uri "arbor://coding/reconciliation/read"
  @max_id_bytes 256
  @max_items 1_000
  @allowed_keys [
    :caller_id,
    :task_id,
    :principal_id,
    :max_items
  ]
  @doc "Run an authorized dry-run reconciliation and persist its manifest envelope."
  @spec dry_run(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def dry_run(opts \\ []) do
    with {:ok, opts} <- normalize_options(opts),
         :ok <- authorize(opts),
         {:ok, observed_at} <- reconciliation_now(:observed_at),
         opts = %{opts | observed_at: observed_at},
         {:ok, observations} <- collect_observations(opts),
         {:ok, task_inventory} <- required_inventory(observations, :task_inventory),
         {:ok, resource_inventory} <- required_inventory(observations, :resource_inventory),
         {:ok, supplementary} <- supplementary_evidence(observations),
         {:ok, manifest, manifest_sha256} <-
           ReconciliationCore.reconcile(
             task_inventory,
             resource_inventory,
             opts.observed_at,
             scope(opts)
           ),
         {:ok, exact_manifest_sha256} <- ReconciliationManifest.digest(manifest),
         true <- exact_manifest_sha256 == manifest_sha256,
         {:ok, persisted_at} <- reconciliation_now(:persisted_at),
         envelope = envelope(manifest, manifest_sha256, persisted_at, supplementary),
         {:ok, descriptor} <- persist(envelope, manifest["scope"]) do
      {:ok,
       %{
         "schema_version" => 1,
         "mode" => "dry_run",
         "manifest" => manifest,
         "manifest_sha256" => manifest_sha256,
         "persisted_at" => persisted_at,
         "artifact" => safe_descriptor(descriptor),
         "supplementary_evidence" => supplementary
       }}
    else
      false -> {:error, :manifest_digest_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :reconciliation_failed}
    end
  rescue
    _exception -> {:error, :reconciliation_failed}
  catch
    _kind, _reason -> {:error, :reconciliation_failed}
  end

  @doc "Alias for callers that describe this operation as reconciliation."
  @spec reconcile(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def reconcile(opts \\ []), do: dry_run(opts)

  defp normalize_options(opts) when is_map(opts), do: normalize_options(Map.to_list(opts))

  defp normalize_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in @allowed_keys)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      with {:ok, caller_id} <- required_id(Keyword.get(opts, :caller_id), :caller_id),
           {:ok, task_id} <- optional_id(Keyword.get(opts, :task_id), :task_id),
           {:ok, principal_id} <- optional_id(Keyword.get(opts, :principal_id), :principal_id),
           {:ok, max_items} <- max_items(Keyword.get(opts, :max_items, 64)) do
        {:ok,
         %{
           caller_id: caller_id,
           task_id: task_id,
           principal_id: principal_id,
           max_items: max_items,
           observed_at: nil
         }}
      end
    else
      {:error, :invalid_reconciliation_options}
    end
  end

  defp normalize_options(_opts), do: {:error, :invalid_reconciliation_options}

  defp required_id(value, _field) when is_binary(value) and byte_size(value) > 0 do
    if valid_id?(value), do: {:ok, value}, else: {:error, :invalid_reconciliation_id}
  end

  defp required_id(_value, _field), do: {:error, :caller_id_required}

  defp optional_id(nil, _field), do: {:ok, nil}
  defp optional_id(value, field), do: required_id(value, field)

  defp valid_id?(value) do
    byte_size(value) <= @max_id_bytes and String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, <<0>>) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value)
  end

  defp max_items(value) when is_integer(value) and value > 0 and value <= @max_items,
    do: {:ok, value}

  defp max_items(_value), do: {:error, :invalid_reconciliation_max_items}

  defp normalize_timestamp(%DateTime{} = value, _field),
    do: {:ok, DateTime.to_iso8601(DateTime.shift_zone!(value, "Etc/UTC"), :extended)}

  defp normalize_timestamp(value, _field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.to_iso8601(DateTime.shift_zone!(datetime, "Etc/UTC"), :extended)}

      _ ->
        {:error, :invalid_reconciliation_timestamp}
    end
  end

  defp normalize_timestamp(_value, _field), do: {:error, :invalid_reconciliation_timestamp}

  defp reconciliation_now(field) do
    clock = Config.coding_reconciliation_clock()

    value =
      cond do
        is_function(clock, 0) ->
          clock.()

        is_atom(clock) and Code.ensure_loaded?(clock) and function_exported?(clock, :now, 0) ->
          clock.now()

        true ->
          DateTime.utc_now()
      end

    normalize_timestamp(value, field)
  rescue
    _ -> {:error, :reconciliation_clock_unavailable}
  catch
    _, _ -> {:error, :reconciliation_clock_unavailable}
  end

  defp authorize(%{caller_id: caller_id, task_id: task_id}) do
    security = Config.security_module()
    uris = if task_id, do: [@read_uri <> "/" <> task_id, @read_uri], else: [@read_uri]

    if is_atom(security) and function_exported?(security, :authorize, 4) do
      case Enum.find_value(uris, fn uri -> authorized?(security, caller_id, uri) end) do
        :ok -> :ok
        nil -> {:error, {:unauthorized, :coding_reconciliation_read_required}}
      end
    else
      {:error, :reconciliation_security_unavailable}
    end
  end

  defp authorized?(security, caller_id, uri) do
    case security.authorize(caller_id, uri, :read, verify_identity: false) do
      {:ok, :authorized} -> :ok
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp collect_observations(opts) do
    case Config.coding_reconciliation_observer_module() do
      nil -> collect_from_public_facades(opts)
      module when is_atom(module) -> collect_from_observer(module, opts)
      _ -> {:error, :reconciliation_inventory_unavailable}
    end
  end

  defp collect_from_observer(module, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :observe, 1) do
      case module.observe(public_observer_opts(opts)) do
        {:ok, observations} when is_map(observations) -> {:ok, observations}
        {:error, reason} -> {:error, {:reconciliation_inventory_unavailable, reason}}
        _ -> {:error, :reconciliation_inventory_malformed}
      end
    else
      {:error, :reconciliation_inventory_unavailable}
    end
  rescue
    _ -> {:error, :reconciliation_inventory_unavailable}
  catch
    _, _ -> {:error, :reconciliation_inventory_unavailable}
  end

  defp public_observer_opts(opts) do
    [
      caller_id: opts.caller_id,
      task_id: opts.task_id,
      principal_id: opts.principal_id,
      max_items: opts.max_items
    ]
  end

  defp collect_from_public_facades(opts) do
    task_opts = [caller_id: opts.caller_id, task_id: opts.task_id, max_items: opts.max_items]

    supplementary_opts = [
      caller_id: opts.caller_id,
      task_id: opts.task_id,
      principal_id: opts.principal_id,
      max_items: opts.max_items
    ]

    resource_opts = [
      task_id: opts.task_id,
      principal_id: opts.principal_id,
      max_items: opts.max_items
    ]

    with {:ok, task_inventory} <-
           call_facade(Config.coding_reconciliation_task_facade(), :task_inventory, task_opts),
         {:ok, resource_inventory} <-
           call_facade(
             Config.coding_reconciliation_resource_facade(),
             :coding_resource_inventory,
             resource_opts
           ),
         {:ok, acp_sessions} <-
           call_facade(
             Config.coding_reconciliation_acp_facade(),
             :acp_managed_session_inventory,
             supplementary_opts
           ),
         {:ok, pending_approvals} <-
           call_facade(
             Config.coding_reconciliation_approval_facade(),
             :pending_approval_inventory,
             supplementary_opts
           ) do
      {:ok,
       %{
         "task_inventory" => task_inventory,
         "resource_inventory" => resource_inventory,
         "acp_sessions" => acp_sessions,
         "pending_approvals" => pending_approvals
       }}
    end
  end

  defp call_facade(module, function, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 1) do
      case apply(module, function, [args]) do
        {:ok, value} when is_map(value) -> {:ok, value}
        {:error, _reason} -> {:error, {:reconciliation_inventory_unavailable, function}}
        _ -> {:error, {:reconciliation_inventory_malformed, function}}
      end
    else
      {:error, {:reconciliation_inventory_unavailable, function}}
    end
  rescue
    _ -> {:error, {:reconciliation_inventory_unavailable, function}}
  catch
    _, _ -> {:error, {:reconciliation_inventory_unavailable, function}}
  end

  defp call_facade(_module, function, _args),
    do: {:error, {:reconciliation_inventory_unavailable, function}}

  defp required_inventory(observations, key) do
    case Map.get(observations, Atom.to_string(key)) do
      inventory when is_map(inventory) ->
        with :ok <- validate_required_inventory(key, inventory), do: {:ok, inventory}

      _ ->
        {:error, {:reconciliation_inventory_unavailable, key}}
    end
  end

  defp validate_required_inventory(:task_inventory, inventory) do
    counts = Map.get(inventory, "counts", %{})

    if Map.get(inventory, "truncated") == false and Map.get(counts, "truncated", 0) == 0 and
         Map.get(counts, "malformed", 0) == 0 do
      :ok
    else
      {:error, :invalid_or_incomplete_task_inventory}
    end
  end

  defp validate_required_inventory(:resource_inventory, inventory) do
    counts = Map.get(inventory, "counts", %{})
    journal = Map.get(inventory, "journal", %{})

    if Map.get(inventory, "truncated") == false and Map.get(counts, "truncated", 0) == 0 and
         Map.get(journal, "quarantined") == false and
         Map.get(counts, "quarantined", 0) == 0 and
         Map.get(counts, "duplicates", 0) == 0 do
      :ok
    else
      {:error, :invalid_or_incomplete_resource_inventory}
    end
  end

  defp supplementary_evidence(observations) do
    with {:ok, acp} <- supplementary_inventory(observations, "acp_sessions"),
         {:ok, approvals} <- supplementary_inventory(observations, "pending_approvals") do
      {:ok,
       %{
         "acp_sessions" => summarize_inventory("acp_sessions", acp),
         "pending_approvals" => summarize_inventory("pending_approvals", approvals)
       }}
    end
  end

  defp supplementary_inventory(observations, key) do
    case Map.get(observations, key) do
      inventory when is_map(inventory) ->
        with :ok <- validate_supplementary_inventory(inventory), do: {:ok, inventory}

      _ ->
        {:error, {:reconciliation_inventory_unavailable, key}}
    end
  end

  defp validate_supplementary_inventory(inventory) do
    counts = Map.get(inventory, "counts")

    with true <- is_integer(Map.get(inventory, "schema_version")),
         true <- is_map(Map.get(inventory, "storage")),
         true <- is_map(Map.get(inventory, "filters")),
         true <- is_map(counts),
         true <- is_boolean(Map.get(inventory, "truncated")),
         false <- Map.get(inventory, "truncated"),
         true <- counts_are_bounded?(counts),
         true <- Map.get(counts, "quarantined", 0) == 0,
         true <- Map.get(counts, "duplicates", 0) == 0,
         true <- Map.get(counts, "malformed", 0) == 0,
         true <- Map.get(counts, "backend_omitted", 0) == 0,
         true <- Map.get(counts, "quarantine_truncated", 0) == 0 do
      :ok
    else
      _ -> {:error, :invalid_or_incomplete_supplementary_inventory}
    end
  end

  defp counts_are_bounded?(counts) do
    Enum.all?(counts, fn {_key, value} ->
      is_integer(value) and value >= 0 and value <= @max_items
    end)
  end

  defp summarize_inventory(kind, inventory) do
    %{
      "kind" => kind,
      "inventory_sha256" => sha256(canonical_json(inventory)),
      "counts" => inventory["counts"]
    }
  end

  defp scope(opts) do
    %{
      "task_id" => opts.task_id,
      "principal_id" => opts.principal_id,
      "agent_id" => nil,
      "state" => nil
    }
  end

  defp envelope(manifest, manifest_sha256, persisted_at, supplementary) do
    %{
      "schema_version" => 1,
      "manifest" => manifest,
      "manifest_sha256" => manifest_sha256,
      "persisted_at" => persisted_at,
      "supplementary_evidence" => supplementary
    }
  end

  defp persist(envelope, scope) do
    store = Config.coding_reconciliation_artifact_store()

    if is_atom(store) and Code.ensure_loaded?(store) and
         function_exported?(store, :archive_reconciliation_manifest, 3) do
      case store.archive_reconciliation_manifest(
             Config.coding_pipeline_logs_root(),
             scope,
             envelope
           ) do
        {:ok, descriptor} when is_map(descriptor) -> {:ok, descriptor}
        {:error, reason} -> {:error, {:reconciliation_manifest_persistence_failed, reason}}
        _ -> {:error, :reconciliation_manifest_persistence_failed}
      end
    else
      {:error, :reconciliation_artifact_store_unavailable}
    end
  rescue
    _ -> {:error, :reconciliation_manifest_persistence_failed}
  catch
    _, _ -> {:error, :reconciliation_manifest_persistence_failed}
  end

  defp safe_descriptor(descriptor) do
    descriptor
    |> Map.take(["manifest_sha256", "envelope_sha256", "scope_sha256", "byte_size"])
  end

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, child} -> {key, canonical_json(child)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value

  defp sha256(value) do
    value = if is_binary(value), do: value, else: Jason.encode!(value)

    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
