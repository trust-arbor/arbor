defmodule Arbor.Cartographer.Scheduler do
  @moduledoc """
  Capability-based node scheduler for distributed agent placement.

  Matches workload requirements against node hardware capabilities
  detected by the Cartographer, selecting the best node for a given task.

  ## Usage

      # Find a Windows node with RE tools
      {:ok, node} = Scheduler.select_node(requirements: [
        {:os, :windows},
        {:has_executable, "strings"}
      ])

      # Find the least loaded node with a GPU
      {:ok, node} = Scheduler.select_node(
        requirements: [{:gpu, true}, {:min_memory_gb, 32}],
        strategy: :least_loaded
      )

      # Any node with enough memory
      {:ok, node} = Scheduler.select_node(
        requirements: [{:min_memory_gb, 16}],
        strategy: :round_robin
      )

  ## Requirements

  Supported requirement types:

  - `{:os, :windows | :linux | :macos}` — operating system
  - `{:arch, :x86_64 | :aarch64 | :arm64}` — CPU architecture
  - `{:min_memory_gb, number}` — minimum system RAM
  - `{:min_cpus, integer}` — minimum CPU count
  - `{:gpu, true}` — has any GPU
  - `{:has_executable, binary}` — executable available in PATH
  - `{:tag, atom}` — has a specific capability tag

  ## Strategies

  - `:first_match` — first node meeting all requirements (default)
  - `:least_loaded` — lowest load among matching nodes
  - `:most_resources` — most memory/CPUs among matching nodes
  - `:round_robin` — distribute evenly (stateful, uses persistent_term)
  """

  require Logger

  @type requirement ::
          {:os, atom()}
          | {:arch, atom()}
          | {:min_memory_gb, number()}
          | {:min_cpus, pos_integer()}
          | {:gpu, boolean()}
          | {:has_executable, String.t()}
          | {:tag, atom()}

  @type strategy :: :first_match | :least_loaded | :most_resources | :round_robin

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Select the best node matching the given requirements and strategy.

  Returns `{:ok, node}` or `{:error, :no_matching_node}`.
  """
  @spec select_node(keyword()) :: {:ok, node()} | {:error, :no_matching_node}
  def select_node(opts \\ []) do
    requirements = Keyword.get(opts, :requirements, [])
    strategy = Keyword.get(opts, :strategy, :first_match)
    exclude = Keyword.get(opts, :exclude, [])

    candidates =
      all_nodes()
      |> Enum.reject(fn node -> node in exclude end)
      |> Enum.filter(fn node -> meets_requirements?(node, requirements) end)

    case apply_strategy(candidates, strategy) do
      nil -> {:error, :no_matching_node}
      node -> {:ok, node}
    end
  end

  @doc """
  List all nodes with their detected hardware capabilities.

  Useful for debugging and `mix arbor.cluster schedule` previews.
  """
  @spec list_capabilities() :: [{node(), map()}]
  def list_capabilities do
    for node <- all_nodes() do
      hw = detect_hardware(node)
      {node, hw}
    end
  end

  @doc """
  Check if a specific node meets a set of requirements.
  """
  @spec node_meets?(node(), [requirement()]) :: boolean()
  def node_meets?(node, requirements) do
    meets_requirements?(node, requirements)
  end

  # ── Requirement Matching ────────────────────────────────────────────

  defp meets_requirements?(node, requirements) do
    hw = detect_hardware(node)
    Enum.all?(requirements, fn req -> check_requirement(node, hw, req) end)
  end

  defp check_requirement(_node, hw, {:os, expected}) do
    detected = detect_os(hw)
    detected == expected
  end

  defp check_requirement(_node, hw, {:arch, expected}) do
    hw[:arch] == expected or normalize_arch(hw[:arch]) == normalize_arch(expected)
  end

  defp check_requirement(_node, hw, {:min_memory_gb, min}) do
    (hw[:memory_gb] || 0) >= min
  end

  defp check_requirement(_node, hw, {:min_cpus, min}) do
    (hw[:cpus] || 0) >= min
  end

  defp check_requirement(_node, hw, {:gpu, true}) do
    case hw[:gpu] do
      [_ | _] -> true
      _ -> false
    end
  end

  defp check_requirement(_node, _hw, {:gpu, false}), do: true

  defp check_requirement(node, _hw, {:has_executable, name}) do
    case :rpc.call(node, System, :find_executable, [name], 5_000) do
      path when is_binary(path) -> true
      _ -> false
    end
  end

  defp check_requirement(node, _hw, {:tag, tag}) do
    case :rpc.call(node, Arbor.Cartographer.CapabilityRegistry, :get_tags, [node], 5_000) do
      tags when is_list(tags) -> tag in tags
      _ -> false
    end
  end

  defp check_requirement(_node, _hw, _unknown), do: true

  # ── Strategies ──────────────────────────────────────────────────────

  defp apply_strategy([], _strategy), do: nil

  defp apply_strategy(candidates, :first_match) do
    hd(candidates)
  end

  defp apply_strategy(candidates, :least_loaded) do
    candidates
    |> Enum.map(fn node -> {node, get_load(node)} end)
    |> Enum.min_by(fn {_node, load} -> load end)
    |> elem(0)
  end

  defp apply_strategy(candidates, :most_resources) do
    candidates
    |> Enum.map(fn node ->
      hw = detect_hardware(node)
      score = (hw[:memory_gb] || 0) + (hw[:cpus] || 0)
      {node, score}
    end)
    |> Enum.max_by(fn {_node, score} -> score end)
    |> elem(0)
  end

  defp apply_strategy(candidates, :round_robin) do
    key = {__MODULE__, :rr_index}

    index =
      try do
        :persistent_term.get(key)
      rescue
        ArgumentError -> 0
      end

    selected = Enum.at(candidates, rem(index, length(candidates)))
    :persistent_term.put(key, index + 1)
    selected
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp all_nodes do
    [Node.self() | Node.list()]
    |> Enum.reject(fn n -> Atom.to_string(n) |> String.starts_with?("arbor_mix_") end)
    |> Enum.sort()
  end

  defp detect_hardware(node) do
    case :rpc.call(node, Arbor.Cartographer, :detect_hardware, [], 10_000) do
      {:ok, hw} -> hw
      _ -> %{}
    end
  end

  defp get_load(node) do
    case :rpc.call(node, Arbor.Cartographer, :get_node_load, [node], 5_000) do
      {:ok, load} when is_number(load) -> load
      _ -> 999.0
    end
  end

  defp detect_os(hw) do
    cond do
      hw[:os_platform] == "windows" -> :windows
      hw[:os_platform] == "linux" -> :linux
      hw[:os_platform] == "darwin" -> :macos
      hw[:os_name] && String.contains?(to_string(hw[:os_name]), "Windows") -> :windows
      hw[:os_name] && String.contains?(to_string(hw[:os_name]), "Mac") -> :macos
      true -> :unknown
    end
  end

  defp normalize_arch(:arm64), do: :aarch64
  defp normalize_arch(:aarch64), do: :aarch64
  defp normalize_arch(:x86_64), do: :x86_64
  defp normalize_arch(other), do: other
end
