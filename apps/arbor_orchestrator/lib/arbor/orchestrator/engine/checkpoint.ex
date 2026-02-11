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

  @doc """
  Signs checkpoint data with HMAC-SHA256.

  Returns the data map with an `"__hmac"` field containing the hex-encoded
  HMAC of the JSON-encoded data (computed without the `__hmac` field).
  """
  @spec sign(map(), binary()) :: map()
  def sign(data, secret) when is_map(data) and is_binary(secret) do
    clean = Map.delete(data, "__hmac")
    {:ok, canonical} = Jason.encode(clean, pretty: true)
    hmac = :crypto.mac(:hmac, :sha256, secret, canonical) |> Base.encode16(case: :lower)
    Map.put(clean, "__hmac", hmac)
  end

  @doc """
  Verifies HMAC integrity of checkpoint data.

  Recomputes the HMAC and compares using constant-time comparison.
  Returns `{:ok, data_without_hmac}` or `{:error, :tampered}`.
  """
  @spec verify(map(), binary()) :: {:ok, map()} | {:error, :tampered}
  def verify(data, secret) when is_map(data) and is_binary(secret) do
    case Map.pop(data, "__hmac") do
      {nil, _} ->
        {:error, :tampered}

      {stored_hmac, clean} ->
        {:ok, canonical} = Jason.encode(clean, pretty: true)
        computed = :crypto.mac(:hmac, :sha256, secret, canonical) |> Base.encode16(case: :lower)

        if :crypto.hash_equals(stored_hmac, computed) do
          {:ok, clean}
        else
          {:error, :tampered}
        end
    end
  end

  @spec write(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = checkpoint, logs_root, opts \\ []) do
    encoded_outcomes =
      checkpoint.node_outcomes
      |> Enum.map(fn {node_id, outcome} -> {node_id, Map.from_struct(outcome)} end)
      |> Map.new()

    payload_map =
      checkpoint
      |> Map.from_struct()
      |> Map.put(:node_outcomes, encoded_outcomes)

    payload_map =
      case Keyword.get(opts, :hmac_secret) do
        nil -> payload_map
        secret -> sign(payload_map, secret)
      end

    with :ok <- File.mkdir_p(logs_root),
         {:ok, payload} <- Jason.encode(payload_map, pretty: true) do
      File.write(Path.join(logs_root, "checkpoint.json"), payload)
    end
  end

  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, decoded} <- maybe_verify(decoded, Keyword.get(opts, :hmac_secret)) do
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

  defp maybe_verify(decoded, nil), do: {:ok, decoded}
  defp maybe_verify(decoded, secret), do: verify(decoded, secret)

  defp parse_status("success"), do: :success
  defp parse_status("partial_success"), do: :partial_success
  defp parse_status("retry"), do: :retry
  defp parse_status("fail"), do: :fail
  defp parse_status("skipped"), do: :skipped
  defp parse_status(_), do: :success
end
