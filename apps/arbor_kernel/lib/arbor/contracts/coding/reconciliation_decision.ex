defmodule Arbor.Contracts.Coding.ReconciliationDecision do
  @moduledoc "Closed, bounded evidence for one coding-resource reconciliation decision."

  use TypedStruct

  alias Arbor.Contracts.Coding.AppleContainerUnitIdentity
  alias Arbor.Contracts.Coding.PendingApprovalIdentity
  alias Arbor.Contracts.Coding.RetainedWorkspaceIdentity

  @legacy_schema_version 1
  @schema_version 2
  @supported_schema_versions [@legacy_schema_version, @schema_version]
  @workspace_resource_types ~w(
    live_workspace_lease retained_workspace_record validation_resource quarantine
  )
  @acp_resource_type "acp_managed_session"
  @pending_approval_resource_type "pending_approval"
  @apple_container_unit_resource_type "apple_container_unit"
  @resource_types @workspace_resource_types ++
                    [
                      @acp_resource_type,
                      @pending_approval_resource_type,
                      @apple_container_unit_resource_type
                    ]
  @decisions ~w(keep retry settle quarantine remove)
  @reasons ~w(
    existing_quarantine
    journal_degraded
    missing_task_or_principal_provenance
    ambiguous_provenance
    missing_task
    live_task_owner_alive
    live_task_owner_dead
    terminal_active_resource
    retained_within_retention
    retained_expired
    dormant_resource
    retry_exhausted
  )
  @workspace_expected_identity_fields [
    :resource_type,
    :resource_id,
    :task_id,
    :principal_id,
    :lifecycle,
    :active,
    :ownership,
    :branch_provenance,
    :cleanup_armed,
    :dormant,
    :retry_count,
    :retry_limit,
    :expires_at
  ]
  @acp_expected_identity_fields [
    :resource_type,
    :resource_id,
    :worker_session_id,
    :provider_session_id,
    :provider,
    :model,
    :status,
    :pooled,
    :return_to_pool,
    :task_id,
    :principal_id,
    :owner_present,
    :owner_alive,
    :session_alive,
    :close_cleanup_in_progress
  ]
  @evidence_fields [:task_presence, :task_state, :owner_status, :journal_status]
  @max_id_bytes 256
  @max_timestamp_bytes 64

  typedstruct enforce: true do
    @typedoc "A bounded, authority-free reconciliation decision."

    field(:schema_version, pos_integer())
    field(:resource_type, String.t())
    field(:resource_id, String.t())
    field(:task_id, String.t() | nil)
    field(:principal_id, String.t() | nil)
    field(:decision, String.t())
    field(:reason, String.t())
    field(:expected_identity, map())
    field(:evidence, map())
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "Construct and validate a closed reconciliation decision."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, fields(), :invalid_reconciliation_decision),
         :ok <- require_fields(attrs),
         {:ok, schema_version} <- exact_version(attrs.schema_version),
         {:ok, resource_type} <- enum(attrs.resource_type, @resource_types, :resource_type),
         {:ok, resource_id} <- bounded_id(attrs.resource_id, :resource_id),
         {:ok, task_id} <- optional_id(attrs.task_id, :task_id),
         {:ok, principal_id} <- optional_id(attrs.principal_id, :principal_id),
         {:ok, decision} <- enum(attrs.decision, @decisions, :decision),
         {:ok, reason} <- enum(attrs.reason, @reasons, :reason),
         {:ok, expected_identity} <-
           normalize_identity(
             attrs.expected_identity,
             schema_version,
             resource_type,
             resource_id,
             task_id,
             principal_id
           ),
         {:ok, evidence} <- normalize_evidence(attrs.evidence) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         resource_type: resource_type,
         resource_id: resource_id,
         task_id: task_id,
         principal_id: principal_id,
         decision: decision,
         reason: reason,
         expected_identity: expected_identity,
         evidence: evidence
       }}
    end
  rescue
    _ -> {:error, {:invalid_reconciliation_decision, :malformed}}
  catch
    _, _ -> {:error, {:invalid_reconciliation_decision, :malformed}}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = decision) do
    %{
      "schema_version" => decision.schema_version,
      "resource_type" => decision.resource_type,
      "resource_id" => decision.resource_id,
      "task_id" => decision.task_id,
      "principal_id" => decision.principal_id,
      "decision" => decision.decision,
      "reason" => decision.reason,
      "expected_identity" => decision.expected_identity,
      "evidence" => decision.evidence
    }
  end

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, decision} <- new(attrs), do: {:ok, to_map(decision)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = decision), do: match?({:ok, _}, new(to_map(decision)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  defp fields do
    [
      :schema_version,
      :resource_type,
      :resource_id,
      :task_id,
      :principal_id,
      :decision,
      :reason,
      :expected_identity,
      :evidence
    ]
  end

  defp normalize_identity(
         value,
         _schema_version,
         resource_type,
         resource_id,
         outer_task_id,
         outer_principal_id
       )
       when is_map(value) and not is_struct(value) and resource_type == @acp_resource_type do
    with {:ok, attrs} <-
           normalize_object(value, @acp_expected_identity_fields, :invalid_identity),
         :ok <- exact_identity_fields(attrs, @acp_expected_identity_fields),
         {:ok, identity_type} <- enum(attrs.resource_type, [@acp_resource_type], :resource_type),
         true <- identity_type == resource_type,
         {:ok, identity_resource_id} <- source_id(attrs.resource_id, :resource_id),
         true <- identity_resource_id == resource_id,
         {:ok, worker_session_id} <- source_id(attrs.worker_session_id, :worker_session_id),
         true <- identity_resource_id == worker_session_id,
         {:ok, provider_session_id} <-
           optional_source_text(attrs.provider_session_id, :provider_session_id),
         {:ok, provider} <- source_text(attrs.provider, :provider),
         {:ok, model} <- optional_source_text(attrs.model, :model),
         {:ok, status} <- source_text(attrs.status, :status),
         {:ok, pooled} <- boolean(attrs.pooled, :pooled),
         {:ok, return_to_pool} <- boolean(attrs.return_to_pool, :return_to_pool),
         {:ok, task_id} <- optional_source_id(attrs.task_id, :task_id),
         true <- task_id == outer_task_id,
         {:ok, principal_id} <- optional_source_id(attrs.principal_id, :principal_id),
         true <- principal_id == outer_principal_id,
         {:ok, owner_present} <- boolean(attrs.owner_present, :owner_present),
         {:ok, owner_alive} <- boolean(attrs.owner_alive, :owner_alive),
         {:ok, session_alive} <- boolean(attrs.session_alive, :session_alive),
         {:ok, close_cleanup_in_progress} <-
           boolean(attrs.close_cleanup_in_progress, :close_cleanup_in_progress),
         :ok <-
           valid_acp_session_state(owner_present, owner_alive, status, close_cleanup_in_progress) do
      {:ok,
       %{
         "resource_type" => identity_type,
         "resource_id" => identity_resource_id,
         "worker_session_id" => worker_session_id,
         "provider_session_id" => provider_session_id,
         "provider" => provider,
         "model" => model,
         "status" => status,
         "pooled" => pooled,
         "return_to_pool" => return_to_pool,
         "task_id" => task_id,
         "principal_id" => principal_id,
         "owner_present" => owner_present,
         "owner_alive" => owner_alive,
         "session_alive" => session_alive,
         "close_cleanup_in_progress" => close_cleanup_in_progress
       }}
    else
      false -> {:error, {:invalid_field, "expected_identity"}}
      error -> error
    end
  end

  defp normalize_identity(
         value,
         _schema_version,
         resource_type,
         resource_id,
         outer_task_id,
         outer_principal_id
       )
       when is_map(value) and not is_struct(value) and
              resource_type == @pending_approval_resource_type do
    with {:ok, identity} <- PendingApprovalIdentity.normalize(value),
         true <- identity["resource_type"] == resource_type,
         true <- identity["resource_id"] == resource_id,
         true <- identity["task_id"] == outer_task_id,
         true <- identity["principal_id"] == outer_principal_id do
      {:ok, identity}
    else
      false -> {:error, {:invalid_field, "expected_identity"}}
      error -> error
    end
  end

  defp normalize_identity(
         value,
         _schema_version,
         resource_type,
         resource_id,
         outer_task_id,
         outer_principal_id
       )
       when is_map(value) and not is_struct(value) and
              resource_type == @apple_container_unit_resource_type do
    with {:ok, identity} <- AppleContainerUnitIdentity.normalize(value),
         true <- identity["resource_type"] == resource_type,
         true <- identity["resource_id"] == resource_id,
         true <- identity["task_id"] == outer_task_id,
         true <- identity["principal_id"] == outer_principal_id do
      {:ok, identity}
    else
      false -> {:error, {:invalid_field, "expected_identity"}}
      error -> error
    end
  end

  defp normalize_identity(
         value,
         schema_version,
         "retained_workspace_record",
         resource_id,
         task_id,
         principal_id
       )
       when is_map(value) and not is_struct(value) do
    with {:ok, identity} <- RetainedWorkspaceIdentity.normalize(value),
         :ok <- retained_identity_version(schema_version, identity),
         true <- identity["resource_id"] == resource_id,
         true <- identity["task_id"] == task_id,
         true <- identity["principal_id"] == principal_id do
      {:ok, identity}
    else
      false -> {:error, {:invalid_field, "expected_identity"}}
      error -> error
    end
  end

  defp normalize_identity(
         value,
         _schema_version,
         resource_type,
         _resource_id,
         _task_id,
         _principal_id
       )
       when is_map(value) and not is_struct(value) and resource_type in @workspace_resource_types do
    with {:ok, attrs} <-
           normalize_object(value, @workspace_expected_identity_fields, :invalid_identity),
         :ok <- exact_identity_fields(attrs, @workspace_expected_identity_fields),
         {:ok, identity_type} <-
           enum(attrs.resource_type, @workspace_resource_types, :resource_type),
         true <- identity_type == resource_type,
         {:ok, resource_id} <- bounded_id(attrs.resource_id, :resource_id),
         {:ok, task_id} <- optional_id(attrs.task_id, :task_id),
         {:ok, principal_id} <- optional_id(attrs.principal_id, :principal_id),
         {:ok, lifecycle} <- optional_text(attrs.lifecycle, :lifecycle),
         {:ok, active} <- boolean(attrs.active, :active),
         {:ok, ownership} <- optional_text(attrs.ownership, :ownership),
         {:ok, provenance} <- optional_text(attrs.branch_provenance, :branch_provenance),
         {:ok, cleanup_armed} <- boolean(attrs.cleanup_armed, :cleanup_armed),
         {:ok, dormant} <- boolean(attrs.dormant, :dormant),
         {:ok, retry_count} <- bounded_integer(attrs.retry_count, :retry_count),
         {:ok, retry_limit} <- bounded_integer(attrs.retry_limit, :retry_limit),
         {:ok, expires_at} <- optional_timestamp(attrs.expires_at, :expires_at) do
      {:ok,
       %{
         "resource_type" => identity_type,
         "resource_id" => resource_id,
         "task_id" => task_id,
         "principal_id" => principal_id,
         "lifecycle" => lifecycle,
         "active" => active,
         "ownership" => ownership,
         "branch_provenance" => provenance,
         "cleanup_armed" => cleanup_armed,
         "dormant" => dormant,
         "retry_count" => retry_count,
         "retry_limit" => retry_limit,
         "expires_at" => expires_at
       }}
    else
      false -> {:error, {:invalid_field, "expected_identity"}}
      error -> error
    end
  end

  defp normalize_identity(
         _value,
         _schema_version,
         _resource_type,
         _resource_id,
         _task_id,
         _principal_id
       ),
       do: {:error, {:invalid_field, "expected_identity"}}

  # Version 1 manifests predate retained source proofs. Keeping their nested
  # identity closed preserves archived v1 bytes and prevents a v2 proof from
  # being misrepresented by an outer v1 envelope.
  defp retained_identity_version(@legacy_schema_version, identity) do
    if Map.has_key?(identity, "identity_version"),
      do: {:error, {:invalid_field, "expected_identity"}},
      else: :ok
  end

  defp retained_identity_version(@schema_version, _identity), do: :ok

  defp normalize_evidence(value) when is_map(value) and not is_struct(value) do
    with {:ok, attrs} <- normalize_object(value, @evidence_fields, :invalid_evidence),
         :ok <- exact_identity_fields(attrs, @evidence_fields),
         {:ok, task_presence} <- enum(attrs.task_presence, ~w(observed absent), :task_presence),
         {:ok, task_state} <-
           optional_enum(
             attrs.task_state,
             ~w(running waiting_approval done failed cancelled),
             :task_state
           ),
         {:ok, owner_status} <-
           enum(attrs.owner_status, ~w(live dead absent unknown), :owner_status),
         {:ok, journal_status} <-
           enum(attrs.journal_status, ~w(complete disabled degraded), :journal_status) do
      {:ok,
       %{
         "task_presence" => task_presence,
         "task_state" => task_state,
         "owner_status" => owner_status,
         "journal_status" => journal_status
       }}
    end
  end

  defp normalize_evidence(_value), do: {:error, {:invalid_field, "evidence"}}

  defp normalize_object(attrs, allowed, tag) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {tag, :struct_not_allowed}}
      map_size(attrs) > length(allowed) -> {:error, {tag, :object_too_large}}
      true -> normalize_entries(Map.to_list(attrs), allowed, tag)
    end
  end

  defp normalize_object(attrs, allowed, tag) when is_list(attrs) do
    entries = Enum.take(attrs, length(allowed) + 1)

    cond do
      length(entries) > length(allowed) -> {:error, {tag, :object_too_large}}
      Enum.all?(entries, &match?({_, _}, &1)) -> normalize_entries(entries, allowed, tag)
      true -> {:error, {tag, :object_required}}
    end
  end

  defp normalize_object(_attrs, _allowed, tag), do: {:error, {tag, :object_required}}

  defp normalize_entries(entries, allowed, tag) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case canonical_key(key, allowed) do
        {:ok, canonical} when not is_map_key(normalized, canonical) ->
          {:cont, {:ok, Map.put(normalized, canonical, value)}}

        {:ok, canonical} ->
          {:halt, {:error, {:duplicate_field, Atom.to_string(canonical)}}}

        :error ->
          {:halt, {:error, {tag, :unknown_field}}}
      end
    end)
  end

  defp canonical_key(key, allowed) when is_atom(key) do
    if Enum.member?(allowed, key), do: {:ok, key}, else: :error
  end

  defp canonical_key(key, allowed) when is_binary(key) do
    Enum.find_value(allowed, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp canonical_key(_key, _allowed), do: :error

  defp require_fields(attrs) do
    required = fields()

    if Enum.all?(required, &Map.has_key?(attrs, &1)), do: :ok, else: {:error, :missing_field}
  end

  defp exact_identity_fields(attrs, fields) do
    if Map.keys(attrs) |> Enum.sort() == fields |> Enum.sort(),
      do: :ok,
      else: {:error, :field_set}
  end

  defp exact_version(version) when version in @supported_schema_versions, do: {:ok, version}
  defp exact_version(_), do: {:error, {:invalid_field, "schema_version"}}

  defp enum(value, allowed, field) do
    normalized = if is_atom(value), do: Atom.to_string(value), else: value

    if normalized in allowed,
      do: {:ok, normalized},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp optional_enum(nil, _allowed, _field), do: {:ok, nil}
  defp optional_enum(value, allowed, field), do: enum(value, allowed, field)

  defp bounded_id(value, field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp bounded_id(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_id(nil, _field), do: {:ok, nil}
  defp optional_id(value, field), do: bounded_id(value, field)

  defp optional_text(nil, _field), do: {:ok, nil}
  defp optional_text(value, field), do: bounded_id(value, field)

  defp source_id(value, field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and String.trim(value) == value and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/),
       do: {:ok, value},
       else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp source_id(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_source_id(nil, _field), do: {:ok, nil}
  defp optional_source_id(value, field), do: source_id(value, field)

  defp source_text(value, field)
       when is_binary(value) and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp source_text(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_source_text(nil, _field), do: {:ok, nil}
  defp optional_source_text(value, field), do: source_text(value, field)

  defp valid_acp_session_state(false, true, _status, _close_cleanup_in_progress),
    do: {:error, {:invalid_field, "owner_alive"}}

  defp valid_acp_session_state(
         _owner_present,
         _owner_alive,
         status,
         true
       )
       when status != "closing",
       do: {:error, {:invalid_field, "close_cleanup_in_progress"}}

  defp valid_acp_session_state(
         _owner_present,
         _owner_alive,
         _status,
         _close_cleanup_in_progress
       ),
       do: :ok

  defp boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp boolean(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp bounded_integer(value, _field)
       when is_integer(value) and value >= 0 and value <= 1_000_000,
       do: {:ok, value}

  defp bounded_integer(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_timestamp(nil, _field), do: {:ok, nil}

  defp optional_timestamp(value, field)
       when is_binary(value) and byte_size(value) <= @max_timestamp_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _ -> {:error, {:invalid_field, Atom.to_string(field)}}
    end
  end

  defp optional_timestamp(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}
end
