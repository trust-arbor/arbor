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
  """

  alias Arbor.LLM.Call
  alias Arbor.LLM.Response
  alias Arbor.LLM.StreamEvent

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
          {:ok, term(), DateTime.t()} | :not_found
  def load(%Call{operation: op} = call) do
    path = path_for(call)

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, recorded_at, _} <- DateTime.from_iso8601(decoded["recorded_at"] || "") do
      {:ok, deserialize(op, decoded["response"]), recorded_at}
    else
      _ -> :not_found
    end
  end

  @doc """
  Persist `result` as a fixture for `call`.
  """
  @spec save(Call.t(), term()) :: :ok
  def save(%Call{operation: op} = call, result) do
    path = path_for(call)
    File.mkdir_p!(Path.dirname(path))

    fixture = %{
      "operation" => Atom.to_string(op),
      "request_hash" => request_hash(call),
      "request_summary" => summarize_request(op, call.request),
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "response" => serialize(op, result)
    }

    File.write!(path, Jason.encode!(fixture, pretty: true))
    :ok
  end

  # ── Serialization (Arbor result shape → JSON-safe shape) ───────────

  defp serialize(:complete, {:ok, %Response{} = resp}) do
    %{"outcome" => "ok", "value" => serialize_response(resp)}
  end

  defp serialize(:stream, {:ok, enum}) do
    events = enum |> Enum.to_list() |> Enum.map(&serialize_stream_event/1)
    %{"outcome" => "ok", "value" => %{"events" => events}}
  end

  defp serialize(op, {:ok, embeddings, usage})
       when op in [:embed_cloud, :embed_local] and is_list(embeddings) do
    %{
      "outcome" => "ok",
      "value" => %{
        "embeddings" => embeddings,
        "usage" => serialize_usage(usage || %{})
      }
    }
  end

  defp serialize(_op, {:error, reason}),
    do: %{"outcome" => "error", "reason" => inspect(reason)}

  defp serialize(_op, other),
    do: %{"outcome" => "raw", "raw" => inspect(other)}

  defp serialize_response(%Response{} = r) do
    %{
      "text" => r.text,
      "finish_reason" => Atom.to_string(r.finish_reason),
      "content_parts" => Enum.map(r.content_parts, &serialize_map/1),
      "usage" => serialize_usage(r.usage),
      "warnings" => r.warnings
      # NOTE: `:raw` deliberately omitted — it holds the upstream
      # ReqLLM.Response struct, which round-trips poorly to JSON.
      # Replayed responses have raw: nil.
    }
  end

  defp serialize_stream_event(%StreamEvent{type: type, data: data}) do
    %{
      "type" => Atom.to_string(type),
      "data" => serialize_map(data)
    }
  end

  defp serialize_stream_event(other), do: stringify(other)

  defp serialize_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp serialize_usage(usage) when is_map(usage), do: serialize_map(usage)
  defp serialize_usage(other), do: stringify(other)

  defp stringify(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp stringify(v) when is_list(v), do: Enum.map(v, &stringify/1)
  defp stringify(v) when is_map(v) and not is_struct(v), do: serialize_map(v)
  defp stringify(v), do: inspect(v)

  # ── Deserialization (JSON shape → Arbor result shape) ──────────────

  defp deserialize(_op, %{"outcome" => "error", "reason" => reason}) do
    {:error, {:replayed_error, reason}}
  end

  defp deserialize(:complete, %{"outcome" => "ok", "value" => json}) do
    {:ok, deserialize_response(json)}
  end

  defp deserialize(:stream, %{"outcome" => "ok", "value" => %{"events" => events}}) do
    {:ok, Enum.map(events, &deserialize_stream_event/1)}
  end

  defp deserialize(op, %{"outcome" => "ok", "value" => v})
       when op in [:embed_cloud, :embed_local] do
    {:ok, v["embeddings"], deserialize_usage(v["usage"] || %{})}
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
    Map.new(part, fn {k, v} -> {safe_atom(k, k), v} end)
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

  defp safe_atom(s, fallback) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> fallback
  end

  defp safe_atom(other, _fallback), do: other

  # ── Request summaries (informational only) ─────────────────────────

  defp summarize_request(:complete, {model_spec, messages, opts}) do
    %{
      "model" => describe_model_spec(model_spec),
      "messages" => Enum.map(messages, &summarize_message/1),
      "opts" => summarize_opts(opts)
    }
  end

  defp summarize_request(:stream, req), do: summarize_request(:complete, req)

  defp summarize_request(op, {model_spec, texts, opts}) when op in [:embed_cloud, :embed_local] do
    %{
      "model" => describe_model_spec(model_spec),
      "texts" => texts,
      "opts" => summarize_opts(opts)
    }
  end

  defp describe_model_spec(%LLMDB.Model{} = m), do: "#{m.provider}:#{m.id}"
  defp describe_model_spec(spec) when is_binary(spec), do: spec

  defp summarize_message(%ReqLLM.Message{role: role, content: content}) do
    %{"role" => Atom.to_string(role), "content" => stringify(content)}
  end

  defp summarize_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => stringify(content)}
  end

  defp summarize_message(other), do: stringify(other)

  defp summarize_opts(opts) when is_list(opts) do
    opts
    |> scrub_opts()
    |> Map.new(fn {k, v} -> {Atom.to_string(k), stringify(v)} end)
  end

  defp summarize_opts(opts), do: stringify(opts)
end
