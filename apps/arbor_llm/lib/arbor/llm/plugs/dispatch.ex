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

  def call(%Call{result: nil, operation: op, request: req} = call) do
    %{call | result: do_dispatch(op, req)}
  end

  # Already has a result — short-circuited by an upstream plug.
  def call(%Call{} = call), do: call

  # ── Operation-specific dispatch ────────────────────────────────────

  defp do_dispatch(:complete, {model_spec, messages, opts}) do
    ReqLLM.generate_text(model_spec, messages, opts)
  rescue
    e -> {:error, exception_for(e)}
  catch
    :exit, reason -> {:error, exit_for(reason)}
  end

  defp do_dispatch(:stream, {model_spec, messages, opts}) do
    ReqLLM.stream_text(model_spec, messages, opts)
  rescue
    e -> {:error, exception_for(e)}
  catch
    :exit, reason -> {:error, exit_for(reason)}
  end

  defp do_dispatch(:embed_cloud, {model_spec, texts, opts}) when is_binary(model_spec) do
    case ReqLLM.Embedding.embed(model_spec, texts, opts) do
      {:ok, %{embeddings: embeddings, usage: usage}} -> {:ok, embeddings, usage}
      {:ok, %{embedding: embedding, usage: usage}} -> {:ok, [embedding], usage}
      {:ok, list} when is_list(list) -> {:ok, list, %{}}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_embed_response, inspect(other)}}
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
    with {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:embedding, model, texts, opts),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           Req.request(request) do
      extract_embeddings(body)
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ProviderError.exception(
           message: "embedding HTTP #{status}",
           status: status,
           retryable: retryable_status?(status),
           details: %{source: :req_llm_direct, body: inspect(body) |> String.slice(0, 500)}
         )}

      {:error, _} = err ->
        err
    end
  rescue
    e -> {:error, exception_for(e)}
  catch
    :exit, reason -> {:error, exit_for(reason)}
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp extract_embeddings(%{"data" => data} = body) when is_list(data) do
    embeddings =
      Enum.map(data, fn
        %{"embedding" => e} -> e
        e when is_list(e) -> e
      end)

    {:ok, embeddings, Map.get(body, "usage", %{})}
  end

  defp extract_embeddings(body), do: {:error, {:unexpected_embed_response, body}}

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
end
