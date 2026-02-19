defmodule Arbor.Orchestrator.Middleware.TaintCheck do
  @moduledoc """
  Mandatory middleware that propagates taint classification through pipeline execution.

  Bridges to `Arbor.Signals.Taint` when available. Classifies node inputs
  before execution and propagates taint labels to outputs after execution.

  No-op when Arbor.Signals.Taint is not loaded.

  ## Token Assigns

    - `:taint_labels` — accumulated taint labels from prior nodes
    - `:skip_taint_check` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  @impl true
  def before_node(token) do
    if Map.get(token.assigns, :skip_taint_check, false) or not taint_available?() do
      token
    else
      classify_inputs(token)
    end
  end

  @impl true
  def after_node(token) do
    if Map.get(token.assigns, :skip_taint_check, false) or not taint_available?() do
      token
    else
      propagate_taint(token)
    end
  end

  defp classify_inputs(token) do
    # Classify context values that will be used by this node
    input_keys = extract_input_keys(token.node)
    existing_labels = Map.get(token.assigns, :taint_labels, %{})

    new_labels =
      Enum.reduce(input_keys, existing_labels, fn key, acc ->
        value = Arbor.Orchestrator.Engine.Context.get(token.context, key)

        if is_binary(value) do
          case classify(value) do
            {:ok, label} -> Map.put(acc, key, label)
            _ -> acc
          end
        else
          acc
        end
      end)

    Token.assign(token, :taint_labels, new_labels)
  end

  defp propagate_taint(token) do
    if token.outcome && token.outcome.context_updates do
      labels = Map.get(token.assigns, :taint_labels, %{})

      # If any input was tainted, propagate to outputs
      tainted_inputs = Enum.any?(labels, fn {_k, v} -> v != :trusted end)

      if tainted_inputs do
        output_labels =
          token.outcome.context_updates
          |> Map.keys()
          |> Enum.reduce(labels, fn key, acc ->
            # Inherit the most restrictive taint from inputs
            worst = worst_taint(Map.values(labels))
            Map.put(acc, key, worst)
          end)

        Token.assign(token, :taint_labels, output_labels)
      else
        token
      end
    else
      token
    end
  end

  defp extract_input_keys(node) do
    # Extract context keys this node reads from
    attrs = node.attrs

    keys =
      for key <- ["source_key", "input_key", "graph_source_key"],
          val = Map.get(attrs, key),
          val != nil,
          do: val

    # Always check last_response as a common input
    ["last_response" | keys] |> Enum.uniq()
  end

  defp classify(value) do
    if taint_available?() do
      try do
        apply(Arbor.Signals.Taint, :classify, [value])
      rescue
        _ -> {:ok, :unknown}
      end
    else
      {:ok, :unknown}
    end
  end

  defp worst_taint([]), do: :unknown

  defp worst_taint(labels) do
    severity = %{hostile: 4, untrusted: 3, unknown: 2, trusted: 1}

    labels
    |> Enum.max_by(fn label -> Map.get(severity, label, 0) end)
  end

  defp taint_available? do
    Code.ensure_loaded?(Arbor.Signals.Taint) and
      function_exported?(Arbor.Signals.Taint, :classify, 1)
  end
end
