defmodule Arbor.LLM.OAuth.Responses do
  @moduledoc """
  The OpenAI **Responses API** wire layer (streaming SSE) against the ChatGPT/Codex + xAI/Grok
  SUBSCRIPTION backends, authenticated with a subscription OAuth token from `Arbor.LLM.OAuth`
  (which hard-refuses Anthropic). Used by `Arbor.LLM.Adapter.OAuthResponses` so an Arbor agent can
  run on a flat subscription instead of a metered API key.

  Supports **tool calling**: the caller supplies pre-built Responses `input` items + `tools`, and
  `complete/3` returns `{:ok, %{text, tool_calls}}` where each tool call is `%{id, name, arguments}`
  (arguments decoded to a map). The subscription backends REQUIRE `stream: true`; we buffer the SSE
  and read text from `response.output_text.delta` deltas and tool calls from the final
  `response.completed` event's `response.output`.
  """

  alias Arbor.LLM.{Deadline, Endpoint, OAuth, Response, ResponseBudget}
  alias Arbor.LLM.OAuth.{CredentialReceipt, ResponsesFailure}

  @max_response_bytes 16_777_216
  @max_events 100_000
  @max_event_bytes 1_048_576
  @max_work 1_600_000
  @max_nodes 100_000
  @max_depth 32
  @max_map_keys 10_000
  @max_list_items 100_000
  @max_timeout 900_000
  @max_error_json_bytes 16_384
  @max_error_code_bytes 128
  @max_terminal_model_bytes 512
  @max_token_count 1_000_000_000
  @max_json_safe_integer 9_007_199_254_740_991

  @xai_terminal_usage_fields [
    "context_details",
    "cost_in_usd_ticks",
    "num_server_side_tools_used",
    "num_sources_used"
  ]

  # The closed set of structured provider error codes that may classify an xAI 403 as
  # subscription tier denial. Matched by EXACT equality on a parsed JSON field — never by
  # substring, regex, or a generic 403. Extend only with a real observed code.
  @xai_tier_codes ["tier_denied", "subscription_tier_denied", "xai_oauth_tier_denied"]

  @error_json_limits [
    max_bytes: @max_error_json_bytes,
    max_nodes: 512,
    max_depth: 8,
    max_map_keys: 128,
    max_list_items: 128
  ]

  @no_identity %{route: nil, backend: nil}

  @endpoints %{
    openai: "https://chatgpt.com/backend-api/codex/responses",
    xai: "https://api.x.ai/v1/responses"
  }

  @default_models %{openai: "gpt-5.6-sol", xai: "grok-4.5"}

  @doc """
  `complete(provider, %{instructions, input, tools}, opts)` → `{:ok, %{text, tool_calls}}`.

  `input` is a fully-built Responses input list, `tools` a Responses tools list (or nil). Options:
  `:model`, `:receive_timeout`. `provider` is resolved against `OAuth.route/1`'s exact closed
  table: the two route IDs plus the two bare backend keys. Anthropic is refused there, and
  `grok` / `codex` / `chatgpt` / unknown names are rejected rather than defaulted to OpenAI.
  """
  @spec complete(atom() | String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(provider, req, opts \\ [])

  def complete(provider, %{} = req, opts) do
    with {:ok, limits} <- build_limits(opts),
         {:ok, identity} <- resolve_identity(provider),
         {:ok, receipt} <- Deadline.receipt(timeout_ms: limits.timeout) do
      Deadline.run(
        fn -> do_complete(identity, req, opts, limits) end,
        receipt,
        ResponsesFailure.transport(identity.route, identity.backend, :deadline_exceeded)
      )
    end
  end

  def complete(_provider, _req, _opts), do: {:error, :invalid_responses_request}

  @doc """
  Single-attempt complete: identical to `complete/3` except source-token 401
  reread/retry is disabled. Private single-attempt policy only — not generic opts.
  """
  @spec complete_single_attempt(atom() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete_single_attempt(provider, req, opts \\ [])

  def complete_single_attempt(provider, %{} = req, opts) do
    with {:ok, limits} <- build_limits(opts),
         {:ok, identity} <- resolve_identity(provider),
         {:ok, receipt} <- Deadline.receipt(timeout_ms: limits.timeout) do
      Deadline.run(
        fn -> do_complete(identity, req, opts, limits, true) end,
        receipt,
        ResponsesFailure.transport(identity.route, identity.backend, :deadline_exceeded)
      )
    end
  end

  def complete_single_attempt(_provider, _req, _opts), do: {:error, :invalid_responses_request}

  # Exact closed resolution only. A bare backend key keeps `route: nil` so it never
  # advertises a route identity it does not have.
  defp resolve_identity(provider) do
    with {:ok, %{route: route, backend: backend}} <- OAuth.route(provider) do
      {:ok, %{route: route, backend: backend}}
    end
  end

  defp do_complete(identity, req, opts, limits, single_attempt? \\ false) do
    with :ok <- ResponseBudget.validate(req, request_limits()),
         {:ok, credential} <- OAuth.credential_receipt(identity.backend) do
      sid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      body = build_body(Keyword.get(opts, :model) || @default_models[identity.backend], req)

      request_with_credential(identity, credential, sid, body, limits, single_attempt?)
    end
  end

  defp request_with_credential(identity, credential, sid, body, limits, single_attempt?) do
    result = request_identity(identity, credential, sid, body, limits)

    case {result, credential, single_attempt?} do
      {{:error, %ResponsesFailure{class: :auth, status: 401}},
       %CredentialReceipt{provider: :openai, owner: "source_owned"} = used, false} ->
        retry_source_once(identity, used, sid, body, limits)

      _ ->
        result
    end
  end

  defp retry_source_once(identity, used, sid, body, limits) do
    with {:ok, latest} <- OAuth.reread_source_credential(used) do
      case request_identity(identity, latest, sid, body, limits) do
        {:error, %ResponsesFailure{class: :auth, status: 401}} ->
          {:error, :oauth_source_reauthentication_required}

        result ->
          result
      end
    else
      {:error, _reason} -> {:error, :oauth_source_reauthentication_required}
    end
  end

  defp request_identity(identity, credential, sid, body, limits) do
    request_sse(
      response_endpoint(identity.backend),
      headers(identity.backend, credential, sid),
      body,
      limits,
      identity
    )
  end

  defp response_endpoint(key) do
    case Application.get_env(:arbor_llm, :oauth_response_endpoints) do
      %{} = configured -> Map.get(configured, key) || Map.get(configured, Atom.to_string(key))
      _ -> nil
    end || @endpoints[key]
  end

  @doc false
  def request_sse(url, headers, body, opts_or_limits, identity \\ @no_identity) do
    with {:ok, identity} <- normalize_identity(identity),
         {:ok, limits} <- normalize_limits(opts_or_limits),
         {:ok, receipt} <- Deadline.receipt(timeout_ms: limits.timeout),
         {:ok, canonical_url} <- Endpoint.validate(url, :oauth_responses) do
      limits = Map.put(limits, :deadline_ms, receipt.deadline_ms)

      Deadline.run(
        fn -> do_request_sse(canonical_url, headers, body, limits, identity) end,
        receipt,
        ResponsesFailure.transport(identity.route, identity.backend, :deadline_exceeded)
      )
    end
  end

  # No fabricated identity: allowed pairs are validated; mismatched or malformed
  # identity returns a bounded, non-retryable protocol failure.
  defp normalize_identity(%{route: :openai_oauth, backend: :openai}),
    do: {:ok, %{route: :openai_oauth, backend: :openai}}

  defp normalize_identity(%{route: :xai_oauth, backend: :xai}),
    do: {:ok, %{route: :xai_oauth, backend: :xai}}

  defp normalize_identity(%{route: nil, backend: :openai}),
    do: {:ok, %{route: nil, backend: :openai}}

  defp normalize_identity(%{route: nil, backend: :xai}),
    do: {:ok, %{route: nil, backend: :xai}}

  defp normalize_identity(%{route: nil, backend: nil}), do: {:ok, @no_identity}

  defp normalize_identity(_identity),
    do: {:error, ResponsesFailure.protocol(nil, nil, :invalid_stream)}

  @doc """
  Convenience for the simple text path (no tools): `messages` is `[%{role, content}]`.
  Returns `{:ok, text}`.
  """
  @spec complete_text(atom() | String.t(), [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def complete_text(provider, messages, opts \\ []) do
    with :ok <- validate_text_messages(messages) do
      instructions =
        messages |> Enum.filter(&(&1.role == :system)) |> Enum.map_join("\n\n", & &1.content)

      input =
        messages
        |> Enum.reject(&(&1.role == :system))
        |> Enum.map(fn m ->
          %{
            "role" => to_string(m.role),
            "content" => [%{"type" => "input_text", "text" => m.content}]
          }
        end)

      case complete(provider, %{instructions: instructions, input: input, tools: nil}, opts) do
        {:ok, %{text: text}} -> {:ok, text}
        err -> err
      end
    end
  end

  defp validate_text_messages(messages) do
    with :ok <- ResponseBudget.validate(messages, request_limits()) do
      validate_text_message_list(messages)
    end
  end

  defp validate_text_message_list([]), do: :ok

  defp validate_text_message_list([%{role: role, content: content} | rest])
       when (is_atom(role) or is_binary(role)) and is_binary(content),
       do: validate_text_message_list(rest)

  defp validate_text_message_list(_improper_or_invalid),
    do: {:error, :bounded_text_messages_required}

  defp request_limits do
    [
      max_bytes: @max_response_bytes,
      max_nodes: @max_nodes,
      max_depth: @max_depth,
      max_map_keys: @max_map_keys,
      max_list_items: @max_list_items
    ]
  end

  # store:false, stream:true (required by the subscription backends). tools only when present.
  defp build_body(model, req) do
    base = %{
      "model" => model,
      "instructions" => req[:instructions] || "",
      "input" => req[:input] || [],
      "store" => false,
      "stream" => true
    }

    case req[:tools] do
      tools when is_list(tools) and tools != [] ->
        Map.merge(base, %{
          "tools" => tools,
          "tool_choice" => "auto",
          "parallel_tool_calls" => true
        })

      _ ->
        base
    end
  end

  # Codex backend needs the Cloudflare-whitelisting headers + account-id (else 403); xAI a conv-id.
  defp headers(:openai, %CredentialReceipt{} = credential, sid) do
    [
      {"authorization", "Bearer " <> credential.access_token},
      {"user-agent", "codex_cli_rs/0.0.0 (Arbor)"},
      {"originator", "codex_cli_rs"},
      {"chatgpt-account-id", credential.account_id || ""},
      {"session_id", sid},
      {"x-client-request-id", sid}
    ]
  end

  defp headers(:xai, %CredentialReceipt{} = credential, sid) do
    [{"authorization", "Bearer " <> credential.access_token}, {"x-grok-conv-id", sid}]
  end

  @doc false
  def parse_sse(raw, opts_or_limits \\ [])

  def parse_sse(raw, opts_or_limits) when is_binary(raw) do
    parse_sse(raw, opts_or_limits, @no_identity)
  end

  def parse_sse(_raw, _opts_or_limits), do: {:error, :binary_sse_required}

  defp parse_sse(raw, opts_or_limits, identity) when is_binary(raw) do
    with {:ok, limits} <- normalize_limits(opts_or_limits),
         true <-
           byte_size(raw) <= limits.max_response_bytes or
             {:error, {:response_bytes_exceeded, limits.max_response_bytes}},
         true <- String.valid?(raw) or {:error, :valid_utf8_sse_required},
         {:ok, state} <- parse_sse_lines(raw, new_parser_state(limits, identity.backend)),
         {:ok, state} <- finish_sse_event(state) do
      {:ok,
       %{
         text: state.text_chunks |> Enum.reverse() |> IO.iodata_to_binary(),
         tool_calls: Enum.reverse(state.tool_calls),
         provider_model: state.provider_model,
         usage: state.usage,
         terminal_seen: state.terminal_seen
       }}
    end
  end

  # Every error escaping this function is a route-aware ResponsesFailure. Granular reasons stay
  # inside parse_sse/2 for its direct callers; they are DISCARDED here rather than wrapped,
  # because they can embed decoded response fragments.
  defp do_request_sse(url, headers, body, limits, identity) do
    into = bounded_sse_receipt(limits)

    case Req.post(url,
           headers: headers,
           json: body,
           receive_timeout: max(limits.deadline_ms - System.monotonic_time(:millisecond), 1),
           redirect: false,
           compressed: false,
           decode_body: false,
           into: into
         ) do
      {:ok, %Req.Response{private: %{arbor_oauth_response_error: reason}}} ->
        {:error, classify_halt(reason, identity)}

      {:ok, %Req.Response{status: 200} = response} ->
        with :ok <- identity_content_encoding(response),
             :ok <- event_stream_content_type(response, identity),
             {:ok, raw} <- collected_body(response, limits.max_response_bytes),
             {:ok, parsed} <- parse_sse(raw, limits, identity),
             {:ok, result} <- stamp_provider_receipt(parsed, identity) do
          {:ok, result}
        else
          {:error, reason} -> {:error, classify_stream_reason(reason, identity)}
        end

      {:ok, %Req.Response{status: status} = response} ->
        case collected_body(response, limits.max_response_bytes) do
          {:ok, raw} ->
            {:error, classify_status(status, raw, response, identity)}

          {:error, reason} ->
            {:error, classify_stream_reason(reason, identity)}
        end

      {:error, _reason} ->
        {:error, transport_failure(identity, :connection_failed)}
    end
  rescue
    _exception ->
      {:error, protocol_failure(identity, :invalid_stream)}
  catch
    _kind, _reason ->
      {:error, protocol_failure(identity, :invalid_stream)}
  end

  defp transport_failure(identity, code),
    do: ResponsesFailure.transport(identity.route, identity.backend, code)

  defp protocol_failure(identity, code),
    do: ResponsesFailure.protocol(identity.route, identity.backend, code)

  defp classify_halt({:responses_deadline_exceeded, _timeout}, identity),
    do: transport_failure(identity, :deadline_exceeded)

  defp classify_halt({:response_bytes_exceeded, _maximum}, identity),
    do: protocol_failure(identity, :response_bytes_exceeded)

  defp classify_halt(_reason, identity), do: transport_failure(identity, :connection_failed)

  defp classify_stream_reason(reason, identity)
       when reason in [:identity_content_encoding_required, :event_stream_content_type_required],
       do: protocol_failure(identity, :invalid_response_headers)

  defp classify_stream_reason({:response_bytes_exceeded, _maximum}, identity),
    do: protocol_failure(identity, :response_bytes_exceeded)

  defp classify_stream_reason(_reason, identity),
    do: protocol_failure(identity, :invalid_stream)

  defp classify_status(status, raw, response, identity) do
    ResponsesFailure.from_status(identity.route, identity.backend, status,
      tier_denied?: xai_tier_denied?(status, raw, identity),
      retry_after_ms: retry_after_ms(status, response)
    )
  end

  # Tier denial requires an EXPLICITLY parsed, allow-listed structured error code on an xAI 403.
  # Never a substring scan, never a generic 403, never any other backend.
  defp xai_tier_denied?(403, raw, %{backend: :xai}) when is_binary(raw) do
    byte_size(raw) <= @max_error_json_bytes and allow_listed_error_code?(raw)
  end

  defp xai_tier_denied?(_status, _raw, _identity), do: false

  defp allow_listed_error_code?(raw) do
    case ResponseBudget.decode_json(raw, @error_json_limits) do
      {:ok, %{} = json} -> structured_error_code(json) in @xai_tier_codes
      _ -> false
    end
  end

  # Only the boolean escapes; neither the body nor the decoded term is retained, and the code
  # that reaches the failure struct is our own atom constant, not the parsed string.
  defp structured_error_code(json) do
    code =
      case json do
        %{"error" => %{"code" => code}} -> code
        %{"code" => code} -> code
        _ -> nil
      end

    if is_binary(code) and byte_size(code) <= @max_error_code_bytes, do: code, else: nil
  end

  # Read from the response HEADER only, never the body, and only where a wait hint is meaningful.
  defp retry_after_ms(status, response) when status in [429, 503] do
    case Req.Response.get_header(response, "retry-after") do
      [value] when is_binary(value) -> bounded_retry_after_seconds(value)
      _ -> nil
    end
  end

  defp retry_after_ms(_status, _response), do: nil

  defp bounded_retry_after_seconds(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 and seconds <= 86_400 -> seconds * 1_000
      _ -> nil
    end
  end

  defp bounded_sse_receipt(limits) do
    fn {:data, data}, {request, response} when is_binary(data) ->
      retained = Map.get(response.private, :arbor_oauth_response_bytes, 0)

      cond do
        System.monotonic_time(:millisecond) >= limits.deadline_ms ->
          halt_receipt(request, response, {:responses_deadline_exceeded, limits.timeout})

        byte_size(data) > limits.max_response_bytes - retained ->
          halt_receipt(
            request,
            response,
            {:response_bytes_exceeded, limits.max_response_bytes}
          )

        true ->
          private =
            response.private
            |> Map.update(:arbor_oauth_response_chunks, [data], &[data | &1])
            |> Map.put(:arbor_oauth_response_bytes, retained + byte_size(data))

          {:cont, {request, %{response | body: "", private: private}}}
      end
    end
  end

  defp halt_receipt(request, response, reason) do
    private = Map.put(response.private, :arbor_oauth_response_error, reason)
    {:halt, {%{request | halted: true}, %{response | body: "", private: private}}}
  end

  defp collected_body(%Req.Response{private: %{arbor_oauth_response_chunks: chunks}}, maximum)
       when is_list(chunks) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    if byte_size(body) <= maximum,
      do: {:ok, body},
      else: {:error, {:response_bytes_exceeded, maximum}}
  end

  defp collected_body(%Req.Response{body: body}, maximum) when is_binary(body) do
    if byte_size(body) <= maximum,
      do: {:ok, body},
      else: {:error, {:response_bytes_exceeded, maximum}}
  end

  defp collected_body(_response, _maximum), do: {:error, :binary_response_body_required}

  defp new_parser_state(limits, backend) do
    %{
      limits: limits,
      backend: backend,
      data_parts: [],
      event_bytes: 0,
      event_count: 0,
      work: 0,
      decoded_nodes: 0,
      decoded_bytes: 0,
      decoded_map_keys: 0,
      decoded_list_items: 0,
      text_chunks: [],
      text_bytes: 0,
      tool_calls: [],
      provider_model: nil,
      usage: %{},
      terminal_seen: false
    }
  end

  defp parse_sse_lines("", state), do: {:ok, state}

  defp parse_sse_lines(body, state) do
    case :binary.match(body, "\n") do
      :nomatch ->
        process_sse_line(strip_cr(body), state)

      {index, 1} ->
        line = body |> binary_part(0, index) |> strip_cr()
        rest = binary_part(body, index + 1, byte_size(body) - index - 1)

        with {:ok, state} <- process_sse_line(line, state) do
          parse_sse_lines(rest, state)
        end
    end
  end

  defp process_sse_line(line, state) do
    with {:ok, state} <- add_work(state, 1) do
      cond do
        line == "" -> finish_sse_event(state)
        String.starts_with?(line, ":") -> {:ok, state}
        String.starts_with?(line, "data:") -> append_sse_data(line, state)
        String.starts_with?(line, "event:") -> {:ok, state}
        String.starts_with?(line, "id:") -> {:ok, state}
        String.starts_with?(line, "retry:") -> {:ok, state}
        true -> {:error, :invalid_sse_field}
      end
    end
  end

  defp append_sse_data("data:" <> value, state) do
    value =
      if String.starts_with?(value, " "),
        do: binary_part(value, 1, byte_size(value) - 1),
        else: value

    bytes = state.event_bytes + byte_size(value) + if(state.data_parts == [], do: 0, else: 1)

    if bytes <= state.limits.max_event_bytes do
      {:ok, %{state | data_parts: [value | state.data_parts], event_bytes: bytes}}
    else
      {:error, {:stream_limit_exceeded, :event_bytes, state.limits.max_event_bytes}}
    end
  end

  defp finish_sse_event(%{data_parts: []} = state), do: {:ok, state}

  defp finish_sse_event(state) do
    event_count = state.event_count + 1

    if event_count > state.limits.max_events do
      {:error, {:stream_limit_exceeded, :events, state.limits.max_events}}
    else
      data = state.data_parts |> Enum.reverse() |> Enum.intersperse("\n") |> IO.iodata_to_binary()
      state = %{state | data_parts: [], event_bytes: 0, event_count: event_count}

      if data == "[DONE]" do
        {:ok, state}
      else
        decode_sse_event(data, state)
      end
    end
  end

  defp decode_sse_event(data, state) do
    limits = json_limits(state.limits, state.limits.max_event_bytes)

    with {:ok, preflight} <- ResponseBudget.preflight_json(data, limits),
         {:ok, state} <- charge_measurements(state, preflight),
         {:ok, decoded, retained} <-
           ResponseBudget.decode_json_source_with_measurements(data, limits),
         {:ok, state} <- charge_measurements(state, measurement_delta(retained, preflight)),
         {:ok, state} <- retain_response_event(decoded, state) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:invalid_responses_event, reason}}
    end
  end

  defp retain_response_event(
         %{"type" => "response.output_text.delta", "delta" => delta},
         state
       )
       when is_binary(delta) do
    bytes = state.text_bytes + byte_size(delta)

    cond do
      not String.valid?(delta) ->
        {:error, :valid_utf8_delta_required}

      bytes > state.limits.max_response_bytes ->
        {:error, {:stream_limit_exceeded, :output_bytes, state.limits.max_response_bytes}}

      true ->
        {:ok, %{state | text_chunks: [delta | state.text_chunks], text_bytes: bytes}}
    end
  end

  defp retain_response_event(
         %{
           "type" => "response.output_item.done",
           "item" => %{"type" => "function_call"} = item
         },
         state
       ) do
    with {:ok, tool_call, measurements} <- tool_call_from_item(item),
         {:ok, state} <- charge_measurements(state, measurements) do
      {:ok, %{state | tool_calls: [tool_call | state.tool_calls]}}
    end
  end

  defp retain_response_event(
         %{"type" => "response.completed", "response" => response},
         %{terminal_seen: false} = state
       )
       when is_map(response) do
    with {:ok, provider_model} <- terminal_model(response),
         {:ok, usage} <- terminal_usage(response, state.backend) do
      {:ok, %{state | provider_model: provider_model, usage: usage, terminal_seen: true}}
    end
  end

  defp retain_response_event(%{"type" => "response.completed"}, %{terminal_seen: true}),
    do: {:error, :duplicate_terminal_response}

  defp retain_response_event(%{"type" => "response.completed"}, _state),
    do: {:error, :invalid_terminal_response}

  defp retain_response_event(_event, state), do: {:ok, state}

  defp terminal_model(response) do
    case Map.fetch(response, "model") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, model} when is_binary(model) ->
        if byte_size(model) <= @max_terminal_model_bytes and String.valid?(model) and
             String.trim(model) == model and String.trim(model) != "" and
             not String.match?(model, ~r/[\x00-\x1F\x7F]/) do
          {:ok, model}
        else
          {:error, :invalid_terminal_model}
        end

      {:ok, _model} ->
        {:error, :invalid_terminal_model}
    end
  end

  defp terminal_usage(response, backend) do
    case Map.fetch(response, "usage") do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, %{}}
      {:ok, usage} -> normalize_terminal_usage(usage, backend)
    end
  end

  defp normalize_terminal_usage(usage, _backend) when is_map(usage) and map_size(usage) == 0,
    do: {:ok, %{}}

  defp normalize_terminal_usage(usage, backend) when is_map(usage) do
    common_allowed = [
      "input_tokens",
      "prompt_tokens",
      "output_tokens",
      "completion_tokens",
      "total_tokens",
      "input_tokens_details",
      "prompt_tokens_details",
      "output_tokens_details",
      "completion_tokens_details"
    ]

    allowed =
      if backend == :xai,
        do: common_allowed ++ @xai_terminal_usage_fields,
        else: common_allowed

    keys = Map.keys(usage)

    cond do
      not Enum.all?(keys, &(is_binary(&1) and &1 in allowed)) ->
        {:error, :invalid_terminal_usage_keys}

      Map.has_key?(usage, "input_tokens") and Map.has_key?(usage, "prompt_tokens") ->
        {:error, :ambiguous_terminal_usage}

      Map.has_key?(usage, "output_tokens") and Map.has_key?(usage, "completion_tokens") ->
        {:error, :ambiguous_terminal_usage}

      Map.has_key?(usage, "input_tokens_details") and
          Map.has_key?(usage, "prompt_tokens_details") ->
        {:error, :ambiguous_terminal_usage_details}

      Map.has_key?(usage, "output_tokens_details") and
          Map.has_key?(usage, "completion_tokens_details") ->
        {:error, :ambiguous_terminal_usage_details}

      true ->
        with {:ok, input_tokens} <- terminal_usage_value(usage, ["input_tokens", "prompt_tokens"]),
             {:ok, output_tokens} <-
               terminal_usage_value(usage, ["output_tokens", "completion_tokens"]),
             {:ok, total_tokens} <- terminal_usage_value(usage, ["total_tokens"]),
             {:ok, cached_tokens} <-
               terminal_detail_value(
                 usage,
                 ["input_tokens_details", "prompt_tokens_details"],
                 "cached_tokens",
                 ["cached_tokens", "cache_write_tokens"]
               ),
             {:ok, cache_write_tokens} <-
               terminal_detail_value(
                 usage,
                 ["input_tokens_details", "prompt_tokens_details"],
                 "cache_write_tokens",
                 ["cached_tokens", "cache_write_tokens"]
               ),
             {:ok, reasoning_tokens} <-
               terminal_detail_value(
                 usage,
                 ["output_tokens_details", "completion_tokens_details"],
                 "reasoning_tokens"
               ),
             :ok <- require_complete_terminal_usage(input_tokens, output_tokens, total_tokens),
             :ok <- consistent_terminal_total(input_tokens, output_tokens, total_tokens),
             :ok <- bounded_terminal_detail(cached_tokens, input_tokens, :cached_tokens),
             :ok <-
               bounded_terminal_detail(
                 cache_write_tokens,
                 input_tokens,
                 :cache_write_tokens
               ),
             :ok <- bounded_terminal_detail(reasoning_tokens, output_tokens, :reasoning_tokens),
             :ok <-
               validate_xai_terminal_usage_extensions(
                 usage,
                 backend,
                 input_tokens,
                 output_tokens
               ) do
          {:ok,
           compact_usage(
             input_tokens,
             output_tokens,
             total_tokens,
             cached_tokens,
             cache_write_tokens,
             reasoning_tokens
           )}
        end
    end
  end

  defp normalize_terminal_usage(_usage, _backend), do: {:error, :invalid_terminal_usage}

  defp validate_xai_terminal_usage_extensions(usage, :xai, input_tokens, output_tokens) do
    with :ok <- validate_xai_context_details(usage, input_tokens, output_tokens),
         :ok <- validate_xai_counter(usage, "cost_in_usd_ticks"),
         :ok <- validate_xai_counter(usage, "num_server_side_tools_used"),
         :ok <- validate_xai_counter(usage, "num_sources_used") do
      :ok
    end
  end

  defp validate_xai_terminal_usage_extensions(_usage, _backend, _input_tokens, _output_tokens),
    do: :ok

  defp validate_xai_context_details(usage, input_tokens, output_tokens) do
    case Map.fetch(usage, "context_details") do
      :error ->
        :ok

      {:ok, %{"input_tokens" => ^input_tokens, "output_tokens" => ^output_tokens} = details}
      when map_size(details) == 2 ->
        :ok

      {:ok, _details} ->
        {:error, :invalid_terminal_usage_context_details}
    end
  end

  defp validate_xai_counter(usage, key) do
    case Map.fetch(usage, key) do
      :error ->
        :ok

      {:ok, value}
      when is_integer(value) and value >= 0 and value <= @max_json_safe_integer ->
        :ok

      {:ok, _value} ->
        {:error, :invalid_terminal_usage_extension_value}
    end
  end

  defp terminal_usage_value(usage, keys) do
    case Enum.find_value(keys, :missing, fn key ->
           case Map.fetch(usage, key) do
             :error -> nil
             {:ok, value} -> {:ok, value}
           end
         end) do
      :missing ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value >= 0 and value <= @max_token_count ->
        {:ok, value}

      {:ok, _value} ->
        {:error, :invalid_terminal_usage_value}
    end
  end

  defp consistent_terminal_total(input_tokens, output_tokens, total_tokens)
       when is_integer(input_tokens) and is_integer(output_tokens) and is_integer(total_tokens) do
    if input_tokens + output_tokens == total_tokens,
      do: :ok,
      else: {:error, :inconsistent_terminal_usage_total}
  end

  defp require_complete_terminal_usage(input_tokens, output_tokens, total_tokens)
       when is_integer(input_tokens) and is_integer(output_tokens) and is_integer(total_tokens),
       do: :ok

  defp require_complete_terminal_usage(_input_tokens, _output_tokens, _total_tokens),
    do: {:error, :incomplete_terminal_usage}

  defp terminal_detail_value(usage, keys, detail_key, allowed_keys \\ nil) do
    allowed_keys = allowed_keys || [detail_key]

    case Enum.filter(keys, &Map.has_key?(usage, &1)) do
      [] ->
        {:ok, nil}

      [key] ->
        case Map.fetch!(usage, key) do
          detail when is_map(detail) ->
            normalize_terminal_detail(detail, detail_key, allowed_keys)

          _ ->
            {:error, :invalid_terminal_usage_details}
        end

      _ ->
        {:error, :ambiguous_terminal_usage_details}
    end
  end

  defp normalize_terminal_detail(detail, detail_key, allowed_keys) when is_map(detail) do
    keys = Map.keys(detail)

    cond do
      not Enum.all?(keys, &(is_binary(&1) and &1 in allowed_keys)) ->
        {:error, :invalid_terminal_usage_detail_keys}

      Map.has_key?(detail, detail_key) ->
        case Map.fetch!(detail, detail_key) do
          value when is_integer(value) and value >= 0 and value <= @max_token_count ->
            {:ok, value}

          _ ->
            {:error, :invalid_terminal_usage_detail_value}
        end

      true ->
        {:ok, nil}
    end
  end

  defp bounded_terminal_detail(nil, _total, _name), do: :ok

  defp bounded_terminal_detail(value, total, _name)
       when is_integer(value) and is_integer(total) and value <= total,
       do: :ok

  defp bounded_terminal_detail(_value, _total, name),
    do: {:error, {:inconsistent_terminal_usage_detail, name}}

  defp compact_usage(
         input_tokens,
         output_tokens,
         total_tokens,
         cached_tokens,
         cache_write_tokens,
         reasoning_tokens
       ) do
    %{}
    |> maybe_put_usage(:input_tokens, input_tokens)
    |> maybe_put_usage(:output_tokens, output_tokens)
    |> maybe_put_usage(:total_tokens, total_tokens)
    |> maybe_put_usage(:cached_tokens, cached_tokens)
    |> maybe_put_usage(:cache_write_tokens, cache_write_tokens)
    |> maybe_put_usage(:reasoning_tokens, reasoning_tokens)
  end

  defp maybe_put_usage(usage, _key, nil), do: usage
  defp maybe_put_usage(usage, key, value), do: Map.put(usage, key, value)

  defp stamp_provider_receipt(%{terminal_seen: true} = parsed, %{backend: backend})
       when backend in [:openai, :xai] do
    with {:ok, receipt} <-
           Response.ProviderReceipt.new(%{
             backend: backend,
             reported_model: parsed.provider_model,
             usage: parsed.usage
           }) do
      {:ok, public_complete_result(parsed, receipt)}
    end
  end

  defp stamp_provider_receipt(parsed, _identity) do
    {:ok, public_complete_result(parsed, nil)}
  end

  defp public_complete_result(parsed, provider_receipt) do
    parsed
    |> Map.take([:text, :tool_calls, :usage])
    |> Map.put(:provider_receipt, provider_receipt)
  end

  defp tool_call_from_item(item) do
    id = item["call_id"] || item["id"]
    name = item["name"]

    with :ok <- bounded_tool_field(id, :id),
         :ok <- bounded_tool_field(name, :name),
         {:ok, arguments, measurements} <- decode_args(item["arguments"]) do
      {:ok, %{id: id, name: name, arguments: arguments}, measurements}
    end
  end

  defp bounded_tool_field(value, _field)
       when is_binary(value) and byte_size(value) in 1..512 do
    if String.valid?(value), do: :ok, else: {:error, :valid_utf8_tool_field_required}
  end

  defp bounded_tool_field(_value, field), do: {:error, {:invalid_tool_field, field}}

  defp decode_args(args) when is_binary(args) do
    case ResponseBudget.decode_json_with_measurements(args, tool_argument_limits()) do
      {:ok, map, measurements} when is_map(map) -> {:ok, map, measurements}
      {:ok, _other, _measurements} -> {:error, :tool_arguments_must_be_map}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp decode_args(map) when is_map(map) do
    case ResponseBudget.measure(map, tool_argument_limits()) do
      {:ok, measurements} -> {:ok, map, measurements}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp decode_args(_args), do: {:error, :tool_arguments_must_be_map_or_json}

  defp charge_measurements(state, measurements) do
    nodes = state.decoded_nodes + Map.get(measurements, :nodes, 0)
    bytes = state.decoded_bytes + Map.get(measurements, :bytes, 0)
    map_keys = state.decoded_map_keys + Map.get(measurements, :map_keys, 0)
    list_items = state.decoded_list_items + Map.get(measurements, :list_items, 0)
    work = state.work + Map.get(measurements, :nodes, 0)

    cond do
      nodes > state.limits.max_nodes ->
        {:error, {:stream_limit_exceeded, :decoded_nodes, state.limits.max_nodes}}

      bytes > state.limits.max_response_bytes ->
        {:error, {:stream_limit_exceeded, :decoded_bytes, state.limits.max_response_bytes}}

      map_keys > state.limits.max_map_keys ->
        {:error, {:stream_limit_exceeded, :decoded_map_keys, state.limits.max_map_keys}}

      list_items > state.limits.max_list_items ->
        {:error, {:stream_limit_exceeded, :decoded_list_items, state.limits.max_list_items}}

      work > state.limits.max_work ->
        {:error, {:stream_limit_exceeded, :work, state.limits.max_work}}

      true ->
        {:ok,
         %{
           state
           | decoded_nodes: nodes,
             decoded_bytes: bytes,
             decoded_map_keys: map_keys,
             decoded_list_items: list_items,
             work: work
         }}
    end
  end

  defp add_work(state, amount) do
    if state.work <= state.limits.max_work - amount,
      do: {:ok, %{state | work: state.work + amount}},
      else: {:error, {:stream_limit_exceeded, :work, state.limits.max_work}}
  end

  defp measurement_delta(retained, preflight) do
    %{
      nodes: max(Map.get(retained, :nodes, 0) - Map.get(preflight, :nodes, 0), 0),
      bytes: max(Map.get(retained, :bytes, 0) - Map.get(preflight, :bytes, 0), 0),
      map_keys: max(Map.get(retained, :map_keys, 0) - Map.get(preflight, :map_keys, 0), 0),
      list_items: max(Map.get(retained, :list_items, 0) - Map.get(preflight, :list_items, 0), 0)
    }
  end

  defp json_limits(limits, maximum) do
    [
      max_bytes: maximum,
      max_nodes: limits.max_nodes,
      max_depth: limits.max_depth,
      max_map_keys: limits.max_map_keys,
      max_list_items: limits.max_list_items
    ]
  end

  defp tool_argument_limits do
    [
      max_bytes: 1_048_576,
      max_nodes: 10_000,
      max_depth: 32,
      max_map_keys: 2_000,
      max_list_items: 10_000
    ]
  end

  defp normalize_limits(%{timeout: _timeout} = limits), do: validate_limits(limits)
  defp normalize_limits(opts) when is_list(opts), do: build_limits(opts)
  defp normalize_limits(_opts), do: {:error, :invalid_responses_limits}

  defp build_limits(opts) do
    with {:ok, supplied} <- collect_limit_options(opts, %{}, 0),
         {:ok, timeout} <-
           Deadline.select(opts, Deadline.timeout_keys(), 180_000, @max_timeout),
         {:ok, max_response_bytes} <-
           positive_clamped(
             supplied,
             :max_response_bytes,
             @max_response_bytes,
             @max_response_bytes
           ),
         {:ok, max_events} <- positive_clamped(supplied, :max_events, @max_events, @max_events),
         {:ok, max_event_bytes} <-
           positive_clamped(
             supplied,
             :max_event_bytes,
             @max_event_bytes,
             min(max_response_bytes, @max_event_bytes)
           ),
         {:ok, max_work} <- positive_clamped(supplied, :max_work, @max_work, @max_work),
         {:ok, max_nodes} <- positive_clamped(supplied, :max_nodes, @max_nodes, @max_nodes),
         {:ok, max_depth} <- positive_clamped(supplied, :max_depth, @max_depth, @max_depth),
         {:ok, max_map_keys} <-
           positive_clamped(supplied, :max_map_keys, @max_map_keys, @max_map_keys),
         {:ok, max_list_items} <-
           positive_clamped(supplied, :max_list_items, @max_list_items, @max_list_items) do
      {:ok,
       %{
         timeout: timeout,
         max_response_bytes: max_response_bytes,
         max_events: max_events,
         max_event_bytes: max_event_bytes,
         max_work: max_work,
         max_nodes: max_nodes,
         max_depth: max_depth,
         max_map_keys: max_map_keys,
         max_list_items: max_list_items
       }}
    end
  end

  defp collect_limit_options([], options, _count), do: {:ok, options}

  defp collect_limit_options(_opts, _options, count) when count >= 64,
    do: {:error, :invalid_responses_limits}

  defp collect_limit_options([{key, value} | rest], options, count) when is_atom(key),
    do: collect_limit_options(rest, Map.put(options, key, value), count + 1)

  defp collect_limit_options(_improper, _options, _count),
    do: {:error, :invalid_responses_limits}

  defp positive_clamped(options, key, default, maximum) do
    value = Map.get(options, key, default)

    if is_integer(value) and value > 0,
      do: {:ok, min(value, maximum)},
      else: {:error, :invalid_responses_limits}
  end

  defp validate_limits(
         %{
           timeout: timeout,
           max_response_bytes: max_response_bytes,
           max_events: max_events,
           max_event_bytes: max_event_bytes,
           max_work: max_work,
           max_nodes: max_nodes,
           max_depth: max_depth,
           max_map_keys: max_map_keys,
           max_list_items: max_list_items
         } = limits
       ) do
    valid? =
      is_integer(timeout) and timeout > 0 and timeout <= @max_timeout and
        is_integer(max_response_bytes) and max_response_bytes > 0 and
        max_response_bytes <= @max_response_bytes and
        is_integer(max_events) and max_events > 0 and max_events <= @max_events and
        is_integer(max_event_bytes) and max_event_bytes > 0 and
        max_event_bytes <= min(max_response_bytes, @max_event_bytes) and
        is_integer(max_work) and max_work > 0 and max_work <= @max_work and
        is_integer(max_nodes) and max_nodes > 0 and max_nodes <= @max_nodes and
        is_integer(max_depth) and max_depth > 0 and max_depth <= @max_depth and
        is_integer(max_map_keys) and max_map_keys > 0 and max_map_keys <= @max_map_keys and
        is_integer(max_list_items) and max_list_items > 0 and
        max_list_items <= @max_list_items

    if valid?, do: {:ok, limits}, else: {:error, :invalid_responses_limits}
  end

  defp validate_limits(_limits), do: {:error, :invalid_responses_limits}

  defp identity_content_encoding(response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] ->
        :ok

      values ->
        if Enum.all?(values, &(String.downcase(String.trim(&1)) in ["", "identity"])),
          do: :ok,
          else: {:error, :identity_content_encoding_required}
    end
  end

  defp event_stream_content_type(response, identity) do
    case Req.Response.get_header(response, "content-type") do
      # The Codex subscription endpoint currently omits Content-Type on a valid
      # 200 SSE response. Keep this exception backend-scoped: xAI and every
      # unbound request still require an explicit event-stream declaration.
      [] when identity.backend == :openai ->
        :ok

      [value] ->
        media_type =
          value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

        if media_type == "text/event-stream",
          do: :ok,
          else: {:error, :event_stream_content_type_required}

      _ ->
        {:error, :event_stream_content_type_required}
    end
  end

  defp strip_cr(line) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end
end
