defmodule Arbor.Orchestrator.Handlers.CodergenHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def execute(node, context, graph, opts) do
    goal = Map.get(graph.attrs, "goal", "")

    prompt =
      node.attrs
      |> Map.get("prompt", Map.get(node.attrs, "label", node.id))
      |> String.replace("$goal", to_string(goal))

    base_updates = %{
      "last_stage" => node.id,
      "last_prompt" => prompt,
      "last_response" => "[Simulated] Response for stage: #{node.id}",
      "context.previous_outcome" => Arbor.Orchestrator.Engine.Context.get(context, "outcome"),
      "llm.model" => Map.get(node.attrs, "llm_model"),
      "llm.provider" => Map.get(node.attrs, "llm_provider"),
      "llm.reasoning_effort" => Map.get(node.attrs, "reasoning_effort"),
      "score" => parse_score(Map.get(node.attrs, "score"))
    }

    response = "[Simulated] Response for stage: #{node.id}"
    _ = write_stage_artifacts(opts, node.id, prompt, response)

    case Map.get(node.attrs, "simulate") do
      "fail" ->
        %Outcome{
          status: :fail,
          failure_reason: "simulated failure",
          context_updates: base_updates
        }

      "retry" ->
        %Outcome{
          status: :retry,
          failure_reason: "simulated retry",
          context_updates: base_updates
        }

      "fail_once" ->
        key = "internal.simulate.fail_once.#{node.id}"
        attempts = Arbor.Orchestrator.Engine.Context.get(context, key, 0)

        if attempts == 0 do
          %Outcome{
            status: :fail,
            failure_reason: "simulated fail once",
            context_updates: Map.put(base_updates, key, 1)
          }
        else
          %Outcome{
            status: :success,
            notes: "Stage completed: #{node.id}",
            context_updates: base_updates
          }
        end

      "raise_retryable" ->
        raise "network timeout"

      "raise_terminal" ->
        raise "401 unauthorized"

      _ ->
        %Outcome{
          status: :success,
          notes: "Stage completed: #{node.id}",
          context_updates: base_updates
        }
    end
  end

  defp parse_score(nil), do: nil
  defp parse_score(value) when is_integer(value), do: value / 1
  defp parse_score(value) when is_float(value), do: value

  defp parse_score(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_score(_), do: nil

  defp write_stage_artifacts(opts, node_id, prompt, response) do
    case Keyword.get(opts, :logs_root) do
      nil ->
        :ok

      logs_root ->
        node_dir = Path.join(logs_root, node_id)

        with :ok <- File.mkdir_p(node_dir),
             :ok <- File.write(Path.join(node_dir, "prompt.md"), prompt),
             :ok <- File.write(Path.join(node_dir, "response.md"), response) do
          :ok
        else
          _ -> :ok
        end
    end
  end
end
