defmodule Arbor.Contracts.Session.TurnAuthority do
  @moduledoc """
  Closed process-local identity for one authenticated Session turn.

  Constructing this struct confers **no** authority — only Security-owned
  stored capabilities can authorize an effect. Session allocates a fresh
  `turn_id` after consuming a one-use delivery receipt and binds the
  Security-owned principal; `disclosure_capability_id` is reserved for a
  later activation slice and is always `nil` from Session ingress today.

  Values deliberately have no Jason encoder so they cannot enter checkpoints
  or JSON logs accidentally. Inspection is fully redacted.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.SigningAuthority.Validator

  @max_human_principal_bytes 256
  @turn_id_regex ~r/^turn_[0-9a-f]{32}$/
  @cap_id_regex ~r/^cap_[0-9a-f]{32}$/

  typedstruct enforce: true do
    @typedoc "Closed authenticated-turn identity (process-local only)"

    field(:turn_id, String.t())
    field(:authenticated_principal_id, String.t())
    field(:disclosure_capability_id, String.t() | nil, default: nil)
  end

  @doc """
  Construct a turn authority after closed-attribute validation.

  Accepts only `turn_id`, `authenticated_principal_id`, and optional
  `disclosure_capability_id`. Unknown, duplicate, malformed, or oversized
  values fail closed.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, normalized} <-
           Validator.extract_attributes(attrs, [
             :turn_id,
             :authenticated_principal_id,
             :disclosure_capability_id
           ]),
         :ok <- require_key(normalized, :turn_id, :missing_turn_id),
         :ok <-
           require_key(
             normalized,
             :authenticated_principal_id,
             :missing_authenticated_principal_id
           ),
         :ok <- validate_turn_id(Map.get(normalized, :turn_id)),
         :ok <- validate_human_principal(Map.get(normalized, :authenticated_principal_id)),
         :ok <- validate_disclosure_capability_id(Map.get(normalized, :disclosure_capability_id)) do
      {:ok,
       %__MODULE__{
         turn_id: Map.fetch!(normalized, :turn_id),
         authenticated_principal_id: Map.fetch!(normalized, :authenticated_principal_id),
         disclosure_capability_id: Map.get(normalized, :disclosure_capability_id)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_), do: {:error, :invalid_attrs}

  defp require_key(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:error, error}
      {:ok, _value} -> :ok
      :error -> {:error, error}
    end
  end

  defp validate_turn_id(id) when is_binary(id) do
    if Regex.match?(@turn_id_regex, id), do: :ok, else: {:error, :invalid_turn_id}
  end

  defp validate_turn_id(_), do: {:error, :invalid_turn_id}

  defp validate_human_principal(id) when is_binary(id) and byte_size(id) > 0 do
    cond do
      not String.valid?(id) ->
        {:error, :invalid_authenticated_principal_id}

      String.contains?(id, <<0>>) ->
        {:error, :invalid_authenticated_principal_id}

      not String.starts_with?(id, "human_") ->
        {:error, :invalid_authenticated_principal_id}

      byte_size(id) > @max_human_principal_bytes ->
        {:error, :invalid_authenticated_principal_id}

      true ->
        :ok
    end
  end

  defp validate_human_principal(_), do: {:error, :invalid_authenticated_principal_id}

  defp validate_disclosure_capability_id(nil), do: :ok

  defp validate_disclosure_capability_id(id) when is_binary(id) do
    if Regex.match?(@cap_id_regex, id),
      do: :ok,
      else: {:error, :invalid_disclosure_capability_id}
  end

  defp validate_disclosure_capability_id(_), do: {:error, :invalid_disclosure_capability_id}
end

defimpl Inspect, for: Arbor.Contracts.Session.TurnAuthority do
  def inspect(%Arbor.Contracts.Session.TurnAuthority{}, _opts) do
    "#Arbor.Contracts.Session.TurnAuthority<turn_id: [REDACTED], authenticated_principal_id: [REDACTED], disclosure_capability_id: [REDACTED]>"
  end
end
