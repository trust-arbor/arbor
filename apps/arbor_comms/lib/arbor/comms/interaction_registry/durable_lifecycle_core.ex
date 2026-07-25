defmodule Arbor.Comms.InteractionRegistry.DurableLifecycleCore do
  @moduledoc """
  Pure reducer and serializer for one durable interaction lifecycle record.

  The record is deliberately a closed, string-keyed JSON object.  Interaction
  metadata and choice values are bounded JSON values; responses use an
  explicit tagged representation so approval and text responses survive a
  JSON round trip without creating atoms from input.

  Terminal projection restores the authority's atom-keyed field names and
  known status/decision/reason atoms. `authority_node` deliberately remains
  a bounded UTF-8 string in the projected map because node identity crosses
  the JSON boundary as data and must not be converted into an atom.

  Limits are intentionally conservative: opaque identifiers are 256 bytes,
  ordinary strings are 16 KiB, metadata is 32 KiB, responses are 16 KiB, and
  nested JSON values are at most eight levels deep with at most 128 entries or
  list items per container.
  """

  alias Arbor.Contracts.Comms.Interaction

  @schema_version 1
  @max_identifier_bytes 256
  @max_string_bytes 16_384
  @max_reason_bytes 1_024
  @max_metadata_bytes 32_768
  @max_response_bytes 16_384
  @max_json_depth 8
  @max_container_entries 128

  @record_keys [
    "schema_version",
    "operation_id",
    "request_id",
    "status",
    "interaction",
    "authority_node",
    "authority_epoch",
    "owner_deadline_unix_ms",
    "terminal",
    "admitted_at_unix_ms",
    "updated_at_unix_ms"
  ]

  @interaction_keys [
    "request_id",
    "kind",
    "agent_id",
    "user_id",
    "description",
    "metadata",
    "resource_uri",
    "urgency",
    "expires_at",
    "response_topic",
    "submitted_at"
  ]

  @terminal_keys [
    "status",
    "decision",
    "response",
    "metadata",
    "reason",
    "resolved_at",
    "authority_node"
  ]

  @statuses ["pending", "responded", "abandoned", "expired"]
  @terminal_statuses ["responded", "abandoned", "expired"]

  @kind_to_string %{
    approval: "approval",
    clarification: "clarification",
    confirmation: "confirmation",
    decision: "decision",
    notification: "notification",
    escalation: "escalation"
  }

  @urgency_to_string %{low: "low", normal: "normal", high: "high", critical: "critical"}

  @doc "Return the durable schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Construct a pending durable record from an interaction and injected values."
  @spec new(Interaction.t(), String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def new(%Interaction{} = interaction, operation_id, authority_node, authority_epoch, now_ms) do
    with :ok <- validate_identifier(operation_id, :operation_id),
         :ok <- validate_identifier(interaction.request_id, :request_id),
         :ok <- validate_identifier(authority_node, :authority_node),
         :ok <- validate_identifier(authority_epoch, :authority_epoch),
         :ok <- validate_time(now_ms),
         {:ok, serialized_interaction} <- serialize_interaction(interaction) do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "operation_id" => operation_id,
         "request_id" => interaction.request_id,
         "status" => "pending",
         "interaction" => serialized_interaction,
         "authority_node" => authority_node,
         "authority_epoch" => authority_epoch,
         "owner_deadline_unix_ms" => nil,
         "terminal" => nil,
         "admitted_at_unix_ms" => now_ms,
         "updated_at_unix_ms" => now_ms
       }}
    end
  end

  def new(_interaction, _operation_id, _authority_node, _authority_epoch, _now_ms),
    do: {:error, :invalid_interaction}

  @doc "Strictly validate an already decoded JSON record."
  @spec decode(map()) :: {:ok, map()} | {:error, term()}
  def decode(record) when is_map(record) do
    with :ok <- exact_keys(record, @record_keys, :record),
         :ok <- validate_schema_version(record["schema_version"]),
         :ok <- validate_identifier(record["operation_id"], :operation_id),
         :ok <- validate_identifier(record["request_id"], :request_id),
         :ok <- validate_enum(record["status"], @statuses, :status),
         {:ok, interaction} <- decode_interaction(record["interaction"]),
         :ok <- same_request_id(record["request_id"], interaction.request_id),
         :ok <- validate_identifier(record["authority_node"], :authority_node),
         :ok <- validate_identifier(record["authority_epoch"], :authority_epoch),
         :ok <- validate_nullable_time(record["owner_deadline_unix_ms"]),
         {:ok, terminal} <- decode_terminal(record["terminal"]),
         :ok <- terminal_status_consistent(record["status"], terminal),
         :ok <- terminal_authority_consistent(record, terminal),
         :ok <- validate_time(record["admitted_at_unix_ms"]),
         :ok <- validate_time(record["updated_at_unix_ms"]),
         :ok <- timestamp_ordering(record, terminal),
         :ok <- bounded_record?(record) do
      {:ok, record}
    end
  end

  def decode(_), do: {:error, :invalid_record}

  @doc "Alias for strict durable-record decoding."
  def strict_decode(record), do: decode(record)

  @doc "Serialize an interaction into its explicit JSON-safe representation."
  @spec serialize_interaction(Interaction.t()) :: {:ok, map()} | {:error, term()}
  def serialize_interaction(%Interaction{} = interaction) do
    with {:ok, kind} <- encode_enum(interaction.kind, @kind_to_string, :kind),
         :ok <- validate_identifier(interaction.request_id, :request_id),
         :ok <- validate_string(interaction.agent_id, :agent_id),
         :ok <- validate_string(interaction.user_id, :user_id),
         :ok <- validate_string(interaction.description, :description),
         {:ok, metadata} <- canonical_json_map(interaction.metadata, @max_metadata_bytes),
         :ok <- validate_nullable_string(interaction.resource_uri, :resource_uri),
         {:ok, urgency} <- encode_enum(interaction.urgency, @urgency_to_string, :urgency),
         {:ok, expires_at} <- encode_datetime(interaction.expires_at, :expires_at),
         :ok <- validate_string(interaction.response_topic, :response_topic),
         {:ok, submitted_at} <- encode_datetime(interaction.submitted_at, :submitted_at) do
      {:ok,
       %{
         "request_id" => interaction.request_id,
         "kind" => kind,
         "agent_id" => interaction.agent_id,
         "user_id" => interaction.user_id,
         "description" => interaction.description,
         "metadata" => metadata,
         "resource_uri" => interaction.resource_uri,
         "urgency" => urgency,
         "expires_at" => expires_at,
         "response_topic" => interaction.response_topic,
         "submitted_at" => submitted_at
       }}
    end
  end

  def serialize_interaction(_), do: {:error, :invalid_interaction}

  @doc "Decode and reconstruct an interaction without unsafe atom creation."
  @spec decode_interaction(map()) :: {:ok, Interaction.t()} | {:error, term()}
  def decode_interaction(map) when is_map(map) do
    with :ok <- exact_keys(map, @interaction_keys, :interaction),
         :ok <- validate_identifier(map["request_id"], :request_id),
         {:ok, kind} <- decode_enum(map["kind"], @kind_to_string, :kind),
         :ok <- validate_string(map["agent_id"], :agent_id),
         :ok <- validate_string(map["user_id"], :user_id),
         :ok <- validate_string(map["description"], :description),
         {:ok, metadata} <- strict_json_map(map["metadata"], @max_metadata_bytes),
         :ok <- validate_nullable_string(map["resource_uri"], :resource_uri),
         {:ok, urgency} <- decode_enum(map["urgency"], @urgency_to_string, :urgency),
         {:ok, expires_at} <- decode_datetime(map["expires_at"], :expires_at),
         :ok <- validate_string(map["response_topic"], :response_topic),
         {:ok, submitted_at} <- decode_datetime(map["submitted_at"], :submitted_at),
         {:ok, interaction} <-
           Interaction.new(%{
             request_id: map["request_id"],
             kind: kind,
             agent_id: map["agent_id"],
             user_id: map["user_id"],
             description: map["description"],
             metadata: metadata,
             resource_uri: map["resource_uri"],
             urgency: urgency,
             expires_at: expires_at,
             response_topic: map["response_topic"],
             submitted_at: submitted_at
           }) do
      {:ok, interaction}
    end
  end

  def decode_interaction(_), do: {:error, :invalid_interaction}

  @doc "Project the serialized interaction in a durable record."
  def project_interaction(record) do
    with {:ok, record} <- decode(record), do: decode_interaction(record["interaction"])
  end

  def to_interaction(record), do: project_interaction(record)

  @doc "Arm an absolute owner deadline; a later arm can never extend an earlier one."
  @spec arm_deadline(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def arm_deadline(record, deadline_unix_ms, now_ms) do
    with {:ok, record} <- decode(record),
         :ok <- validate_time(deadline_unix_ms),
         :ok <- validate_time(now_ms),
         :ok <- now_not_before_record(record, now_ms) do
      if record["status"] != "pending" do
        {:ok, record}
      else
        deadline = earliest(record["owner_deadline_unix_ms"], deadline_unix_ms)
        {:ok, %{record | "owner_deadline_unix_ms" => deadline, "updated_at_unix_ms" => now_ms}}
      end
    end
  end

  def arm_owner_deadline(record, deadline_unix_ms, now_ms),
    do: arm_deadline(record, deadline_unix_ms, now_ms)

  @doc "Claim a new epoch for a pending record on its existing authority node."
  @spec claim_epoch(map(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def claim_epoch(record, authority_node, authority_epoch, now_ms) do
    with {:ok, record} <- decode(record),
         :ok <- validate_identifier(authority_node, :authority_node),
         :ok <- validate_identifier(authority_epoch, :authority_epoch),
         :ok <- validate_time(now_ms),
         :ok <- now_not_before_record(record, now_ms),
         :ok <- same_authority_node(record, authority_node) do
      cond do
        record["status"] != "pending" ->
          {:error, :not_pending}

        record["authority_epoch"] == authority_epoch ->
          {:ok, record}

        true ->
          {:ok, %{record | "authority_epoch" => authority_epoch, "updated_at_unix_ms" => now_ms}}
      end
    end
  end

  @doc "Claim an epoch with an expected current epoch, rejecting stale claims."
  @spec claim_epoch(map(), String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def claim_epoch(record, authority_node, expected_epoch, new_epoch, now_ms) do
    with {:ok, record} <- decode(record),
         :ok <- validate_identifier(authority_node, :authority_node),
         :ok <- validate_identifier(expected_epoch, :authority_epoch),
         :ok <- validate_identifier(new_epoch, :authority_epoch),
         :ok <- validate_time(now_ms),
         :ok <- now_not_before_record(record, now_ms),
         :ok <- same_authority_node(record, authority_node),
         :ok <- expected_epoch(record, expected_epoch) do
      claim_epoch(record, authority_node, new_epoch, now_ms)
    end
  end

  def claim_authority_epoch(record, authority_node, authority_epoch, now_ms),
    do: claim_epoch(record, authority_node, authority_epoch, now_ms)

  @doc "Return whether the owner deadline is due at the injected wall-clock time."
  def deadline_due?(record, now_ms) do
    case decode(record) do
      {:ok, %{"status" => "pending", "owner_deadline_unix_ms" => deadline}} ->
        is_integer(now_ms) and is_integer(deadline) and deadline <= now_ms

      _ ->
        false
    end
  end

  @doc "Return whether the interaction expiry is due at the injected wall-clock time."
  def expiry_due?(record, now_ms) do
    case decode(record) do
      {:ok, %{"status" => "pending", "interaction" => interaction}} when is_integer(now_ms) ->
        case decode_datetime(interaction["expires_at"], :expires_at) do
          {:ok, nil} -> false
          {:ok, expires_at} -> DateTime.to_unix(expires_at, :millisecond) <= now_ms
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "Choose the terminal cause that is due; expiry wins when both clocks elapsed."
  def due_decision(record, now_ms) do
    cond do
      expiry_due?(record, now_ms) -> {:due, :expired}
      deadline_due?(record, now_ms) -> {:due, :abandoned}
      true -> :not_due
    end
  end

  def due?(record, now_ms), do: due_decision(record, now_ms) != :not_due

  @doc "Transition pending to a terminal public authority map, bound to exact node and epoch."
  @spec transition(map(), map(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def transition(record, terminal, authority_node, authority_epoch, now_ms) do
    with {:ok, record} <- decode(record),
         :ok <- validate_identifier(authority_node, :authority_node),
         :ok <- validate_identifier(authority_epoch, :authority_epoch),
         :ok <- validate_time(now_ms),
         :ok <- now_not_before_record(record, now_ms),
         :ok <- same_authority_node(record, authority_node),
         :ok <- expected_epoch(record, authority_epoch),
         {:ok, terminal} <- normalize_terminal(terminal, authority_node, now_ms) do
      case record["status"] do
        "pending" ->
          {:ok,
           %{
             record
             | "status" => terminal["status"],
               "terminal" => terminal,
               "updated_at_unix_ms" => now_ms
           }}

        status ->
          if record["terminal"] == terminal do
            {:ok, record}
          else
            {:error, {:terminal_conflict, status}}
          end
      end
    end
  end

  def transition_terminal(record, terminal, authority_node, authority_epoch, now_ms),
    do: transition(record, terminal, authority_node, authority_epoch, now_ms)

  @doc "Build and apply a response terminal transition."
  def respond(record, response, metadata, authority_node, authority_epoch, now_ms) do
    decision = approval_decision(response)

    transition(
      record,
      %{
        status: :responded,
        decision: decision,
        response: response,
        metadata: metadata,
        reason: nil
      },
      authority_node,
      authority_epoch,
      now_ms
    )
  end

  @doc "Build and apply an abandonment terminal transition."
  def abandon(record, reason, authority_node, authority_epoch, now_ms) do
    transition(
      record,
      %{status: :abandoned, decision: nil, response: nil, metadata: %{}, reason: reason},
      authority_node,
      authority_epoch,
      now_ms
    )
  end

  @doc """
  Project the durable terminal map back to the current atom-key authority shape.

  The returned `authority_node` is intentionally still a string; converting
  persisted node names to atoms would make the projection an atom-creation
  boundary and would not match the durable contract.
  """
  def project_terminal(record) do
    with {:ok, record} <- decode(record),
         terminal when is_map(terminal) <- record["terminal"] do
      decode_terminal_public(terminal)
    else
      nil -> {:error, :no_terminal}
      error -> error
    end
  end

  def terminal(record), do: project_terminal(record)

  @doc "Serialize a supported interaction response explicitly and reversibly."
  def serialize_response(response), do: encode_response(response)

  @doc "Decode a supported serialized response without atomizing input."
  def deserialize_response(response), do: decode_response(response)

  defp normalize_terminal(terminal, authority_node, now_ms) when is_map(terminal) do
    if durable_terminal_map?(terminal) do
      normalize_serialized_terminal(terminal, authority_node)
    else
      normalize_public_terminal(terminal, authority_node, now_ms)
    end
  end

  defp normalize_terminal(_, _authority_node, _now_ms), do: {:error, :invalid_terminal}

  defp normalize_serialized_terminal(terminal, authority_node) do
    with {:ok, terminal} <- decode_terminal(terminal),
         :ok <- terminal_authority_matches(terminal, authority_node) do
      {:ok, terminal}
    end
  end

  defp normalize_public_terminal(terminal, authority_node, now_ms) do
    with :ok <- terminal_input_keys(terminal),
         {:ok, status} <- normalize_status(value(terminal, "status")),
         true <- status in @terminal_statuses,
         {:ok, decision} <- encode_decision(value(terminal, "decision")),
         {:ok, response} <- encode_response(value(terminal, "response")),
         {:ok, metadata} <- canonical_json_map(value(terminal, "metadata"), @max_metadata_bytes),
         {:ok, reason} <- encode_reason(value(terminal, "reason")),
         :ok <- validate_identifier(authority_node, :authority_node),
         :ok <- terminal_authority_matches(terminal, authority_node),
         {:ok, resolved_at} <- terminal_time(value(terminal, "resolved_at"), now_ms),
         :ok <- validate_terminal_shape(status, decision, response, reason) do
      {:ok,
       %{
         "status" => status,
         "decision" => decision,
         "response" => response,
         "metadata" => metadata,
         "reason" => reason,
         "resolved_at" => resolved_at,
         "authority_node" => authority_node
       }}
    else
      false -> {:error, :invalid_terminal_status}
      error -> error
    end
  end

  defp decode_terminal(nil), do: {:ok, nil}

  defp decode_terminal(terminal) when is_map(terminal) do
    with :ok <- exact_keys(terminal, @terminal_keys, :terminal),
         :ok <- validate_enum(terminal["status"], @terminal_statuses, :terminal_status),
         :ok <- validate_nullable_decision(terminal["decision"]),
         {:ok, response} <- decode_response(terminal["response"]),
         {:ok, _metadata} <- strict_json_map(terminal["metadata"], @max_metadata_bytes),
         :ok <- validate_nullable_reason(terminal["reason"]),
         :ok <- validate_time(terminal["resolved_at"]),
         :ok <- validate_identifier(terminal["authority_node"], :authority_node),
         :ok <-
           validate_terminal_shape(
             terminal["status"],
             terminal["decision"],
             response,
             terminal["reason"]
           ) do
      {:ok, terminal}
    end
  end

  defp decode_terminal(_), do: {:error, :invalid_terminal}

  defp decode_terminal_public(terminal) do
    with {:ok, status} <- decode_status(terminal["status"]),
         {:ok, decision} <- decode_decision(terminal["decision"]),
         {:ok, response} <- decode_response(terminal["response"]),
         {:ok, reason} <- decode_reason(terminal["reason"]) do
      {:ok,
       %{
         status: status,
         decision: decision,
         response: response,
         metadata: terminal["metadata"],
         reason: reason,
         resolved_at: terminal["resolved_at"],
         authority_node: terminal["authority_node"]
       }}
    end
  end

  defp encode_response(nil), do: {:ok, nil}

  defp encode_response(response) when response in [:approved, :rejected, :acknowledged] do
    {:ok, %{"kind" => Atom.to_string(response)}}
  end

  defp encode_response({:text, text}) do
    with :ok <- validate_string(text, :response_text) do
      bounded_json(%{"kind" => "text", "text" => text}, @max_response_bytes)
    end
  end

  defp encode_response({:choice, value}) do
    with {:ok, value} <- canonical_json(value, 0),
         {:ok, encoded} <-
           bounded_json(%{"kind" => "choice", "value" => value}, @max_response_bytes) do
      {:ok, encoded}
    end
  end

  defp encode_response(_), do: {:error, :non_json_response}

  defp decode_response(nil), do: {:ok, nil}

  defp decode_response(response) when is_map(response) do
    case response["kind"] do
      "approved" ->
        exact_response_keys(response, ["kind"], :approved) |> then_ok(:approved)

      "rejected" ->
        exact_response_keys(response, ["kind"], :rejected) |> then_ok(:rejected)

      "acknowledged" ->
        exact_response_keys(response, ["kind"], :acknowledged) |> then_ok(:acknowledged)

      "text" ->
        decode_text_response(response)

      "choice" ->
        decode_choice_response(response)

      _ ->
        {:error, :invalid_response}
    end
  end

  defp decode_response(_), do: {:error, :invalid_response}

  defp decode_text_response(response) do
    with :ok <- exact_response_keys(response, ["kind", "text"], :text),
         :ok <- validate_string(response["text"], :response_text) do
      {:ok, {:text, response["text"]}}
    end
  end

  defp decode_choice_response(response) do
    with :ok <- exact_response_keys(response, ["kind", "value"], :choice),
         {:ok, value} <- strict_json(response["value"], @max_response_bytes) do
      {:ok, {:choice, value}}
    end
  end

  defp then_ok(:ok, value), do: {:ok, value}
  defp then_ok(error, _value), do: error

  defp encode_decision(nil), do: {:ok, nil}

  defp encode_decision(value) when value in [:approved, :rejected],
    do: {:ok, Atom.to_string(value)}

  defp encode_decision(value) when value in ["approved", "rejected"], do: {:ok, value}
  defp encode_decision(_), do: {:error, :invalid_decision}

  defp decode_decision(nil), do: {:ok, nil}
  defp decode_decision("approved"), do: {:ok, :approved}
  defp decode_decision("rejected"), do: {:ok, :rejected}
  defp decode_decision(_), do: {:error, :invalid_decision}

  defp validate_nullable_decision(nil), do: :ok

  defp validate_nullable_decision(value),
    do: validate_enum(value, ["approved", "rejected"], :decision)

  defp encode_reason(nil), do: {:ok, nil}
  defp encode_reason(value) when is_atom(value), do: encode_reason(Atom.to_string(value))

  defp encode_reason(value) when is_binary(value) do
    validate_string(value, :reason, @max_reason_bytes)
    |> then_ok(value)
  end

  defp encode_reason(_), do: {:error, :invalid_reason}

  defp decode_reason(nil), do: {:ok, nil}
  defp decode_reason("owner_timeout"), do: {:ok, :owner_timeout}
  defp decode_reason("await_timeout"), do: {:ok, :await_timeout}
  defp decode_reason("expires_at_elapsed"), do: {:ok, :expires_at_elapsed}
  defp decode_reason(value) when is_binary(value), do: {:ok, value}
  defp decode_reason(_), do: {:error, :invalid_reason}

  defp approval_decision(:approved), do: :approved
  defp approval_decision(:rejected), do: :rejected
  defp approval_decision(_), do: nil

  defp normalize_status(value) when value in [:responded, :abandoned, :expired],
    do: {:ok, Atom.to_string(value)}

  defp normalize_status(value) when is_binary(value), do: {:ok, value}
  defp normalize_status(_), do: {:error, :invalid_status}

  defp decode_status("responded"), do: {:ok, :responded}
  defp decode_status("abandoned"), do: {:ok, :abandoned}
  defp decode_status("expired"), do: {:ok, :expired}
  defp decode_status(_), do: {:error, :invalid_status}

  defp encode_enum(value, mapping, field) when is_atom(value) do
    case Map.fetch(mapping, value) do
      {:ok, encoded} -> {:ok, encoded}
      :error -> {:error, {:invalid, field}}
    end
  end

  defp encode_enum(_value, _mapping, field), do: {:error, {:invalid, field}}

  defp decode_enum(value, mapping, field) when is_binary(value) do
    case Enum.find(mapping, fn {_atom, string} -> string == value end) do
      {atom, _string} -> {:ok, atom}
      nil -> {:error, {:invalid, field}}
    end
  end

  defp decode_enum(_value, _mapping, field), do: {:error, {:invalid, field}}

  defp encode_datetime(nil, _field), do: {:ok, nil}

  defp encode_datetime(%DateTime{} = datetime, _field) do
    try do
      {:ok, DateTime.to_iso8601(datetime)}
    rescue
      _ -> {:error, :invalid_datetime}
    end
  end

  defp encode_datetime(_, field), do: {:error, {:invalid, field}}

  defp decode_datetime(nil, _field), do: {:ok, nil}

  defp decode_datetime(value, _field) when is_binary(value) do
    with :ok <- validate_string(value, :datetime),
         {:ok, datetime, 0} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      {:ok, _datetime, _offset} -> {:error, :datetime_must_be_utc}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp decode_datetime(_, field), do: {:error, {:invalid, field}}

  defp terminal_time(nil, now_ms), do: {:ok, now_ms}
  defp terminal_time(value, _now_ms) when is_integer(value) and value >= 0, do: {:ok, value}
  defp terminal_time(_, _), do: {:error, :invalid_resolved_at}

  defp canonical_json_map(value, max_bytes) when is_map(value) do
    with {:ok, canonical} <- canonical_json(value, 0),
         {:ok, canonical} <- bounded_json(canonical, max_bytes) do
      {:ok, canonical}
    end
  end

  defp canonical_json_map(_, _), do: {:error, :metadata_must_be_map}

  defp strict_json_map(value, max_bytes) when is_map(value),
    do: strict_json(value, max_bytes)

  defp strict_json_map(_, _), do: {:error, :metadata_must_be_map}

  defp strict_json(value, max_bytes) do
    with true <- string_keys_only?(value),
         {:ok, canonical} <- canonical_json(value, 0),
         {:ok, canonical} <- bounded_json(canonical, max_bytes) do
      {:ok, canonical}
    else
      false -> {:error, :non_string_json_key}
      error -> error
    end
  end

  defp string_keys_only?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, nested} -> is_binary(key) and string_keys_only?(nested) end)
  end

  defp string_keys_only?(value) when is_list(value), do: Enum.all?(value, &string_keys_only?/1)
  defp string_keys_only?(_value), do: true

  defp canonical_json(_value, depth) when depth > @max_json_depth, do: {:error, :json_too_deep}

  defp canonical_json(value, _depth) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_string_bytes,
      do: {:ok, value},
      else: {:error, :invalid_json_string}
  end

  defp canonical_json(value, _depth) when is_boolean(value) or is_nil(value), do: {:ok, value}
  defp canonical_json(value, _depth) when is_integer(value), do: {:ok, value}
  defp canonical_json(value, _depth) when is_float(value), do: {:ok, value}

  defp canonical_json(value, depth) when is_list(value) do
    if length(value) > @max_container_entries do
      {:error, :json_container_too_large}
    else
      Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
        case canonical_json(item, depth + 1) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          error -> {:halt, error}
        end
      end)
      |> reverse_json_list()
    end
  end

  defp canonical_json(value, depth) when is_map(value) do
    cond do
      is_struct(value) -> {:error, :non_json_value}
      map_size(value) > @max_container_entries -> {:error, :json_container_too_large}
      true -> canonical_json_map_entries(Map.to_list(value), depth, %{})
    end
  end

  defp canonical_json(_, _depth), do: {:error, :non_json_value}

  defp canonical_json_map_entries([], _depth, acc), do: {:ok, acc}

  defp canonical_json_map_entries([{key, value} | rest], depth, acc) do
    with {:ok, key} <- json_key(key),
         false <- Map.has_key?(acc, key),
         {:ok, value} <- canonical_json(value, depth + 1) do
      canonical_json_map_entries(rest, depth, Map.put(acc, key, value))
    else
      true -> {:error, :duplicate_json_key}
      error -> error
    end
  end

  defp json_key(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) <= @max_string_bytes,
      do: {:ok, key},
      else: {:error, :invalid_json_key}
  end

  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp json_key(_), do: {:error, :invalid_json_key}

  defp bounded_json(value, max_bytes) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> {:ok, value}
      {:ok, _encoded} -> {:error, :json_value_too_large}
      {:error, _reason} -> {:error, :non_json_value}
    end
  end

  defp reverse_json_list({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reverse_json_list(error), do: error

  defp exact_keys(map, expected, field) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:unknown_fields, field}}
  end

  defp terminal_input_keys(map) do
    required = ["status", "decision", "response", "metadata", "reason"]

    normalized_keys = Enum.map(Map.keys(map), &normalize_terminal_key/1)

    if length(normalized_keys) == length(Enum.uniq(normalized_keys)) and
         length(normalized_keys) == length(required) and
         Enum.all?(normalized_keys, &(&1 in required)) and
         Enum.all?(required, &(&1 in normalized_keys)) do
      :ok
    else
      {:error, {:unknown_fields, :terminal}}
    end
  end

  defp durable_terminal_map?(map) do
    Enum.all?(Map.keys(map), &is_binary/1) and
      Enum.sort(Map.keys(map)) == Enum.sort(@terminal_keys)
  end

  defp normalize_terminal_key(key) when is_binary(key), do: key
  defp normalize_terminal_key(:status), do: "status"
  defp normalize_terminal_key(:decision), do: "decision"
  defp normalize_terminal_key(:response), do: "response"
  defp normalize_terminal_key(:metadata), do: "metadata"
  defp normalize_terminal_key(:reason), do: "reason"
  defp normalize_terminal_key(:resolved_at), do: "resolved_at"
  defp normalize_terminal_key(:authority_node), do: "authority_node"
  defp normalize_terminal_key(_), do: nil

  defp terminal_authority_matches(map, authority_node) do
    case value(map, "authority_node") do
      nil -> :ok
      ^authority_node -> :ok
      _ -> {:error, :wrong_authority_node}
    end
  end

  defp exact_response_keys(map, expected, field), do: exact_keys(map, expected, field)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, terminal_atom_key(key))
    end
  end

  defp terminal_atom_key("status"), do: :status
  defp terminal_atom_key("decision"), do: :decision
  defp terminal_atom_key("response"), do: :response
  defp terminal_atom_key("metadata"), do: :metadata
  defp terminal_atom_key("reason"), do: :reason
  defp terminal_atom_key("resolved_at"), do: :resolved_at
  defp terminal_atom_key("authority_node"), do: :authority_node
  defp terminal_atom_key(_), do: nil

  defp validate_schema_version(@schema_version), do: :ok
  defp validate_schema_version(_), do: {:error, :unsupported_schema_version}

  defp validate_enum(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, {:invalid, field}}
  end

  defp validate_identifier(value, _field)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_identifier_bytes,
       do: if(String.valid?(value), do: :ok, else: {:error, :invalid_utf8})

  defp validate_identifier(_value, field), do: {:error, {:invalid, field}}

  defp validate_string(value, field, max_bytes \\ @max_string_bytes)

  defp validate_string(value, _field, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8}
  end

  defp validate_string(_value, field, _max_bytes), do: {:error, {:invalid, field}}

  defp validate_nullable_string(nil, _field), do: :ok
  defp validate_nullable_string(value, field), do: validate_string(value, field)

  defp validate_time(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_time(_), do: {:error, :invalid_time}

  defp now_not_before_record(%{"updated_at_unix_ms" => updated_at}, now_ms)
       when is_integer(now_ms) and now_ms >= updated_at,
       do: :ok

  defp now_not_before_record(_record, _now_ms), do: {:error, :time_before_update}

  defp validate_nullable_time(nil), do: :ok
  defp validate_nullable_time(value), do: validate_time(value)

  defp validate_nullable_reason(nil), do: :ok
  defp validate_nullable_reason(value), do: validate_string(value, :reason, @max_reason_bytes)

  defp same_request_id(request_id, request_id), do: :ok
  defp same_request_id(_, _), do: {:error, :request_id_mismatch}

  defp same_authority_node(%{"authority_node" => node}, node), do: :ok
  defp same_authority_node(_, _), do: {:error, :wrong_authority_node}

  defp expected_epoch(%{"authority_epoch" => epoch}, epoch), do: :ok
  defp expected_epoch(_, _), do: {:error, :stale_authority_epoch}

  defp terminal_status_consistent("pending", nil), do: :ok

  defp terminal_status_consistent(status, %{"status" => status})
       when status in @terminal_statuses,
       do: :ok

  defp terminal_status_consistent(_, _), do: {:error, :invalid_terminal_state}

  defp terminal_authority_consistent(_record, nil), do: :ok

  defp terminal_authority_consistent(
         %{"authority_node" => authority_node},
         %{"authority_node" => authority_node}
       ),
       do: :ok

  defp terminal_authority_consistent(_record, _terminal),
    do: {:error, :terminal_authority_mismatch}

  defp timestamp_ordering(
         %{
           "admitted_at_unix_ms" => admitted_at,
           "updated_at_unix_ms" => updated_at
         },
         nil
       )
       when updated_at >= admitted_at,
       do: :ok

  defp timestamp_ordering(
         %{"admitted_at_unix_ms" => admitted_at, "updated_at_unix_ms" => updated_at},
         %{"resolved_at" => resolved_at}
       )
       when resolved_at >= admitted_at and updated_at >= resolved_at,
       do: :ok

  defp timestamp_ordering(_record, _terminal), do: {:error, :invalid_timestamp_order}

  defp validate_terminal_shape("responded", decision, response, nil)
       when decision in [nil, "approved", "rejected"] and not is_nil(response),
       do: :ok

  defp validate_terminal_shape(status, nil, nil, reason)
       when status in ["abandoned", "expired"] and is_binary(reason) and byte_size(reason) > 0,
       do: :ok

  defp validate_terminal_shape(_status, _decision, _response, _reason),
    do: {:error, :invalid_terminal_shape}

  defp bounded_record?(record) do
    case Jason.encode(record) do
      {:ok, encoded} when byte_size(encoded) <= 128_000 -> :ok
      {:ok, _} -> {:error, :record_too_large}
      {:error, _} -> {:error, :record_not_json}
    end
  end

  defp earliest(nil, deadline), do: deadline
  defp earliest(existing, deadline), do: min(existing, deadline)
end
