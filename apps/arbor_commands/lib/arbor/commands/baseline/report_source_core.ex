defmodule Arbor.Commands.Baseline.ReportSourceCore do
  @moduledoc """
  Pure decision of which baseline-status observations to trust.

  The Mix task reports whether a local Arbor node was reachable. This
  core chooses the `StatusCore` input and the printed source label.
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

  @spec decide(state()) :: decision()
  def decide(%{reachability: :reachable, local: local, node: node}) when is_map(node) do
    %{source: "node", input: merge_node(local, node)}
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

  @spec show(decision()) :: decision()
  def show(%{source: source, input: input} = decision)
      when is_binary(source) and is_map(input) do
    decision
  end

  def show(_decision), do: %{source: "local (node not running)", input: %{}}

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

  defp local_map(local) when is_map(local), do: local
  defp local_map(_local), do: %{}

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
