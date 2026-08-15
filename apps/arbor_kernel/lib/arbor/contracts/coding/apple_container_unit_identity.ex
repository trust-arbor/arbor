defmodule Arbor.Contracts.Coding.AppleContainerUnitIdentity do
  @moduledoc """
  Closed, digest-bound identity for one Apple Container unit-intent journal row.

  This module validates evidence projected by Shell. It has no authority and
  never imports or calls Shell, a journal, or a worker.
  """

  @resource_type "apple_container_unit"
  @fields [
    :resource_type,
    :resource_id,
    :unit_name,
    :execution_id,
    :reserved_at_ms,
    :owner_status,
    :validation_resource_id,
    :workspace_id,
    :task_id,
    :principal_id,
    :source_record_digest
  ]
  @settle_fields [:resource_id, :expected_identity]
  @max_execution_id_bytes 256
  @max_owner_id_bytes 128
  @max_json_safe_integer 9_007_199_254_740_991
  @resource_id_re ~r/\Aacu_v1_([0-9a-f]{32})\z/
  @unit_name_re ~r/\Aarbor-v1-([0-9a-f]{32})\z/
  @digest_re ~r/\A[0-9a-f]{64}\z/

  @doc "Closed identity field atoms."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "The only admitted resource type."
  @spec resource_type() :: String.t()
  def resource_type, do: @resource_type

  @doc ""
  @spec normalize_settle_fields(map()) ::
          {:ok, String.t(), map()} | {:error, :invalid_reconciliation_settle_fields}
  def normalize_settle_fields(fields) when is_map(fields) and not is_struct(fields) do
    with {:ok, attrs} <-
           normalize_object(fields, @settle_fields, :invalid_reconciliation_settle_fields),
         :ok <- exact_fields(attrs, @settle_fields),
         {:ok, identity} <- normalize(attrs.expected_identity),
         :ok <- require_known_owner(identity),
         true <- attrs.resource_id == identity["resource_id"] do
      {:ok, identity["resource_id"], identity}
    else
      _ -> {:error, :invalid_reconciliation_settle_fields}
    end
  rescue
    _ -> {:error, :invalid_reconciliation_settle_fields}
  catch
    _, _ -> {:error, :invalid_reconciliation_settle_fields}
  end

  def normalize_settle_fields(_), do: {:error, :invalid_reconciliation_settle_fields}

  @doc "Normalize a complete known or legacy owner-unknown projection."
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) when is_map(attrs) and not is_struct(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @fields, :invalid_identity),
         :ok <- exact_fields(attrs, @fields),
         {:ok, resource_type} <- enum(attrs.resource_type, @resource_type, :resource_type),
         {:ok, resource_id, suffix} <- resource_id(attrs.resource_id),
         {:ok, unit_name} <- unit_name(attrs.unit_name, suffix),
         {:ok, execution_id} <-
           bounded_text(attrs.execution_id, :execution_id, @max_execution_id_bytes),
         {:ok, reserved_at_ms} <- reserved_at_ms(attrs.reserved_at_ms),
         {:ok, owner_status} <- enum(attrs.owner_status, ["known", "unknown"], :owner_status),
         {:ok, validation_resource_id} <-
           owner_id(attrs.validation_resource_id, :validation_resource_id),
         {:ok, workspace_id} <- owner_id(attrs.workspace_id, :workspace_id),
         {:ok, task_id} <- owner_id(attrs.task_id, :task_id),
         {:ok, principal_id} <- owner_id(attrs.principal_id, :principal_id),
         :ok <-
           owner_shape(owner_status, validation_resource_id, workspace_id, task_id, principal_id),
         {:ok, source_record_digest} <- digest(attrs.source_record_digest) do
      {:ok,
       %{
         "resource_type" => resource_type,
         "resource_id" => resource_id,
         "unit_name" => unit_name,
         "execution_id" => execution_id,
         "reserved_at_ms" => reserved_at_ms,
         "owner_status" => owner_status,
         "validation_resource_id" => validation_resource_id,
         "workspace_id" => workspace_id,
         "task_id" => task_id,
         "principal_id" => principal_id,
         "source_record_digest" => source_record_digest
       }}
    else
      error -> error
    end
  rescue
    _ -> {:error, {:invalid_identity, :malformed}}
  catch
    _, _ -> {:error, {:invalid_identity, :malformed}}
  end

  def normalize(_), do: {:error, {:invalid_identity, :object_required}}

  defp require_known_owner(%{
         "owner_status" => "known",
         "validation_resource_id" => validation_resource_id,
         "workspace_id" => workspace_id,
         "task_id" => task_id,
         "principal_id" => principal_id
       })
       when is_binary(validation_resource_id) and is_binary(workspace_id) and
              is_binary(task_id) and is_binary(principal_id),
       do: :ok

  defp require_known_owner(_), do: {:error, :apple_container_unit_owner_required}

  defp resource_id(value) when is_binary(value) do
    case Regex.run(@resource_id_re, value, capture: :all_but_first) do
      [suffix] -> {:ok, value, suffix}
      _ -> {:error, {:invalid_field, "resource_id"}}
    end
  end

  defp resource_id(_), do: {:error, {:invalid_field, "resource_id"}}

  defp unit_name(value, suffix) when is_binary(value) do
    if value == "arbor-v1-" <> suffix and Regex.match?(@unit_name_re, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, "unit_name"}}
  end

  defp unit_name(_, _), do: {:error, {:invalid_field, "unit_name"}}

  defp bounded_text(value, field, max_bytes)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max_bytes do
    if String.valid?(value) and not forbidden_text?(value),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp bounded_text(_, field, _), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp owner_id(nil, _field), do: {:ok, nil}
  defp owner_id(value, field), do: bounded_text(value, field, @max_owner_id_bytes)

  defp owner_shape("known", validation_resource_id, workspace_id, task_id, principal_id)
       when is_binary(validation_resource_id) and is_binary(workspace_id) and
              is_binary(task_id) and is_binary(principal_id),
       do: :ok

  defp owner_shape("unknown", nil, nil, nil, nil), do: :ok
  defp owner_shape(_, _, _, _, _), do: {:error, :invalid_owner_shape}

  defp reserved_at_ms(value)
       when is_integer(value) and value >= 0 and value <= @max_json_safe_integer,
       do: {:ok, value}

  defp reserved_at_ms(_), do: {:error, {:invalid_field, "reserved_at_ms"}}

  defp digest(value) when is_binary(value) do
    if Regex.match?(@digest_re, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, "source_record_digest"}}
  end

  defp digest(_), do: {:error, {:invalid_field, "source_record_digest"}}

  defp enum(value, allowed, field) do
    value = if is_atom(value), do: Atom.to_string(value), else: value

    if value in List.wrap(allowed),
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  defp forbidden_text?(value) do
    String.contains?(value, ["/", "\\", <<0>>]) or
      String.match?(value, ~r/[[:space:]]|[\x00-\x1F\x7F]/)
  end

  defp normalize_object(attrs, allowed, tag) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {tag, :struct_not_allowed}}
      map_size(attrs) > length(allowed) -> {:error, {tag, :object_too_large}}
      true -> normalize_entries(Map.to_list(attrs), allowed, tag)
    end
  end

  defp normalize_object(_attrs, _allowed, tag), do: {:error, {tag, :object_required}}

  defp normalize_entries(entries, allowed, tag) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case canonical_key(key, allowed) do
        {:ok, canonical} when not is_map_key(normalized, canonical) ->
          {:cont, {:ok, Map.put(normalized, canonical, value)}}

        {:ok, _canonical} ->
          {:halt, {:error, {tag, :duplicate_field}}}

        :error ->
          {:halt, {:error, {tag, :unknown_field}}}
      end
    end)
  end

  defp canonical_key(key, allowed) when is_atom(key) do
    if key in allowed, do: {:ok, key}, else: :error
  end

  defp canonical_key(key, allowed) when is_binary(key) do
    Enum.find_value(allowed, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp canonical_key(_, _), do: :error

  defp exact_fields(attrs, fields) do
    if Map.keys(attrs) |> Enum.sort() == Enum.sort(fields), do: :ok, else: {:error, :field_set}
  end
end
