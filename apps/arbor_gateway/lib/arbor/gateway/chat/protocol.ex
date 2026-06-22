defmodule Arbor.Gateway.Chat.Protocol do
  @moduledoc """
  Wire protocol for the Gateway chat WebSocket — pure frame decode/encode, no
  transport or state. JSON frames; see `0-inbox/gateway-chat-api.md`.

  Keeping this pure means the protocol is unit-testable without a live socket;
  `Arbor.Gateway.Chat.Socket` is the thin transport shell around it.
  """

  @typedoc "A decoded client→server command."
  @type command ::
          {:attach, %{agent_id: String.t() | nil, engagement_id: String.t() | nil}}
          | {:send, String.t()}
          | :cancel
          | :list_engagements

  @typedoc "A server→client event to encode."
  @type event ::
          {:engagement, %{id: String.t(), transcript: list()}}
          | {:delta, String.t()}
          | {:message, map()}
          | {:notification, %{text: String.t(), kind: term()}}
          | {:tool_use, map()}
          | {:turn_complete, map()}
          | {:engagements, [map()]}
          | {:error, term()}

  @doc "Decode a client→server text frame into a command."
  @spec decode(binary()) :: {:ok, command()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, map} -> decode_map(map)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_map(%{"type" => "attach"} = m),
    do: {:ok, {:attach, %{agent_id: m["agent_id"], engagement_id: m["engagement_id"]}}}

  defp decode_map(%{"type" => "send", "text" => text}) when is_binary(text),
    do: {:ok, {:send, text}}

  defp decode_map(%{"type" => "send"}), do: {:error, :missing_text}
  defp decode_map(%{"type" => "cancel"}), do: {:ok, :cancel}
  defp decode_map(%{"type" => "list_engagements"}), do: {:ok, :list_engagements}
  defp decode_map(%{"type" => type}), do: {:error, {:unknown_type, type}}
  defp decode_map(_), do: {:error, :missing_type}

  @doc "Encode a server→client event to a JSON binary (for a `{:text, _}` frame)."
  @spec encode(event()) :: binary()
  def encode({:engagement, %{id: id, transcript: transcript}}),
    do: enc(%{type: "engagement", engagement_id: id, transcript: transcript})

  def encode({:delta, text}), do: enc(%{type: "delta", text: text})
  def encode({:message, message}), do: enc(%{type: "message", message: message})

  def encode({:notification, %{text: text, kind: kind}}),
    do: enc(%{type: "notification", text: text, kind: to_string(kind)})

  def encode({:tool_use, info}), do: enc(%{type: "tool_use", tool: info})
  def encode({:turn_complete, usage}), do: enc(%{type: "turn_complete", usage: usage})
  def encode({:engagements, list}), do: enc(%{type: "engagements", engagements: list})
  def encode({:error, reason}), do: enc(%{type: "error", reason: stringify(reason)})

  defp enc(map), do: Jason.encode!(map)

  defp stringify(r) when is_binary(r), do: r
  defp stringify(r), do: inspect(r)
end
