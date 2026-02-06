defmodule Arbor.Demo.Timing do
  @moduledoc """
  Timing configuration for demo scenarios.

  Provides tunable timing parameters for different demo contexts:
  - `:fast` - Aggressive timing for quick rehearsals (~45s total)
  - `:normal` - Balanced timing for typical demos (~60s total)
  - `:slow` - Relaxed timing for unreliable conditions (~90s total)

  ## Usage

      # Set timing mode
      Arbor.Demo.Timing.set(:fast)

      # Get current configuration
      Arbor.Demo.Timing.config()

      # Get specific timing value
      Arbor.Demo.Timing.monitor_poll_interval()
  """

  use Agent

  @type timing_mode :: :fast | :normal | :slow

  # Timing profiles
  @profiles %{
    fast: %{
      monitor_poll_interval_ms: 500,
      debug_agent_cycles: 3,
      council_timeout_ms: 5_000,
      hot_load_verification_ms: 1_000,
      stage_transition_delay_ms: 100,
      total_scenario_timeout_ms: 45_000
    },
    normal: %{
      monitor_poll_interval_ms: 1_000,
      debug_agent_cycles: 5,
      council_timeout_ms: 10_000,
      hot_load_verification_ms: 2_000,
      stage_transition_delay_ms: 200,
      total_scenario_timeout_ms: 60_000
    },
    slow: %{
      monitor_poll_interval_ms: 2_000,
      debug_agent_cycles: 10,
      council_timeout_ms: 30_000,
      hot_load_verification_ms: 3_000,
      stage_transition_delay_ms: 500,
      total_scenario_timeout_ms: 90_000
    }
  }

  # ============================================================================
  # Agent Setup
  # ============================================================================

  @doc """
  Start the timing configuration agent.

  Called automatically by the demo application supervisor.
  """
  def start_link(opts \\ []) do
    initial_mode = Keyword.get(opts, :mode, :normal)
    Agent.start_link(fn -> initial_mode end, name: __MODULE__)
  end

  @doc """
  Get a child spec for the supervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Set the timing mode.

  ## Examples

      Arbor.Demo.Timing.set(:fast)
      Arbor.Demo.Timing.set(:normal)
      Arbor.Demo.Timing.set(:slow)
  """
  @spec set(timing_mode()) :: :ok
  def set(mode) when mode in [:fast, :normal, :slow] do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> mode end)
    else
      # Agent not started, store in application env
      Application.put_env(:arbor_demo, :timing_mode, mode)
    end

    :ok
  end

  @doc """
  Get the current timing mode.
  """
  @spec current_mode() :: timing_mode()
  def current_mode do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
    else
      Application.get_env(:arbor_demo, :timing_mode, :normal)
    end
  end

  @doc """
  Get all timing values for the current mode.
  """
  @spec config() :: map()
  def config do
    Map.get(@profiles, current_mode(), @profiles.normal)
  end

  @doc """
  Get a specific timing value.
  """
  @spec get(atom()) :: term()
  def get(key) do
    Map.get(config(), key)
  end

  # ============================================================================
  # Timing Accessors
  # ============================================================================

  @doc """
  How often the monitor polls for anomalies.
  """
  @spec monitor_poll_interval() :: non_neg_integer()
  def monitor_poll_interval do
    get(:monitor_poll_interval_ms)
  end

  @doc """
  Maximum cycles for the DebugAgent bounded reasoning.
  """
  @spec debug_agent_cycles() :: non_neg_integer()
  def debug_agent_cycles do
    get(:debug_agent_cycles)
  end

  @doc """
  Timeout for council evaluation.
  """
  @spec council_timeout() :: non_neg_integer()
  def council_timeout do
    get(:council_timeout_ms)
  end

  @doc """
  Time to wait for hot-load verification.
  """
  @spec hot_load_verification() :: non_neg_integer()
  def hot_load_verification do
    get(:hot_load_verification_ms)
  end

  @doc """
  Delay between pipeline stage transitions (for visual effect).
  """
  @spec stage_transition_delay() :: non_neg_integer()
  def stage_transition_delay do
    get(:stage_transition_delay_ms)
  end

  @doc """
  Overall timeout for a complete scenario.
  """
  @spec total_scenario_timeout() :: non_neg_integer()
  def total_scenario_timeout do
    get(:total_scenario_timeout_ms)
  end

  # ============================================================================
  # Profile Information
  # ============================================================================

  @doc """
  Get all available timing profiles.
  """
  @spec profiles() :: map()
  def profiles do
    @profiles
  end

  @doc """
  Get a specific timing profile by name.
  """
  @spec profile(timing_mode()) :: map() | nil
  def profile(mode) do
    Map.get(@profiles, mode)
  end

  @doc """
  Print timing configuration to console (for debugging).
  """
  @spec print_config() :: :ok
  def print_config do
    mode = current_mode()
    cfg = config()

    IO.puts("\n=== Demo Timing Configuration ===")
    IO.puts("Mode: #{mode}")
    IO.puts("")

    for {key, value} <- Enum.sort(cfg) do
      IO.puts("  #{key}: #{format_value(value)}")
    end

    IO.puts("")
    :ok
  end

  defp format_value(ms) when is_integer(ms) and ms >= 1000 do
    "#{div(ms, 1000)}s"
  end

  defp format_value(ms) when is_integer(ms) do
    "#{ms}ms"
  end

  defp format_value(value), do: inspect(value)
end
