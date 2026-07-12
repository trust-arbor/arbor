defmodule Arbor.LLM.Plugs.Fixture do
  @moduledoc """
  Shared fixture I/O for the `Replay` and `Record` plugs.

  Not itself a plug — these are pure functions both plugs use.
  Centralizes:

    * Where fixtures live on disk (configurable, with a sensible
      umbrella-aware default)
    * The SHA-256 hash that keys each fixture
    * The JSON serialize/deserialize round-trip for `Arbor.LLM.Call`
      results (chat completions, streams, embeddings, errors)

  ## Fixture format

      {
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

  Streaming recording accepts eager event lists and `Arbor.LLM.OwnedStream`.
  Generic lazy enumerables are rejected without enumeration because they have no
  cancellation/finalization protocol when a producer callback stops returning.
  """

  alias Arbor.LLM.Call
  alias Arbor.LLM.Boundary
  alias Arbor.LLM.Deadline
  alias Arbor.LLM.OwnedStream
  alias Arbor.LLM.Response
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
         {:ok, recorded_at, _} <- DateTime.from_iso8601(decoded["recorded_at"] || ""),
         {:ok, deserialized} <- safe_deserialize(op, decoded["response"]),
         {:ok, response} <- validate_replay(call, deserialized) do
      {:ok, response, recorded_at}
    else
      {:error, {:invalid_embedding_fixture, _reason} = reason} -> {:error, reason}
      {:error, reason} -> fixture_error(reason)
      _invalid -> fixture_error(:invalid_fixture_shape)
    end
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

  # ── Serialization (Arbor result shape → JSON-safe shape) ───────────

  defp prepare_serialization(:complete, {:ok, %Response{} = resp} = result, _opts, _receipt) do
    {:ok, %{"outcome" => "ok", "value" => serialize_response(resp)}, result}
  end

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

  defp prepare_serialization(_op, other, _opts, _receipt),
    do: {:ok, %{"outcome" => "raw", "raw" => Arbor.LLM.inspect_external_reason(other)}, other}

  defp serialize_response(%Response{} = r) do
    %{
      "text" => r.text,
      "finish_reason" => r.finish_reason,
      "content_parts" => r.content_parts,
      "usage" => r.usage,
      "warnings" => r.warnings
      # NOTE: `:raw` deliberately omitted — it holds the upstream
      # ReqLLM.Response struct, which round-trips poorly to JSON.
      # Replayed responses have raw: nil.
    }
  end

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

  # ── Deserialization (JSON shape → Arbor result shape) ──────────────

  defp deserialize(_op, %{"outcome" => "error", "reason" => reason}) do
    {:error, {:replayed_error, external_reason(reason)}}
  end

  defp deserialize(:complete, %{"outcome" => "ok", "value" => json}) do
    {:ok, deserialize_response(json)}
  end

  defp deserialize(:stream, %{"outcome" => "ok", "value" => %{"events" => events}}) do
    {:ok, Enum.map(events, &deserialize_stream_event/1)}
  end

  defp deserialize(op, %{"outcome" => "ok", "value" => v})
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

  defp deserialize(op, %{"outcome" => "ok"}) when op in [:embed_cloud, :embed_local],
    do: {:invalid_fixture_shape, :embedding_value_object_required}

  defp deserialize(_op, _response), do: {:invalid_fixture_shape, :known_outcome_required}

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

  defp deserialize_response(json) do
    %Response{
      text: json["text"] || "",
      finish_reason: safe_atom(json["finish_reason"] || "stop", :stop),
      content_parts: (json["content_parts"] || []) |> Enum.map(&deserialize_content_part/1),
      usage: deserialize_usage(json["usage"] || %{}),
      warnings: json["warnings"] || [],
      raw: nil
    }
  end

  defp deserialize_content_part(part) when is_map(part) do
    atomized = Map.new(part, fn {k, v} -> {safe_atom(k, k), v} end)

    # `kind` is the discriminator — downstream code pattern-matches on
    # the atom (e.g. `case part.kind do :text -> ...`). Atom-ize it on
    # the way back so replay results match the live shape.
    case Map.get(atomized, :kind) do
      kind when is_binary(kind) -> Map.put(atomized, :kind, safe_atom(kind, kind))
      _ -> atomized
    end
  end

  defp deserialize_stream_event(%{"type" => type, "data" => data}) do
    %StreamEvent{
      type: safe_atom(type, :delta),
      data: Map.new(data, fn {k, v} -> {safe_atom(k, k), v} end)
    }
  end

  defp deserialize_usage(usage) when is_map(usage) do
    Map.new(usage, fn {k, v} -> {safe_atom(k, k), v} end)
  end

  defp deserialize_usage(_usage), do: :invalid_usage

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

  defp safe_deserialize(op, response) do
    {:ok, deserialize(op, response)}
  rescue
    exception -> {:error, {:fixture_decode_exception, external_exception(exception)}}
  catch
    kind, reason -> {:error, {:fixture_decode_failure, kind, external_reason(reason)}}
  end

  defp fixture_error(reason), do: {:error, {:invalid_fixture, external_reason(reason)}}
  defp external_reason(reason), do: Arbor.LLM.sanitize_external_reason(reason)
  defp external_exception(exception), do: Arbor.LLM.sanitize_external_exception(exception)

  defp safe_atom(s, fallback) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> fallback
  end

  defp safe_atom(other, _fallback), do: other

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
