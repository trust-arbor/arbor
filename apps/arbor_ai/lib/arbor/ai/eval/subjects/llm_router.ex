defmodule Arbor.AI.Eval.Subjects.LLMRouter do
  @moduledoc """
  Evaluation subject that asks a local LLM to select actions from an explicit index.

  The caller must provide `:index_path`. Tests and alternate runtimes can inject
  `:router_fn` with the signature
  `(base_url, model, system_prompt, user_prompt, timeout -> result)`.

  `:top_k` is capped at 100, the legacy `:max_desc_chars` option is enforced
  as a UTF-8 byte ceiling capped at 4,096, and `:timeout` at five minutes.
  """

  @behaviour Arbor.Eval.Subject

  alias Arbor.AI.Eval.RetrievalSupport

  @default_base_url "http://localhost:11434"
  @default_timeout 60_000
  @default_top_k 5
  @default_max_desc_chars 200
  @max_chat_response_bytes 262_144

  @impl true
  def run(input, opts \\ []) do
    with :ok <- RetrievalSupport.validate_opts(opts),
         {:ok, index_path} <- RetrievalSupport.required_string(opts, :index_path),
         {:ok, prompt} <- RetrievalSupport.extract_prompt(input),
         {:ok, model} <- RetrievalSupport.required_string(opts, :model),
         {:ok, top_k} <-
           RetrievalSupport.positive_integer_option(opts, :top_k, @default_top_k),
         {:ok, max_desc_chars} <-
           RetrievalSupport.positive_integer_option(
             opts,
             :max_desc_chars,
             @default_max_desc_chars
           ),
         {:ok, base_url} <-
           RetrievalSupport.string_option(opts, :base_url, @default_base_url),
         {:ok, timeout} <-
           RetrievalSupport.positive_integer_option(opts, :timeout, @default_timeout),
         {:ok, router_fn} <-
           RetrievalSupport.callback_option(opts, :router_fn, 5, &default_router/5),
         {:ok, actions} <- RetrievalSupport.load_index(index_path) do
      route(actions, prompt, model, top_k, max_desc_chars, base_url, timeout, router_fn)
    end
  end

  defp route(actions, prompt, model, top_k, max_desc_chars, base_url, timeout, router_fn) do
    with {:ok, system_prompt} <-
           actions
           |> build_system_prompt(top_k, max_desc_chars)
           |> RetrievalSupport.validate_router_prompt() do
      known_modules = MapSet.new(actions, & &1.module)
      started_at = System.monotonic_time(:millisecond)

      case RetrievalSupport.invoke(
             router_fn,
             [base_url, model, system_prompt, prompt, timeout],
             :router_callback_failed
           ) do
        {:ok, content} when is_binary(content) ->
          with {:ok, modules} <-
                 RetrievalSupport.parse_router_response(content, known_modules, top_k) do
            ranked = Enum.map(modules, &%{module: &1, score: nil})

            {:ok,
             %{
               text: Jason.encode!(modules),
               retrieved: ranked,
               duration_ms: System.monotonic_time(:millisecond) - started_at,
               model: model,
               provider: "ollama"
             }}
          end

        {:ok, _content} ->
          {:error, {:invalid_router_response, :binary_content_required}}

        {:error, _reason} = error ->
          error

        _response ->
          {:error, {:invalid_router_response, :ok_tuple_required}}
      end
    end
  end

  defp build_system_prompt(actions, top_k, max_desc_chars) do
    action_list =
      actions
      |> Enum.map(fn action ->
        "- #{action.module}: #{RetrievalSupport.truncate_utf8(action.description, max_desc_chars)}"
      end)
      |> Enum.join("\n")

    """
    You are an action selector for the Arbor agent framework. Given a user request, choose the #{top_k} most relevant action modules from the list below, ordered most-relevant first.

    Available actions:

    #{action_list}

    Respond with ONLY a JSON object in this exact shape:

    {"selected": ["Arbor.Actions.X", "Arbor.Actions.Y", ...]}

    The "selected" array MUST contain exactly #{top_k} module names from the list above, ordered by relevance to the user's request (most relevant first). Do not invent module names. Do not include any prose or explanation.
    """
  end

  defp default_router(base_url, model, system_prompt, user_prompt, timeout) do
    body = %{
      model: model,
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ],
      stream: false,
      format: "json",
      options: %{temperature: 0.0}
    }

    case RetrievalSupport.post_json(
           base_url <> "/api/chat",
           body,
           timeout,
           @max_chat_response_bytes
         ) do
      {:ok, 200, %{"message" => %{"content" => content}}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, status, response_body} ->
        RetrievalSupport.http_error(:router_http_error, status, response_body)

      {:error, _reason} = error ->
        error
    end
  end
end
