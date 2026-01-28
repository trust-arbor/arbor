defmodule Arbor.Consensus.Config do
  @moduledoc """
  Configuration for the consensus system.

  Centralizes quorum rules, perspective assignments, timeouts,
  and concurrency limits. Built from keyword opts or defaults.
  """

  use TypedStruct

  alias Arbor.Contracts.Consensus.Protocol

  @default_council_size 7
  @default_evaluation_timeout_ms 90_000
  @default_max_concurrent 10

  @default_quorum_rules %{
    governance_change: 6,
    code_modification: 5,
    capability_change: 5,
    configuration_change: 5,
    dependency_change: 5,
    layer_modification: 5,
    documentation_change: 4,
    test_change: 4
  }

  @default_perspectives %{
    code_modification: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    governance_change: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    capability_change: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    configuration_change: [
      :security,
      :stability,
      :capability,
      :resource,
      :emergence,
      :code_review,
      :random
    ],
    dependency_change: [
      :security,
      :stability,
      :adversarial,
      :resource,
      :code_review,
      :test_runner,
      :random
    ],
    layer_modification: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    documentation_change: [
      :code_review,
      :capability,
      :stability,
      :resource,
      :random,
      :emergence,
      :test_runner
    ],
    test_change: [
      :test_runner,
      :code_review,
      :stability,
      :capability,
      :resource,
      :random,
      :emergence
    ]
  }

  typedstruct do
    @typedoc "Consensus system configuration"

    field(:council_size, pos_integer(), default: @default_council_size)
    field(:evaluation_timeout_ms, pos_integer(), default: @default_evaluation_timeout_ms)
    field(:max_concurrent_proposals, pos_integer(), default: @default_max_concurrent)
    field(:auto_execute_approved, boolean(), default: false)
    field(:quorum_rules, map(), default: @default_quorum_rules)
    field(:perspectives_for_change_type, map(), default: @default_perspectives)
  end

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:council_size` - Number of evaluators per council (default: 7)
    * `:evaluation_timeout_ms` - Timeout for evaluator tasks (default: 90_000)
    * `:max_concurrent_proposals` - Max proposals being evaluated at once (default: 10)
    * `:auto_execute_approved` - Whether to auto-execute approved proposals (default: false)
    * `:quorum_rules` - Map of change_type => required approvals
    * `:perspectives_for_change_type` - Map of change_type => [perspective]
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      council_size: Keyword.get(opts, :council_size, @default_council_size),
      evaluation_timeout_ms:
        Keyword.get(opts, :evaluation_timeout_ms, @default_evaluation_timeout_ms),
      max_concurrent_proposals:
        Keyword.get(opts, :max_concurrent_proposals, @default_max_concurrent),
      auto_execute_approved: Keyword.get(opts, :auto_execute_approved, false),
      quorum_rules:
        Map.merge(@default_quorum_rules, Keyword.get(opts, :quorum_rules, %{})),
      perspectives_for_change_type:
        Map.merge(
          @default_perspectives,
          Keyword.get(opts, :perspectives_for_change_type, %{})
        )
    }
  end

  @doc """
  Get the required quorum for a change type.
  """
  @spec quorum_for(t(), atom()) :: pos_integer()
  def quorum_for(%__MODULE__{quorum_rules: rules}, change_type) do
    Map.get(rules, change_type, Protocol.standard_quorum())
  end

  @doc """
  Get the perspectives to evaluate for a change type.
  """
  @spec perspectives_for(t(), atom()) :: [atom()]
  def perspectives_for(%__MODULE__{perspectives_for_change_type: perspectives}, change_type) do
    Map.get(perspectives, change_type, Protocol.perspectives() -- [:human])
  end

  @doc """
  Check if a change type requires supermajority (6/7 or higher).
  """
  @spec requires_supermajority?(t(), atom()) :: boolean()
  def requires_supermajority?(%__MODULE__{} = config, change_type) do
    quorum_for(config, change_type) >= Protocol.meta_quorum()
  end

  # ===========================================================================
  # Application-level config (read from Application env)
  # ===========================================================================

  @app :arbor_consensus

  @doc """
  Timeout for deterministic evaluator commands (default: 60_000ms).
  """
  @spec deterministic_evaluator_timeout() :: pos_integer()
  def deterministic_evaluator_timeout do
    Application.get_env(@app, :deterministic_evaluator_timeout, 60_000)
  end

  @doc """
  Sandbox mode for deterministic evaluator shell commands (default: :strict).
  """
  @spec deterministic_evaluator_sandbox() :: atom()
  def deterministic_evaluator_sandbox do
    Application.get_env(@app, :deterministic_evaluator_sandbox, :strict)
  end

  @doc """
  Default working directory for deterministic evaluator (default: nil).

  If nil, requires project_path in proposal metadata.
  """
  @spec deterministic_evaluator_default_cwd() :: String.t() | nil
  def deterministic_evaluator_default_cwd do
    Application.get_env(@app, :deterministic_evaluator_default_cwd, nil)
  end
end
