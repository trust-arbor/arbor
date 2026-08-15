defmodule Arbor.Contracts.Coding.PendingApprovalIdentity do
  @moduledoc """
  Pure, closed pending-approval identity used by reconciliation decisions,
  inventory projection, and source-owned compare-and-settle.

  Authority-free: never reads backends or Agent modules. Callers lift source
  records into the closed field set, then normalize here.
  """

  alias Arbor.Contracts.Coding.PendingApprovalResourceId
  alias Arbor.Contracts.Security.CapabilityUri

  @resource_type "pending_approval"
  @fields [
    :resource_type,
    :resource_id,
    :approval_id,
    :source,
    :task_id,
    :agent_id,
    :principal_id,
    :approver_id,
    :resource_uri,
    :action,
    :status,
    :created_at
  ]
  @settle_fields [:resource_id, :expected_identity]
  @statuses ~w(pending evaluating)
  @max_id_bytes 256
  @max_timestamp_bytes 64
  @task_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc "Closed identity field atoms."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "Closed pending statuses as strings."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Resource type string for pending-approval identities."
  @spec resource_type() :: String.t()
  def resource_type, do: @resource_type

  @doc """
  Normalize the closed source-owner compare-and-settle envelope.

  Atom and string keys are accepted, but duplicate canonical keys are rejected.
  The outer resource ID must match the normalized expected identity.
  """
  @spec normalize_settle_fields(map()) ::
          {:ok, String.t(), map()} | {:error, :invalid_reconciliation_settle_fields}
  def normalize_settle_fields(fields) when is_map(fields) and not is_struct(fields) do
    with {:ok, attrs} <-
           normalize_object(fields, @settle_fields, :invalid_reconciliation_settle_fields),
         :ok <- exact_fields(attrs, @settle_fields),
         {:ok, %{"resource_id" => identity_resource_id} = identity} <-
           normalize(attrs.expected_identity),
         true <- attrs.resource_id == identity_resource_id do
      {:ok, identity_resource_id, identity}
    else
      _ -> {:error, :invalid_reconciliation_settle_fields}
    end
  rescue
    _ -> {:error, :invalid_reconciliation_settle_fields}
  catch
    _, _ -> {:error, :invalid_reconciliation_settle_fields}
  end

  def normalize_settle_fields(_fields),
    do: {:error, :invalid_reconciliation_settle_fields}

  @doc """
  Normalize a closed pending-approval identity map.

  Accepts atom or string keys. Rejects structs, unknown fields, and identity
  that does not bind `resource_id` to `source` + `approval_id`.
  """
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @fields, :invalid_identity),
         :ok <- exact_fields(attrs, @fields),
         {:ok, identity_type} <- enum(attrs.resource_type, [@resource_type], :resource_type),
         {:ok, resource_id} <- bounded_id(attrs.resource_id, :resource_id),
         true <- PendingApprovalResourceId.valid?(resource_id),
         {:ok, approval_id} <- required_source_text(attrs.approval_id, :approval_id),
         {:ok, source} <- enum(attrs.source, PendingApprovalResourceId.sources(), :source),
         {:ok, expected_resource_id} <- PendingApprovalResourceId.resource_id(source, approval_id),
         true <- expected_resource_id == resource_id,
         {:ok, task_id} <- optional_task_id(attrs.task_id),
         {:ok, agent_id} <- optional_source_id(attrs.agent_id, :agent_id),
         {:ok, principal_id} <- optional_source_id(attrs.principal_id, :principal_id),
         {:ok, approver_id} <- optional_source_id(attrs.approver_id, :approver_id),
         {:ok, resource_uri} <- optional_resource_uri(attrs.resource_uri),
         {:ok, action} <- optional_source_text(attrs.action, :action),
         {:ok, status} <- enum(attrs.status, @statuses, :status),
         {:ok, created_at} <- optional_timestamp(attrs.created_at, :created_at) do
      {:ok,
       %{
         "resource_type" => identity_type,
         "resource_id" => resource_id,
         "approval_id" => approval_id,
         "source" => source,
         "task_id" => task_id,
         "agent_id" => agent_id,
         "principal_id" => principal_id,
         "approver_id" => approver_id,
         "resource_uri" => resource_uri,
         "action" => action,
         "status" => status,
         "created_at" => created_at
       }}
    else
      false -> {:error, {:invalid_field, "expected_identity"}}
      error -> error
    end
  rescue
    _ -> {:error, {:invalid_identity, :malformed}}
  catch
    _, _ -> {:error, {:invalid_identity, :malformed}}
  end

  @doc """
  Project identity from a consensus authorization-request proposal-like map.

  Accepts Proposal structs or plain maps with the inventory field shapes.
  """
  @spec from_consensus_proposal(map() | struct()) :: {:ok, map()} | {:error, term()}
  def from_consensus_proposal(proposal) when is_map(proposal) do
    metadata = value(proposal, :metadata, %{}) || %{}
    context = value(proposal, :context, %{}) || %{}
    approval_id = to_string_id(value(proposal, :id))
    principal_id = value(metadata, :principal_id) || value(proposal, :proposer)
    agent_id = value(proposal, :proposer) || principal_id
    task_id = extract_task_id(metadata) || extract_task_id(context)

    with {:ok, approval_id} <- required_source_text(approval_id, :approval_id),
         {:ok, resource_id} <- PendingApprovalResourceId.resource_id("consensus", approval_id),
         {:ok, status} <- status_from_source(value(proposal, :status)),
         attrs <- %{
           "resource_type" => @resource_type,
           "resource_id" => resource_id,
           "approval_id" => approval_id,
           "source" => "consensus",
           "task_id" => task_id,
           "agent_id" => agent_id,
           "principal_id" => principal_id,
           "approver_id" => value(metadata, :approver_id),
           "resource_uri" => value(metadata, :resource_uri) || value(context, :resource_uri),
           "action" =>
             value(metadata, :action) || value(context, :action) || value(proposal, :topic),
           "status" => status,
           "created_at" => value(proposal, :created_at)
         } do
      normalize(attrs)
    end
  rescue
    _ -> {:error, :current_identity_unavailable}
  catch
    _, _ -> {:error, :current_identity_unavailable}
  end

  def from_consensus_proposal(_), do: {:error, :current_identity_unavailable}

  @doc """
  Project identity from an interaction-like map while it is still pending.

  Status is forced to `\"pending\"` — callers only invoke this for pending
  authority entries.
  """
  @spec from_interaction(map() | struct()) :: {:ok, map()} | {:error, term()}
  def from_interaction(interaction) when is_map(interaction) do
    metadata = value(interaction, :metadata, %{}) || %{}
    approval_id = to_string_id(value(interaction, :request_id))
    agent_id = value(interaction, :agent_id)
    principal_id = value(metadata, :principal_id) || agent_id
    task_id = extract_task_id(metadata)

    with {:ok, approval_id} <- required_source_text(approval_id, :approval_id),
         {:ok, resource_id} <- PendingApprovalResourceId.resource_id("interaction", approval_id),
         attrs <- %{
           "resource_type" => @resource_type,
           "resource_id" => resource_id,
           "approval_id" => approval_id,
           "source" => "interaction",
           "task_id" => task_id,
           "agent_id" => agent_id,
           "principal_id" => principal_id,
           "approver_id" => value(interaction, :user_id),
           "resource_uri" => value(interaction, :resource_uri) || value(metadata, :resource_uri),
           "action" => value(metadata, :action) || value(interaction, :kind),
           "status" => "pending",
           "created_at" => value(interaction, :submitted_at)
         } do
      normalize(attrs)
    end
  rescue
    _ -> {:error, :current_identity_unavailable}
  catch
    _, _ -> {:error, :current_identity_unavailable}
  end

  def from_interaction(_), do: {:error, :current_identity_unavailable}

  @doc "Extract nested task_id from metadata/context maps used by approval backends."
  @spec extract_task_id(term()) :: String.t() | nil
  def extract_task_id(map) when is_map(map) do
    value(map, :task_id) ||
      nested_value(map, [:provenance, :task_id]) ||
      nested_value(map, [:approval_context, :task_id]) ||
      nested_value(map, [:approval_context, :provenance, :task_id])
  end

  def extract_task_id(_), do: nil

  defp status_from_source(status) when status in [:pending, "pending"], do: {:ok, "pending"}

  defp status_from_source(status) when status in [:evaluating, "evaluating"],
    do: {:ok, "evaluating"}

  defp status_from_source(_), do: {:error, {:invalid_field, "status"}}

  defp to_string_id(value) when is_binary(value), do: value
  defp to_string_id(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_id(value), do: value

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default

  defp nested_value(term, []), do: term

  defp nested_value(term, [key | rest]) do
    case value(term, key) do
      nil -> nil
      next -> nested_value(next, rest)
    end
  end

  defp normalize_object(attrs, allowed, tag) when is_map(attrs) do
    cond do
      is_struct(attrs) ->
        # Proposal/Interaction structs are handled by from_* helpers, not normalize/1.
        {:error, {tag, :struct_not_allowed}}

      map_size(attrs) > length(allowed) ->
        {:error, {tag, :object_too_large}}

      true ->
        normalize_entries(Map.to_list(attrs), allowed, tag)
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

  defp exact_fields(attrs, fields) do
    if Map.keys(attrs) |> Enum.sort() == fields |> Enum.sort(),
      do: :ok,
      else: {:error, :field_set}
  end

  defp enum(value, allowed, field) do
    normalized = if is_atom(value), do: Atom.to_string(value), else: value

    if normalized in allowed,
      do: {:ok, normalized},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp bounded_id(value, field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp bounded_id(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

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

  defp optional_task_id(nil), do: {:ok, nil}

  defp optional_task_id(value)
       when is_binary(value) and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and Regex.match?(@task_id_pattern, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, "task_id"}}
  end

  defp optional_task_id(_value), do: {:error, {:invalid_field, "task_id"}}

  defp source_text(value, field)
       when is_binary(value) and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp source_text(value, field) when is_atom(value),
    do: source_text(Atom.to_string(value), field)

  defp source_text(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp optional_source_text(nil, _field), do: {:ok, nil}
  defp optional_source_text(value, field), do: source_text(value, field)

  defp required_source_text(value, field) do
    case source_text(value, field) do
      {:ok, text} when is_binary(text) and text != "" -> {:ok, text}
      {:ok, _} -> {:error, {:invalid_field, Atom.to_string(field)}}
      error -> error
    end
  end

  defp optional_resource_uri(nil), do: {:ok, nil}

  defp optional_resource_uri(resource_uri)
       when is_binary(resource_uri) and byte_size(resource_uri) <= @max_id_bytes do
    if CapabilityUri.valid?(resource_uri),
      do: {:ok, resource_uri},
      else: {:error, {:invalid_field, "resource_uri"}}
  end

  defp optional_resource_uri(_resource_uri), do: {:error, {:invalid_field, "resource_uri"}}

  defp optional_timestamp(nil, _field), do: {:ok, nil}
  defp optional_timestamp(%DateTime{} = value, _field), do: {:ok, DateTime.to_iso8601(value)}

  defp optional_timestamp(value, field)
       when is_binary(value) and byte_size(value) <= @max_timestamp_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _ -> {:error, {:invalid_field, Atom.to_string(field)}}
    end
  end

  defp optional_timestamp(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}
end
