defmodule Arbor.Orchestrator.CodingPlan.TranscriptStore do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.{TaskOutcomeRegistry, TranscriptDescriptor}

  @filename "acp-transcript.json"
  @schema_version 1
  @max_turns 32
  @max_identities 512
  @max_capture_index 511
  @max_aggregate_bytes 512_000
  @max_original_bytes 1_000_000_000
  @max_stream_events_seen 1_000_000
  @max_task_id_bytes 512
  @max_prompt_bytes 64_000
  @max_response_bytes 64_000
  @max_error_bytes 4_096
  @max_event_bytes 2_048
  @max_stream_events 64
  @lowercase_sha256 ~r/\A[0-9a-f]{64}\z/
  @turn_id_pattern ~r/\Aacp_turn_[0-9a-f]{64}\z/

  @transcript_keys MapSet.new(~w(
                     schema_version
                     task_id
                     turns
                     identities
                     turns_retained
                     turns_seen
                     turns_omitted
                     turns_truncated
                     aggregate_truncated
                     sha256
                   ))
  @turn_keys MapSet.new(~w(
               schema_version
               turn_id
               execution
               prompt
               terminal
               continuity
               stream_tail
               captured_at
             ))
  @field_keys MapSet.new(~w(text original_bytes truncated sha256))
  @event_keys MapSet.new(~w(source_seq kind content tool_name tool_call_id))
  @prompt_kinds MapSet.new(["initial", "task_control"])
  @event_kinds MapSet.new([
                 "agent_message_chunk",
                 "agent_thought_chunk",
                 "tool_call",
                 "tool_call_update",
                 "plan",
                 "text",
                 "unknown"
               ])

  @type descriptor :: %{required(String.t()) => term()}

  @spec filename() :: String.t()
  def filename, do: @filename

  @spec append_turn(String.t(), String.t(), map()) ::
          {:ok, descriptor()} | {:error, term()}
  def append_turn(root, task_id, turn) do
    with {:ok, root} <- validate_root(root),
         {:ok, task_id} <- validate_task_id(task_id),
         :ok <- validate_turn(turn) do
      lock = {{__MODULE__, root}, self()}

      case :global.trans(lock, fn -> append_locked(root, task_id, turn) end, [node()]) do
        {:aborted, reason} -> {:error, {:transcript_lock_failed, reason}}
        result -> result
      end
    end
  end

  @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(root, task_id) do
    with {:ok, root} <- validate_root(root),
         {:ok, task_id} <- validate_task_id(task_id),
         {:ok, transcript, _body} <- load_existing(root, task_id) do
      {:ok, transcript}
    end
  end

  @spec descriptor(String.t(), String.t()) ::
          {:ok, descriptor()} | {:error, :absent} | {:error, term()}
  def descriptor(root, task_id) do
    with {:ok, root} <- validate_root(root),
         {:ok, task_id} <- validate_task_id(task_id),
         {:ok, transcript, body} <- load_existing(root, task_id) do
      build_descriptor(artifact_path(root), transcript, body)
    end
  end

  @spec valid_descriptor?(term()) :: boolean()
  def valid_descriptor?(descriptor), do: TranscriptDescriptor.valid?(descriptor)

  defp append_locked(root, task_id, turn) do
    case load_existing(root, task_id) do
      {:ok, transcript, body} -> append_to_existing(root, transcript, body, turn)
      {:error, :absent} -> append_to_new(root, task_id, turn)
      {:error, _reason} = error -> error
    end
  end

  defp append_to_existing(root, transcript, body, turn) do
    turn_id = turn["turn_id"]
    content_digest = turn_content_digest(turn)

    case Enum.find(transcript["identities"], &(&1["turn_id"] == turn_id)) do
      %{"content_sha256" => ^content_digest} ->
        build_descriptor(artifact_path(root), transcript, body)

      %{} ->
        {:error, {:turn_identity_conflict, turn_id}}

      nil ->
        append_unique(root, transcript, turn, content_digest)
    end
  end

  defp append_to_new(root, task_id, turn) do
    transcript = %{
      "schema_version" => @schema_version,
      "task_id" => task_id,
      "turns" => [],
      "identities" => [],
      "turns_retained" => 0,
      "turns_seen" => 0,
      "turns_omitted" => 0,
      "turns_truncated" => false,
      "aggregate_truncated" => false
    }

    append_unique(root, transcript, turn, turn_content_digest(turn))
  end

  defp append_unique(root, transcript, turn, content_digest) do
    identities = transcript["identities"]

    if length(identities) >= @max_identities do
      {:error, :transcript_identity_capacity_exceeded}
    else
      identity = %{"turn_id" => turn["turn_id"], "content_sha256" => content_digest}
      identities = identities ++ [identity]
      turns = Enum.take(transcript["turns"] ++ [turn], -@max_turns)
      seen = length(identities)

      updated =
        transcript
        |> Map.drop(["sha256"])
        |> Map.put("identities", identities)
        |> Map.put("turns", turns)
        |> put_turn_counts(seen, length(turns))

      publish_with_budget(root, updated)
    end
  end

  defp publish_with_budget(root, transcript) do
    case encode_transcript(transcript) do
      {:ok, body, with_digest} when byte_size(body) <= @max_aggregate_bytes ->
        path = artifact_path(root)

        with :ok <- atomic_write(path, body),
             {:ok, descriptor} <- build_descriptor(path, with_digest, body) do
          {:ok, descriptor}
        end

      {:ok, _body, _with_digest} ->
        compact_and_publish(root, transcript)

      {:error, _reason} = error ->
        error
    end
  end

  defp compact_and_publish(root, %{"turns" => [_oldest, _next | _rest]} = transcript) do
    turns = tl(transcript["turns"])

    compacted =
      transcript
      |> Map.put("turns", turns)
      |> Map.put("aggregate_truncated", true)
      |> put_turn_counts(transcript["turns_seen"], length(turns))

    publish_with_budget(root, compacted)
  end

  defp compact_and_publish(_root, _transcript), do: {:error, :aggregate_budget_exceeded}

  defp put_turn_counts(transcript, seen, retained) do
    omitted = seen - retained

    transcript
    |> Map.put("turns_seen", seen)
    |> Map.put("turns_retained", retained)
    |> Map.put("turns_omitted", omitted)
    |> Map.put("turns_truncated", omitted > 0)
  end

  # -- validation -----------------------------------------------------------

  defp validate_turn(turn) when is_map(turn) and not is_struct(turn) do
    with true <- MapSet.new(Map.keys(turn)) == @turn_keys or {:error, :invalid_turn_shape},
         true <- turn["schema_version"] == @schema_version or {:error, :invalid_turn_schema},
         :ok <- validate_execution(turn["execution"], turn["turn_id"]),
         :ok <- validate_prompt(turn["prompt"]),
         :ok <- validate_terminal(turn["terminal"]),
         :ok <- validate_continuity(turn["continuity"]),
         :ok <- validate_stream_tail(turn["stream_tail"]),
         :ok <- validate_field(turn["captured_at"], 64, nonblank: true),
         true <- json_clean?(turn) or {:error, :turn_not_json_clean} do
      :ok
    end
  end

  defp validate_turn(_turn), do: {:error, :invalid_turn}

  defp validate_execution(execution, turn_id)
       when is_map(execution) and not is_struct(execution) do
    with true <-
           MapSet.new(Map.keys(execution)) == MapSet.new(~w(execution_id capture_index)) or
             {:error, :invalid_execution_shape},
         :ok <- validate_field(execution["execution_id"], 512, nonblank: true),
         index when is_integer(index) and index >= 0 and index <= @max_capture_index <-
           execution["capture_index"],
         true <-
           (is_binary(turn_id) and Regex.match?(@turn_id_pattern, turn_id)) or
             {:error, :invalid_turn_id},
         expected = deterministic_turn_id(execution["execution_id"]["text"], index),
         true <- turn_id == expected or {:error, :turn_identity_mismatch} do
      :ok
    else
      false -> {:error, :invalid_capture_index}
      nil -> {:error, :invalid_capture_index}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_capture_index}
    end
  end

  defp validate_execution(_execution, _turn_id), do: {:error, :invalid_execution_shape}

  defp validate_prompt(prompt) when is_map(prompt) and not is_struct(prompt) do
    with true <-
           MapSet.new(Map.keys(prompt)) == MapSet.new(~w(kind control_id content)) or
             {:error, :invalid_prompt_shape},
         true <-
           MapSet.member?(@prompt_kinds, prompt["kind"]) or
             {:error, :invalid_prompt_kind},
         :ok <- validate_field(prompt["control_id"], 256),
         :ok <- validate_field(prompt["content"], @max_prompt_bytes),
         :ok <- validate_prompt_control(prompt["kind"], prompt["control_id"]["text"]) do
      :ok
    end
  end

  defp validate_prompt(_prompt), do: {:error, :invalid_prompt_shape}

  defp validate_prompt_control("initial", ""), do: :ok

  defp validate_prompt_control("task_control", control_id)
       when is_binary(control_id) and control_id != "",
       do: :ok

  defp validate_prompt_control(_kind, _control_id), do: {:error, :invalid_prompt_control_id}

  defp validate_terminal(terminal) when is_map(terminal) and not is_struct(terminal) do
    with true <-
           MapSet.new(Map.keys(terminal)) ==
             MapSet.new(~w(status response error stop_reason)) or
             {:error, :invalid_terminal_shape},
         true <-
           TaskOutcomeRegistry.transcript_terminal_status?(terminal["status"]) or
             {:error, :invalid_terminal_status},
         :ok <- validate_field(terminal["response"], @max_response_bytes),
         :ok <- validate_field(terminal["error"], @max_error_bytes),
         :ok <- validate_field(terminal["stop_reason"], 128) do
      :ok
    end
  end

  defp validate_terminal(_terminal), do: {:error, :invalid_terminal_shape}

  defp validate_continuity(continuity)
       when is_map(continuity) and not is_struct(continuity) do
    with true <-
           MapSet.new(Map.keys(continuity)) ==
             MapSet.new(~w(provider provider_session_id)) or
             {:error, :invalid_continuity_shape},
         :ok <- validate_field(continuity["provider"], 64),
         :ok <- validate_field(continuity["provider_session_id"], 200) do
      :ok
    end
  end

  defp validate_continuity(_continuity), do: {:error, :invalid_continuity_shape}

  defp validate_stream_tail(tail) when is_map(tail) and not is_struct(tail) do
    expected_keys =
      MapSet.new(~w(events events_retained events_seen events_omitted events_truncated))

    with true <-
           MapSet.new(Map.keys(tail)) == expected_keys or
             {:error, :invalid_stream_tail_shape},
         true <- is_list(tail["events"]) or {:error, :invalid_stream_events},
         true <-
           length(tail["events"]) <= @max_stream_events or
             {:error, :stream_event_count_exceeded},
         true <-
           tail["events_retained"] == length(tail["events"]) or
             {:error, :invalid_stream_counts},
         true <-
           (bounded_stream_count?(tail["events_seen"]) and
              bounded_stream_count?(tail["events_omitted"])) or
             {:error, :invalid_stream_counts},
         true <-
           tail["events_seen"] >= tail["events_retained"] or
             {:error, :invalid_stream_counts},
         true <-
           tail["events_omitted"] ==
             tail["events_seen"] - tail["events_retained"] or
             {:error, :invalid_stream_counts},
         true <-
           tail["events_truncated"] == tail["events_omitted"] > 0 or
             {:error, :invalid_stream_counts},
         :ok <- validate_events(tail["events"], tail["events_seen"], -1) do
      :ok
    end
  end

  defp validate_stream_tail(_tail), do: {:error, :invalid_stream_tail_shape}

  defp validate_events([], _seen, _previous), do: :ok

  defp validate_events([event | rest], seen, previous)
       when is_map(event) and not is_struct(event) do
    with true <-
           MapSet.new(Map.keys(event)) == @event_keys or
             {:error, :invalid_stream_event_shape},
         seq when is_integer(seq) and seq > previous and seq < seen <- event["source_seq"],
         true <-
           MapSet.member?(@event_kinds, event["kind"]) or
             {:error, :invalid_stream_event_kind},
         :ok <- validate_field(event["content"], @max_event_bytes),
         :ok <- validate_field(event["tool_name"], 128),
         :ok <- validate_field(event["tool_call_id"], 128) do
      validate_events(rest, seen, seq)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_stream_sequence}
    end
  end

  defp validate_events(_events, _seen, _previous), do: {:error, :invalid_stream_event_shape}

  defp validate_field(field, max_bytes, opts \\ [])

  defp validate_field(field, max_bytes, opts)
       when is_map(field) and not is_struct(field) do
    text = field["text"]
    original = field["original_bytes"]
    truncated = field["truncated"]

    with true <-
           MapSet.new(Map.keys(field)) == @field_keys or
             {:error, :invalid_bounded_field_shape},
         true <-
           (is_binary(text) and String.valid?(text) and byte_size(text) <= max_bytes) or
             {:error, :invalid_bounded_text},
         true <-
           (is_integer(original) and original >= 0 and original <= @max_original_bytes) or
             {:error, :invalid_original_byte_count},
         true <- is_boolean(truncated) or {:error, :invalid_truncation_flag},
         true <- lowercase_sha256?(field["sha256"]) or {:error, :invalid_field_digest},
         :ok <- validate_field_facts(field),
         true <-
           not Keyword.get(opts, :nonblank, false) or text != "" or
             {:error, :blank_bounded_field} do
      :ok
    end
  end

  defp validate_field(_field, _max_bytes, _opts), do: {:error, :invalid_bounded_field_shape}

  defp validate_field_facts(%{
         "text" => text,
         "original_bytes" => original,
         "truncated" => false,
         "sha256" => digest
       }) do
    if original == byte_size(text) and digest == sha256_hex(text),
      do: :ok,
      else: {:error, :inconsistent_bounded_field}
  end

  defp validate_field_facts(%{"text" => text, "original_bytes" => original, "truncated" => true}) do
    if original != byte_size(text), do: :ok, else: {:error, :inconsistent_bounded_field}
  end

  # -- transcript IO --------------------------------------------------------

  defp load_existing(root, task_id) do
    path = artifact_path(root)

    with {:ok, body} <- read_secure_regular(path),
         {:ok, transcript} <- decode_transcript(body),
         :ok <- validate_transcript(transcript),
         :ok <- verify_task_binding(transcript, task_id),
         :ok <- verify_transcript_digest(transcript) do
      {:ok, transcript, body}
    end
  end

  defp validate_transcript(transcript) when is_map(transcript) and not is_struct(transcript) do
    with true <-
           MapSet.new(Map.keys(transcript)) == @transcript_keys or
             {:error, :invalid_transcript_shape},
         true <-
           transcript["schema_version"] == @schema_version or
             {:error, :unsupported_transcript_schema},
         true <- valid_task_id?(transcript["task_id"]) or {:error, :invalid_task_id},
         true <-
           (is_list(transcript["turns"]) and is_list(transcript["identities"])) or
             {:error, :invalid_transcript_collections},
         true <-
           length(transcript["turns"]) <= @max_turns or
             {:error, :transcript_turn_count_exceeded},
         true <-
           length(transcript["identities"]) <= @max_identities or
             {:error, :transcript_identity_count_exceeded},
         :ok <- validate_identity_ledger(transcript["identities"]),
         :ok <- validate_turns(transcript["turns"]),
         :ok <- validate_retained_identities(transcript["turns"], transcript["identities"]),
         :ok <- validate_transcript_counts(transcript),
         true <-
           lowercase_sha256?(transcript["sha256"]) or
             {:error, :invalid_transcript_digest},
         true <- json_clean?(transcript) or {:error, :transcript_not_json_clean} do
      :ok
    end
  end

  defp validate_transcript(_transcript), do: {:error, :invalid_transcript}

  defp validate_identity_ledger(identities) do
    result =
      Enum.reduce_while(identities, MapSet.new(), fn identity, seen ->
        valid =
          is_map(identity) and not is_struct(identity) and
            MapSet.new(Map.keys(identity)) == MapSet.new(~w(turn_id content_sha256)) and
            is_binary(identity["turn_id"]) and
            Regex.match?(@turn_id_pattern, identity["turn_id"]) and
            lowercase_sha256?(identity["content_sha256"]) and
            not MapSet.member?(seen, identity["turn_id"])

        if valid,
          do: {:cont, MapSet.put(seen, identity["turn_id"])},
          else: {:halt, :error}
      end)

    if result == :error, do: {:error, :invalid_identity_ledger}, else: :ok
  end

  defp validate_turns(turns) do
    Enum.reduce_while(turns, :ok, fn turn, :ok ->
      case validate_turn(turn) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_retained_identities(turns, identities) do
    expected = Enum.take(identities, -length(turns))

    valid =
      length(expected) == length(turns) and
        Enum.zip(turns, expected)
        |> Enum.all?(fn {turn, identity} ->
          turn["turn_id"] == identity["turn_id"] and
            turn_content_digest(turn) == identity["content_sha256"]
        end)

    if valid, do: :ok, else: {:error, :retained_turn_identity_mismatch}
  end

  defp validate_transcript_counts(transcript) do
    retained = length(transcript["turns"])
    seen = length(transcript["identities"])
    omitted = seen - retained

    valid =
      transcript["turns_retained"] == retained and
        transcript["turns_seen"] == seen and omitted >= 0 and
        transcript["turns_omitted"] == omitted and
        transcript["turns_truncated"] == omitted > 0 and
        is_boolean(transcript["aggregate_truncated"])

    if valid, do: :ok, else: {:error, :invalid_transcript_counts}
  end

  defp verify_task_binding(%{"task_id" => task_id}, task_id), do: :ok

  defp verify_task_binding(%{"task_id" => stored}, expected),
    do: {:error, {:task_id_mismatch, expected, stored}}

  defp verify_transcript_digest(transcript) do
    expected = transcript |> Map.drop(["sha256"]) |> canonical_digest()
    if transcript["sha256"] == expected, do: :ok, else: {:error, :transcript_digest_mismatch}
  end

  defp encode_transcript(transcript) do
    body = Map.drop(transcript, ["sha256"])
    with_digest = Map.put(body, "sha256", canonical_digest(body))

    case Jason.encode(with_digest, pretty: true) do
      {:ok, encoded} -> {:ok, encoded, with_digest}
      {:error, reason} -> {:error, {:json_encode_failed, Exception.message(reason)}}
    end
  rescue
    error -> {:error, {:json_encode_failed, Exception.message(error)}}
  end

  defp decode_transcript(body) when byte_size(body) <= @max_aggregate_bytes do
    case Jason.decode(body) do
      {:ok, transcript} when is_map(transcript) -> {:ok, transcript}
      {:ok, _other} -> {:error, :invalid_transcript}
      {:error, reason} -> {:error, {:json_decode_failed, Exception.message(reason)}}
    end
  end

  defp decode_transcript(_body), do: {:error, :transcript_too_large}

  defp build_descriptor(path, transcript, body) do
    descriptor = %{
      "path" => path,
      "sha256" => transcript["sha256"],
      "byte_size" => byte_size(body),
      "turns_retained" => transcript["turns_retained"],
      "turns_seen" => transcript["turns_seen"],
      "turns_omitted" => transcript["turns_omitted"],
      "turns_truncated" => transcript["turns_truncated"],
      "aggregate_truncated" => transcript["aggregate_truncated"],
      "schema_version" => @schema_version,
      "task_id" => transcript["task_id"]
    }

    case TranscriptDescriptor.normalize(descriptor) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_descriptor, reason}}
    end
  end

  defp read_secure_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_aggregate_bytes ->
        with {:ok, canonical} <- SafePath.resolve_real(path),
             true <- canonical == path or {:error, :unsafe_transcript_path},
             {:ok, body} <- read_bounded(path) do
          {:ok, body}
        else
          {:error, :transcript_too_large} -> {:error, :transcript_too_large}
          {:error, reason} -> {:error, {:read_transcript_failed, reason}}
          false -> {:error, :unsafe_transcript_path}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :transcript_too_large}

      {:error, :enoent} ->
        {:error, :absent}

      {:ok, _other} ->
        {:error, :unsafe_transcript_path}

      {:error, reason} ->
        {:error, {:read_transcript_failed, reason}}
    end
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary], fn device ->
           case IO.binread(device, @max_aggregate_bytes + 1) do
             :eof -> {:ok, ""}
             body when is_binary(body) and byte_size(body) <= @max_aggregate_bytes -> {:ok, body}
             body when is_binary(body) -> {:error, :transcript_too_large}
             {:error, reason} -> {:error, reason}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_write(path, content) do
    temporary = temporary_path(path)

    try do
      with :ok <- write_secure_temp(temporary, content),
           :ok <- File.rename(temporary, path),
           :ok <- File.chmod(path, 0o600) do
        :ok
      else
        {:error, reason} -> {:error, {:write_transcript_failed, reason}}
      end
    after
      _ = File.rm(temporary)
    end
  end

  defp write_secure_temp(path, content) do
    case File.open(path, [:write, :binary, :exclusive], fn device ->
           with :ok <- File.chmod(path, 0o600),
                :ok <- IO.binwrite(device, content),
                :ok <- :file.sync(device) do
             :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- paths and digests ----------------------------------------------------

  defp validate_root(root) when is_binary(root) do
    with true <- String.valid?(root) or {:error, {:invalid_root, :invalid_encoding}},
         true <- String.trim(root) != "" or {:error, {:invalid_root, :empty}},
         true <- not String.contains?(root, <<0>>) or {:error, {:invalid_root, :null_byte}},
         true <- SafePath.absolute?(root) or {:error, {:invalid_root, :not_absolute}},
         true <- Path.expand(root) == root or {:error, {:invalid_root, :not_canonical}},
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, canonical} <- SafePath.resolve_real(root),
         true <- canonical == root or {:error, {:invalid_root, :symlinked}} do
      {:ok, root}
    else
      {:error, {:invalid_root, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_root, reason}}
      false -> {:error, {:invalid_root, :invalid}}
      _ -> {:error, {:invalid_root, :not_directory}}
    end
  rescue
    _ -> {:error, {:invalid_root, :invalid_path}}
  end

  defp validate_root(_root), do: {:error, {:invalid_root, :expected_string}}

  defp validate_task_id(task_id) do
    if valid_task_id?(task_id), do: {:ok, task_id}, else: {:error, :invalid_task_id}
  end

  defp valid_task_id?(task_id) when is_binary(task_id) do
    String.valid?(task_id) and String.trim(task_id) != "" and
      byte_size(task_id) <= @max_task_id_bytes and not String.contains?(task_id, <<0>>) and
      not String.match?(task_id, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_task_id?(_task_id), do: false

  defp artifact_path(root), do: Path.join(root, @filename)

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")
  end

  defp deterministic_turn_id(execution_id, capture_index) do
    "acp_turn_" <> sha256_hex(execution_id <> ":" <> Integer.to_string(capture_index))
  end

  defp turn_content_digest(turn),
    do: turn |> Map.drop(["captured_at"]) |> canonical_digest()

  defp canonical_digest(value), do: value |> canonical_json() |> sha256_hex()

  defp canonical_json(map) when is_map(map) and not is_struct(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> canonical_json(value)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp sha256_hex(binary),
    do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp lowercase_sha256?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@lowercase_sha256, value)

  defp lowercase_sha256?(_value), do: false

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  defp bounded_stream_count?(value),
    do: non_neg_integer?(value) and value <= @max_stream_events_seen

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
