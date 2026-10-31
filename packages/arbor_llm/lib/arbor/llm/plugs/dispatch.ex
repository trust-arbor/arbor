defmodule Arbor.LLM.Plugs.Dispatch do
  @moduledoc """
  Terminal plug — invokes the actual req_llm call for the operation
  and stamps the result onto the call.

  Pattern-matches on `result: nil` so that if an upstream plug
  (`Plugs.Replay`) has already filled in a result via halt, Dispatch
  is a no-op. This is what makes the pipeline composable: Dispatch
  is "the work that happens unless someone short-circuited it."

  The four operations correspond to the four `call_req_llm*`
  dispatch points in `Arbor.LLM.Adapter.ReqLLM`:

    * `:complete` — `ReqLLM.generate_text/3`
    * `:stream` — `ReqLLM.stream_text/3`
    * `:embed_cloud` — `ReqLLM.Embedding.embed/3`
    * `:embed_local` — `provider_module.prepare_request(:embedding, …)`
      + `Req.request/1` directly (bypasses
      `ReqLLM.Embedding.validate_model/1`'s catalog gate for
      operator-pulled local-LM models)

  ## Failures

  Every failure is one `%Arbor.LLM.ProviderError{}` built by
  `Arbor.LLM.ProviderErrorCore` — HTTP status, transport, provider-library
  exceptions, exits, and local refusals of a provider response alike — so
  `Plugs.RateLimitBackoff`, `Arbor.LLM.Retry`, and provider fallback decide
  on typed fields. A deadline expiry stays `%Arbor.LLM.RequestTimeoutError{}`.
  A non-2xx response is halted right after the bounded body decoder, before
  the provider library's response steps turn it into an exception that drops
  the headers (`Retry-After`) and carries the request body. Errors leave
  bounded to the adapter-error budget via `Arbor.LLM.Boundary.provider_error/1`.
  """

  use Arbor.LLM.Plug
  alias Arbor.LLM.Call
  alias Arbor.LLM.Boundary
  alias Arbor.LLM.ProviderError
  alias Arbor.LLM.ProviderErrorCore
  alias Arbor.LLM.RequestTimeoutError
  alias Arbor.LLM.ResponseBudget
  alias Arbor.LLM.Adapter.ReqLLM.BoundedStream

  @default_max_response_bytes 16_777_216

  def call(%Call{halted: true} = call), do: call

  def call(%Call{result: nil, operation: op, request: req, assigns: assigns} = call) do
    single_attempt? = Map.get(assigns, :single_attempt) == true
    live_completion? = Map.get(assigns, :live_completion) == true
    call = prepare_sensitivity(call)
    admitted = Arbor.LLM.Plugs.Sensitivity.call(call)

    if admitted.halted do
      admitted
    else
      {model, content, opts} = req
      opts = Keyword.put(opts, :arbor_sensitivity, admitted.metadata.sensitivity_input)

      %{
        admitted
        | result:
            op
            |> do_dispatch({model, content, opts}, single_attempt?, live_completion?)
            |> bounded()
      }
    end
  end

  # Already has a result — short-circuited by an upstream plug.
  def call(%Call{} = call), do: call

  defp prepare_sensitivity(%Call{request: {model, content, opts}} = call) do
    {provider, model_id} =
      case model do
        %LLMDB.Model{provider: p, id: id} ->
          {p, id}

        value when is_binary(value) ->
          case String.split(value, ":", parts: 2) do
            [p, id] -> {p, id}
            _ -> {nil, value}
          end

        _ ->
          {nil, nil}
      end

    current_content = [
      content,
      Keyword.get(opts, :tools, []),
      Keyword.get(opts, :provider_options, [])
    ]

    original = Map.get(call.metadata, :sensitivity_input)

    if is_map(original) do
      expected = Arbor.LLM.ProviderRegistry.req_llm_atom(original.provider)
      actual = Arbor.LLM.ProviderRegistry.req_llm_atom(provider) || provider

      with true <-
             expected == actual or {:error, {:sensitivity_blocked, :provider_selection_changed}},
           {:ok, old_opts} <- Arbor.LLM.carry_sensitivity(original.content, original.opts),
           {:ok, new_opts} <-
             Arbor.LLM.carry_sensitivity(
               current_content,
               Keyword.take(opts, [:sensitivity, :taint, :base_url])
             ),
           {:ok, joined} <-
             Arbor.LLM.carry_sensitivity(
               %{sensitivity: Keyword.fetch!(old_opts, :sensitivity)},
               new_opts
             ) do
        input = %{
          provider: original.provider,
          model: model_id,
          content: current_content,
          opts: joined
        }

        Call.put_metadata(call, %{sensitivity_input: input})
      else
        {:error, _} = error -> %{call | halted: true, result: error}
      end
    else
      Call.put_metadata(call, %{
        sensitivity_input: %{
          provider: provider,
          model: model_id,
          content: current_content,
          opts: opts
        }
      })
    end
  end

  # ── Operation-specific dispatch ────────────────────────────────────

  defp do_dispatch(:complete, {model_spec, messages, opts}, single_attempt?, live_completion?) do
    {sensitivity, opts} = Keyword.pop(opts, :arbor_sensitivity)
    maximum = Keyword.get(opts, :arbor_max_response_bytes, 16_777_216)
    anonymous? = Keyword.get(opts, :arbor_anonymous_auth) == true

    req_opts = Keyword.drop(opts, [:arbor_max_response_bytes, :arbor_anonymous_auth])

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:chat, model, messages, req_opts) do
      request
      |> protect_sensitivity(sensitivity)
      |> ResponseBudget.apply_req_receipt(maximum)
      |> halt_http_failure()
      |> maybe_disable_req_retry(single_attempt?)
      |> maybe_disable_redirects(live_completion?)
      |> maybe_apply_anonymous_auth(anonymous?)
      |> Req.request()
      |> response_result(:req_llm, &{:ok, &1})
    else
      {:error, reason} -> {:error, provider_error(reason, :req_llm)}
    end
  rescue
    e -> {:error, provider_error(e, :req_llm)}
  catch
    kind, reason -> {:error, caught(kind, reason, :req_llm)}
  end

  defp do_dispatch(operation, request, single_attempt?, _live_completion?),
    do: do_dispatch(operation, request, single_attempt?)

  defp maybe_disable_redirects(request, true),
    do: Req.Request.merge_options(request, redirect: false)

  defp maybe_disable_redirects(request, false), do: request

  defp do_dispatch(:stream, {model_spec, messages, opts}, _single_attempt?) do
    maximum = Keyword.get(opts, :arbor_max_response_bytes, @default_max_response_bytes)
    max_events = Keyword.get(opts, :max_stream_events, 100_000)
    max_event_bytes = Keyword.get(opts, :max_stream_event_bytes, min(1_048_576, maximum))

    req_opts =
      Keyword.drop(opts, [
        :arbor_max_response_bytes,
        :max_stream_events,
        :max_stream_event_bytes
      ])

    # Bounded Finch streaming already performs one stream request.
    case BoundedStream.start(model_spec, messages, req_opts,
           max_response_bytes: maximum,
           max_events: max_events,
           max_event_bytes: max_event_bytes
         ) do
      {:error, reason} -> {:error, provider_error(reason, :req_llm)}
      started -> started
    end
  rescue
    e -> {:error, provider_error(e, :req_llm)}
  catch
    kind, reason -> {:error, caught(kind, reason, :req_llm)}
  end

  defp do_dispatch(:embed_cloud, {model_spec, texts, opts}, single_attempt?)
       when is_binary(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         true <- embedding_capable?(model) or {:error, {:embedding_not_supported, model_spec}} do
      dispatch_embedding(model, texts, opts, :req_llm, single_attempt?)
    else
      {:error, reason} -> {:error, provider_error(reason, :req_llm)}
    end
  rescue
    e -> {:error, provider_error(e, :req_llm)}
  catch
    kind, reason -> {:error, caught(kind, reason, :req_llm)}
  end

  defp do_dispatch(:embed_local, {%LLMDB.Model{} = model, texts, opts}, single_attempt?) do
    # Local LM path: bypass ReqLLM.Embedding.embed/3's validate_model
    # gate (which hard-checks llm_db's embedding-capable catalog).
    # Operator-pulled local models aren't in the catalog, so the gate
    # would reject them before reaching the network. Call the
    # provider's prepare_request + Req.request directly — same shape
    # as the openai embeddings API which Ollama serves at /v1/embeddings.
    dispatch_embedding(model, texts, opts, :req_llm_direct, single_attempt?)
  rescue
    e -> {:error, provider_error(e, :req_llm_direct)}
  catch
    kind, reason -> {:error, caught(kind, reason, :req_llm_direct)}
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # Apply retry suppression only after provider prepare_request has attached its
  # defaults — pre-provider option overrides are reinstalled by provider attach.
  defp maybe_disable_req_retry(%Req.Request{} = request, true) do
    Req.Request.merge_options(request, retry: false, max_retries: 0)
  end

  defp maybe_disable_req_retry(request, _single_attempt?), do: request

  defp maybe_apply_anonymous_auth(request, true),
    do: Arbor.LLM.OpenCodeZen.apply_anonymous_auth(request)

  defp maybe_apply_anonymous_auth(request, _anonymous?), do: request

  defp dispatch_embedding(model, texts, opts, source, single_attempt?) do
    {sensitivity, opts} = Keyword.pop(opts, :arbor_sensitivity)
    maximum = Keyword.get(opts, :arbor_max_response_bytes, @default_max_response_bytes)
    anonymous? = Keyword.get(opts, :arbor_anonymous_auth) == true
    req_opts = Keyword.drop(opts, [:arbor_max_response_bytes, :arbor_anonymous_auth])

    with {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:embedding, model, texts, req_opts) do
      request
      |> protect_sensitivity(sensitivity)
      |> ResponseBudget.apply_req_receipt(maximum)
      |> halt_http_failure()
      |> maybe_disable_req_retry(single_attempt?)
      |> maybe_apply_anonymous_auth(anonymous?)
      |> Req.request()
      |> response_result(source, fn body ->
        case Boundary.embedding_response_with_indices(body, length(texts)) do
          {:error, reason} ->
            {:error,
             ProviderErrorCore.from_failure(reason,
               source: source,
               message: "invalid provider embedding response"
             )}

          indexed ->
            indexed
        end
      end)
    else
      {:error, reason} -> {:error, provider_error(reason, source)}
    end
  end

  # ── Failure classification ─────────────────────────────────────────

  defp protect_sensitivity(request, input) do
    endpoint = Keyword.get(input.opts, :base_url) || Req.Request.get_option(request, :base_url)

    case Arbor.LLM.Endpoint.validate(endpoint, {:req_llm_base, input.provider}) do
      {:ok, endpoint} ->
        Arbor.LLM.Sensitivity.protect_request(
          request,
          input.provider,
          input.model,
          input.content,
          Keyword.put(input.opts, :base_url, endpoint)
        )

      {:error, _} ->
        Req.Request.append_request_steps(request,
          arbor_sensitivity: fn req ->
            Req.Request.halt(req, %Req.Response{
              status: 403,
              private: %{arbor_sensitivity_error: {:sensitivity_blocked, :invalid_destination}}
            })
          end
        )
    end
  end

  # Insert a response step right after the bounded body decoder that halts any
  # non-2xx, so Arbor classifies it from the real status, headers, and body
  # before the provider library converts it into an exception.
  defp halt_http_failure(%Req.Request{response_steps: steps} = request) do
    {before, rest} =
      Enum.split_while(steps, fn {name, _step} -> name != :arbor_decode_bounded_body end)

    case rest do
      [decode | later] ->
        %{
          request
          | response_steps: before ++ [decode, {:arbor_http_failure, &halt_failure/1}] ++ later
        }

      [] ->
        Req.Request.prepend_response_steps(request, arbor_http_failure: &halt_failure/1)
    end
  end

  defp halt_failure({request, %Req.Response{status: status} = response})
       when status not in 200..299,
       do: Req.Request.halt(request, response)

  defp halt_failure(request_response), do: request_response

  # Status first: a non-2xx is a provider failure even when its body was
  # undecodable (an HTML error page) or oversized.
  defp response_result(
         {:ok, %Req.Response{private: %{arbor_sensitivity_error: reason}}},
         _source,
         _on_success
       ),
       do: {:error, reason}

  defp response_result({:ok, %Req.Response{status: status} = response}, source, _on_success)
       when status not in 200..299,
       do: {:error, http_error(response, source)}

  defp response_result(
         {:ok, %Req.Response{private: %{arbor_response_overflow: maximum}}},
         source,
         _on_success
       ),
       do: {:error, provider_error({:response_bytes_exceeded, maximum}, source)}

  defp response_result(
         {:ok, %Req.Response{private: %{arbor_response_error: reason}}},
         source,
         _on_success
       ),
       do: {:error, provider_error({:invalid_response_body, reason}, source)}

  defp response_result({:ok, %Req.Response{body: body}}, _source, on_success),
    do: on_success.(body)

  defp response_result({:error, reason}, source, _on_success),
    do: {:error, provider_error(reason, source)}

  defp http_error(%Req.Response{status: status, headers: headers} = response, source) do
    body = failure_body(response)

    ProviderErrorCore.from_http(status, headers, body,
      source: source,
      original: %{response | body: body, private: %{}}
    )
  end

  # The decoded JSON body when the bounded decoder accepted it; otherwise the
  # raw bytes it buffered (e.g. an HTML error page from a proxy).
  defp failure_body(%Req.Response{private: %{arbor_response_chunks: chunks} = private})
       when is_list(chunks) and
              (is_map_key(private, :arbor_response_error) or
                 is_map_key(private, :arbor_response_overflow)),
       do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp failure_body(%Req.Response{body: body}), do: body

  defp provider_error(reason, source), do: ProviderErrorCore.from_failure(reason, source: source)

  defp caught(:exit, {:timeout, _reason}, _source),
    do: RequestTimeoutError.exception(message: "request timed out")

  defp caught(kind, reason, source), do: provider_error({kind, reason}, source)

  defp bounded({:error, %ProviderError{} = error}), do: {:error, Boundary.provider_error(error)}
  defp bounded(result), do: result

  defp embedding_capable?(%LLMDB.Model{capabilities: capabilities}) when is_map(capabilities),
    do:
      Map.get(capabilities, :embeddings, Map.get(capabilities, "embeddings")) not in [nil, false]

  defp embedding_capable?(_model), do: false
end
