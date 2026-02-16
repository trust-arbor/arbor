defmodule Arbor.Security.CapabilityStore.Serializer do
  @moduledoc """
  Serialization and deserialization for capabilities.

  Converts between `Capability` structs and JSON-safe maps,
  handling binary fields (signatures) as hex strings and
  DateTime fields as ISO 8601.
  """

  alias Arbor.Contracts.Security.Capability

  @known_constraint_keys ~w(allowed_paths time_window rate_limit patterns max_size requires_approval allowed_actions scope)a

  @doc """
  Serialize a `Capability` struct to a JSON-safe map.
  """
  @spec serialize(Capability.t()) :: map()
  def serialize(%Capability{} = cap) do
    %{
      "id" => cap.id,
      "resource_uri" => cap.resource_uri,
      "principal_id" => cap.principal_id,
      "granted_at" => DateTime.to_iso8601(cap.granted_at),
      "expires_at" => encode_optional_datetime(cap.expires_at),
      "parent_capability_id" => cap.parent_capability_id,
      "delegation_depth" => cap.delegation_depth,
      "constraints" => serialize_constraints(cap.constraints),
      "signature" => encode_optional_binary(cap.signature),
      "issuer_id" => cap.issuer_id,
      "issuer_signature" => encode_optional_binary(cap.issuer_signature),
      "delegation_chain" => serialize_delegation_chain(cap.delegation_chain),
      "metadata" => cap.metadata
    }
  end

  @doc """
  Deserialize a JSON-safe map to a `Capability` struct.

  Returns `{:ok, capability}` or `{:error, reason}`.
  """
  @spec deserialize(map()) :: {:ok, Capability.t()} | {:error, term()}
  def deserialize(data) when is_map(data) do
    cap = %Capability{
      id: data["id"],
      resource_uri: data["resource_uri"],
      principal_id: data["principal_id"],
      granted_at: parse_datetime(data["granted_at"]),
      expires_at: parse_optional_datetime(data["expires_at"]),
      parent_capability_id: data["parent_capability_id"],
      delegation_depth: data["delegation_depth"] || 3,
      constraints: deserialize_constraints(data["constraints"] || %{}),
      signature: decode_optional_binary(data["signature"]),
      issuer_id: data["issuer_id"],
      issuer_signature: decode_optional_binary(data["issuer_signature"]),
      delegation_chain: deserialize_delegation_chain(data["delegation_chain"] || []),
      metadata: data["metadata"] || %{}
    }

    {:ok, cap}
  rescue
    e -> {:error, e}
  end

  # ── Constraints ──

  defp serialize_constraints(constraints) when is_map(constraints) do
    Map.new(constraints, fn {k, v} -> {to_string(k), v} end)
  end

  # Convert known string keys back to atoms so constraint enforcement works after restore
  defp deserialize_constraints(constraints) when is_map(constraints) do
    allowed_strings = Enum.map(@known_constraint_keys, &Atom.to_string/1)

    Map.new(constraints, fn
      {k, v} when is_binary(k) ->
        if k in allowed_strings do
          {String.to_existing_atom(k), v}
        else
          {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  # ── Delegation chain ──

  defp serialize_delegation_chain(chain) when is_list(chain) do
    Enum.map(chain, fn record ->
      record
      |> Enum.map(fn {k, v} -> {to_string(k), serialize_chain_value(v)} end)
      |> Map.new()
    end)
  end

  defp serialize_delegation_chain(_), do: []

  defp serialize_chain_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_chain_value(v) when is_atom(v), do: Atom.to_string(v)

  defp serialize_chain_value(v) when is_binary(v) do
    if String.valid?(v), do: v, else: Base.encode16(v, case: :lower)
  end

  defp serialize_chain_value(v), do: v

  defp deserialize_delegation_chain(chain) when is_list(chain), do: chain
  defp deserialize_delegation_chain(_), do: []

  # ── Binary encoding ──

  defp encode_optional_binary(nil), do: nil
  defp encode_optional_binary(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  defp decode_optional_binary(nil), do: nil
  defp decode_optional_binary(""), do: nil

  defp decode_optional_binary(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  # ── DateTime encoding ──

  defp encode_optional_datetime(nil), do: nil
  defp encode_optional_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
