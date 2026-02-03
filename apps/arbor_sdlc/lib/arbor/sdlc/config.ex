defmodule Arbor.SDLC.Config do
  @moduledoc """
  Configuration for the SDLC automation system.

  Centralizes configuration for roadmap paths, polling intervals,
  processor settings, and LLM routing preferences.

  ## Configuration Sources

  Configuration is loaded from application environment:

      config :arbor_sdlc,
        roadmap_root: ".arbor/roadmap",
        poll_interval: 30_000,
        processor_routing: %{
          expander: :moderate,
          deliberator: :moderate,
          consistency_checker: :none
        }

  ## Processor Routing

  Each processor can be configured to use different AI complexity tiers:

  - `:none` - No LLM calls (heuristic/rule-based only)
  - `:simple` - Fast, cheap API calls for simple tasks
  - `:moderate` - Balanced API calls (default for most processors)
  - `:complex` - CLI agent with full codebase context

  Item metadata (priority, category) can override defaults:
  - Critical priority features always use :complex
  - Documentation items can use :simple
  """

  use TypedStruct

  alias Arbor.SDLC.Pipeline

  @app :arbor_sdlc

  # Default values
  @default_roadmap_root ".arbor/roadmap"
  @default_poll_interval 30_000
  @default_debounce_ms 1_000
  @default_watcher_enabled true
  @default_enabled_stages []

  @default_processor_routing %{
    expander: :moderate,
    deliberator: :moderate,
    consistency_checker: :none,
    planned: :none,
    in_progress: :none
  }

  # Auto-hand defaults
  @default_max_concurrent_sessions 3
  @default_session_max_turns 50
  @default_session_test_timeout 300_000
  @default_session_spawn_cooldown 60_000

  @type complexity_tier :: :none | :simple | :moderate | :complex

  typedstruct do
    @typedoc "SDLC system configuration"

    field(:roadmap_root, String.t(), default: @default_roadmap_root)
    field(:poll_interval, pos_integer(), default: @default_poll_interval)
    field(:debounce_ms, pos_integer(), default: @default_debounce_ms)
    field(:watcher_enabled, boolean(), default: @default_watcher_enabled)
    field(:enabled_stages, [atom()], default: @default_enabled_stages)
    field(:processor_routing, map(), default: @default_processor_routing)

    # Persistence configuration
    field(:persistence_backend, module(), default: Arbor.Persistence.Store.ETS)
    field(:persistence_name, atom(), default: :sdlc_tracker)

    # Consensus configuration for deliberator
    field(:consensus_server, GenServer.server(), default: Arbor.Consensus.Coordinator)
    field(:consensus_change_type, atom(), default: :sdlc_decision)
    field(:max_deliberation_attempts, pos_integer(), default: 3)

    # AI configuration
    field(:ai_module, module(), default: Arbor.AI)
    field(:ai_backend, atom(), default: :cli)
    field(:ai_timeout, pos_integer(), default: 60_000)
  end

  @doc """
  Create a new config from application environment and options.

  Options override application environment values.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      roadmap_root: get_value(:roadmap_root, opts, @default_roadmap_root),
      poll_interval: get_value(:poll_interval, opts, @default_poll_interval),
      debounce_ms: get_value(:debounce_ms, opts, @default_debounce_ms),
      watcher_enabled: get_value(:watcher_enabled, opts, @default_watcher_enabled),
      enabled_stages: get_value(:enabled_stages, opts, @default_enabled_stages),
      processor_routing:
        Map.merge(
          @default_processor_routing,
          get_value(:processor_routing, opts, %{})
        ),
      persistence_backend: get_value(:persistence_backend, opts, Arbor.Persistence.Store.ETS),
      persistence_name: get_value(:persistence_name, opts, :sdlc_tracker),
      consensus_server: get_value(:consensus_server, opts, Arbor.Consensus.Coordinator),
      consensus_change_type: get_value(:consensus_change_type, opts, :sdlc_decision),
      max_deliberation_attempts: get_value(:max_deliberation_attempts, opts, 3),
      ai_module: get_value(:ai_module, opts, Arbor.AI),
      ai_backend: get_value(:ai_backend, opts, :cli),
      ai_timeout: get_value(:ai_timeout, opts, 60_000)
    }
  end

  # Get value from opts, then app env, then default
  defp get_value(key, opts, default) do
    Keyword.get(opts, key, Application.get_env(@app, key, default))
  end

  # =============================================================================
  # Per-Processor Configuration
  # =============================================================================

  @doc """
  Get the complexity tier for a processor.

  Returns the configured tier, with item-based overrides.
  """
  @spec routing_for(t(), atom(), map() | nil) :: complexity_tier()
  def routing_for(%__MODULE__{processor_routing: routing}, processor, item \\ nil) do
    base_tier = Map.get(routing, processor, :moderate)
    maybe_override_tier(base_tier, item)
  end

  # Override routing based on item metadata
  defp maybe_override_tier(base_tier, nil), do: base_tier

  defp maybe_override_tier(_base_tier, %{priority: :critical, category: :feature}) do
    :complex
  end

  defp maybe_override_tier(_base_tier, %{priority: :critical, category: :infrastructure}) do
    :complex
  end

  defp maybe_override_tier(base_tier, %{category: :documentation}) when base_tier != :complex do
    :simple
  end

  defp maybe_override_tier(base_tier, _item), do: base_tier

  # =============================================================================
  # Application-Level Accessors
  # =============================================================================

  @doc """
  Get the configured roadmap root path.
  """
  @spec roadmap_root() :: String.t()
  def roadmap_root do
    Application.get_env(@app, :roadmap_root, @default_roadmap_root)
  end

  @doc """
  Get the absolute roadmap root path.
  """
  @spec absolute_roadmap_root() :: String.t()
  def absolute_roadmap_root do
    root = roadmap_root()

    if Path.type(root) == :absolute do
      root
    else
      Path.join(File.cwd!(), root)
    end
  end

  @doc """
  Get the configured poll interval in milliseconds.
  """
  @spec poll_interval() :: pos_integer()
  def poll_interval do
    Application.get_env(@app, :poll_interval, @default_poll_interval)
  end

  @doc """
  Check if the watcher is enabled.
  """
  @spec watcher_enabled?() :: boolean()
  def watcher_enabled? do
    Application.get_env(@app, :watcher_enabled, @default_watcher_enabled)
  end

  @doc """
  Get the list of stages enabled for automatic processing.

  An empty list means no stages are automatically processed by the watcher.
  """
  @spec enabled_stages() :: [atom()]
  def enabled_stages do
    Application.get_env(@app, :enabled_stages, @default_enabled_stages)
  end

  @doc """
  Check if a specific stage is enabled for automatic processing.
  """
  @spec stage_enabled?(atom()) :: boolean()
  def stage_enabled?(stage) when is_atom(stage) do
    stage in enabled_stages()
  end

  @doc """
  Enable a stage for automatic processing at runtime.
  """
  @spec enable_stage(atom()) :: :ok
  def enable_stage(stage) when is_atom(stage) do
    current = enabled_stages()

    unless stage in current do
      Application.put_env(@app, :enabled_stages, [stage | current])
    end

    :ok
  end

  @doc """
  Disable a stage for automatic processing at runtime.
  """
  @spec disable_stage(atom()) :: :ok
  def disable_stage(stage) when is_atom(stage) do
    current = enabled_stages()
    Application.put_env(@app, :enabled_stages, List.delete(current, stage))
    :ok
  end

  @doc """
  Enable all pipeline stages at runtime.
  """
  @spec enable_all_stages() :: :ok
  def enable_all_stages do
    Application.put_env(@app, :enabled_stages, Pipeline.stages())
    :ok
  end

  @doc """
  Disable all processing stages at runtime.
  """
  @spec disable_all_stages() :: :ok
  def disable_all_stages do
    Application.put_env(@app, :enabled_stages, [])
    :ok
  end

  @doc """
  Get the configured AI module.
  """
  @spec ai_module() :: module()
  def ai_module do
    Application.get_env(@app, :ai_module, Arbor.AI)
  end

  @doc """
  Get the timeout for AI operations in milliseconds.
  """
  @spec ai_timeout() :: pos_integer()
  def ai_timeout do
    Application.get_env(@app, :ai_timeout, 60_000)
  end

  @doc """
  Get the configured persistence backend module.
  """
  @spec persistence_backend() :: module()
  def persistence_backend do
    Application.get_env(@app, :persistence_backend, Arbor.Persistence.Store.ETS)
  end

  @doc """
  Get the persistence store name.
  """
  @spec persistence_name() :: atom()
  def persistence_name do
    Application.get_env(@app, :persistence_name, :sdlc_tracker)
  end

  @doc """
  Get the consensus change type for SDLC decisions.
  """
  @spec consensus_change_type() :: atom()
  def consensus_change_type do
    Application.get_env(@app, :consensus_change_type, :sdlc_decision)
  end

  @doc """
  Get the maximum number of deliberation attempts for a single item.
  """
  @spec max_deliberation_attempts() :: pos_integer()
  def max_deliberation_attempts do
    Application.get_env(@app, :max_deliberation_attempts, 3)
  end

  @doc """
  Get the decisions directory path.
  """
  @spec decisions_directory() :: String.t()
  def decisions_directory do
    Application.get_env(@app, :decisions_directory, ".arbor/decisions")
  end

  @doc """
  Get the absolute decisions directory path.
  """
  @spec absolute_decisions_directory() :: String.t()
  def absolute_decisions_directory do
    dir = decisions_directory()

    if Path.type(dir) == :absolute do
      dir
    else
      Path.join(File.cwd!(), dir)
    end
  end

  @doc """
  Get paths to vision documents for consistency checking.
  """
  @spec vision_docs() :: [String.t()]
  def vision_docs do
    Application.get_env(@app, :vision_docs, [
      "VISION.md",
      "CLAUDE.md"
    ])
  end

  @doc """
  Get the component vision docs directory.
  """
  @spec component_vision_directory() :: String.t()
  def component_vision_directory do
    Application.get_env(@app, :component_vision_directory, "docs/vision")
  end

  # =============================================================================
  # Auto-Hand Session Configuration
  # =============================================================================

  @doc """
  Get the maximum number of concurrent auto-hand sessions.
  """
  @spec max_concurrent_sessions() :: pos_integer()
  def max_concurrent_sessions do
    Application.get_env(@app, :max_concurrent_sessions, @default_max_concurrent_sessions)
  end

  @doc """
  Get the maximum turns for a single auto-hand session.
  """
  @spec session_max_turns() :: pos_integer()
  def session_max_turns do
    Application.get_env(@app, :session_max_turns, @default_session_max_turns)
  end

  @doc """
  Get the timeout for test execution in milliseconds.
  """
  @spec session_test_timeout() :: pos_integer()
  def session_test_timeout do
    Application.get_env(@app, :session_test_timeout, @default_session_test_timeout)
  end

  @doc """
  Get the cooldown between session spawns in milliseconds.
  """
  @spec session_spawn_cooldown() :: pos_integer()
  def session_spawn_cooldown do
    Application.get_env(@app, :session_spawn_cooldown, @default_session_spawn_cooldown)
  end

  @doc """
  Check if auto-hand processing is enabled.

  Auto-hand processing is enabled when both :planned and :in_progress
  stages are in the enabled_stages list.
  """
  @spec auto_hand_enabled?() :: boolean()
  def auto_hand_enabled? do
    stages = enabled_stages()
    :planned in stages and :in_progress in stages
  end

  @doc """
  Enable auto-hand processing at runtime.
  """
  @spec enable_auto_hand() :: :ok
  def enable_auto_hand do
    enable_stage(:planned)
    enable_stage(:in_progress)
    :ok
  end

  @doc """
  Disable auto-hand processing at runtime.
  """
  @spec disable_auto_hand() :: :ok
  def disable_auto_hand do
    disable_stage(:planned)
    disable_stage(:in_progress)
    :ok
  end
end
