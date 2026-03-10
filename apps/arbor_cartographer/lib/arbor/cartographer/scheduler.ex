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
  - `{:max_load, number}` — maximum load score (0-100, default: 90)

  ## Strategies

  - `:first_match` — first node meeting all requirements (default)
  - `:least_loaded` — lowest load among matching nodes
  - `:most_resources` — most memory/CPUs among matching nodes
  - `:round_robin` — distribute evenly (stateful, uses persistent_term)

  ## Resource Guards

  By default, nodes with load > 90% are excluded from scheduling.
  Override with `max_load:` option or `{:max_load, n}` requirement.

  ## Circuit Breaker

  Nodes that fail RPC calls are tracked. After 3 failures within 60 seconds,
  a node is "tripped" and excluded from scheduling for 30 seconds. This
  prevents repeated attempts to route work to unreachable or flapping nodes.

  Use `report_failure/1` to record failures and `circuit_status/0` to inspect.
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
          | {:max_load, number()}

  @type strategy :: :first_match | :least_loaded | :most_resources | :round_robin

  # Circuit breaker defaults
  @failure_threshold 3
  @failure_window_ms :timer.seconds(60)
  @cooldown_ms :timer.seconds(30)

  # Resource guard default
  @default_max_load 90.0

  # ETS table for circuit breaker state
  @breaker_table :arbor_scheduler_circuit_breaker

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Select the best node matching the given requirements and strategy.

  Returns `{:ok, node}` or `{:error, :no_matching_node}`.

  ## Options

  - `:requirements` — list of requirement tuples (default: [])
  - `:strategy` — selection strategy (default: :first_match)
  - `:exclude` — list of nodes to exclude
  - `:max_load` — override default load threshold (default: 90.0)
  - `:skip_circuit_breaker` — bypass circuit breaker checks (default: false)
  - `:skip_resource_guard` — bypass load threshold checks (default: false)
  """
  @spec select_node(keyword()) :: {:ok, node()} | {:error, :no_matching_node}
  def select_node(opts \\ []) do
    requirements = Keyword.get(opts, :requirements, [])
    strategy = Keyword.get(opts, :strategy, :first_match)
    exclude = Keyword.get(opts, :exclude, [])
    skip_breaker = Keyword.get(opts, :skip_circuit_breaker, false)
    skip_guard = Keyword.get(opts, :skip_resource_guard, false)

    # Extract max_load from requirements or options
    max_load = extract_max_load(requirements, opts)
    requirements = Enum.reject(requirements, &match?({:max_load, _}, &1))

    tripped = if skip_breaker, do: [], else: tripped_nodes()

    candidates =
      all_nodes()
      |> Enum.reject(fn node -> node in exclude end)
      |> Enum.reject(fn node -> node in tripped end)
      |> Enum.filter(fn node -> meets_requirements?(node, requirements) end)

    # Apply resource guard (filter overloaded nodes)
    candidates = maybe_apply_resource_guard(candidates, skip_guard, max_load)

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

  # ── Circuit Breaker API ────────────────────────────────────────────

  @doc """
  Report a failure for a node (e.g., RPC timeout, crash).

  After `#{@failure_threshold}` failures within `#{div(@failure_window_ms, 1000)}s`,
  the node is tripped and excluded from scheduling for `#{div(@cooldown_ms, 1000)}s`.
  """
  @spec report_failure(node()) :: :ok | :tripped
  def report_failure(node) do
    ensure_breaker_table()
    now = System.monotonic_time(:millisecond)

    # Get existing failures, prune old ones
    failures =
      case :ets.lookup(@breaker_table, {:failures, node}) do
        [{_, existing}] -> Enum.filter(existing, fn ts -> now - ts < @failure_window_ms end)
        [] -> []
      end

    failures = [now | failures]
    :ets.insert(@breaker_table, {{:failures, node}, failures})

    if length(failures) >= @failure_threshold do
      trip_node(node, now)
      :tripped
    else
      :ok
    end
  end

  @doc """
  Report a successful interaction with a node, clearing its failure history.
  """
  @spec report_success(node()) :: :ok
  def report_success(node) do
    ensure_breaker_table()
    :ets.delete(@breaker_table, {:failures, node})
    :ets.delete(@breaker_table, {:tripped, node})
    :ok
  end

  @doc """
  Reset the circuit breaker for a specific node.
  """
  @spec reset_breaker(node()) :: :ok
  def reset_breaker(node) do
    report_success(node)
  end

  @doc """
  Reset all circuit breaker state.
  """
  @spec reset_all_breakers() :: :ok
  def reset_all_breakers do
    ensure_breaker_table()
    :ets.delete_all_objects(@breaker_table)
    :ok
  end

  @doc """
  Get circuit breaker status for all tracked nodes.

  Returns a map of `%{node => %{status: :ok | :tripped, failures: count, ...}}`.
  """
  @spec circuit_status() :: map()
  def circuit_status do
    ensure_breaker_table()
    now = System.monotonic_time(:millisecond)

    # Collect all nodes with failure or trip records
    nodes =
      :ets.foldl(
        fn
          {{:failures, node}, _}, acc -> MapSet.put(acc, node)
          {{:tripped, node}, _}, acc -> MapSet.put(acc, node)
          _, acc -> acc
        end,
        MapSet.new(),
        @breaker_table
      )

    Map.new(nodes, fn node ->
      failures =
        case :ets.lookup(@breaker_table, {:failures, node}) do
          [{_, fs}] -> Enum.filter(fs, fn ts -> now - ts < @failure_window_ms end)
          [] -> []
        end

      tripped_info =
        case :ets.lookup(@breaker_table, {:tripped, node}) do
          [{_, tripped_at}] ->
            remaining = max(0, @cooldown_ms - (now - tripped_at))
            if remaining > 0, do: %{tripped_at: tripped_at, remaining_ms: remaining}, else: nil

          [] ->
            nil
        end

      status = if tripped_info, do: :tripped, else: :ok

      info = %{
        status: status,
        failures: length(failures),
        failure_threshold: @failure_threshold
      }

      info =
        if tripped_info, do: Map.put(info, :remaining_ms, tripped_info.remaining_ms), else: info

      {node, info}
    end)
  end

  @doc """
  Check if a specific node's circuit breaker is tripped.
  """
  @spec node_tripped?(node()) :: boolean()
  def node_tripped?(node) do
    node in tripped_nodes()
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

  defp check_requirement(_node, _hw, {:max_load, _}), do: true

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

  # ── Circuit Breaker Internals ──────────────────────────────────────

  defp ensure_breaker_table do
    case :ets.info(@breaker_table) do
      :undefined ->
        :ets.new(@breaker_table, [:named_table, :public, :set])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp trip_node(node, now) do
    :ets.insert(@breaker_table, {{:tripped, node}, now})

    Logger.warning(
      "[Scheduler] Circuit breaker tripped for #{node} — " <>
        "#{@failure_threshold} failures in #{div(@failure_window_ms, 1000)}s, " <>
        "excluded for #{div(@cooldown_ms, 1000)}s"
    )
  end

  defp tripped_nodes do
    ensure_breaker_table()
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn
        {{:tripped, node}, tripped_at}, acc ->
          if now - tripped_at < @cooldown_ms do
            [node | acc]
          else
            # Cooldown expired — auto-reset
            :ets.delete(@breaker_table, {:tripped, node})
            :ets.delete(@breaker_table, {:failures, node})
            acc
          end

        _, acc ->
          acc
      end,
      [],
      @breaker_table
    )
  end

  # ── Resource Guard Helpers ─────────────────────────────────────────

  defp maybe_apply_resource_guard(candidates, true, _max_load), do: candidates

  defp maybe_apply_resource_guard(candidates, false, max_load) do
    Enum.filter(candidates, fn node -> get_load(node) <= max_load end)
  end

  defp extract_max_load(requirements, opts) do
    # Check requirements first, then options, then default
    case Enum.find(requirements, &match?({:max_load, _}, &1)) do
      {:max_load, threshold} -> threshold
      nil -> Keyword.get(opts, :max_load, @default_max_load)
    end
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
