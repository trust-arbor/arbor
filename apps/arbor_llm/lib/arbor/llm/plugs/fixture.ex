defmodule Arbor.LLM.Plugs.Fixture do
  @moduledoc """
  Shared fixture I/O for the `Replay` and `Record` plugs.

  Not itself a plug — these are pure functions both plugs use.
  Centralizes:

    * Where fixtures live on disk (configurable, with a sensible
      umbrella-aware default)
    * The SHA-256 hash that keys each fixture
    * The typed JSON boundary for `Arbor.LLM.Call` results (chat
      completions, streams, embeddings, errors)

  ## Fixture format

      {
        "schema_version": 2,
        "operation": "complete",
        "request_hash": "b3a8f2c7…",
        "request_summary": { … informational, ignored by the loader … },
        "recorded_at": "2026-06-02T16:45:00Z",
        "response": { … operation-specific result shape … }
      }

  Identical request shapes hash to the same fixture path regardless
  of test file or session. Per-call-volatile fields
  (`:signed_request`, `:base_url`, `:provider`) are scrubbed before
  hashing so fixtures stay stable.

  Complete fixtures record the live `{:ok, %ReqLLM.Response{}}` boundary. Only
  text, thinking text, tool calls, finish reason, and bounded usage cross the
  boundary; transport context, provider metadata, raw/error fields, headers,
  signatures, encrypted reasoning details, and other provider internals do not.
  New v2 writes require canonical atom-keyed live usage; string-keyed usage is
  rejected because replay reconstructs the adapter-visible usage map with atom
  keys.
  Loaded complete fixtures reconstruct a minimal `%ReqLLM.Response{}` so the
  adapter's existing translation path remains the single response boundary.

  New fixtures use schema version 2. Missing versions load as legacy v1. Unknown
  versions fail closed. Live lazy `ReqLLM` streams are deliberately unsupported
  for recording: only eager event lists and owned Arbor streams are recordable;
  a bounded live stream is rejected without enumeration or fixture publication.
  """

  alias Arbor.LLM.Call
  alias Arbor.LLM.Boundary
  alias Arbor.LLM.Deadline
  alias Arbor.LLM.OwnedStream
  alias Arbor.LLM.ResponseBudget
  alias Arbor.LLM.StreamEvent

  @maximum_fixture_bytes 16_777_216
  @default_record_timeout_ms 30_000
  @fixture_limits [
    max_bytes: @maximum_fixture_bytes,
    max_nodes: 100_000,
    max_depth: 32,
    max_map_keys: 10_000,
    max_list_items: 100_000
  ]
  @fixture_schema_version 2
  @legacy_fixture_schema_version 1
  @max_response_string_bytes 1_048_576
  @max_response_content_parts 100_000
  @max_response_tool_calls 100_000
  @max_response_text_bytes 1_048_576
  @max_response_reasoning_bytes 1_048_576
  @max_response_tool_bytes 1_048_576
  @max_response_argument_nodes 100_000
  @max_response_argument_depth 32
  @max_usage_token 1_000_000_000
  @max_usage_cost 1_000_000.0
  @usage_fields [
    {"input_tokens", :input_tokens},
    {"output_tokens", :output_tokens},
    {"total_tokens", :total_tokens},
    {"cached_tokens", :cached_tokens},
    {"reasoning_tokens", :reasoning_tokens},
    {"prompt_tokens", :prompt_tokens},
    {"completion_tokens", :completion_tokens},
    {"cache_read_tokens", :cache_read_tokens},
    {"input", :input},
    {"output", :output},
    {"total", :total},
    {"input_cost", :input_cost},
    {"output_cost", :output_cost},
    {"total_cost", :total_cost}
  ]
  @finish_reasons %{
    "stop" => :stop,
    "length" => :length,
    "tool_calls" => :tool_calls,
    "content_filter" => :content_filter,
    "error" => :error,
    "cancelled" => :cancelled,
    "incomplete" => :incomplete,
    "unknown" => :unknown
  }

  # ── Paths ──────────────────────────────────────────────────────────

  @doc "Compute the on-disk path for a call's fixture."
  @spec path_for(Call.t()) :: String.t()
  def path_for(%Call{} = call) do
    Path.join(fixtures_root(), request_hash(call) <> ".json")
  end

  @doc "Resolved fixtures root — operator-overridable via app config."
  @spec fixtures_root() :: String.t()
  def fixtures_root do
    config = Application.get_env(:arbor_llm, :recorder, [])
    Keyword.get(config, :fixtures_path, default_fixtures_root())
  end

  defp default_fixtures_root do
    Path.join([
      File.cwd!() |> root_for_arbor_llm(),
      "test",
      "fixtures",
      "llm_recordings"
    ])
  end

  # Tests can be run from umbrella root (cwd ends with /arbor) or
  # from inside the app (cwd ends with /arbor_llm). Anchor the
  # fixtures dir under apps/arbor_llm regardless.
  defp root_for_arbor_llm(cwd) do
    cond do
      File.exists?(Path.join(cwd, "mix.exs")) and String.ends_with?(cwd, "arbor_llm") ->
        cwd

      File.exists?(Path.join([cwd, "apps", "arbor_llm", "mix.exs"])) ->
        Path.join([cwd, "apps", "arbor_llm"])

      true ->
        cwd
    end
  end

  # ── Hashing ────────────────────────────────────────────────────────

  @doc """
  SHA-256 hash that keys a fixture. Excludes per-call-volatile fields
  so identical-shape calls match across sessions.
  """
  @spec request_hash(Call.t()) :: String.t()
  def request_hash(%Call{operation: op, request: req}) do
    canonical = canonicalize(op, req)
    payload = :erlang.term_to_binary(canonical, [:deterministic])
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp canonicalize(:complete, {model_spec, messages, opts}) do
    {:complete, normalize_model_spec(model_spec), normalize_messages(messages), scrub_opts(opts)}
  end

  defp canonicalize(:stream, {model_spec, messages, opts}) do
    {:stream, normalize_model_spec(model_spec), normalize_messages(messages), scrub_opts(opts)}
  end

  defp canonicalize(:embed_cloud, {model_spec, texts, opts}) do
    {:embed_cloud, normalize_model_spec(model_spec), texts, scrub_opts(opts)}
  end

  defp canonicalize(:embed_local, {model, texts, opts}) do
    {:embed_local, normalize_model_spec(model), texts, scrub_opts(opts)}
  end

  defp normalize_model_spec(%LLMDB.Model{} = model), do: {model.provider, model.id}
  defp normalize_model_spec(spec) when is_binary(spec), do: spec

  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %_{} = msg -> msg |> Map.from_struct() |> Map.delete(:__struct__)
      msg -> msg
    end)
  end

  defp normalize_messages(other), do: other

  defp scrub_opts(opts) when is_list(opts) do
    opts
    |> Keyword.drop([:signed_request, :base_url, :provider])
    |> Enum.sort()
  end

  defp scrub_opts(opts), do: opts

  # ── Load / Save ────────────────────────────────────────────────────

  @doc """
  Load a fixture for `call`. Returns `{:ok, response, recorded_at}`
  where `response` is the deserialized result and `recorded_at` is
  the `DateTime` the fixture was captured. `:not_found` if no fixture
  exists.
  """
  @spec load(Call.t()) ::
          {:ok, term(), DateTime.t()} | :not_found | {:error, term()}
  def load(%Call{operation: op} = call) do
    path = path_for(call)

    case Arbor.LLM.read_bounded_regular_file(path, @maximum_fixture_bytes) do
      {:ok, body} -> load_body(call, op, body)
      {:error, {:file_stat_failed, :enoent}} -> :not_found
      {:error, reason} -> fixture_error({:fixture_read_failed, reason})
    end
  rescue
    exception -> fixture_error({:fixture_load_exception, external_exception(exception)})
  catch
    kind, reason -> fixture_error({:fixture_load_failure, kind, external_reason(reason)})
  end

  defp load_body(call, op, body) do
    with {:ok, decoded} <-
           Arbor.LLM.ResponseBudget.decode_json(body,
             max_bytes: @maximum_fixture_bytes,
             max_nodes: 100_000,
             max_depth: 32,
             max_map_keys: 10_000,
             max_list_items: 100_000
           ),
         true <- is_map(decoded) or {:error, :fixture_object_required},
         true <- decoded["operation"] == Atom.to_string(op) or {:error, :operation_mismatch},
         true <- decoded["request_hash"] == request_hash(call) or {:error, :request_hash_mismatch},
         {:ok, schema_version} <- schema_version(decoded),
         {:ok, recorded_at, _} <- DateTime.from_iso8601(decoded["recorded_at"] || ""),
         {:ok, deserialized} <- safe_deserialize(op, schema_version, decoded["response"]),
         {:ok, response} <- validate_replay(call, deserialized) do
      {:ok, response, recorded_at}
    else
      {:error, {:invalid_embedding_fixture, _reason} = reason} -> {:error, reason}
      {:error, reason} -> fixture_error(reason)
      _invalid -> fixture_error(:invalid_fixture_shape)
    end
  end

  defp schema_version(decoded) do
    version = Map.get(decoded, "schema_version", @legacy_fixture_schema_version)

    if version in [@legacy_fixture_schema_version, @fixture_schema_version],
      do: {:ok, version},
      else: {:error, {:unsupported_schema_version, version}}
  end

  @doc """
  Persist `result` as a fixture for `call`.
  """
  @spec save(Call.t(), term()) :: :ok | {:error, term()}
  def save(%Call{} = call, result) do
    case record(call, result) do
      {:ok, _replayable_result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec record(Call.t(), term()) :: {:ok, term()} | {:error, term()}
  def record(%Call{} = call, result) do
    opts = request_options(call)

    with {:ok, opts, _timeout} <-
           Deadline.normalize_options(opts, @default_record_timeout_ms),
         {:ok, receipt} <- Deadline.receipt(opts) do
      try do
        do_record(call, result, opts, receipt)
      after
        finalize_recording_stream(result)
      end
    end
  rescue
    exception -> fixture_error({:fixture_save_exception, external_exception(exception)})
  catch
    kind, reason -> fixture_error({:fixture_save_failure, kind, external_reason(reason)})
  end

  defp do_record(%Call{operation: op} = call, result, opts, receipt) do
    path = path_for(call)

    with :ok <- ensure_record_active(receipt),
         {:ok, response, replayable_result} <-
           prepare_serialization(op, result, opts, receipt),
         :ok <- ensure_record_active(receipt),
         fixture = %{
           "schema_version" => @fixture_schema_version,
           "operation" => Atom.to_string(op),
           "request_hash" => request_hash(call),
           "request_summary" => summarize_request(op, call.request),
           "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "response" => response
         },
         {:ok, fixture} <- json_safe(fixture),
         :ok <- ensure_record_active(receipt),
         {:ok, encoded} <- encode_fixture(fixture),
         :ok <- ensure_record_active(receipt),
         :ok <-
           Arbor.LLM.FileReceipt.publish(path, encoded, @maximum_fixture_bytes, receipt) do
      {:ok, replayable_result}
    else
      {:error, reason} -> fixture_error({:fixture_save_failed, reason})
    end
  end

  # ── Serialization (live pipeline result → closed JSON shape) ───────

  defp prepare_serialization(
         :complete,
         {:ok, %ReqLLM.Response{} = response} = result,
         _opts,
         _receipt
       ) do
    with {:ok, serialized} <- serialize_req_llm_response(response) do
      {:ok, %{"outcome" => "ok", "value" => serialized}, result}
    end
  end

  defp prepare_serialization(:complete, {:ok, _other}, _opts, _receipt),
    do: {:error, :req_llm_response_required}

  defp prepare_serialization(:stream, {:ok, enum}, opts, receipt) do
    with {:ok, events} <- collect_stream_events(enum, opts, receipt) do
      serialized = Enum.map(events, &serialize_stream_event/1)
      {:ok, %{"outcome" => "ok", "value" => %{"events" => serialized}}, {:ok, events}}
    end
  end

  defp prepare_serialization(op, {:ok, indexed_embeddings, usage} = result, _opts, _receipt)
       when op in [:embed_cloud, :embed_local] and is_list(indexed_embeddings) do
    response = %{
      "outcome" => "ok",
      "value" => %{
        "association_version" => 1,
        "indexed_embeddings" => indexed_embeddings,
        "usage" => usage || %{}
      }
    }

    {:ok, response, result}
  end

  defp prepare_serialization(_op, {:error, reason} = result, _opts, _receipt),
    do:
      {:ok, %{"outcome" => "error", "reason" => Arbor.LLM.inspect_external_reason(reason)},
       result}

  defp prepare_serialization(:complete, _other, _opts, _receipt),
    do: {:error, :req_llm_response_required}

  defp prepare_serialization(_op, other, _opts, _receipt),
    do: {:ok, %{"outcome" => "raw", "raw" => Arbor.LLM.inspect_external_reason(other)}, other}

  defp serialize_req_llm_response(%ReqLLM.Response{} = response) do
    with {:ok, text, thinking} <- response_content_and_thinking(response.message),
         {:ok, tool_calls} <- response_tool_calls(response.message),
         {:ok, finish_reason} <- serialize_finish_reason(response.finish_reason),
         {:ok, usage} <- serialize_usage(response.usage) do
      {:ok,
       %{
         "response_kind" => "req_llm",
         "text" => text,
         "thinking" => thinking,
         "tool_calls" => tool_calls,
         "finish_reason" => finish_reason,
         "usage" => usage
       }}
    end
  end

  # This mirrors the adapter's two response accessors without invoking
  # `ReqLLM.Response.text/1` or building unbounded intermediate lists.
  defp response_content_and_thinking(nil), do: {:ok, "", []}

  defp response_content_and_thinking(%ReqLLM.Message{} = message) do
    with {:ok, text, content_thinking} <- extract_content_parts(message.content),
         {:ok, reasoning_details} <- extract_reasoning_details(message.reasoning_details) do
      thinking = if reasoning_details == [], do: content_thinking, else: reasoning_details
      {:ok, text, thinking}
    end
  end

  defp response_content_and_thinking(_message),
    do: {:error, {:complete_response_invalid, :message}}

  defp extract_content_parts(parts) when is_list(parts) do
    do_extract_content_parts(parts, 0, [], 0, [], 0)
  end

  defp extract_content_parts(_parts),
    do: {:error, {:complete_response_invalid, :content}}

  defp do_extract_content_parts([], _count, text_acc, _text_bytes, thinking_acc, _thinking_bytes) do
    {:ok, IO.iodata_to_binary(Enum.reverse(text_acc)), Enum.reverse(thinking_acc)}
  end

  defp do_extract_content_parts(
         _parts,
         count,
         _text_acc,
         _text_bytes,
         _thinking_acc,
         _thinking_bytes
       )
       when count >= @max_response_content_parts,
       do: {:error, {:complete_response_limit_exceeded, :content_parts}}

  defp do_extract_content_parts(
         [part | rest],
         count,
         text_acc,
         text_bytes,
         thinking_acc,
         thinking_bytes
       ) do
    next_count = count + 1

    case part do
      %ReqLLM.Message.ContentPart{type: :text, text: text}
      when is_binary(text) ->
        with {:ok, text_bytes} <-
               add_response_bytes(text, text_bytes, @max_response_text_bytes, :text),
             {:ok, _} <- bounded_response_string(text, :text),
             {:ok, text_acc} <- valid_response_iolist(text, text_acc) do
          do_extract_content_parts(
            rest,
            next_count,
            text_acc,
            text_bytes,
            thinking_acc,
            thinking_bytes
          )
        end

      %ReqLLM.Message.ContentPart{type: :thinking, text: nil} ->
        do_extract_content_parts(
          rest,
          next_count,
          text_acc,
          text_bytes,
          thinking_acc,
          thinking_bytes
        )

      %ReqLLM.Message.ContentPart{type: :thinking, text: text}
      when is_binary(text) ->
        with {:ok, thinking_bytes} <-
               add_response_bytes(
                 text,
                 thinking_bytes,
                 @max_response_reasoning_bytes,
                 :thinking
               ),
             {:ok, _} <- bounded_response_string(text, :thinking) do
          do_extract_content_parts(
            rest,
            next_count,
            text_acc,
            text_bytes,
            [text | thinking_acc],
            thinking_bytes
          )
        end

      %ReqLLM.Message.ContentPart{type: type}
      when type in [:image_url, :image, :file] ->
        do_extract_content_parts(
          rest,
          next_count,
          text_acc,
          text_bytes,
          thinking_acc,
          thinking_bytes
        )

      _invalid ->
        {:error, {:complete_response_invalid, :content_part}}
    end
  end

  defp do_extract_content_parts(
         _improper,
         _count,
         _text_acc,
         _text_bytes,
         _thinking_acc,
         _thinking_bytes
       ),
       do: {:error, {:complete_response_invalid, :content}}

  defp extract_reasoning_details(nil), do: {:ok, []}

  defp extract_reasoning_details(details) when is_list(details) do
    do_extract_reasoning_details(details, 0, [], 0, false)
  end

  defp extract_reasoning_details(_details),
    do: {:error, {:complete_response_invalid, :reasoning_details}}

  defp do_extract_reasoning_details([], _count, _acc, _bytes, false), do: {:ok, []}

  defp do_extract_reasoning_details([], _count, acc, _bytes, true),
    do: {:ok, Enum.reverse(acc)}

  defp do_extract_reasoning_details(_details, count, _acc, _bytes, _has_content)
       when count >= @max_response_content_parts,
       do: {:error, {:complete_response_limit_exceeded, :reasoning_details}}

  defp do_extract_reasoning_details([detail | rest], count, acc, bytes, has_content?) do
    case detail do
      %ReqLLM.Message.ReasoningDetails{text: nil} ->
        do_extract_reasoning_details(rest, count + 1, acc, bytes, has_content?)

      %ReqLLM.Message.ReasoningDetails{text: text}
      when is_binary(text) ->
        with {:ok, bytes} <-
               add_response_bytes(text, bytes, @max_response_reasoning_bytes, :reasoning_details),
             {:ok, _} <- bounded_response_string(text, :thinking) do
          do_extract_reasoning_details(
            rest,
            count + 1,
            [text | acc],
            bytes,
            has_content? or text != ""
          )
        end

      _invalid ->
        {:error, {:complete_response_invalid, :reasoning_detail}}
    end
  end

  defp do_extract_reasoning_details(_improper, _count, _acc, _bytes, _has_content),
    do: {:error, {:complete_response_invalid, :reasoning_details}}

  defp response_tool_calls(nil), do: {:ok, []}

  defp response_tool_calls(%ReqLLM.Message{} = message) do
    calls = message.tool_calls || []

    if is_list(calls),
      do: do_serialize_tool_calls(calls, 0, [], 0),
      else: {:error, {:complete_response_invalid, :tool_calls}}
  end

  defp response_tool_calls(_message),
    do: {:error, {:complete_response_invalid, :tool_calls}}

  defp do_serialize_tool_calls([], _count, acc, _bytes),
    do: {:ok, Enum.reverse(acc)}

  defp do_serialize_tool_calls(_calls, count, _acc, _bytes)
       when count >= @max_response_tool_calls,
       do: {:error, {:complete_response_limit_exceeded, :tool_calls}}

  defp do_serialize_tool_calls([tool_call | rest], count, acc, bytes) do
    with {:ok, serialized, call_bytes} <- serialize_tool_call(tool_call),
         {:ok, bytes} <-
           add_response_bytes(call_bytes, bytes, @max_response_tool_bytes, :tool_calls) do
      do_serialize_tool_calls(rest, count + 1, [serialized | acc], bytes)
    end
  end

  defp do_serialize_tool_calls(_improper, _count, _acc, _bytes),
    do: {:error, {:complete_response_invalid, :tool_calls}}

  defp add_response_bytes(value, bytes, maximum, field) when is_binary(value),
    do: add_response_bytes(byte_size(value), bytes, maximum, field)

  defp add_response_bytes(value, bytes, maximum, field)
       when is_integer(value) and value >= 0 do
    if bytes <= maximum - value,
      do: {:ok, bytes + value},
      else: {:error, {:complete_response_limit_exceeded, field}}
  end

  defp valid_response_iolist(value, acc) when is_binary(value), do: {:ok, [value | acc]}

  defp serialize_tool_call(%ReqLLM.ToolCall{id: id, function: function})
       when is_map(function) do
    serialize_tool_call_fields(
      id,
      Map.get(function, "name", Map.get(function, :name)),
      Map.get(function, "arguments", Map.get(function, :arguments))
    )
  end

  defp serialize_tool_call(%{} = tool_call) do
    function = Map.get(tool_call, "function", Map.get(tool_call, :function, %{}))

    if is_map(function) do
      serialize_tool_call_fields(
        Map.get(tool_call, "id", Map.get(tool_call, :id)),
        Map.get(function, "name", Map.get(function, :name)),
        Map.get(function, "arguments", Map.get(function, :arguments))
      )
    else
      {:error, {:complete_response_invalid, :tool_call_function}}
    end
  end

  defp serialize_tool_call(_tool_call),
    do: {:error, {:complete_response_invalid, :tool_call}}

  defp serialize_tool_call_fields(id, name, arguments)
       when is_binary(id) and is_binary(name) and not is_nil(arguments) do
    with {:ok, id} <- bounded_response_string(id, :tool_call_id),
         {:ok, name} <- bounded_response_string(name, :tool_call_name),
         {:ok, arguments, argument_bytes} <- bounded_json_value(arguments) do
      call_bytes = byte_size(id) + byte_size(name) + argument_bytes
      {:ok, %{"id" => id, "name" => name, "arguments" => arguments}, call_bytes}
    end
  end

  defp serialize_tool_call_fields(_id, _name, _arguments),
    do: {:error, {:complete_response_invalid, :tool_call_fields}}

  defp bounded_json_value(value) do
    case bounded_json_value(value, %{nodes: 0, bytes: 0, depth: 0}) do
      {:ok, json_value, %{bytes: bytes}} -> {:ok, json_value, bytes}
      {:error, _reason} = error -> error
    end
  end

  defp bounded_json_value(value, state)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value) do
    with {:ok, state} <- bounded_json_node(state, scalar_bytes(value)) do
      {:ok, value, state}
    end
  end

  defp bounded_json_value(value, state) when is_atom(value) do
    bounded_json_value(Atom.to_string(value), state)
  end

  defp bounded_json_value(value, state) when is_list(value) do
    if state.depth >= @max_response_argument_depth do
      {:error, {:complete_response_limit_exceeded, :tool_call_arguments}}
    else
      bounded_json_list(value, [], %{state | depth: state.depth + 1}, 0)
    end
  end

  defp bounded_json_value(value, state) when is_map(value) do
    if state.depth >= @max_response_argument_depth do
      {:error, {:complete_response_limit_exceeded, :tool_call_arguments}}
    else
      bounded_json_map(:maps.iterator(value), %{}, %{state | depth: state.depth + 1})
    end
  end

  defp bounded_json_value(_value, _state),
    do: {:error, {:complete_response_invalid, :tool_call_arguments}}

  defp bounded_json_list([], acc, state, _count),
    do: {:ok, Enum.reverse(acc), %{state | depth: state.depth - 1}}

  defp bounded_json_list([head | tail], acc, state, count)
       when count < @max_response_argument_nodes do
    with {:ok, value, state} <- bounded_json_value(head, state) do
      bounded_json_list(tail, [value | acc], state, count + 1)
    end
  end

  defp bounded_json_list(_improper, _acc, _state, _count),
    do: {:error, {:complete_response_limit_exceeded, :tool_call_arguments}}

  defp bounded_json_map(iterator, acc, state) do
    case :maps.next(iterator) do
      :none ->
        {:ok, acc, %{state | depth: state.depth - 1}}

      {key, value, next} ->
        with {:ok, key} <- bounded_json_key(key),
             {:ok, state} <- bounded_json_node(state, byte_size(key)),
             true <- not Map.has_key?(acc, key) or {:error, {:duplicate_json_key, key}},
             {:ok, value, state} <- bounded_json_value(value, state) do
          bounded_json_map(next, Map.put(acc, key, value), state)
        end
    end
  end

  defp bounded_json_key(:__struct__), do: {:ok, "__external_struct__"}
  defp bounded_json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp bounded_json_key(key) when is_binary(key), do: {:ok, key}
  defp bounded_json_key(_key), do: {:error, :string_or_atom_fixture_key_required}

  defp bounded_json_node(%{nodes: nodes} = state, bytes)
       when nodes < @max_response_argument_nodes and bytes >= 0 do
    if state.bytes <= @max_response_tool_bytes - bytes do
      {:ok, %{state | nodes: nodes + 1, bytes: state.bytes + bytes}}
    else
      {:error, {:complete_response_limit_exceeded, :tool_call_arguments}}
    end
  end

  defp bounded_json_node(_state, _bytes),
    do: {:error, {:complete_response_limit_exceeded, :tool_call_arguments}}

  defp scalar_bytes(value) when is_binary(value), do: byte_size(value)
  defp scalar_bytes(value) when is_integer(value), do: byte_size(Integer.to_string(value))
  defp scalar_bytes(value) when is_float(value), do: byte_size(Float.to_string(value))
  defp scalar_bytes(true), do: 4
  defp scalar_bytes(false), do: 5
  defp scalar_bytes(nil), do: 4

  defp serialize_finish_reason(nil), do: {:ok, nil}

  defp serialize_finish_reason(reason) when is_atom(reason) do
    case reason do
      reason
      when reason in [
             :stop,
             :length,
             :tool_calls,
             :content_filter,
             :error,
             :cancelled,
             :incomplete,
             :unknown
           ] ->
        {:ok, Atom.to_string(reason)}

      _ ->
        {:error, {:complete_response_invalid, :finish_reason}}
    end
  end

  defp serialize_finish_reason(_reason),
    do: {:error, {:complete_response_invalid, :finish_reason}}

  defp serialize_usage(nil), do: {:ok, %{}}

  defp serialize_usage(usage) when is_map(usage) do
    if Enum.all?(Map.keys(usage), &is_atom/1) do
      Enum.reduce_while(@usage_fields, {:ok, %{}}, fn {wire_key, atom_key}, {:ok, acc} ->
        case Map.fetch(usage, atom_key) do
          :error ->
            {:cont, {:ok, acc}}

          {:ok, nil} ->
            {:cont, {:ok, acc}}

          {:ok, value} ->
            case bounded_usage_value(atom_key, value) do
              {:ok, value} -> {:cont, {:ok, Map.put(acc, wire_key, value)}}
              :error -> {:halt, {:error, {:complete_response_invalid, {:usage, atom_key}}}}
            end
        end
      end)
    else
      {:error, {:complete_response_invalid, :usage_keys}}
    end
  end

  defp serialize_usage(_usage),
    do: {:error, {:complete_response_invalid, :usage}}

  defp bounded_usage_value(key, value)
       when key in [
              :input_tokens,
              :output_tokens,
              :total_tokens,
              :cached_tokens,
              :reasoning_tokens,
              :prompt_tokens,
              :completion_tokens,
              :cache_read_tokens,
              :input,
              :output,
              :total
            ] and is_integer(value) and value >= 0 and value <= @max_usage_token,
       do: {:ok, value}

  defp bounded_usage_value(key, value) when key in [:input_cost, :output_cost, :total_cost] do
    cond do
      is_integer(value) and value >= 0 and value <= @max_usage_cost ->
        {:ok, value * 1.0}

      is_float(value) and value >= 0.0 and value < @max_usage_cost and value == value ->
        {:ok, value}

      true ->
        :error
    end
  end

  defp bounded_usage_value(_key, _value), do: :error

  defp bounded_response_string(nil, _field), do: {:ok, ""}

  defp bounded_response_string(value, _field)
       when is_binary(value) and byte_size(value) <= @max_response_string_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_response_string}
  end

  defp bounded_response_string(_value, field),
    do: {:error, {:complete_response_invalid, field}}

  defp serialize_stream_event(%StreamEvent{type: type, data: data}) do
    %{
      "type" => type,
      "data" => data
    }
  end

  defp serialize_stream_event(other), do: Arbor.LLM.sanitize_external_reason(other)

  defp collect_stream_events(%OwnedStream{} = stream, opts, receipt) do
    Deadline.run(
      fn -> do_collect_stream_events(stream, opts, receipt) end,
      receipt,
      {:fixture_record_deadline_exceeded, receipt.timeout_ms}
    )
  end

  defp collect_stream_events(events, opts, receipt) when is_list(events),
    do: do_collect_stream_events(events, opts, receipt)

  defp collect_stream_events(_unowned_lazy_source, _opts, _receipt),
    do: {:error, :owned_stream_or_eager_list_required}

  defp do_collect_stream_events(enum, opts, receipt) do
    with :ok <- ensure_record_active(receipt),
         {:ok, tracker} <- Boundary.stream_tracker(opts),
         {:ok, maximum} <- Boundary.stream_event_limit(opts) do
      result =
        Enum.reduce_while(enum, {[], 0}, fn event, {events, count} ->
          next = count + 1

          cond do
            not record_active?(receipt) ->
              {:halt, {:error, {:fixture_record_deadline_exceeded, receipt.timeout_ms}}}

            next > maximum ->
              {:halt, {:error, {:stream_limit_exceeded, :events, maximum}}}

            true ->
              case Boundary.track_stream_event(tracker, event, opts) do
                {:ok, normalized} -> {:cont, {[normalized | events], next}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
          end
        end)

      case result do
        {:error, _reason} = error ->
          error

        {events, _count} ->
          with :ok <- ensure_record_active(receipt) do
            {:ok, Enum.reverse(events)}
          end
      end
    end
  rescue
    exception -> {:error, {:stream_collection_failed, external_exception(exception)}}
  catch
    kind, reason -> {:error, {:stream_collection_failure, kind, external_reason(reason)}}
  end

  defp finalize_recording_stream({:ok, %OwnedStream{} = stream}) do
    _ = OwnedStream.finalize(stream)
    :ok
  end

  defp finalize_recording_stream(_result), do: :ok

  defp ensure_record_active(receipt) do
    if record_active?(receipt),
      do: :ok,
      else: {:error, {:fixture_record_deadline_exceeded, receipt.timeout_ms}}
  end

  defp record_active?(%{deadline_ms: deadline_ms}) when is_integer(deadline_ms),
    do: System.monotonic_time(:millisecond) <= deadline_ms

  defp record_active?(_receipt), do: false

  defp json_safe(value) do
    with :ok <- ResponseBudget.validate(value, @fixture_limits) do
      json_value(value)
    end
  end

  defp json_value(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, value}

  defp json_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp json_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> json_list([])

  defp json_value(value) when is_list(value), do: json_list(value, [])

  defp json_value(value) when is_map(value),
    do: json_map(:maps.iterator(value), %{})

  defp json_value(_value), do: {:error, :json_compatible_fixture_required}

  defp json_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp json_list([head | tail], acc) do
    with {:ok, head} <- json_value(head) do
      json_list(tail, [head | acc])
    end
  end

  defp json_list(_improper, _acc), do: {:error, :proper_fixture_list_required}

  defp json_map(iterator, acc) do
    case :maps.next(iterator) do
      :none ->
        {:ok, acc}

      {key, value, next} ->
        with {:ok, key} <- json_key(key),
             true <- not Map.has_key?(acc, key) or {:error, {:duplicate_json_key, key}},
             {:ok, value} <- json_value(value) do
          json_map(next, Map.put(acc, key, value))
        end
    end
  end

  defp json_key(:__struct__), do: {:ok, "__external_struct__"}
  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp json_key(key) when is_binary(key), do: {:ok, key}
  defp json_key(_key), do: {:error, :string_or_atom_fixture_key_required}

  defp encode_fixture(fixture) do
    case Jason.encode(fixture, pretty: true) do
      {:ok, encoded} when byte_size(encoded) <= @maximum_fixture_bytes -> {:ok, encoded}
      {:ok, _oversized} -> {:error, {:fixture_bytes_exceeded, @maximum_fixture_bytes}}
      {:error, _reason} -> {:error, :fixture_encoding_failed}
    end
  rescue
    exception -> {:error, {:fixture_encoding_exception, external_exception(exception)}}
  catch
    kind, reason -> {:error, {:fixture_encoding_failure, kind, external_reason(reason)}}
  end

  defp request_options(%Call{request: request})
       when is_tuple(request) and tuple_size(request) == 3 do
    case elem(request, 2) do
      opts when is_list(opts) -> opts
      _other -> []
    end
  end

  defp request_options(_call), do: []

  # ── Deserialization (JSON shape → live adapter boundary) ───────────

  defp deserialize(_op, _version, %{"outcome" => "error", "reason" => reason}) do
    {:error, {:replayed_error, external_reason(reason)}}
  end

  defp deserialize(:complete, @fixture_schema_version, %{
         "outcome" => "ok",
         "value" => value
       }) do
    deserialize_req_llm_response(value)
  end

  defp deserialize(:complete, @legacy_fixture_schema_version, %{
         "outcome" => "ok",
         "value" => value
       }) do
    deserialize_legacy_response(value)
  end

  defp deserialize(:stream, _version, %{"outcome" => "ok", "value" => %{"events" => events}})
       when is_list(events) do
    {:ok, Enum.map(events, &deserialize_stream_event/1)}
  end

  defp deserialize(op, _version, %{"outcome" => "ok", "value" => v})
       when op in [:embed_cloud, :embed_local] and is_map(v) do
    cond do
      Map.has_key?(v, "indexed_embeddings") ->
        deserialize_indexed_embeddings(v)

      Map.has_key?(v, "association_version") ->
        {:invalid_fixture_shape, :versioned_indexed_embeddings_required}

      Map.has_key?(v, "embeddings") ->
        usage = Map.get(v, "usage", %{})

        {:legacy_positional_embeddings, Map.get(v, "embeddings"), deserialize_usage(usage)}

      true ->
        {:invalid_fixture_shape, :embedding_value_required}
    end
  end

  defp deserialize(op, _version, %{"outcome" => "ok"}) when op in [:embed_cloud, :embed_local],
    do: {:invalid_fixture_shape, :embedding_value_object_required}

  defp deserialize(_op, _version, _response),
    do: {:invalid_fixture_shape, :known_outcome_required}

  defp deserialize_indexed_embeddings(value) do
    version = Map.get(value, "association_version", 1)
    entries = Map.get(value, "indexed_embeddings")
    usage = Map.get(value, "usage", %{})

    cond do
      version != 1 ->
        {:invalid_fixture_shape, {:unsupported_embedding_association_version, version}}

      not is_list(entries) ->
        {:invalid_fixture_shape, :indexed_embeddings_list_required}

      not is_map(usage) ->
        {:invalid_fixture_shape, :embedding_usage_object_required}

      true ->
        indexed =
          Enum.map(entries, fn
            entry when is_map(entry) ->
              %{
                index: Map.get(entry, "index"),
                embedding: Map.get(entry, "embedding")
              }

            invalid ->
              invalid
          end)

        {:ok, indexed, deserialize_usage(usage)}
    end
  end

  defp deserialize_req_llm_response(value) when is_map(value) do
    required_keys = ["finish_reason", "response_kind", "text", "thinking", "tool_calls", "usage"]

    with :ok <- closed_map(value, required_keys),
         true <- value["response_kind"] == "req_llm" or {:error, :req_llm_response_required},
         {:ok, text} <- deserialize_response_string(value["text"], :text),
         {:ok, thinking} <- deserialize_response_strings(value["thinking"], :thinking),
         {:ok, tool_calls} <- deserialize_req_llm_tool_calls(value["tool_calls"]),
         {:ok, finish_reason} <- deserialize_finish_reason(value["finish_reason"]),
         usage when is_map(usage) <- deserialize_usage(value["usage"], :v2) do
      {:ok, build_req_llm_response(text, thinking, tool_calls, finish_reason, usage)}
    else
      {:error, reason} -> {:invalid_fixture_shape, reason}
      :invalid_usage -> {:invalid_fixture_shape, :complete_usage_required}
      _invalid -> {:invalid_fixture_shape, :req_llm_response_required}
    end
  end

  defp deserialize_req_llm_response(_value),
    do: {:invalid_fixture_shape, :req_llm_response_object_required}

  defp deserialize_legacy_response(json) when is_map(json) do
    text = Map.get(json, "text", "")
    content_parts = Map.get(json, "content_parts", [])
    finish_reason = Map.get(json, "finish_reason", "stop")
    reasoning_content = Map.get(json, "reasoning_content")

    with {:ok, text} <- deserialize_response_string(text, :text),
         {:ok, content, tool_calls} <- deserialize_legacy_content_parts(content_parts),
         {:ok, content} <- add_legacy_reasoning(content, reasoning_content),
         {:ok, content} <- add_legacy_text(content, text),
         {:ok, finish_reason} <- deserialize_legacy_finish_reason(finish_reason),
         usage when is_map(usage) <- deserialize_usage(Map.get(json, "usage", %{}), :legacy) do
      {:ok, build_req_llm_response(text, content, tool_calls, finish_reason, usage, true)}
    else
      :invalid_usage -> {:invalid_fixture_shape, :legacy_usage_required}
      {:error, reason} -> {:invalid_fixture_shape, reason}
      _invalid -> {:invalid_fixture_shape, :legacy_response_required}
    end
  end

  defp deserialize_legacy_response(_json),
    do: {:invalid_fixture_shape, :legacy_response_object_required}

  defp deserialize_legacy_content_parts(parts) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, [], []}, fn part, {:ok, content, tool_calls} ->
      case deserialize_legacy_content_part(part) do
        {:content, part} -> {:cont, {:ok, [part | content], tool_calls}}
        {:tool_call, tool_call} -> {:cont, {:ok, content, [tool_call | tool_calls]}}
        :ignore -> {:cont, {:ok, content, tool_calls}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, content, tool_calls} -> {:ok, Enum.reverse(content), Enum.reverse(tool_calls)}
      {:error, _reason} = error -> error
    end
  end

  defp deserialize_legacy_content_parts(_parts),
    do: {:error, :legacy_content_parts_list_required}

  defp deserialize_legacy_content_part(%{"kind" => "text", "text" => text}) do
    with {:ok, text} <- deserialize_response_string(text, :text) do
      {:content, ReqLLM.Message.ContentPart.text(text)}
    end
  end

  defp deserialize_legacy_content_part(%{"kind" => "thinking", "text" => text}) do
    with {:ok, text} <- deserialize_response_string(text, :thinking) do
      {:content, ReqLLM.Message.ContentPart.thinking(text)}
    end
  end

  defp deserialize_legacy_content_part(%{"kind" => "tool_call"} = part) do
    with {:ok, tool_call} <-
           deserialize_tool_call_fields(
             Map.get(part, "id"),
             Map.get(part, "name"),
             Map.get(part, "arguments", %{})
           ) do
      {:tool_call, tool_call}
    end
  end

  defp deserialize_legacy_content_part(%{"kind" => kind})
       when kind in ["image", "audio", "document", "tool_result"],
       do: :ignore

  defp deserialize_legacy_content_part(_part),
    do: {:error, :legacy_content_part_required}

  defp add_legacy_reasoning(content, reasoning) when is_binary(reasoning) and reasoning != "" do
    with {:ok, reasoning} <- deserialize_response_string(reasoning, :thinking) do
      if Enum.any?(content, &match?(%ReqLLM.Message.ContentPart{type: :thinking}, &1)),
        do: {:ok, content},
        else: {:ok, [ReqLLM.Message.ContentPart.thinking(reasoning) | content]}
    end
  end

  defp add_legacy_reasoning(content, nil), do: {:ok, content}
  defp add_legacy_reasoning(content, _reasoning), do: {:ok, content}

  defp add_legacy_text(content, text) do
    if text == "" or Enum.any?(content, &match?(%ReqLLM.Message.ContentPart{type: :text}, &1)),
      do: {:ok, content},
      else: {:ok, content ++ [ReqLLM.Message.ContentPart.text(text)]}
  end

  defp deserialize_req_llm_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      with :ok <- closed_map(call, ["arguments", "id", "name"]),
           {:ok, tool_call} <-
             deserialize_tool_call_fields(call["id"], call["name"], call["arguments"]) do
        {:cont, {:ok, [tool_call | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _invalid -> {:halt, {:error, :tool_call_required}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _reason} = error -> error
    end
  end

  defp deserialize_req_llm_tool_calls(_calls),
    do: {:error, :tool_calls_list_required}

  defp deserialize_tool_call_fields(id, name, arguments)
       when is_binary(id) and is_binary(name) do
    if is_json_term(arguments) do
      with {:ok, id} <- deserialize_response_string(id, :tool_call_id),
           {:ok, name} <- deserialize_response_string(name, :tool_call_name) do
        {:ok,
         %ReqLLM.ToolCall{
           id: id,
           type: "function",
           function: %{"name" => name, "arguments" => arguments}
         }}
      end
    else
      {:error, :tool_call_arguments_required}
    end
  end

  defp deserialize_tool_call_fields(_id, _name, _arguments),
    do: {:error, :tool_call_fields_required}

  defp deserialize_finish_reason(nil), do: {:ok, nil}

  defp deserialize_finish_reason(reason) when is_binary(reason),
    do: Map.fetch(@finish_reasons, reason)

  defp deserialize_finish_reason(_reason), do: {:error, :finish_reason_required}

  defp deserialize_legacy_finish_reason(nil), do: {:ok, nil}
  defp deserialize_legacy_finish_reason("other"), do: {:ok, :unknown}
  defp deserialize_legacy_finish_reason(reason), do: deserialize_finish_reason(reason)

  defp deserialize_response_string(value, _field)
       when is_binary(value) and byte_size(value) <= @max_response_string_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_response_string}
  end

  defp deserialize_response_string(_value, field),
    do: {:error, {:invalid_response_string, field}}

  defp deserialize_response_strings(values, field) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case deserialize_response_string(value, field) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp deserialize_response_strings(_values, field),
    do: {:error, {:invalid_response_strings, field}}

  defp closed_map(map, keys) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :closed_fixture_map_required}
  end

  defp closed_map(_map, _keys), do: {:error, :closed_fixture_map_required}

  defp build_req_llm_response(text, thinking, tool_calls, finish_reason, usage, legacy? \\ false)

  defp build_req_llm_response(text, thinking, tool_calls, finish_reason, usage, false)
       when is_binary(text) and is_list(thinking) do
    content = Enum.map(thinking, &ReqLLM.Message.ContentPart.thinking/1)
    content = if text == "", do: content, else: content ++ [ReqLLM.Message.ContentPart.text(text)]
    build_req_llm_response(text, content, tool_calls, finish_reason, usage, true)
  end

  defp build_req_llm_response(_text, content, tool_calls, finish_reason, usage, true) do
    %ReqLLM.Response{
      id: "fixture-replay",
      model: "fixture-replay",
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{role: :assistant, content: content, tool_calls: tool_calls},
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: %{},
      error: nil
    }
  end

  defp is_json_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp is_json_term(value) when is_list(value), do: Enum.all?(value, &is_json_term/1)

  defp is_json_term(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and is_json_term(v) end)

  defp is_json_term(_value), do: false

  defp deserialize_stream_event(%{"type" => type, "data" => data}) when is_map(data) do
    %StreamEvent{type: deserialize_stream_type(type), data: deserialize_stream_data(data)}
  end

  defp deserialize_stream_event(_event),
    do: %StreamEvent{type: :error, data: %{reason: :invalid_event}}

  defp deserialize_stream_type(type) do
    case type do
      "start" -> :start
      "delta" -> :delta
      "tool_call" -> :tool_call
      "step_finish" -> :step_finish
      "finish" -> :finish
      "error" -> :error
      _ -> :error
    end
  end

  defp deserialize_stream_data(data) do
    Map.new(data, fn {key, value} ->
      {stream_data_key(key), value}
    end)
  end

  defp stream_data_key("text"), do: :text
  defp stream_data_key("thinking"), do: :thinking
  defp stream_data_key("terminal?"), do: :terminal?
  defp stream_data_key("reason"), do: :reason
  defp stream_data_key(key), do: key

  defp deserialize_usage(usage) when is_map(usage), do: deserialize_usage(usage, :legacy)
  defp deserialize_usage(_usage), do: :invalid_usage

  defp deserialize_usage(usage, mode) when is_map(usage) and mode in [:v2, :legacy] do
    with :ok <- validate_usage_keys(usage, mode) do
      Enum.reduce_while(@usage_fields, %{}, fn {wire_key, atom_key}, acc ->
        case Map.fetch(usage, wire_key) do
          :error ->
            {:cont, acc}

          {:ok, nil} ->
            {:cont, acc}

          {:ok, value} ->
            case bounded_usage_value(atom_key, value) do
              {:ok, value} -> {:cont, Map.put(acc, atom_key, value)}
              :error -> {:halt, :invalid_usage}
            end
        end
      end)
    else
      :invalid_usage -> :invalid_usage
    end
  end

  defp deserialize_usage(_usage, _mode), do: :invalid_usage

  defp validate_usage_keys(_usage, :legacy), do: :ok

  defp validate_usage_keys(usage, :v2) do
    allowed = Enum.map(@usage_fields, &elem(&1, 0))

    if Enum.all?(Map.keys(usage), &is_binary/1) and
         Enum.all?(Map.keys(usage), &(&1 in allowed)),
       do: :ok,
       else: :invalid_usage
  end

  defp validate_replay(
         %Call{operation: op, request: {_model, texts, _opts}},
         {:ok, indexed, usage}
       )
       when op in [:embed_cloud, :embed_local] and is_list(texts) do
    case Boundary.embedding_response_with_indices(
           %{indexed_embeddings: indexed, usage: usage},
           length(texts)
         ) do
      {:ok, authoritative, validated_usage} -> {:ok, {:ok, authoritative, validated_usage}}
      {:error, reason} -> {:error, {:invalid_embedding_fixture, reason}}
    end
  end

  defp validate_replay(
         %Call{operation: op, request: {_model, texts, _opts}},
         {:legacy_positional_embeddings, vectors, usage}
       )
       when op in [:embed_cloud, :embed_local] and is_list(texts) do
    if length(texts) == 1 do
      case Boundary.embedding_response_with_indices(
             %{embeddings: vectors, usage: usage},
             1
           ) do
        {:ok, authoritative, validated_usage} ->
          {:ok, {:ok, authoritative, validated_usage}}

        {:error, reason} ->
          {:error, {:invalid_embedding_fixture, reason}}
      end
    else
      {:error, {:invalid_embedding_fixture, :ambiguous_legacy_positional_embeddings}}
    end
  end

  defp validate_replay(%Call{operation: op}, {:invalid_fixture_shape, reason})
       when op in [:embed_cloud, :embed_local],
       do: {:error, {:invalid_embedding_fixture, external_reason(reason)}}

  defp validate_replay(%Call{}, {:invalid_fixture_shape, reason}),
    do: {:error, {:invalid_fixture_shape, external_reason(reason)}}

  defp validate_replay(%Call{}, response), do: {:ok, response}

  defp safe_deserialize(op, schema_version, response) do
    {:ok, deserialize(op, schema_version, response)}
  rescue
    exception -> {:error, {:fixture_decode_exception, external_exception(exception)}}
  catch
    kind, reason -> {:error, {:fixture_decode_failure, kind, external_reason(reason)}}
  end

  defp fixture_error(reason), do: {:error, {:invalid_fixture, external_reason(reason)}}
  defp external_reason(reason), do: Arbor.LLM.sanitize_external_reason(reason)
  defp external_exception(exception), do: Arbor.LLM.sanitize_external_exception(exception)

  # ── Request summaries (informational only) ─────────────────────────

  defp summarize_request(op, {model_spec, inputs, opts}) do
    %{
      "operation" => Atom.to_string(op),
      "model" => Arbor.LLM.inspect_external_reason(model_spec),
      "input_count" => bounded_list_count(inputs, 0),
      "option_keys" => bounded_option_keys(opts, [], 0)
    }
  end

  defp summarize_request(op, request) do
    %{
      "operation" => Atom.to_string(op),
      "request" => Arbor.LLM.inspect_external_reason(request)
    }
  end

  defp bounded_list_count([], count), do: count
  defp bounded_list_count(_list, count) when count >= 2_048, do: "2048+"
  defp bounded_list_count([_head | tail], count), do: bounded_list_count(tail, count + 1)
  defp bounded_list_count(_improper, _count), do: "invalid"

  defp bounded_option_keys([], acc, _count), do: Enum.reverse(acc)
  defp bounded_option_keys(_opts, acc, count) when count >= 128, do: Enum.reverse(acc)

  defp bounded_option_keys([{key, _value} | rest], acc, count) when is_atom(key),
    do: bounded_option_keys(rest, [Atom.to_string(key) | acc], count + 1)

  defp bounded_option_keys(_invalid, acc, _count), do: Enum.reverse(acc)
end
