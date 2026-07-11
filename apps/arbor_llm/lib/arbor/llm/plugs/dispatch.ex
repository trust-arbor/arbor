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
  """

  use Arbor.LLM.Plug
  alias Arbor.LLM.Call
  alias Arbor.LLM.ProviderError
  alias Arbor.LLM.ResponseBudget
  alias Arbor.LLM.Adapter.ReqLLM.BoundedStream

  @default_max_response_bytes 16_777_216
  @max_embedding_vectors 2_048
  @max_embedding_dimensions 8_192

  def call(%Call{halted: true} = call), do: call

  def call(%Call{result: nil, operation: op, request: req} = call) do
    %{call | result: do_dispatch(op, req)}
  end

  # Already has a result — short-circuited by an upstream plug.
  def call(%Call{} = call), do: call

  # ── Operation-specific dispatch ────────────────────────────────────

  defp do_dispatch(:complete, {model_spec, messages, opts}) do
    maximum = Keyword.get(opts, :arbor_max_response_bytes, 16_777_216)
    req_opts = Keyword.delete(opts, :arbor_max_response_bytes)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:chat, model, messages, req_opts),
         request <- ResponseBudget.apply_req_receipt(request, maximum),
         {:ok, %Req.Response{private: %{arbor_response_overflow: ^maximum}}} <-
           Req.request(request) do
      {:error, {:response_bytes_exceeded, maximum}}
    else
      {:ok, %Req.Response{private: %{arbor_response_error: reason}}} ->
        {:error, {:invalid_response_body, reason}}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, _reason} = error ->
        error
    end
  rescue
    e -> {:error, exception_for(e)}
  catch
    :exit, reason -> {:error, exit_for(reason)}
  end

  defp do_dispatch(:stream, {model_spec, messages, opts}) do
    maximum = Keyword.get(opts, :arbor_max_response_bytes, @default_max_response_bytes)
    max_events = Keyword.get(opts, :max_stream_events, 100_000)
    max_event_bytes = Keyword.get(opts, :max_stream_event_bytes, min(1_048_576, maximum))

    req_opts =
      Keyword.drop(opts, [
        :arbor_max_response_bytes,
        :max_stream_events,
        :max_stream_event_bytes
      ])

    BoundedStream.start(model_spec, messages, req_opts,
      max_response_bytes: maximum,
      max_events: max_events,
      max_event_bytes: max_event_bytes
    )
  rescue
    e -> {:error, exception_for(e)}
  catch
    :exit, reason -> {:error, exit_for(reason)}
  end

  defp do_dispatch(:embed_cloud, {model_spec, texts, opts}) when is_binary(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         true <- embedding_capable?(model) or {:error, {:embedding_not_supported, model_spec}} do
      dispatch_embedding(model, texts, opts, :req_llm)
    end
  rescue
    e -> {:error, exception_for(e)}
  catch
    :exit, reason -> {:error, exit_for(reason)}
  end

  defp do_dispatch(:embed_local, {%LLMDB.Model{} = model, texts, opts}) do
    # Local LM path: bypass ReqLLM.Embedding.embed/3's validate_model
    # gate (which hard-checks llm_db's embedding-capable catalog).
    # Operator-pulled local models aren't in the catalog, so the gate
    # would reject them before reaching the network. Call the
    # provider's prepare_request + Req.request directly — same shape
    # as the openai embeddings API which Ollama serves at /v1/embeddings.
    dispatch_embedding(model, texts, opts, :req_llm_direct)
  rescue
    e -> {:error, exception_for(e)}
  catch
    :exit, reason -> {:error, exit_for(reason)}
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp dispatch_embedding(model, texts, opts, source) do
    maximum = Keyword.get(opts, :arbor_max_response_bytes, @default_max_response_bytes)
    req_opts = Keyword.delete(opts, :arbor_max_response_bytes)

    with {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:embedding, model, texts, req_opts),
         request <- ResponseBudget.apply_req_receipt(request, maximum),
         {:ok, %Req.Response{private: %{arbor_response_overflow: ^maximum}}} <-
           Req.request(request) do
      {:error, {:response_bytes_exceeded, maximum}}
    else
      {:ok, %Req.Response{private: %{arbor_response_error: reason}}} ->
        {:error, {:invalid_response_body, reason}}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        extract_embeddings(body, length(texts))

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ProviderError.exception(
           message: "embedding HTTP #{status}",
           status: status,
           retryable: retryable_status?(status),
           details: %{source: source, body: inspect(body, limit: 20, printable_limit: 500)}
         )}

      {:error, _} = error ->
        error
    end
  end

  defp extract_embeddings(%{"data" => data} = body, expected_count)
       when is_list(data) and length(data) <= @max_embedding_vectors do
    with true <-
           length(data) == expected_count or
             {:error, {:unexpected_embedding_count, expected_count}},
         {:ok, embeddings, dimensions} <- extract_embedding_vectors(data, [], nil),
         true <- dimensions > 0 or {:error, :empty_embedding_vector} do
      {:ok, embeddings, Map.get(body, "usage", %{})}
    end
  end

  defp extract_embeddings(%{"data" => data}, _expected_count) when is_list(data),
    do: {:error, {:embedding_vector_count_exceeded, @max_embedding_vectors}}

  defp extract_embeddings(body, _expected_count), do: {:error, {:unexpected_embed_response, body}}

  defp extract_embedding_vectors([], acc, dimensions),
    do: {:ok, Enum.reverse(acc), dimensions || 0}

  defp extract_embedding_vectors([entry | rest], acc, expected_dimensions) do
    vector = if is_map(entry), do: Map.get(entry, "embedding"), else: entry

    with {:ok, dimensions} <- validate_embedding_vector(vector, 0),
         true <-
           is_nil(expected_dimensions) or dimensions == expected_dimensions or
             {:error, {:embedding_dimension_mismatch, expected_dimensions, dimensions}} do
      extract_embedding_vectors(rest, [vector | acc], dimensions)
    end
  end

  defp validate_embedding_vector([], 0), do: {:error, :empty_embedding_vector}
  defp validate_embedding_vector([], dimensions), do: {:ok, dimensions}

  defp validate_embedding_vector(_vector, dimensions)
       when dimensions >= @max_embedding_dimensions,
       do: {:error, {:embedding_dimensions_exceeded, @max_embedding_dimensions}}

  defp validate_embedding_vector([value | rest], dimensions) do
    if ResponseBudget.finite_number?(value),
      do: validate_embedding_vector(rest, dimensions + 1),
      else: {:error, :finite_numeric_embedding_required}
  end

  defp validate_embedding_vector(_improper_or_non_list, _dimensions),
    do: {:error, :proper_embedding_vector_required}

  defp exception_for(%{__struct__: mod} = e)
       when mod in [ReqLLM.Error.API.Request, ReqLLM.Error.API.Response] do
    status = Map.get(e, :status)

    ProviderError.exception(
      message: Exception.message(e),
      status: status,
      retryable: retryable_status?(status),
      details: %{source: :req_llm, raw: inspect(e)}
    )
  end

  defp exception_for(e) do
    ProviderError.exception(
      message: Exception.message(e),
      retryable: false,
      details: %{source: :req_llm, raw: inspect(e)}
    )
  end

  defp exit_for({:timeout, _}) do
    Arbor.LLM.RequestTimeoutError.exception(message: "request timed out")
  end

  defp exit_for(reason) do
    ProviderError.exception(
      message: "request exited: " <> inspect(reason),
      retryable: false,
      details: %{source: :req_llm, raw: inspect(reason)}
    )
  end

  defp retryable_status?(status) when status in [408, 429, 500, 502, 503, 504], do: true
  defp retryable_status?(_), do: false

  defp embedding_capable?(%LLMDB.Model{capabilities: capabilities}) when is_map(capabilities),
    do:
      Map.get(capabilities, :embeddings, Map.get(capabilities, "embeddings")) not in [nil, false]

  defp embedding_capable?(_model), do: false
end
