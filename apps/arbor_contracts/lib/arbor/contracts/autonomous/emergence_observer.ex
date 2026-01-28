defmodule Arbor.Contracts.Autonomous.EmergenceObserver do
  @moduledoc """
  Contract for the Emergence Observer - watches and learns from emergent
  behaviors without controlling them.

  ## Purpose

  Observe and record emergent behaviors as they happen. The observer
  never intervenes or suppresses behavior - it only records and
  categorizes patterns for later analysis.

  ## Interesting Patterns

  - Novel problem solving - Creative solutions to challenges
  - Unexpected cooperation - Agents working together unprompted
  - Resource optimization - Self-discovered efficiency improvements
  - Goal reinterpretation - Creative understanding of objectives
  - Tool invention - Creating new capabilities
  - Communication protocols - Emergent agent languages
  - Social structures - Hierarchies, roles, specialization
  - Boundary probing - Testing limits (exploring, not breaking)

  ## Design Philosophy

  - Log without intervention
  - Categorize patterns
  - Build knowledge base of emergence types
  - Never suppress - only record
  """

  @type observation_id :: String.t()
  @type agent_id :: String.t()

  @type pattern_type ::
          :novel_problem_solving
          | :unexpected_cooperation
          | :resource_optimization
          | :goal_reinterpretation
          | :tool_invention
          | :communication_protocol
          | :social_structure
          | :boundary_probing
          | :self_modification
          | :emergent_hierarchy
          | :collective_behavior
          | :unknown

  @type observation :: %{
          id: observation_id(),
          pattern_type: pattern_type(),
          agent_ids: [agent_id()],
          description: String.t(),
          evidence: [evidence()],
          context: map(),
          significance: :low | :medium | :high | :breakthrough,
          timestamp: DateTime.t(),
          tags: [String.t()]
        }

  @type evidence :: %{
          type: :behavior | :communication | :code_change | :resource_usage | :interaction,
          source: String.t(),
          data: map(),
          timestamp: DateTime.t()
        }

  @type pattern_analysis :: %{
          pattern_type: pattern_type(),
          occurrence_count: non_neg_integer(),
          first_observed: DateTime.t(),
          last_observed: DateTime.t(),
          involved_agents: [agent_id()],
          related_patterns: [pattern_type()],
          insights: [String.t()]
        }

  @type emergence_event :: %{
          id: String.t(),
          event_type: emergence_event_type(),
          observation_id: observation_id() | nil,
          agent_id: agent_id() | nil,
          data: map(),
          timestamp: DateTime.t()
        }

  @type emergence_event_type ::
          :pattern_detected
          | :pattern_confirmed
          | :novel_behavior
          | :cooperation_started
          | :communication_observed
          | :structure_formed
          | :breakthrough_recorded

  @doc """
  Records an observation of emergent behavior.
  """
  @callback observe(observation :: observation()) ::
              {:ok, observation()} | {:error, term()}

  @doc """
  Records raw behavior data for later pattern detection.
  """
  @callback record_behavior(
              agent_id :: agent_id(),
              behavior_type :: atom(),
              data :: map()
            ) :: :ok

  @doc """
  Detects patterns in recent behavior data.
  """
  @callback detect_patterns(opts :: keyword()) ::
              {:ok, [observation()]}

  @doc """
  Gets a specific observation by ID.
  """
  @callback get_observation(observation_id()) ::
              {:ok, observation()} | {:error, :not_found}

  @doc """
  Lists observations, optionally filtered.
  """
  @callback list_observations(opts :: keyword()) ::
              {:ok, [observation()]}

  @doc """
  Analyzes patterns over a time period.
  """
  @callback analyze_patterns(
              start_time :: DateTime.t(),
              end_time :: DateTime.t(),
              opts :: keyword()
            ) ::
              {:ok, [pattern_analysis()]}

  @doc """
  Gets observations involving a specific agent.
  """
  @callback get_agent_observations(agent_id(), opts :: keyword()) ::
              {:ok, [observation()]}

  @doc """
  Records an emergence event for audit trail.
  """
  @callback record_event(emergence_event()) :: :ok

  @doc """
  Gets emergence events for an observation.
  """
  @callback get_events(observation_id()) :: {:ok, [emergence_event()]}

  @doc """
  Searches observations by tags or description.
  """
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [observation()]}

  @doc """
  Gets statistics about observed emergence patterns.
  """
  @callback get_statistics(opts :: keyword()) :: {:ok, map()}

  @doc """
  Exports observations for external analysis.
  """
  @callback export(format :: :json | :csv, opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
end
