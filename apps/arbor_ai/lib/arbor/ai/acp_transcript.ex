defmodule Arbor.AI.AcpTranscript do
  @moduledoc """
  Pure, bounded normalization for source-captured ACP prompt turns.

  The reducer has no clock or filesystem access. Callers inject `captured_at`
  and persist the returned closed, string-keyed JSON value through a trusted
  boundary. Free-form values retain their original byte count and SHA-256 even
  when their valid UTF-8 projection is truncated.
  """

  alias Arbor.Contracts.Coding.TranscriptDescriptor

  @schema_version 1

  @max_prompt_bytes 64_000
  @max_response_bytes 64_000
  @max_error_bytes 4_096
  @max_stream_events 64
  @max_stream_events_seen 1_000_000
  @max_capture_index 511
  @max_original_bytes 1_000_000_000
  @max_event_bytes 2_048
  @max_execution_id_bytes 512
  @max_control_id_bytes 256
  @max_provider_bytes 64
  @max_session_id_bytes 200
  @max_stop_reason_bytes 128
  @max_timestamp_bytes 64
  @max_tool_name_bytes 128
  @max_tool_call_id_bytes 128

  @prompt_kinds MapSet.new(["initial", "task_control"])

  @terminal_statuses MapSet.new([
                       "success",
                       "provider_error",
                       "timeout",
                       "inactivity_timeout",
                       "stream_callback_failure",
                       "stream_callback_timeout",
                       "prompt_exit",
                       "client_down",
                       "cancelled"
                     ])

  @event_kinds MapSet.new([
                 "agent_message_chunk",
                 "agent_thought_chunk",
                 "tool_call",
                 "tool_call_update",
                 "plan",
                 "text",
                 "unknown"
               ])

  @lowercase_sha256 ~r/\A[0-9a-f]{64}\z/

  @type json_map :: %{required(String.t()) => term()}

  @doc "Closed transcript and descriptor schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Reducer bounds exposed for focused tests and operator diagnostics."
  @spec bounds() :: map()
  def bounds do
    %{
      max_prompt_bytes: @max_prompt_bytes,
      max_response_bytes: @max_response_bytes,
      max_error_bytes: @max_error_bytes,
      max_stream_events: @max_stream_events,
      max_stream_events_seen: @max_stream_events_seen,
      max_capture_index: @max_capture_index,
      max_original_bytes: @max_original_bytes,
      max_event_bytes: @max_event_bytes
    }
  end

  @doc "Return an empty source-sequenced stream-tail accumulator."
  @spec empty_stream_tail() :: json_map()
  def empty_stream_tail do
    %{
      "events" => [],
      "events_retained" => 0,
      "events_seen" => 0,
      "events_omitted" => 0,
      "events_truncated" => false
    }
  end

  @doc "Append one provider update while retaining only the latest event window."
  @spec append_stream_event(term(), term()) :: json_map()
  def append_stream_event(tail, update) do
    base = normalize_stream_tail(tail)
    source_seq = base["events_seen"]

    if source_seq < @max_stream_events_seen do
      event = normalize_stream_event(update, source_seq)
      seen = source_seq + 1

      events =
        (base["events"] ++ [event])
        |> Enum.take(-@max_stream_events)

      retained = length(events)
      omitted = max(seen - retained, 0)

      %{
        "events" => events,
        "events_retained" => retained,
        "events_seen" => seen,
        "events_omitted" => omitted,
        "events_truncated" => omitted > 0
      }
    else
      base
    end
  end

  @doc "Normalize one hostile or provider-specific update into a closed event."
  @spec normalize_stream_event(term(), non_neg_integer()) :: json_map()
  def normalize_stream_event(update, source_seq)
      when is_integer(source_seq) and source_seq >= 0 and
             source_seq < @max_stream_events_seen do
    %{
      "source_seq" => source_seq,
      "kind" => event_kind(update),
      "content" => bound_text_field(event_text(update), @max_event_bytes),
      "tool_name" => bound_text_field(event_tool_name(update), @max_tool_name_bytes),
      "tool_call_id" => bound_text_field(event_tool_call_id(update), @max_tool_call_id_bytes)
    }
  end

  def normalize_stream_event(update, _source_seq), do: normalize_stream_event(update, 0)

  @doc "Build a deterministic, closed turn envelope for one actual provider prompt."
  @spec build_turn(keyword() | map()) :: {:ok, json_map()} | {:error, term()}
  def build_turn(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, execution_id} <-
           required_bounded_string(attrs, :execution_id, @max_execution_id_bytes),
         {:ok, capture_index} <- capture_index(attrs),
         {:ok, prompt_kind} <- prompt_kind(attrs),
         {:ok, control_id} <- control_id(attrs, prompt_kind),
         {:ok, terminal_status} <- terminal_status(attrs),
         {:ok, captured_at} <- required_bounded_string(attrs, :captured_at, @max_timestamp_bytes) do
      turn = %{
        "schema_version" => @schema_version,
        "turn_id" => turn_id(execution_id, capture_index),
        "execution" => %{
          "execution_id" => bound_text_field(execution_id, @max_execution_id_bytes),
          "capture_index" => capture_index
        },
        "prompt" => %{
          "kind" => prompt_kind,
          "control_id" => bound_text_field(control_id, @max_control_id_bytes),
          "content" => bound_text_field(attr(attrs, :prompt, ""), @max_prompt_bytes)
        },
        "terminal" => %{
          "status" => terminal_status,
          "response" => bound_text_field(attr(attrs, :response_text, ""), @max_response_bytes),
          "error" => bound_text_field(attr(attrs, :error, ""), @max_error_bytes),
          "stop_reason" => bound_text_field(attr(attrs, :stop_reason, ""), @max_stop_reason_bytes)
        },
        "continuity" => %{
          "provider" => bound_text_field(attr(attrs, :provider, ""), @max_provider_bytes),
          "provider_session_id" =>
            bound_text_field(
              attr(attrs, :provider_session_id, attr(attrs, :session_id, "")),
              @max_session_id_bytes
            )
        },
        "stream_tail" => normalize_stream_tail(attr(attrs, :stream_tail, nil)),
        "captured_at" => bound_text_field(captured_at, @max_timestamp_bytes)
      }

      if json_clean?(turn), do: {:ok, turn}, else: {:error, :turn_not_json_clean}
    end
  end

  def build_turn(_attrs), do: {:error, :invalid_turn_attrs}

  @doc "Deterministic identity for one prompt within an Engine-owned action execution."
  @spec turn_id(String.t(), non_neg_integer()) :: String.t()
  def turn_id(execution_id, capture_index)
      when is_binary(execution_id) and is_integer(capture_index) and capture_index >= 0 do
    digest = sha256_hex(execution_id <> ":" <> Integer.to_string(capture_index))
    "acp_turn_" <> digest
  end

  @doc "Validate the exact descriptor shape accepted at the AI/action boundary."
  @spec valid_descriptor?(term()) :: boolean()
  def valid_descriptor?(descriptor), do: TranscriptDescriptor.valid?(descriptor)

  @doc "Project a free-form scalar into valid UTF-8 with size and digest facts."
  @spec bound_text_field(term(), pos_integer()) :: json_map()
  def bound_text_field(value, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    raw = scalar_binary(value)
    valid = String.replace_invalid(raw, "\uFFFD")
    text = truncate_valid_utf8(valid, max_bytes)

    %{
      "text" => text,
      "original_bytes" => byte_size(raw),
      "truncated" => raw != valid or byte_size(text) < byte_size(valid),
      "sha256" => sha256_hex(raw)
    }
  end

  def bound_text_field(_value, _max_bytes), do: bound_text_field("", @max_event_bytes)

  # -- stream normalization -------------------------------------------------

  defp normalize_stream_tail(tail) when is_map(tail) and not is_struct(tail) do
    raw_events = map_value(tail, "events", :events)

    events =
      case raw_events do
        list when is_list(list) ->
          list
          |> Enum.take(-@max_stream_events)
          |> normalize_retained_events()

        _ ->
          []
      end

    minimum_seen =
      case List.last(events) do
        %{"source_seq" => seq} -> seq + 1
        _ -> length(events)
      end

    seen =
      case map_value(tail, "events_seen", :events_seen) do
        value
        when is_integer(value) and value >= minimum_seen and
               value <= @max_stream_events_seen ->
          value

        _ ->
          minimum_seen
      end

    retained = length(events)
    omitted = max(seen - retained, 0)

    %{
      "events" => events,
      "events_retained" => retained,
      "events_seen" => seen,
      "events_omitted" => omitted,
      "events_truncated" => omitted > 0
    }
  end

  defp normalize_stream_tail(_tail), do: empty_stream_tail()

  defp normalize_retained_events(events) do
    {normalized, _next_seq} =
      Enum.map_reduce(events, 0, fn event, next_seq ->
        seq = retained_source_seq(event, next_seq)
        {normalize_retained_event(event, seq), seq + 1}
      end)

    normalized
  end

  defp retained_source_seq(event, next_seq) when is_map(event) and not is_struct(event) do
    case map_value(event, "source_seq", :source_seq) do
      seq
      when is_integer(seq) and seq >= next_seq and seq < @max_stream_events_seen ->
        seq

      _ ->
        next_seq
    end
  end

  defp retained_source_seq(_event, next_seq), do: next_seq

  defp normalize_retained_event(event, source_seq)
       when is_map(event) and not is_struct(event) do
    kind = map_value(event, "kind", :kind) |> normalize_event_kind()

    %{
      "source_seq" => source_seq,
      "kind" => kind,
      "content" => normalize_bound_field(map_value(event, "content", :content), @max_event_bytes),
      "tool_name" =>
        normalize_bound_field(map_value(event, "tool_name", :tool_name), @max_tool_name_bytes),
      "tool_call_id" =>
        normalize_bound_field(
          map_value(event, "tool_call_id", :tool_call_id),
          @max_tool_call_id_bytes
        )
    }
  end

  defp normalize_retained_event(_event, source_seq),
    do: normalize_stream_event(%{}, source_seq)

  defp normalize_bound_field(field, max_bytes)
       when is_map(field) and not is_struct(field) do
    text = map_value(field, "text", :text)
    projected = bound_text_field(text, max_bytes)
    projected_bytes = byte_size(projected["text"])
    claimed_original = map_value(field, "original_bytes", :original_bytes)
    claimed_truncated = map_value(field, "truncated", :truncated)
    claimed_digest = map_value(field, "sha256", :sha256)

    bounded_original? =
      is_integer(claimed_original) and claimed_original >= 0 and
        claimed_original <= @max_original_bytes

    preserve_claim? =
      bounded_original? and lowercase_sha256?(claimed_digest) and
        (claimed_truncated == true or
           (claimed_truncated == false and claimed_original == projected_bytes and
              claimed_digest == projected["sha256"]))

    {original_bytes, truncated, digest} =
      if preserve_claim? do
        {claimed_original, claimed_truncated, claimed_digest}
      else
        {projected["original_bytes"], projected["truncated"], projected["sha256"]}
      end

    %{
      "text" => projected["text"],
      "original_bytes" => original_bytes,
      "truncated" => truncated,
      "sha256" => digest
    }
  end

  defp normalize_bound_field(value, max_bytes), do: bound_text_field(value, max_bytes)

  # -- turn input -----------------------------------------------------------

  defp required_bounded_string(attrs, key, max_bytes) do
    value = attr(attrs, key, nil)

    if bounded_nonblank_string?(value, max_bytes),
      do: {:ok, value},
      else: {:error, {:invalid_turn_field, key}}
  end

  defp capture_index(attrs) do
    case attr(attrs, :capture_index, nil) do
      value when is_integer(value) and value >= 0 and value <= @max_capture_index -> {:ok, value}
      _ -> {:error, {:invalid_turn_field, :capture_index}}
    end
  end

  defp prompt_kind(attrs) do
    value = attr(attrs, :prompt_kind, nil) |> scalar_binary()

    if MapSet.member?(@prompt_kinds, value),
      do: {:ok, value},
      else: {:error, {:invalid_turn_field, :prompt_kind}}
  end

  defp control_id(attrs, "initial") do
    case attr(attrs, :control_id, nil) do
      nil -> {:ok, ""}
      "" -> {:ok, ""}
      _ -> {:error, {:invalid_turn_field, :control_id}}
    end
  end

  defp control_id(attrs, "task_control") do
    required_bounded_string(attrs, :control_id, @max_control_id_bytes)
  end

  defp terminal_status(attrs) do
    value = attr(attrs, :terminal_status, nil) |> scalar_binary()

    if MapSet.member?(@terminal_statuses, value),
      do: {:ok, value},
      else: {:error, {:invalid_turn_field, :terminal_status}}
  end

  defp normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: Map.new(attrs), else: %{}
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: attrs

  defp attr(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end

  # -- provider event projection -------------------------------------------

  defp event_kind(update) when is_map(update) and not is_struct(update) do
    update
    |> map_value(["sessionUpdate", :sessionUpdate, "kind", :kind])
    |> normalize_event_kind()
  end

  defp event_kind(_update), do: "unknown"

  defp normalize_event_kind(value) do
    value = scalar_binary(value)
    if MapSet.member?(@event_kinds, value), do: value, else: "unknown"
  end

  defp event_text(update) when is_map(update) and not is_struct(update) do
    content = map_value(update, "content", :content)

    cond do
      is_binary(content) -> content
      is_map(content) -> map_value(content, "text", :text)
      true -> map_value(update, ["text", :text, "title", :title])
    end
  end

  defp event_text(_update), do: ""

  defp event_tool_name(update) when is_map(update) and not is_struct(update),
    do: map_value(update, ["toolName", :toolName, "tool_name", :tool_name, "name", :name])

  defp event_tool_name(_update), do: ""

  defp event_tool_call_id(update) when is_map(update) and not is_struct(update),
    do: map_value(update, ["toolCallId", :toolCallId, "tool_call_id", :tool_call_id, "id", :id])

  defp event_tool_call_id(_update), do: ""

  # -- scalar and JSON helpers ---------------------------------------------

  defp scalar_binary(value) when is_binary(value), do: value
  defp scalar_binary(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)

  defp scalar_binary(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp scalar_binary(_value), do: ""

  defp truncate_valid_utf8(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp truncate_valid_utf8(binary, max_bytes) do
    binary
    |> binary_part(0, max_bytes)
    |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      trim_incomplete_utf8(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  defp map_value(map, string_key, atom_key) when is_map(map),
    do: Map.get(map, string_key, Map.get(map, atom_key))

  defp map_value(_map, _string_key, _atom_key), do: nil

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp sha256_hex(binary),
    do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp lowercase_sha256?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@lowercase_sha256, value)

  defp lowercase_sha256?(_value), do: false

  defp bounded_nonblank_string?(value, max_bytes) when is_binary(value) do
    String.valid?(value) and String.trim(value) != "" and byte_size(value) <= max_bytes and
      not String.contains?(value, <<0>>) and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp bounded_nonblank_string?(_value, _max_bytes), do: false

  defp json_clean?(value) when is_binary(value), do: String.valid?(value)

  defp json_clean?(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_clean?(nested)
    end)
  end

  defp json_clean?(_value), do: false
end
