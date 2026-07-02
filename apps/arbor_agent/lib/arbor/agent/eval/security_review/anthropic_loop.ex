defmodule Arbor.Agent.Eval.SecurityReview.AnthropicLoop do
  @moduledoc """
  A minimal, self-contained **Anthropic-format tool loop** for the L2-review eval's
  agentic strategy — driven directly against an Anthropic-compatible `/v1/messages`
  endpoint (LM Studio exposes one), bypassing `Arbor.LLM`.

  Why direct: `Arbor.LLM` routes local-LM providers through req_llm's **OpenAI**
  format, and local models (qwen) emit tool calls in **Anthropic** `tool_use` form —
  which the OpenAI endpoint mangles. The Anthropic endpoint returns structured
  `tool_use` blocks (verified), so we speak that protocol directly. Three arbor_llm
  gotchas (local→openai mapping, the `/models` adapter probe path, the `/v1` base_url
  convention) are all sidestepped.

  The loop: POST messages → if the model returns `tool_use` blocks, execute each
  via the matching `Arbor.LLM.Tool`'s `execute` fn, append the assistant turn + a
  user turn of `tool_result` blocks, and repeat — until the model stops calling
  tools (`stop_reason != "tool_use"`) or `max_rounds` is hit. Returns the final
  assistant text (the findings JSON). The HTTP `post` fn is injected for testing.
  """

  @anthropic_version "2023-06-01"
  # Effectively uncapped for security findings — the Anthropic API REQUIRES a value
  # (nil is illegal), so this is set high rather than removed. Modern Claude models
  # support 32k+ output; a low cap here truncated long findings JSON.
  @max_tokens 32_000

  @type opts :: %{
          required(:base_url) => String.t(),
          required(:model) => String.t(),
          required(:system) => String.t(),
          required(:user) => String.t(),
          required(:tools) => [Arbor.LLM.Tool.t()],
          optional(:max_rounds) => pos_integer(),
          optional(:receive_timeout) => pos_integer(),
          optional(:api_key) => String.t(),
          optional(:post) => function()
        }

  @doc "Run the tool loop. Returns `{:ok, final_text}` or `{:error, reason}`."
  @spec run(opts()) :: {:ok, String.t()} | {:error, term()}
  def run(%{base_url: base_url, model: model, system: system, user: user, tools: tools} = o) do
    max_rounds = o[:max_rounds] || 8
    recv = o[:receive_timeout] || 600_000
    api_key = o[:api_key] || "lm-studio"
    post = o[:post] || (&default_post/4)

    url = String.trim_trailing(base_url, "/") <> "/v1/messages"

    headers = [
      {"content-type", "application/json"},
      {"anthropic-version", @anthropic_version},
      {"x-api-key", api_key}
    ]

    tool_specs = Enum.map(tools, &tool_spec/1)
    tools_by_name = Map.new(tools, &{&1.name, &1})

    loop([%{"role" => "user", "content" => user}], 0, max_rounds, %{
      url: url,
      headers: headers,
      model: model,
      system: system,
      tool_specs: tool_specs,
      tools_by_name: tools_by_name,
      recv: recv,
      post: post
    })
  end

  @doc """
  One no-tools Anthropic message → the assistant's text. Used by the LLM judge
  (a single yes/no adjudication, no investigation). Omits the `tools` key entirely.
  """
  @spec single_shot(map()) :: {:ok, String.t()} | {:error, term()}
  def single_shot(%{base_url: base_url, model: model, system: system, user: user} = o) do
    recv = o[:receive_timeout] || 300_000
    api_key = o[:api_key] || "lm-studio"
    post = o[:post] || (&default_post/4)

    url = String.trim_trailing(base_url, "/") <> "/v1/messages"

    headers = [
      {"content-type", "application/json"},
      {"anthropic-version", @anthropic_version},
      {"x-api-key", api_key}
    ]

    body = %{
      "model" => model,
      "max_tokens" => @max_tokens,
      "system" => system,
      "messages" => [%{"role" => "user", "content" => user}]
    }

    case post.(url, headers, body, recv) do
      {:ok, %{"content" => content}} -> {:ok, text_of(content)}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------

  # Out of investigation budget: make ONE final turn with NO tools AND an explicit
  # "stop, output JSON now" instruction — removing tools alone isn't enough (the
  # model keeps narrating), so we nudge it to conclude. Salvages the investigation
  # instead of throwing it away.
  defp loop(messages, round, max_rounds, ctx) when round >= max_rounds do
    body = %{
      "model" => ctx.model,
      "max_tokens" => @max_tokens,
      "system" => ctx.system,
      "messages" => with_conclusion_nudge(messages)
    }

    case ctx.post.(ctx.url, ctx.headers, body, ctx.recv) do
      {:ok, %{"content" => content}} -> {:ok, text_of(content)}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp loop(messages, round, max_rounds, ctx) do
    body = %{
      "model" => ctx.model,
      "max_tokens" => @max_tokens,
      "system" => ctx.system,
      "tools" => ctx.tool_specs,
      "messages" => messages
    }

    case ctx.post.(ctx.url, ctx.headers, body, ctx.recv) do
      {:ok, %{"content" => content} = resp} ->
        case Enum.filter(content, &(&1["type"] == "tool_use")) do
          [] ->
            {:ok, text_of(content)}

          tool_uses ->
            results = Enum.map(tool_uses, &execute_tool(&1, ctx.tools_by_name))

            messages =
              messages ++
                [
                  %{"role" => "assistant", "content" => content},
                  %{"role" => "user", "content" => results}
                ]

            # stop_reason may be "tool_use"; keep looping while there are calls.
            if resp["stop_reason"] == "tool_use" or tool_uses != [] do
              loop(messages, round + 1, max_rounds, ctx)
            else
              {:ok, text_of(content)}
            end
        end

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @conclusion "Stop investigating now. Based ONLY on what you have already read, output " <>
                "ONLY the JSON array of findings — no prose, no markdown, no further tool use. " <>
                "If you found no real security issue, output exactly []."

  # Append the conclusion instruction to the final user turn (the last message is a
  # user tool_result turn; appending a text block keeps it one valid user turn
  # rather than an illegal user-after-user).
  defp with_conclusion_nudge(messages) do
    nudge = %{"type" => "text", "text" => @conclusion}

    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_list(content) ->
        List.replace_at(messages, -1, %{"role" => "user", "content" => content ++ [nudge]})

      _ ->
        messages ++ [%{"role" => "user", "content" => [nudge]}]
    end
  end

  # Execute one tool_use block against the matching tool; wrap as a tool_result.
  defp execute_tool(%{"id" => id, "name" => name, "input" => input}, tools_by_name) do
    result =
      case Map.fetch(tools_by_name, name) do
        {:ok, tool} -> safe_execute(tool, input)
        :error -> %{error: "unknown tool: #{name}"}
      end

    %{"type" => "tool_result", "tool_use_id" => id, "content" => Jason.encode!(result)}
  end

  defp safe_execute(tool, input) do
    case tool.execute.(input) do
      {:ok, map} -> map
      {:error, reason} -> %{error: inspect(reason)}
      map when is_map(map) -> map
      other -> %{result: inspect(other)}
    end
  rescue
    e -> %{error: Exception.message(e)}
  end

  defp text_of(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp tool_spec(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description || "",
      "input_schema" => tool.input_schema
    }
  end

  # ---------------------------------------------------------------------------

  defp default_post(url, headers, body, recv) do
    case Req.post(url, json: body, headers: headers, receive_timeout: recv, retry: false) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
