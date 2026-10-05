defmodule Arbor.Client.Protocol do
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
          | :retry
          | :cancel
          | :list_engagements
          | :list_approvals
          | {:approve, String.t()}
          | {:deny, String.t()}

  @typedoc "A decoded server→client event."
  @type event ::
          {:engagement, %{id: String.t() | nil, transcript: list()}}
          | {:conversation_history, map()}
          | {:conversation_window, map()}
          | {:conversation_notices, map()}
          | {:conversation_command, map()}
          | {:conversation_events, map()}
          | {:conversation_activity, map()}
          | {:conversation_cancellation, map()}
          | {:conversation_interactions, map()}
          | {:conversation_interaction_answer, map()}
          | {:delta, String.t()}
          | {:message, map()}
          | {:notification, %{text: String.t(), kind: String.t()}}
          | {:tool_use, map()}
          | {:turn_complete, map()}
          | {:engagements, [map()]}
          | {:approval_request, %{proposal_id: String.t(), tool: String.t(), args: map()}}
          | {:approvals, [map()]}
          | {:approval_resolved, %{proposal_id: String.t(), status: String.t()}}
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
  def encode(:list_approvals), do: enc(%{type: "list_approvals"})
  def encode({:approve, id}), do: enc(%{type: "approve", proposal_id: id})
  def encode({:deny, id}), do: enc(%{type: "deny", proposal_id: id})

  defp enc(map), do: Jason.encode!(map)

  @doc "Build the exact operation payload shared with Arbor.Agent.conversation_request_payload/5."
  def conversation_payload(operation, caller, target, input, opts \\ [])

  def conversation_payload(operation, caller, target, input, opts)
      when operation in [
             :activity,
             :cancel,
             :interactions,
             :interaction_choice,
             :interaction_approval
           ],
      do: Arbor.Client.ControlPayload.encode(operation, caller, target, input, opts)

  def conversation_payload(:window, caller, target, _input, opts),
    do: conversation_window_payload(caller, target, opts)

  def conversation_payload(:notices, caller, target, nil, opts),
    do: Arbor.Client.NoticePayload.encode(caller, target, opts)

  def conversation_payload(:notices, _caller, _target, _input, _opts),
    do: {:error, :invalid_notice_request}

  def conversation_payload(operation, caller, target, input, opts) do
    input = if operation == :submit, do: [input.id, input.text], else: input

    Jason.encode!([
      "arbor.conversation.v2",
      to_string(operation),
      caller,
      target,
      input,
      [Keyword.get(opts, :after), Keyword.get(opts, :through), Keyword.get(opts, :limit)],
      Keyword.get(opts, :expected_engagement_id)
    ])
  end

  @doc """
  Encode the host's separately versioned bounded transcript window payload.

  `:before` and `:after` are exclusive entry ordinals; omit both for the latest
  window. `:through` pins the head observed while paging, `:limit` is 1..100, and
  `:expected_engagement_id` fences conversation ownership. The Gateway validates
  those values and remains the authority for the resulting entries and head.
  """
  def conversation_window_payload(caller, target, opts \\ []) do
    Jason.encode!([
      "arbor.conversation.window.v1",
      caller,
      target,
      [
        Keyword.get(opts, :before),
        Keyword.get(opts, :after),
        Keyword.get(opts, :through),
        Keyword.get(opts, :limit)
      ],
      Keyword.get(opts, :expected_engagement_id)
    ])
  end

  def signed_operation(identity, target, operation, input, opts \\ []) do
    payload = conversation_payload(operation, identity.agent_id, target, input, opts)

    if is_binary(payload) do
      enc(%{
        payload: payload,
        authorization: Arbor.Client.Signer.authorization_for_payload(identity, payload)
      })
    else
      payload
    end
  end

  @doc "Encode an operation for an authenticated server-scoped conversation session."
  def session_operation(caller, target, operation, input, opts \\ []) do
    case conversation_payload(operation, caller, target, input, opts) do
      payload when is_binary(payload) ->
        enc(%{payload: payload, authentication: "conversation_session"})

      error ->
        error
    end
  end

  # ── Decode: server → client ──────────────────────────────────────────────

  @spec decode(binary()) :: {:ok, event()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, %{"type" => "conversation_notices"}} ->
        case Arbor.Client.NoticePage.decode_frame(binary) do
          {:ok, page} -> {:ok, {:conversation_notices, page}}
          error -> error
        end

      {:ok, map} ->
        decode_map(map)

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp decode_map(%{"type" => "conversation_history", "data" => page}),
    do: {:ok, {:conversation_history, page}}

  defp decode_map(%{"type" => "conversation_window", "data" => page}),
    do: {:ok, {:conversation_window, page}}

  defp decode_map(%{"type" => "conversation_rejected", "data" => rejection}),
    do: {:ok, {:conversation_rejected, rejection}}

  defp decode_map(%{"type" => "conversation_command", "data" => command}),
    do: {:ok, {:conversation_command, command}}

  defp decode_map(%{"type" => "conversation_events", "data" => page}),
    do: {:ok, {:conversation_events, page}}

  defp decode_map(%{"type" => type, "data" => data})
       when type in [
              "conversation_activity",
              "conversation_cancellation",
              "conversation_interactions",
              "conversation_interaction_answer"
            ] and is_map(data) do
    if byte_size(Jason.encode!(data)) <= 131_584 do
      event =
        case type do
          "conversation_activity" -> :conversation_activity
          "conversation_cancellation" -> :conversation_cancellation
          "conversation_interactions" -> :conversation_interactions
          "conversation_interaction_answer" -> :conversation_interaction_answer
        end

      {:ok, {event, data}}
    else
      {:error, :control_reply_too_large}
    end
  end

  defp decode_map(%{"type" => "engagement"} = m),
    do:
      {:ok,
       {:engagement,
        %{
          id: m["engagement_id"],
          transcript: m["transcript"] || [],
          display_name: m["display_name"]
        }}}

  defp decode_map(%{"type" => "delta", "text" => text}), do: {:ok, {:delta, text}}
  defp decode_map(%{"type" => "message", "message" => message}), do: {:ok, {:message, message}}

  defp decode_map(%{"type" => "notification"} = m),
    do: {:ok, {:notification, %{text: m["text"] || "", kind: m["kind"] || "notification"}}}

  defp decode_map(%{"type" => "tool_use"} = m), do: {:ok, {:tool_use, m["tool"] || %{}}}

  defp decode_map(%{"type" => "turn_complete"} = m),
    do: {:ok, {:turn_complete, m["usage"] || %{}}}

  defp decode_map(%{"type" => "engagements"} = m),
    do: {:ok, {:engagements, m["engagements"] || []}}

  defp decode_map(%{"type" => "approval_request"} = m),
    do:
      {:ok,
       {:approval_request,
        %{proposal_id: m["proposal_id"], tool: m["tool"] || "tool", args: m["args"] || %{}}}}

  defp decode_map(%{"type" => "approvals"} = m),
    do: {:ok, {:approvals, m["approvals"] || []}}

  defp decode_map(%{"type" => "approval_resolved"} = m),
    do:
      {:ok,
       {:approval_resolved, %{proposal_id: m["proposal_id"], status: m["status"] || "resolved"}}}

  defp decode_map(%{"type" => "error"} = m), do: {:ok, {:error, m["reason"] || "error"}}
  defp decode_map(%{"type" => type}), do: {:error, {:unknown_type, type}}
  defp decode_map(_), do: {:error, :missing_type}
end
