defmodule Arbor.Orchestrator.Engine.FidelityTransformer do
  @moduledoc """
  Transforms context based on fidelity mode before handler execution.

  The fidelity system controls how much context each node receives.
  Modes (in order of detail):
  - `"full"` — all context values, unmodified
  - `"truncate"` — values truncated to a character limit
  - `"compact"` — key-value summary (default)
  - `"summary:low"` / `"summary:medium"` / `"summary:high"` — LLM-generated summaries

  The transformer creates a *view* of the context for handler execution.
  The engine retains the full context for lineage tracking and checkpoints.
  """

  alias Arbor.Orchestrator.Engine.Context

  @default_truncate_limit 4_000
  @compact_max_value_length 200

  # Keys that are always passed through regardless of fidelity mode
  @passthrough_keys ~w(
    current_node graph.goal graph.label workdir
    internal.fidelity.mode internal.fidelity.thread_id
    outcome preferred_label __completed_nodes__ __adapted_graph__
  )

  # Prefixes that are always passed through (pipeline-internal state)
  @passthrough_prefixes ~w(parallel. internal. context. __)

  @doc """
  Transform a context based on the resolved fidelity mode.

  Returns a new context suitable for handler execution. The original
  context is not modified.

  ## Options
  - `:truncate_limit` — character limit for truncate mode (default: #{@default_truncate_limit})
  - `:llm_backend` — function for summary modes `(prompt, opts) -> {:ok, text} | {:error, reason}`
  """
  @spec transform(Context.t(), String.t(), keyword()) :: Context.t()
  def transform(context, mode, opts \\ [])

  def transform(%Context{} = context, "full", _opts), do: context

  def transform(context, "truncate", opts) do
    limit = Keyword.get(opts, :truncate_limit, @default_truncate_limit)
    transform_values(context, &truncate_value(&1, &2, limit))
  end

  def transform(context, "compact", _opts) do
    transform_values(context, &compact_value/2)
  end

  def transform(context, "summary:" <> level, opts) when level in ~w(low medium high) do
    case Keyword.get(opts, :llm_backend) do
      nil ->
        # No LLM backend available — fall back to compact mode
        transform(context, "compact", opts)

      llm_fn when is_function(llm_fn, 2) ->
        summarize_context(context, level, llm_fn)
    end
  end

  def transform(context, _unknown_mode, opts) do
    # Unknown mode falls back to compact
    transform(context, "compact", opts)
  end

  # Transform all non-passthrough values using a mapping function
  defp transform_values(%Context{values: values} = context, mapper_fn) do
    transformed =
      Enum.reduce(values, %{}, fn {key, value}, acc ->
        if passthrough_key?(key) do
          Map.put(acc, key, value)
        else
          Map.put(acc, key, mapper_fn.(key, value))
        end
      end)

    %{context | values: transformed}
  end

  defp passthrough_key?(key) when key in @passthrough_keys, do: true

  defp passthrough_key?(key) when is_binary(key) do
    Enum.any?(@passthrough_prefixes, &String.starts_with?(key, &1))
  end

  defp passthrough_key?(_), do: false

  defp truncate_value(_key, value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "\n...[truncated at #{limit} chars]"
    else
      value
    end
  end

  defp truncate_value(_key, value, limit) do
    str = inspect(value, limit: :infinity, printable_limit: limit)

    if String.length(str) > limit do
      String.slice(str, 0, limit) <> "...[truncated]"
    else
      value
    end
  end

  defp compact_value(_key, value) when is_binary(value) do
    if String.length(value) > @compact_max_value_length do
      String.slice(value, 0, @compact_max_value_length) <>
        "... (#{String.length(value)} chars total)"
    else
      value
    end
  end

  defp compact_value(_key, value) when is_list(value) do
    "[#{length(value)} items]"
  end

  defp compact_value(_key, value) when is_map(value) do
    "%{#{map_size(value)} keys}"
  end

  defp compact_value(_key, value), do: value

  defp summarize_context(%Context{values: values} = context, level, llm_fn) do
    # Separate passthrough from summarizable
    {passthrough, summarizable} =
      Enum.split_with(values, fn {key, _} -> passthrough_key?(key) end)

    # Only summarize if there's meaningful content
    content_text =
      summarizable
      |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} ->
        "#{k}: #{inspect(v, limit: 500, printable_limit: 1000)}"
      end)

    if content_text == "" do
      context
    else
      detail_instruction = summary_detail_instruction(level)

      prompt =
        "Summarize the following pipeline context for the next processing stage. " <>
          detail_instruction <>
          "\n\nContext:\n#{content_text}\n\nProvide a concise summary:"

      case llm_fn.(prompt, model: "fast") do
        {:ok, summary} ->
          new_values =
            passthrough
            |> Map.new()
            |> Map.put("context.summary", summary)
            |> Map.put("context.summary.level", level)

          %{context | values: new_values}

        {:error, _reason} ->
          # LLM failure — fall back to compact
          transform_values(context, &compact_value/2)
      end
    end
  end

  defp summary_detail_instruction("low") do
    "Keep it very brief — one or two sentences capturing only the essential state."
  end

  defp summary_detail_instruction("medium") do
    "Include key decisions, outputs, and state. A short paragraph."
  end

  defp summary_detail_instruction("high") do
    "Provide a detailed summary preserving important context, decisions, " <>
      "intermediate results, and any error states. Multiple paragraphs are fine."
  end
end
