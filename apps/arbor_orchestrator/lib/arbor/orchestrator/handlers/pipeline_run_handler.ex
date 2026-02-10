defmodule Arbor.Orchestrator.Handlers.PipelineRunHandler do
  @moduledoc """
  Handler that executes a child pipeline (DOT graph) synchronously.

  Node attributes:
    - `source_key` - context key containing DOT string (default: "last_response")
    - `source_file` - alternative: path to a .dot file to run
    - `workdir` - working directory for the child pipeline (inherits parent if unset)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, opts) do
    try do
      source = get_source(node, context, opts)

      unless source do
        raise "no DOT source found — set 'source_key' or 'source_file' attribute"
      end

      child_opts = build_child_opts(node, context, opts)

      case Arbor.Orchestrator.run(source, child_opts) do
        {:ok, result} ->
          child_status = result.final_outcome && result.final_outcome.status
          completed = length(result.completed_nodes)

          context_updates =
            %{
              "pipeline.ran.#{node.id}" => true,
              "pipeline.child_status.#{node.id}" => to_string(child_status || :unknown),
              "pipeline.child_nodes_completed.#{node.id}" => completed
            }
            |> merge_child_context(node.id, result.context)

          if child_status == :success do
            %Outcome{
              status: :success,
              notes: "Child pipeline completed: #{completed} nodes",
              context_updates: context_updates
            }
          else
            %Outcome{
              status: :fail,
              failure_reason:
                "Child pipeline ended with status #{child_status}: #{result.final_outcome && result.final_outcome.failure_reason}",
              context_updates: context_updates
            }
          end

        {:error, reason} ->
          %Outcome{
            status: :fail,
            failure_reason: "Child pipeline error: #{inspect(reason)}",
            context_updates: %{
              "pipeline.ran.#{node.id}" => false
            }
          }
      end
    rescue
      e ->
        %Outcome{
          status: :fail,
          failure_reason: "pipeline.run error: #{Exception.message(e)}"
        }
    end
  end

  defp get_source(node, context, opts) do
    cond do
      Map.get(node.attrs, "source_file") ->
        path = Map.get(node.attrs, "source_file")
        workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")

        resolved =
          if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path)

        case File.read(Path.expand(resolved)) do
          {:ok, content} -> content
          {:error, _} -> nil
        end

      true ->
        key = Map.get(node.attrs, "source_key", "last_response")
        Context.get(context, key)
    end
  end

  defp build_child_opts(node, context, opts) do
    workdir =
      Map.get(node.attrs, "workdir") ||
        Context.get(context, "workdir") ||
        Keyword.get(opts, :workdir)

    child_opts = Keyword.take(opts, [:logs_root, :on_event])

    if workdir do
      Keyword.put(child_opts, :workdir, workdir)
    else
      child_opts
    end
  end

  # Promote selected child context values into parent context under a namespace
  defp merge_child_context(updates, node_id, child_context) when is_map(child_context) do
    child_context
    |> Enum.filter(fn {key, _v} ->
      is_binary(key) and not String.starts_with?(key, "graph.")
    end)
    |> Enum.reduce(updates, fn {key, value}, acc ->
      # Only promote JSON-serializable scalar values
      if is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
        Map.put(acc, "pipeline.child.#{node_id}.#{key}", value)
      else
        acc
      end
    end)
  end

  defp merge_child_context(updates, _node_id, _), do: updates
end
