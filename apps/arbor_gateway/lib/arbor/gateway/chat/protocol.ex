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
    with {:ok, %Jason.OrderedObject{values: envelope_pairs}} <-
           Jason.decode(binary, objects: :ordered_objects),
         true <- length(envelope_pairs) == 2,
         %{"payload" => payload, "authorization" => "Signature " <> encoded} = envelope <-
           Map.new(envelope_pairs),
         true <- map_size(envelope) == 2 and is_binary(payload),
         {:ok, request} <- decode_payload(payload),
         caller = request.caller,
         {:ok, json} <- Base.decode64(encoded, padding: false),
         {:ok, %Jason.OrderedObject{values: auth_pairs}} <-
           Jason.decode(json, objects: :ordered_objects),
         true <- length(auth_pairs) == 4,
         %{
           "agent_id" => ^caller,
           "timestamp" => timestamp,
           "nonce" => nonce,
           "signature" => signature
         } = auth <- Map.new(auth_pairs),
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
           ) do
      {:ok, request |> Map.delete(:caller) |> Map.put(:proof, proof)}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def decode_authenticated(_), do: {:error, :unauthorized}

  @doc "Decode a session-mode frame; its caller and target must match the socket binding."
  def decode_session(binary) when is_binary(binary) and byte_size(binary) <= 262_144 do
    with {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(binary, objects: :ordered_objects),
         true <- length(pairs) == 2,
         %{"payload" => payload, "authentication" => "conversation_session"} = envelope <-
           Map.new(pairs),
         true <- map_size(envelope) == 2 and is_binary(payload) do
      decode_payload(payload)
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def decode_session(_), do: {:error, :unauthorized}

  defp decode_payload(payload) do
    case Jason.decode(payload) do
      {:ok,
       [
         "arbor.conversation.window.v1",
         caller,
         target,
         [before, after_cursor, through, limit],
         fence
       ]} ->
        decode_window(caller, target, before, after_cursor, through, limit, fence)

      {:ok,
       [
         "arbor.conversation.notices.v1",
         caller,
         target,
         [before, through, limit],
         fence
       ]} ->
        decode_notices(payload, caller, target, before, through, limit, fence)

      {:ok, [tag | _] = control}
      when tag in [
             "arbor.conversation.activity.v1",
             "arbor.conversation.cancel.v1",
             "arbor.conversation.interactions.v1",
             "arbor.conversation.interaction.choice.v1",
             "arbor.conversation.interaction.approval.v1"
           ] ->
        decode_control(control)

      _ ->
        decode_v2_payload(payload)
    end
  end

  defp decode_notices(payload, caller, target, before, through, limit, fence) do
    page = Enum.reject([before: before, through: through, limit: limit], &is_nil(elem(&1, 1)))

    # Reuse the public closed grammar. It requires the exact canonical payload
    # and engagement fence; parsing does not grant authority or choose a route.
    with {:ok, ^payload} <-
           Arbor.Security.conversation_notice_read_request_payload(caller, target, page, fence) do
      {:ok,
       %{
         operation: :notices,
         caller: caller,
         target: target,
         input: nil,
         opts: Keyword.put(page, :expected_engagement_id, fence)
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp decode_control([tag, caller, target, input, [cursor, limit, timeout], fence])
       when tag in ["arbor.conversation.activity.v1", "arbor.conversation.cancel.v1"] do
    operation = if tag == "arbor.conversation.activity.v1", do: :activity, else: :cancel

    with true <- control_scope?(caller, target, fence),
         true <-
           (operation == :activity and is_nil(input)) or
             (operation == :cancel and command_id?(input)),
         true <-
           is_nil(limit) or (operation == :activity and is_integer(limit) and limit in 1..50),
         true <- is_nil(timeout) or (is_integer(timeout) and timeout in 1..30_000),
         {:ok, cursor} <- control_cursor(operation, cursor) do
      opts = control_opts([cursor: cursor, limit: limit, control_timeout: timeout], fence)
      {:ok, %{operation: operation, caller: caller, target: target, input: input, opts: opts}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp decode_control(["arbor.conversation.interactions.v1", caller, target, command_id, fence]) do
    if control_scope?(caller, target, fence) and command_id?(command_id),
      do:
        {:ok,
         %{
           operation: :interactions,
           caller: caller,
           target: target,
           input: command_id,
           opts: control_opts([], fence)
         }},
      else: {:error, :unauthorized}
  end

  defp decode_control([
         "arbor.conversation.interaction.choice.v1",
         caller,
         target,
         [command_id, request_id, operation_id, revision, choice_id],
         fence
       ]) do
    if control_scope?(caller, target, fence) and command_id?(command_id) and
         Enum.all?([request_id, operation_id, choice_id], &bounded_control_string?(&1, 256)) and
         revision === 1 do
      input = %{
        command_id: command_id,
        request_id: request_id,
        operation_id: operation_id,
        revision: revision,
        choice_id: choice_id
      }

      {:ok,
       %{
         operation: :interaction_choice,
         caller: caller,
         target: target,
         input: input,
         opts: control_opts([], fence)
       }}
    else
      {:error, :unauthorized}
    end
  end

  defp decode_control([
         "arbor.conversation.interaction.approval.v1",
         caller,
         target,
         [command_id, request_id, operation_id, revision, decision, note],
         fence
       ]) do
    if control_scope?(caller, target, fence) and command_id?(command_id) and
         Enum.all?([request_id, operation_id], &bounded_control_string?(&1, 256)) and
         revision === 1 and decision in ["approve", "deny", "rework"] and control_note?(note) do
      input = %{
        command_id: command_id,
        request_id: request_id,
        operation_id: operation_id,
        revision: revision,
        decision: decision,
        note: note
      }

      {:ok,
       %{
         operation: :interaction_approval,
         caller: caller,
         target: target,
         input: input,
         opts: control_opts([], fence)
       }}
    else
      {:error, :unauthorized}
    end
  end

  defp decode_control(_), do: {:error, :unauthorized}

  defp control_cursor(_, nil), do: {:ok, nil}

  defp control_cursor(:activity, [ordinal, id])
       when is_integer(ordinal) and ordinal in 1..9_223_372_036_854_775_807 do
    if command_id?(id),
      do: {:ok, %{admitted_event_number: ordinal, command_id: id}},
      else: {:error, :invalid_cursor}
  end

  defp control_cursor(_, _), do: {:error, :invalid_cursor}

  defp control_opts(opts, fence) do
    opts = Enum.reject(opts, fn {_, value} -> is_nil(value) end)
    if fence, do: Keyword.put(opts, :expected_engagement_id, fence), else: opts
  end

  defp control_scope?(caller, target, fence),
    do:
      control_principal?(caller) and control_principal?(target) and
        (is_nil(fence) or
           (is_binary(fence) and byte_size(fence) == 36 and
              Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, fence)))

  defp control_principal?(id),
    do:
      bounded_control_string?(id, 256) and
        Regex.match?(~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/, id)

  defp command_id?(id),
    do: bounded_control_string?(id, 128) and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp bounded_control_string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp control_note?(nil), do: true

  defp control_note?(note) when is_binary(note) and byte_size(note) <= 1_024,
    do: String.valid?(note) and not Regex.match?(~r/[\x00-\x1f\x7f]/, note)

  defp control_note?(_), do: false

  defp decode_window(caller, target, before, after_cursor, through, limit, fence) do
    opts =
      [before: before, after: after_cursor, through: through, limit: limit]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    valid_fence =
      is_nil(fence) or
        (is_binary(fence) and Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, fence))

    if is_binary(caller) and is_binary(target) and valid_fence and
         valid_window_bounds?(before, after_cursor, through, limit) do
      opts = if fence, do: Keyword.put(opts, :expected_engagement_id, fence), else: opts
      {:ok, %{operation: :window, caller: caller, target: target, input: nil, opts: opts}}
    else
      {:error, :unauthorized}
    end
  end

  defp valid_window_bounds?(before, after_cursor, through, limit) do
    (is_nil(before) or window_ordinal?(before, 1)) and
      (is_nil(after_cursor) or window_ordinal?(after_cursor, 0)) and
      (is_nil(through) or window_ordinal?(through, 0)) and
      (is_nil(limit) or (is_integer(limit) and limit in 1..100)) and
      (is_nil(before) or is_nil(after_cursor)) and
      (is_nil(through) or
         ((is_nil(before) or before <= through) and
            (is_nil(after_cursor) or after_cursor <= through)))
  end

  defp window_ordinal?(value, minimum),
    do: is_integer(value) and value >= minimum and value <= 9_223_372_036_854_775_807

  defp decode_v2_payload(payload) do
    with {:ok,
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
         {:ok, opts} <- page_opts(operation, after_cursor, through, limit),
         true <-
           is_nil(expected_engagement_id) or
             (is_binary(expected_engagement_id) and
                Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, expected_engagement_id)) do
      opts =
        if expected_engagement_id,
          do: Keyword.put(opts, :expected_engagement_id, expected_engagement_id),
          else: opts

      {:ok, %{operation: operation, caller: caller, target: target, input: input, opts: opts}}
    else
      _ -> {:error, :unauthorized}
    end
  end

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
      when type in [
             :conversation_history,
             :conversation_window,
             :conversation_notices,
             :conversation_command,
             :conversation_events,
             :conversation_activity,
             :conversation_cancellation,
             :conversation_interactions,
             :conversation_interaction_answer
           ],
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
