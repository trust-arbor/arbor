defmodule Arbor.Comms.ConversationInteractionsCore do
  @moduledoc false

  alias Arbor.Comms.ConversationJournalCore
  alias Arbor.Contracts.Comms.ApprovalAnswer

  @attachment_keys ~w(owner_id agent_id engagement_id command_id task_id source_id session_id operation_id revision kind text choices)
  @evidence_keys ~w(responder_id request_id operation_id revision response)

  def request_payload(:interactions, caller, target, command_id, expected) do
    with :ok <- ConversationJournalCore.validate_id(command_id),
         :ok <- validate_payload_scope(caller, target, expected) do
      {:ok,
       Jason.encode!(["arbor.conversation.interactions.v1", caller, target, command_id, expected])}
    end
  end

  def request_payload(:interaction_choice, caller, target, input, expected) when is_map(input) do
    with :ok <- validate_payload_scope(caller, target, expected),
         true <-
           Enum.sort(Map.keys(input)) ==
             Enum.sort([:command_id, :request_id, :operation_id, :revision, :choice_id]),
         :ok <- ConversationJournalCore.validate_id(input.command_id),
         true <-
           Enum.all?([input.request_id, input.operation_id, input.choice_id], &bounded?(&1, 256)),
         true <- input.revision == 1 do
      {:ok,
       Jason.encode!([
         "arbor.conversation.interaction.choice.v1",
         caller,
         target,
         [
           input.command_id,
           input.request_id,
           input.operation_id,
           input.revision,
           input.choice_id
         ],
         expected
       ])}
    else
      _ -> {:error, :invalid_interaction_answer}
    end
  end

  def request_payload(:interaction_approval, caller, target, input, expected)
      when is_map(input) do
    with :ok <- validate_payload_scope(caller, target, expected),
         true <-
           Enum.sort(Map.keys(input)) ==
             Enum.sort([:command_id, :request_id, :operation_id, :revision, :decision, :note]),
         :ok <- ConversationJournalCore.validate_id(input.command_id),
         true <- Enum.all?([input.request_id, input.operation_id], &bounded?(&1, 256)),
         true <- input.revision == 1,
         true <- input.decision in [:approve, :deny, :rework, "approve", "deny", "rework"],
         {:ok, _} <- ApprovalAnswer.validate_note(input.note) do
      {:ok,
       Jason.encode!([
         "arbor.conversation.interaction.approval.v1",
         caller,
         target,
         [
           input.command_id,
           input.request_id,
           input.operation_id,
           input.revision,
           to_string(input.decision),
           input.note
         ],
         expected
       ])}
    else
      _ -> {:error, :invalid_interaction_answer}
    end
  end

  def request_payload(_, _, _, _, _), do: {:error, :invalid_interaction_answer}

  defp validate_payload_scope(caller, target, expected) do
    if bounded?(caller, 256) and bounded?(target, 256) and
         Regex.match?(~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/, caller) and
         Regex.match?(~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/, target) and
         (is_nil(expected) or
            (is_binary(expected) and Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, expected))),
       do: :ok,
       else: {:error, :invalid_opts}
  end

  @approval_display_maps %{
    "payload_preview" => ~w(kind bytes truncated preview),
    "risk_hints" =>
      ~w(workspace in_workspace effect_class egress_tier egress_destination external),
    "trust" => ~w(mode effective_mode ceiling decision reason rule_id matched_rule resource_uri)
  }

  # Native authorization retains rich taint in process-local context. Durable
  # conversation approval stores only original normalized identity and bounded
  # display fields; display labels never establish authority or taint evidence.
  def approval_projection(identity, description, metadata) do
    capability_id = object_value(metadata, "capability_id")

    with true <- is_nil(capability_id) or bounded?(capability_id, 256) do
      display =
        Enum.reduce(
          ~w(action target_type target reason gate payload_preview risk_hints trust),
          %{},
          fn key, acc ->
            case approval_display_value(key, object_value(metadata, key)) do
              nil -> acc
              value -> Map.put(acc, key, value)
            end
          end
        )

      stored = %{
        "task_id" => identity["task_id"],
        "agent_id" => identity["agent_id"],
        "principal_id" => identity["principal_id"],
        "resource_uri" => identity["resource_uri"],
        "action" => identity["action"],
        "capability_id" => capability_id,
        "display" => display
      }

      details =
        display
        |> Enum.sort()
        |> Enum.map(fn {key, value} ->
          key <> ": " <> if(is_binary(value), do: value, else: Jason.encode!(value))
        end)

      text =
        Enum.join([truncate_display(description, 1024) | details], "\n") |> truncate_display(4096)

      {:ok, %{metadata: stored, text: text}}
    else
      _ -> {:error, :invalid_protected_source}
    end
  end

  defp approval_display_value(key, value) when is_map(value) and not is_struct(value) do
    case Map.get(@approval_display_maps, key) do
      nil ->
        nil

      keys ->
        keys
        |> Enum.reduce(%{}, fn field, acc ->
          case display_scalar(object_value(value, field)) do
            nil -> acc
            scalar -> Map.put(acc, field, scalar)
          end
        end)
        |> case do
          empty when map_size(empty) == 0 -> nil
          display -> display
        end
    end
  end

  defp approval_display_value(_key, value), do: display_scalar(value)

  defp display_scalar(value) when is_binary(value) do
    if String.valid?(value), do: truncate_display(value, 512), else: nil
  end

  defp display_scalar(nil), do: nil
  defp display_scalar(value) when is_boolean(value) or is_integer(value), do: value
  defp display_scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp display_scalar(_value), do: nil

  defp object_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {atom, value} when is_atom(atom) -> if Atom.to_string(atom) == key, do: {:found, value}
          _ -> nil
        end)
        |> case do
          {:found, value} -> value
          _ -> nil
        end
    end
  end

  defp object_value(_map, _key), do: nil
  defp truncate_display(value, limit) when byte_size(value) <= limit, do: value

  defp truncate_display(value, limit),
    do: utf8_prefix(binary_part(value, 0, limit - 3)) <> "…"

  defp utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

  def validate_spec(%{kind: :choice, text: text, choices: choices} = spec) do
    if Enum.sort(Map.keys(spec)) == Enum.sort([:kind, :text, :choices]) and
         bounded?(text, 4096) and valid_choices?(choices),
       do: :ok,
       else: {:error, :invalid_interaction}
  end

  def validate_spec(_), do: {:error, :unsupported_protected_gate}

  def attachment(scope, command, source_id, session_id, operation_id, spec) do
    with :ok <- ConversationJournalCore.validate_scope(scope), :ok <- validate_spec(spec) do
      {:ok,
       %{
         "owner_id" => scope.principal_id,
         "agent_id" => scope.agent_id,
         "engagement_id" => scope.engagement_id,
         "command_id" => command.command_id,
         "task_id" => command.task_id,
         "source_id" => source_id,
         "session_id" => session_id,
         "operation_id" => operation_id,
         "revision" => 1,
         "kind" => "choice",
         "text" => spec.text,
         "choices" => Enum.map(spec.choices, &%{"id" => &1.id, "label" => &1.label})
       }}
    end
  end

  def validate_attachment(nil), do: :ok

  def validate_attachment(value) when is_map(value) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@attachment_keys),
         true <-
           Enum.all?(
             ~w(owner_id agent_id engagement_id command_id task_id source_id session_id operation_id),
             &bounded?(value[&1], 256)
           ),
         true <- value["revision"] == 1,
         true <- value["kind"] in ["choice", "approval"],
         true <- bounded?(value["text"], 4096),
         true <- valid_json_choices?(value["choices"]) do
      :ok
    else
      _ -> {:error, :invalid_conversation_attachment}
    end
  end

  def validate_attachment(_), do: {:error, :invalid_conversation_attachment}

  def validate_evidence(nil), do: :ok

  def validate_evidence(value) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(@evidence_keys) and
         Enum.all?(~w(responder_id request_id operation_id), &bounded?(value[&1], 256)) and
         value["revision"] == 1 and bounded?(value["response"], 4096),
       do: :ok,
       else: {:error, :invalid_verified_response}
  end

  def validate_evidence(_), do: {:error, :invalid_verified_response}

  def matches?(attachment, scope, command_id) when is_map(attachment) do
    attachment["owner_id"] == scope.principal_id and attachment["agent_id"] == scope.agent_id and
      attachment["engagement_id"] == scope.engagement_id and
      attachment["command_id"] == command_id
  end

  def matches?(_, _, _), do: false

  def answer(attachment, operation, request_id) do
    required = [:command_id, :request_id, :operation_id, :revision, :choice_id]

    with true <- is_map(operation) and Enum.sort(Map.keys(operation)) == Enum.sort(required),
         true <- attachment["kind"] == "choice",
         true <- operation.command_id == attachment["command_id"],
         true <- operation.request_id == request_id,
         true <- operation.operation_id == attachment["operation_id"],
         true <- operation.revision == attachment["revision"],
         true <- Enum.any?(attachment["choices"], &(&1["id"] == operation.choice_id)) do
      {:ok, {:choice, operation.choice_id}}
    else
      _ -> {:error, :invalid_interaction_answer}
    end
  end

  def project(attachment, request_id, status, deadline) do
    %{
      request_id: request_id,
      operation_id: attachment["operation_id"],
      command_id: attachment["command_id"],
      revision: attachment["revision"],
      kind: attachment["kind"],
      text: attachment["text"],
      choices: Enum.map(attachment["choices"], &%{id: &1["id"], label: &1["label"]}),
      deadline_unix_ms: deadline,
      status: status
    }
  end

  defp valid_choices?(choices) when is_list(choices) and length(choices) in 1..32 do
    Enum.all?(choices, fn
      %{id: id, label: label} = choice ->
        map_size(choice) == 2 and bounded?(id, 128) and bounded?(label, 512)

      _ ->
        false
    end) and length(Enum.uniq_by(choices, & &1.id)) == length(choices)
  end

  defp valid_choices?(_), do: false

  defp valid_json_choices?(choices) when is_list(choices) do
    converted =
      Enum.map(choices, fn
        %{"id" => id, "label" => label} = choice when map_size(choice) == 2 ->
          %{id: id, label: label}

        _ ->
          nil
      end)

    valid_choices?(converted)
  end

  defp valid_json_choices?(_), do: false

  defp bounded?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)
end
