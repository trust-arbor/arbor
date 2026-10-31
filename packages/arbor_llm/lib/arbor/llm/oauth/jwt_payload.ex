defmodule Arbor.LLM.OAuth.JwtPayload do
  @moduledoc false

  # Genuinely separate, non-facade module: shared bounded JWT-payload decode
  # used by Arbor.LLM.OAuth's expiry check and Arbor.LLM.OAuth.Login's account
  # identity extraction. Neither caller's own module exposes this as a public
  # (even @doc false) function -- keeping it out of both facades entirely is
  # what prevents a second, independently-edited decode implementation.

  @max_bytes 65_536
  @max_nodes 1_000
  @max_depth 8
  @max_map_keys 200
  @max_list_items 1_000

  @doc """
  Decode the middle (payload) segment of a compact JWT (`<header>.<payload>.<signature>`).

  Bounded: rejects anything that doesn't parse as `<binary>.<binary>.<binary>`,
  isn't valid base64url, or decodes to a JSON document outside the fixed
  structural budget below. This performs no signature verification -- callers
  must not treat the result as an authentication decision.
  """
  @spec decode(String.t()) :: {:ok, map()} | {:error, :invalid_jwt_payload}
  def decode(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = json} <- Arbor.LLM.ResponseBudget.decode_json(decoded, limits()) do
      {:ok, json}
    else
      _ -> {:error, :invalid_jwt_payload}
    end
  end

  def decode(_token), do: {:error, :invalid_jwt_payload}

  defp limits do
    [
      max_bytes: @max_bytes,
      max_nodes: @max_nodes,
      max_depth: @max_depth,
      max_map_keys: @max_map_keys,
      max_list_items: @max_list_items
    ]
  end
end
