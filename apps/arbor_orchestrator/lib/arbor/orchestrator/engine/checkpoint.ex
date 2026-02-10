defmodule Arbor.Orchestrator.Engine.Checkpoint do
  @moduledoc false

  @type t :: %__MODULE__{
          timestamp: String.t(),
          current_node: String.t(),
          completed_nodes: [String.t()],
          node_retries: map(),
          context_values: map(),
          node_outcomes: %{String.t() => Arbor.Orchestrator.Engine.Outcome.t()}
        }

  defstruct timestamp: "",
            current_node: "",
            completed_nodes: [],
            node_retries: %{},
            context_values: %{},
            node_outcomes: %{}

  @spec from_state(
          String.t(),
          [String.t()],
          map(),
          Arbor.Orchestrator.Engine.Context.t(),
          map()
        ) :: t()
  def from_state(current_node, completed_nodes, node_retries, context, node_outcomes) do
    %__MODULE__{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      current_node: current_node,
      completed_nodes: completed_nodes,
      node_retries: node_retries,
      context_values: Arbor.Orchestrator.Engine.Context.snapshot(context),
      node_outcomes: node_outcomes
    }
  end

  @spec write(t(), String.t()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = checkpoint, logs_root) do
    encoded_outcomes =
      checkpoint.node_outcomes
      |> Enum.map(fn {node_id, outcome} -> {node_id, Map.from_struct(outcome)} end)
      |> Map.new()

    payload_map =
      checkpoint
      |> Map.from_struct()
      |> Map.put(:node_outcomes, encoded_outcomes)

    with :ok <- File.mkdir_p(logs_root),
         {:ok, payload} <- Jason.encode(payload_map, pretty: true) do
      File.write(Path.join(logs_root, "checkpoint.json"), payload)
    end
  end

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload) do
      outcomes =
        decoded
        |> Map.get("node_outcomes", %{})
        |> Enum.map(fn {node_id, outcome_map} ->
          {node_id,
           %Arbor.Orchestrator.Engine.Outcome{
             status: parse_status(Map.get(outcome_map, "status", "success")),
             preferred_label: Map.get(outcome_map, "preferred_label"),
             suggested_next_ids: Map.get(outcome_map, "suggested_next_ids", []),
             context_updates: Map.get(outcome_map, "context_updates", %{}),
             notes: Map.get(outcome_map, "notes"),
             failure_reason: Map.get(outcome_map, "failure_reason")
           }}
        end)
        |> Map.new()

      {:ok,
       %__MODULE__{
         timestamp: Map.get(decoded, "timestamp", ""),
         current_node: Map.get(decoded, "current_node", ""),
         completed_nodes: Map.get(decoded, "completed_nodes", []),
         node_retries: Map.get(decoded, "node_retries", %{}),
         context_values: Map.get(decoded, "context_values", %{}),
         node_outcomes: outcomes
       }}
    end
  end

  defp parse_status("success"), do: :success
  defp parse_status("partial_success"), do: :partial_success
  defp parse_status("retry"), do: :retry
  defp parse_status("fail"), do: :fail
  defp parse_status("skipped"), do: :skipped
  defp parse_status(_), do: :success
end
