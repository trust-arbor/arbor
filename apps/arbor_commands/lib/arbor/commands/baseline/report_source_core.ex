defmodule Arbor.Commands.Baseline.ReportSourceCore do
  @moduledoc """
  Pure decision of which baseline-status observations to trust.

  The Mix task reports whether a local Arbor node was reachable. This
  core chooses the `StatusCore` input and the printed source label.

  A report is labeled `source=node` only when every required node
  observation is present. Partial maps fall back to a fully local
  report rather than a hybrid labeled as the node's view.
  """

  @node_keys [:runtime, :baseline, :mix_lock_digest, :probe]

  @type reachability :: :reachable | :unreachable | {:error, term()}

  @type state :: %{
          reachability: reachability(),
          local: map(),
          node: map() | nil
        }

  @type decision :: %{source: String.t(), input: map()}

  @spec new(map()) :: state()
  def new(params) when is_map(params) do
    %{
      reachability: Map.get(params, :reachability, :unreachable),
      local: Map.get(params, :local, %{}),
      node: Map.get(params, :node)
    }
  end

  def new(_params) do
    %{reachability: :unreachable, local: %{}, node: nil}
  end

  @doc """
  True when `node` has every required observation key with an expected shape.

  Accepts atom or string keys. Used by the Mix task so the reachable
  path can skip local Shell probes.
  """
  @spec complete_node_observations?(term()) :: boolean()
  def complete_node_observations?(node) when is_map(node) do
    Enum.all?(@node_keys, fn key ->
      case fetch_observation(node, key) do
        {:ok, value} -> valid_observation?(key, value)
        :error -> false
      end
    end)
  end

  def complete_node_observations?(_node), do: false

  @spec decide(state()) :: decision()
  def decide(%{reachability: :reachable, local: local, node: node}) when is_map(node) do
    if complete_node_observations?(node) do
      %{source: "node", input: merge_node(local, node)}
    else
      %{source: "local (invalid_node_observations)", input: local_map(local)}
    end
  end

  def decide(%{reachability: :reachable, local: local}) do
    %{source: "local (invalid_node_observations)", input: local_map(local)}
  end

  def decide(%{reachability: :unreachable, local: local}) do
    %{source: "local (node not running)", input: local_map(local)}
  end

  def decide(%{reachability: {:error, reason}, local: local}) do
    %{source: "local (#{format_reason(reason)})", input: local_map(local)}
  end

  def decide(_state) do
    %{source: "local (node not running)", input: %{}}
  end

  defp merge_node(local, node) do
    Enum.reduce(@node_keys, local_map(local), fn key, acc ->
      case fetch_observation(node, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_observation(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp fetch_observation(_map, _key), do: :error

  defp valid_observation?(:runtime, value) when is_map(value), do: true
  defp valid_observation?(:baseline, value) when is_map(value), do: true
  defp valid_observation?(:mix_lock_digest, value) when is_binary(value), do: true
  defp valid_observation?(:mix_lock_digest, {:ok, value}) when is_binary(value), do: true
  defp valid_observation?(:mix_lock_digest, {:error, _reason}), do: true
  defp valid_observation?(:probe, {:ok, value}) when is_map(value), do: true
  defp valid_observation?(:probe, {:error, _reason}), do: true
  defp valid_observation?(_key, _value), do: false

  defp local_map(local) when is_map(local), do: local
  defp local_map(_local), do: %{}

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
