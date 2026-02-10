defmodule Arbor.Orchestrator.Handlers.PipelineValidateHandler do
  @moduledoc """
  Handler that parses and validates DOT content from the pipeline context.

  Node attributes:
    - `source_key` - context key containing DOT string (default: "last_response")
    - `source_file` - alternative: path to a .dot file to validate
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

      case Arbor.Orchestrator.parse(source) do
        {:ok, parsed_graph} ->
          diagnostics = Arbor.Orchestrator.validate(parsed_graph)
          errors = Enum.filter(diagnostics, &(&1.severity == :error))
          valid = errors == []

          diag_messages =
            Enum.map(diagnostics, fn d ->
              %{
                "rule" => d.rule,
                "severity" => to_string(d.severity),
                "message" => d.message,
                "node_id" => d.node_id,
                "fix" => d.fix
              }
            end)

          if valid do
            %Outcome{
              status: :success,
              notes:
                "DOT parsed and validated: #{map_size(parsed_graph.nodes)} nodes, #{length(diagnostics)} diagnostics, 0 errors",
              context_updates: %{
                "pipeline.valid.#{node.id}" => true,
                "pipeline.node_count.#{node.id}" => map_size(parsed_graph.nodes),
                "pipeline.diagnostics.#{node.id}" => diag_messages,
                "pipeline.dot_source.#{node.id}" => source
              }
            }
          else
            error_msgs =
              errors
              |> Enum.map(fn d -> "[#{d.rule}] #{d.message}" end)
              |> Enum.join("; ")

            %Outcome{
              status: :fail,
              failure_reason: "Validation errors: #{error_msgs}",
              context_updates: %{
                "pipeline.valid.#{node.id}" => false,
                "pipeline.diagnostics.#{node.id}" => diag_messages,
                "pipeline.dot_source.#{node.id}" => source
              }
            }
          end

        {:error, reason} ->
          %Outcome{
            status: :fail,
            failure_reason: "DOT parse error: #{reason}",
            context_updates: %{
              "pipeline.valid.#{node.id}" => false,
              "pipeline.dot_source.#{node.id}" => source
            }
          }
      end
    rescue
      e ->
        %Outcome{
          status: :fail,
          failure_reason: "pipeline.validate error: #{Exception.message(e)}"
        }
    end
  end

  @impl true
  def idempotency, do: :read_only

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
end
