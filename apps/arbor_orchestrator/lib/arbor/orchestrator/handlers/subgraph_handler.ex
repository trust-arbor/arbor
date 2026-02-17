defmodule Arbor.Orchestrator.Handlers.SubgraphHandler do
  @moduledoc """
  Handler for hierarchical graph composition.

  Executes a child graph from within a parent graph with explicit
  context passing and result mapping. No implicit inheritance —
  child graphs start with empty context unless explicitly given keys.

  Dispatches by `type` attribute:

    * `graph.invoke`  — execute a named or file-referenced child graph
    * `graph.compose` — execute a DOT string from context

  ## Node attributes

    * `graph_name`       — resolve from GraphRegistry
    * `graph_file`       — path to .dot file
    * `graph_source_key` — context key containing DOT string (for invoke)
    * `source_key`       — context key containing DOT string (for compose, default: `"last_response"`)
    * `pass_context`     — comma-separated list of context keys to pass to child
    * `pass_all_context` — `"true"` to pass entire parent context (not recommended)
    * `result_mapping`   — comma-separated `child_key:parent_key` pairs
    * `result_prefix`    — prefix for all child context keys (default: `"subgraph.<node_id>."`)
    * `ignore_child_failure` — `"true"` to continue even if child fails
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.GraphRegistry

  @impl true
  def execute(node, context, _graph, opts) do
    type = Map.get(node.attrs, "type", "graph.invoke")
    handle_type(type, node, context, opts)
  rescue
    e -> fail("#{Map.get(node.attrs, "type")}: #{Exception.message(e)}")
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Dispatch ---

  defp handle_type("graph.invoke", node, context, opts) do
    with {:ok, dot_source} <- resolve_graph_source(node, context),
         {:ok, child_context_values} <- build_child_context(node, context),
         {:ok, child_opts} <- build_child_opts(node, opts) do
      run_child(dot_source, child_context_values, child_opts, node, context)
    else
      {:error, reason} -> fail("graph.invoke: #{inspect(reason)}")
    end
  end

  defp handle_type("graph.compose", node, context, opts) do
    source_key = Map.get(node.attrs, "source_key", "last_response")
    dot_source = Context.get(context, source_key)

    if dot_source do
      with {:ok, child_context_values} <- build_child_context(node, context),
           {:ok, child_opts} <- build_child_opts(node, opts) do
        run_child(dot_source, child_context_values, child_opts, node, context)
      else
        {:error, reason} -> fail("graph.compose: #{inspect(reason)}")
      end
    else
      fail("graph.compose: no DOT source at context key '#{source_key}'")
    end
  end

  defp handle_type(type, _node, _context, _opts) do
    fail("unknown graph node type: #{type}")
  end

  # --- Child execution ---

  defp run_child(dot_source, child_context_values, child_opts, node, _context) do
    child_opts = Keyword.put(child_opts, :initial_values, child_context_values)

    case Arbor.Orchestrator.run(dot_source, child_opts) do
      {:ok, result} ->
        child_status = result.final_outcome && result.final_outcome.status
        ignore_failure = Map.get(node.attrs, "ignore_child_failure") == "true"

        context_updates =
          map_child_results(node, result.context)
          |> Map.put("subgraph.#{node.id}.status", to_string(child_status || :unknown))
          |> Map.put(
            "subgraph.#{node.id}.nodes_completed",
            length(result.completed_nodes)
          )

        if child_status == :success or ignore_failure do
          %Outcome{
            status: :success,
            notes: "Child graph completed: #{length(result.completed_nodes)} nodes",
            context_updates: context_updates
          }
        else
          failure_reason =
            (result.final_outcome && result.final_outcome.failure_reason) || "unknown"

          %Outcome{
            status: :fail,
            failure_reason: "Child graph failed: #{failure_reason}",
            context_updates: context_updates
          }
        end

      {:error, reason} ->
        ignore_failure = Map.get(node.attrs, "ignore_child_failure") == "true"

        if ignore_failure do
          %Outcome{
            status: :success,
            notes: "Child graph error (ignored): #{inspect(reason)}",
            context_updates: %{
              "subgraph.#{node.id}.status" => "error",
              "subgraph.#{node.id}.error" => inspect(reason)
            }
          }
        else
          fail("child graph error: #{inspect(reason)}")
        end
    end
  end

  # --- Graph resolution ---

  defp resolve_graph_source(node, context) do
    cond do
      name = Map.get(node.attrs, "graph_name") ->
        GraphRegistry.resolve(name)

      file = Map.get(node.attrs, "graph_file") ->
        case File.read(Path.expand(file)) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:file_read, reason, file}}
        end

      key = Map.get(node.attrs, "graph_source_key") ->
        case Context.get(context, key) do
          nil -> {:error, "no DOT source at context key '#{key}'"}
          dot -> {:ok, dot}
        end

      true ->
        {:error, "no graph source: set graph_name, graph_file, or graph_source_key"}
    end
  end

  # --- Context isolation ---

  defp build_child_context(node, context) do
    cond do
      Map.get(node.attrs, "pass_all_context") == "true" ->
        {:ok, context.values}

      keys_str = Map.get(node.attrs, "pass_context") ->
        keys = String.split(keys_str, ",") |> Enum.map(&String.trim/1)

        values =
          Enum.reduce(keys, %{}, fn key, acc ->
            case Context.get(context, key) do
              nil -> acc
              val -> Map.put(acc, key, val)
            end
          end)

        {:ok, values}

      true ->
        {:ok, %{}}
    end
  end

  # --- Result mapping ---

  defp map_child_results(node, child_context) when is_map(child_context) do
    case Map.get(node.attrs, "result_mapping") do
      mapping when not is_nil(mapping) ->
        apply_explicit_mapping(mapping, child_context)

      _ ->
        prefix = Map.get(node.attrs, "result_prefix", "subgraph.#{node.id}.")
        apply_prefix_mapping(prefix, child_context)
    end
  end

  defp map_child_results(_node, _), do: %{}

  defp apply_explicit_mapping(mapping_str, child_context) do
    mapping_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, ":", parts: 2) do
        [child_key, parent_key] ->
          case Map.get(child_context, String.trim(child_key)) do
            nil -> acc
            val -> Map.put(acc, String.trim(parent_key), val)
          end

        _ ->
          acc
      end
    end)
  end

  defp apply_prefix_mapping(prefix, child_context) do
    child_context
    |> Enum.filter(fn {key, _} ->
      is_binary(key) and not String.starts_with?(key, "graph.")
    end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
        Map.put(acc, "#{prefix}#{key}", value)
      else
        acc
      end
    end)
  end

  # --- Child opts ---

  defp build_child_opts(node, parent_opts) do
    child_opts = Keyword.take(parent_opts, [:on_event])

    logs_root = Keyword.get(parent_opts, :logs_root)

    child_opts =
      if logs_root do
        child_logs = Path.join(logs_root, "subgraph_#{node.id}")
        File.mkdir_p(child_logs)
        Keyword.put(child_opts, :logs_root, child_logs)
      else
        child_opts
      end

    {:ok, child_opts}
  end

  defp fail(reason) do
    %Outcome{status: :fail, failure_reason: reason}
  end
end
