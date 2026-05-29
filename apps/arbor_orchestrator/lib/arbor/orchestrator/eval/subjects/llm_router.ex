defmodule Arbor.Orchestrator.Eval.Subjects.LLMRouter do
  @moduledoc """
  Eval subject for tool/capability retrieval via a small local LLM acting as a classifier.

  Takes a user prompt, sends it to an Ollama chat model along with a system prompt
  enumerating all available action modules, and parses the model's top-K JSON response.

  Designed for direct comparison against `EmbeddingRetrieval` — same input shape,
  same output shape, same grader integration.

  ## Input

  A map with a `"prompt"` key, or a bare string.

  ## Options

    * `:provider` — must be "ollama"
    * `:model` — chat model name (e.g. "granite4:1b", "granite4.1:3b", "phi4-mini")
    * `:index_path` — path to the action_index.json
    * `:top_k` — number of results to return (default: 5)
    * `:max_desc_chars` — truncate each action's description to this length for the
      system prompt (default: 200). Lower for smaller models to keep context budget.
    * `:base_url` — Ollama base URL (default: http://localhost:11434)
    * `:timeout` — request timeout in ms (default: 60_000)

  ## Output

  Same shape as `EmbeddingRetrieval` — graders work unchanged:

      {:ok, %{
        text: "[\\"Arbor.Actions.File\\", ...]",
        retrieved: [%{module: "Arbor.Actions.File", score: nil}, ...],
        duration_ms: 320,
        model: "granite4:1b",
        provider: "ollama"
      }}

  Score is `nil` because the LLM doesn't return a calibrated similarity; ranking is by list order only.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @default_index_path "apps/arbor_orchestrator/priv/eval_datasets/preprocessor_tool_retrieval/action_index.json"
  @default_base_url "http://localhost:11434"
  @default_timeout 60_000
  @default_top_k 5
  @default_max_desc_chars 200

  @impl true
  def run(input, opts \\ []) do
    prompt = extract_prompt(input)
    model = Keyword.fetch!(opts, :model)
    index_path = Keyword.get(opts, :index_path, @default_index_path)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    max_desc_chars = Keyword.get(opts, :max_desc_chars, @default_max_desc_chars)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, index} <- load_index(index_path) do
      system_prompt = build_system_prompt(index, top_k, max_desc_chars)
      known_modules = MapSet.new(index["actions"], & &1["module"])

      start = System.monotonic_time(:millisecond)

      case call_llm(base_url, model, system_prompt, prompt, timeout) do
        {:ok, content} ->
          duration_ms = System.monotonic_time(:millisecond) - start
          ranked = parse_response(content, known_modules, top_k)

          {:ok,
           %{
             text: Jason.encode!(Enum.map(ranked, & &1.module)),
             retrieved: ranked,
             duration_ms: duration_ms,
             model: model,
             provider: "ollama"
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp extract_prompt(%{"prompt" => prompt}) when is_binary(prompt), do: prompt
  defp extract_prompt(prompt) when is_binary(prompt), do: prompt

  defp extract_prompt(input),
    do: raise("LLMRouter expects %{\"prompt\" => binary} or a binary; got: #{inspect(input)}")

  defp load_index(path) do
    key = {__MODULE__, :index, Path.expand(path)}

    case :persistent_term.get(key, :miss) do
      :miss ->
        with {:ok, body} <- File.read(path),
             {:ok, index} <- Jason.decode(body) do
          :persistent_term.put(key, index)
          {:ok, index}
        else
          {:error, err} -> {:error, "failed to load index #{path}: #{inspect(err)}"}
        end

      index ->
        {:ok, index}
    end
  end

  defp build_system_prompt(index, top_k, max_desc_chars) do
    action_list =
      index["actions"]
      |> Enum.map(fn a ->
        desc = truncate(a["description"], max_desc_chars)
        "- #{a["module"]}: #{desc}"
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

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: binary_part(text, 0, max) <> "..."

  defp call_llm(base_url, model, system, user, timeout) do
    url = base_url <> "/api/chat"

    body = %{
      model: model,
      messages: [
        %{role: "system", content: system},
        %{role: "user", content: user}
      ],
      stream: false,
      format: "json",
      options: %{temperature: 0.0}
    }

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        {:error, "ollama chat returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  # Parse the model's JSON response. Tolerate a few possible shapes:
  # - {"selected": ["X", ...]}
  # - {"actions": ["X", ...]}
  # - ["X", ...]
  # Filter out hallucinated module names not in the known set.
  defp parse_response(content, known_modules, top_k) do
    case Jason.decode(content) do
      {:ok, %{"selected" => list}} when is_list(list) -> normalize(list, known_modules, top_k)
      {:ok, %{"actions" => list}} when is_list(list) -> normalize(list, known_modules, top_k)
      {:ok, list} when is_list(list) -> normalize(list, known_modules, top_k)
      _ -> []
    end
  end

  defp normalize(list, known_modules, top_k) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.filter(&MapSet.member?(known_modules, &1))
    |> Enum.take(top_k)
    |> Enum.map(&%{module: &1, score: nil})
  end
end
