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
          | :list_approvals
          | {:approve, String.t()}
          | {:deny, String.t()}

  @typedoc "A server→client event to encode."
  @type event ::
          {:engagement, %{id: String.t(), transcript: list()}}
          | {:conversation_history, map()}
          | {:conversation_command, map()}
          | {:conversation_events, map()}
          | {:delta, String.t()}
          | {:message, map()}
          | {:notification, %{text: String.t(), kind: term()}}
          | {:tool_use, map()}
          | {:turn_complete, map()}
          | {:engagements, [map()]}
          | {:approval_request, %{proposal_id: String.t(), tool: String.t(), args: map()}}
          | {:approvals, [map()]}
          | {:approval_resolved, %{proposal_id: String.t(), status: String.t()}}
          | {:error, term()}

  alias Arbor.Contracts.Security.SignedRequest

  @doc "Decode an operation-bound frame without consuming its signature nonce."
  def decode_authenticated(binary) when is_binary(binary) and byte_size(binary) <= 262_144 do
    with {:ok, %{"payload" => payload, "authorization" => "Signature " <> encoded} = envelope} <-
           Jason.decode(binary),
         true <- map_size(envelope) == 2 and is_binary(payload),
         {:ok,
          [
            "arbor.conversation.v2",
            operation,
            caller,
            target,
            input,
            [after_cursor, through, limit],
            expected_engagement_id
          ]} <- Jason.decode(payload),
         {:ok, operation, input} <- operation(operation, input),
         true <- is_binary(caller) and is_binary(target),
         {:ok, json} <- Base.decode64(encoded, padding: false),
         {:ok,
          %{
            "agent_id" => ^caller,
            "timestamp" => timestamp,
            "nonce" => nonce,
            "signature" => signature
          } = auth} <- Jason.decode(json),
         true <- map_size(auth) == 4,
         {:ok, timestamp, 0} <- DateTime.from_iso8601(timestamp),
         {:ok, nonce} <- Base.decode64(nonce),
         {:ok, signature} <- Base.decode64(signature),
         {:ok, proof} <-
           SignedRequest.new(
             payload: payload,
             agent_id: caller,
             timestamp: timestamp,
             nonce: nonce,
             signature: signature
           ),
         {:ok, opts} <- page_opts(operation, after_cursor, through, limit),
         true <-
           is_nil(expected_engagement_id) or
             (is_binary(expected_engagement_id) and
                Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, expected_engagement_id)) do
      opts =
        if expected_engagement_id,
          do: Keyword.put(opts, :expected_engagement_id, expected_engagement_id),
          else: opts

      {:ok, %{operation: operation, target: target, input: input, opts: opts, proof: proof}}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def decode_authenticated(_), do: {:error, :unauthorized}

  defp operation("submit", [id, text]) when is_binary(id) and is_binary(text),
    do: {:ok, :submit, %{id: id, text: text}}

  defp operation("command", id) when is_binary(id), do: {:ok, :command, id}

  defp operation("events", cursor) when is_integer(cursor) and cursor >= 0,
    do: {:ok, :events, cursor}

  defp operation("history", nil), do: {:ok, :history, nil}
  defp operation(_, _), do: {:error, :invalid_operation}

  defp page_opts(operation, after_cursor, through, limit) do
    opts =
      [after: after_cursor, through: through, limit: limit]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    allowed =
      case operation do
        :history -> [:after, :through, :limit]
        :events -> [:through, :limit]
        _ -> []
      end

    if Enum.all?(opts, fn {key, value} -> key in allowed and is_integer(value) and value >= 0 end),
       do: {:ok, opts},
       else: {:error, :invalid_opts}
  end

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
  defp decode_map(%{"type" => "list_approvals"}), do: {:ok, :list_approvals}

  defp decode_map(%{"type" => "approve", "proposal_id" => id}) when is_binary(id),
    do: {:ok, {:approve, id}}

  defp decode_map(%{"type" => "deny", "proposal_id" => id}) when is_binary(id),
    do: {:ok, {:deny, id}}

  defp decode_map(%{"type" => type}) when type in ["approve", "deny"],
    do: {:error, :missing_proposal_id}

  defp decode_map(%{"type" => type}), do: {:error, {:unknown_type, type}}
  defp decode_map(_), do: {:error, :missing_type}

  @doc "Encode a server→client event to a JSON binary (for a `{:text, _}` frame)."
  @spec encode(event()) :: binary()
  def encode({:engagement, %{id: id, transcript: transcript} = m}),
    do:
      enc(%{
        type: "engagement",
        engagement_id: id,
        transcript: transcript,
        display_name: Map.get(m, :display_name)
      })

  def encode({type, page})
      when type in [:conversation_history, :conversation_command, :conversation_events],
      do: enc(%{type: to_string(type), data: page})

  def encode({:conversation_rejected, %{id: id, reason: reason}}),
    do: enc(%{type: "conversation_rejected", data: %{id: id, reason: stringify(reason)}})

  def encode({:delta, text}), do: enc(%{type: "delta", text: text})
  def encode({:message, message}), do: enc(%{type: "message", message: message})

  def encode({:notification, %{text: text, kind: kind}}),
    do: enc(%{type: "notification", text: text, kind: to_string(kind)})

  def encode({:tool_use, info}), do: enc(%{type: "tool_use", tool: info})
  def encode({:turn_complete, usage}), do: enc(%{type: "turn_complete", usage: usage})
  def encode({:engagements, list}), do: enc(%{type: "engagements", engagements: list})

  def encode({:approval_request, %{proposal_id: id} = req}),
    do:
      enc(%{
        type: "approval_request",
        proposal_id: id,
        tool: Map.get(req, :tool, ""),
        args: Map.get(req, :args, %{})
      })

  def encode({:approvals, list}), do: enc(%{type: "approvals", approvals: list})

  def encode({:approval_resolved, %{proposal_id: id, status: status}}),
    do: enc(%{type: "approval_resolved", proposal_id: id, status: to_string(status)})

  def encode({:error, reason}), do: enc(%{type: "error", reason: stringify(reason)})

  defp enc(map), do: Jason.encode!(map)

  defp stringify(r) when is_binary(r), do: r
  defp stringify(r) when is_atom(r), do: Atom.to_string(r)
  defp stringify(r), do: inspect(r)
end
