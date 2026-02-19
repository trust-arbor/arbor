defmodule Arbor.Orchestrator.Middleware.TaintCheck do
  @moduledoc """
  Mandatory middleware that propagates taint classification through pipeline execution.

  Bridges to `Arbor.Signals.Taint` when available. Classifies node inputs
  before execution and propagates taint labels to outputs after execution.

  Supports both legacy atom-based taint labels and the 4-dimensional Taint struct
  from `Arbor.Contracts.Security.Taint`.

  No-op when Arbor.Signals.Taint is not loaded.

  ## Token Assigns

    - `:taint_labels` — accumulated taint labels from prior nodes (atom or struct)
    - `:skip_taint_check` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  alias Arbor.Orchestrator.Engine.Context

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
        value = Context.get(token.context, key)

        if is_binary(value) do
          label = classify_value(value, token.node)
          Map.put(acc, key, label)
        else
          acc
        end
      end)

    Token.assign(token, :taint_labels, new_labels)
  end

  defp propagate_taint(token) do
    if token.outcome && token.outcome.context_updates do
      labels = Map.get(token.assigns, :taint_labels, %{})

      # Check if any input was tainted
      tainted_inputs =
        Enum.any?(labels, fn {_k, v} ->
          extract_level(v) != :trusted
        end)

      if tainted_inputs do
        output_labels =
          token.outcome.context_updates
          |> Map.keys()
          |> Enum.reduce(labels, fn key, acc ->
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
    attrs = node.attrs

    keys =
      for key <- ["source_key", "input_key", "graph_source_key"],
          val = Map.get(attrs, key),
          val != nil,
          do: val

    # Always check last_response as a common input
    ["last_response" | keys] |> Enum.uniq()
  end

  # Classify a value, optionally using file-path heuristics from node attrs
  defp classify_value(value, node) do
    # Try file-path-based classification first (council decision #3)
    case auto_classify_by_path(node) do
      nil -> classify_by_content(value)
      taint -> taint
    end
  end

  # File-path patterns for auto-classification
  defp auto_classify_by_path(node) do
    path = Map.get(node.attrs, "path") || Map.get(node.attrs, "file_path")

    if is_binary(path) do
      cond do
        String.contains?(path, [".env", "credentials", "secret", "private_key"]) ->
          make_taint_struct(:untrusted, :restricted)

        String.contains?(path, ["/tmp/", "/var/", "/proc/"]) ->
          make_taint_struct(:untrusted, :internal)

        true ->
          nil
      end
    else
      nil
    end
  end

  defp classify_by_content(_value) do
    if struct_propagation_available?() do
      # Use struct-aware propagation
      make_taint_struct(:trusted, :internal)
    else
      # Legacy atom classification
      :trusted
    end
  end

  defp make_taint_struct(level, sensitivity) do
    taint_struct = Arbor.Contracts.Security.Taint

    if Code.ensure_loaded?(taint_struct) do
      struct(taint_struct, level: level, sensitivity: sensitivity)
    else
      level
    end
  end

  # Extract level from either atom or struct taint labels
  defp extract_level(label) when is_atom(label), do: label
  defp extract_level(%{level: level}), do: level
  defp extract_level(_), do: :unknown

  defp worst_taint([]), do: :unknown

  defp worst_taint(labels) do
    if struct_propagation_available?() do
      # Try struct-based propagation
      structs =
        Enum.filter(labels, fn
          %{__struct__: _} -> true
          _ -> false
        end)

      if structs != [] do
        apply(Arbor.Signals.Taint, :propagate_taint, [structs])
      else
        worst_taint_atoms(labels)
      end
    else
      worst_taint_atoms(labels)
    end
  end

  defp worst_taint_atoms(labels) do
    severity = %{hostile: 4, untrusted: 3, derived: 2, unknown: 1, trusted: 0}

    labels
    |> Enum.map(&extract_level/1)
    |> Enum.max_by(fn label -> Map.get(severity, label, 0) end)
  end

  defp taint_available? do
    Code.ensure_loaded?(Arbor.Signals.Taint)
  end

  defp struct_propagation_available? do
    Code.ensure_loaded?(Arbor.Signals.Taint) and
      function_exported?(Arbor.Signals.Taint, :propagate_taint, 1)
  end
end
