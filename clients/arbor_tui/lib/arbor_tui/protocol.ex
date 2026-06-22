defmodule ArborTui.Protocol do
  @moduledoc """
  Client-side codec for the Gateway chat WebSocket frames.

  The mirror of the server's `Arbor.Gateway.Chat.Protocol`, from the client's
  point of view: we `encode/1` commands (client→server) and `decode/1` events
  (server→client). JSON frames; the shapes here MUST match the server module.
  """

  @typedoc "A client→server command to encode."
  @type command ::
          {:attach, String.t(), String.t() | nil}
          | {:send, String.t()}
          | :cancel
          | :list_engagements

  @typedoc "A decoded server→client event."
  @type event ::
          {:engagement, %{id: String.t() | nil, transcript: list()}}
          | {:delta, String.t()}
          | {:message, map()}
          | {:notification, %{text: String.t(), kind: String.t()}}
          | {:tool_use, map()}
          | {:turn_complete, map()}
          | {:engagements, [map()]}
          | {:error, String.t()}

  # ── Encode: client → server ────────────────────────────────────────────────

  @spec encode(command()) :: binary()
  def encode({:attach, agent_id, nil}),
    do: enc(%{type: "attach", agent_id: agent_id})

  def encode({:attach, agent_id, engagement_id}),
    do: enc(%{type: "attach", agent_id: agent_id, engagement_id: engagement_id})

  def encode({:send, text}), do: enc(%{type: "send", text: text})
  def encode(:cancel), do: enc(%{type: "cancel"})
  def encode(:list_engagements), do: enc(%{type: "list_engagements"})

  defp enc(map), do: Jason.encode!(map)

  # ── Decode: server → client ──────────────────────────────────────────────

  @spec decode(binary()) :: {:ok, event()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, map} -> decode_map(map)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_map(%{"type" => "engagement"} = m),
    do: {:ok, {:engagement, %{id: m["engagement_id"], transcript: m["transcript"] || []}}}

  defp decode_map(%{"type" => "delta", "text" => text}), do: {:ok, {:delta, text}}
  defp decode_map(%{"type" => "message", "message" => message}), do: {:ok, {:message, message}}

  defp decode_map(%{"type" => "notification"} = m),
    do: {:ok, {:notification, %{text: m["text"] || "", kind: m["kind"] || "notification"}}}

  defp decode_map(%{"type" => "tool_use"} = m), do: {:ok, {:tool_use, m["tool"] || %{}}}

  defp decode_map(%{"type" => "turn_complete"} = m),
    do: {:ok, {:turn_complete, m["usage"] || %{}}}

  defp decode_map(%{"type" => "engagements"} = m),
    do: {:ok, {:engagements, m["engagements"] || []}}

  defp decode_map(%{"type" => "error"} = m), do: {:ok, {:error, m["reason"] || "error"}}
  defp decode_map(%{"type" => type}), do: {:error, {:unknown_type, type}}
  defp decode_map(_), do: {:error, :missing_type}
end
