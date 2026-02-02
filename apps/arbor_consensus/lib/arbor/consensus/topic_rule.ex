defmodule Arbor.Consensus.TopicRule do
  @moduledoc """
  Defines routing and evaluation rules for a consensus topic.

  A TopicRule specifies:
  - Which evaluators are required
  - What quorum threshold applies
  - Who can propose to this topic
  - What modes (decision/advisory) are allowed
  - Pattern matching rules for auto-routing

  ## Bootstrap Topics

  Two topics are bootstrapped at startup and cannot be deleted:

  - `:topic_governance` - For creating/modifying topics (supermajority required)
  - `:general` - Catch-all for unmatched proposals (majority required)

  ## Example

      %TopicRule{
        topic: :security_audit,
        required_evaluators: [SecurityEvaluator],
        min_quorum: :supermajority,
        allowed_proposers: [:security_team, :admin],
        allowed_modes: [:decision],
        match_patterns: ["security", "vulnerability", "audit"],
        is_bootstrap: false,
        registered_by: "admin_agent",
        registered_at: ~U[2026-02-02 14:00:00Z]
      }

  """

  use TypedStruct

  @type quorum_type :: :majority | :supermajority | :unanimous | pos_integer()

  typedstruct do
    @typedoc "A topic routing and evaluation rule"

    field(:topic, atom(), enforce: true)
    field(:required_evaluators, [module()], default: [])
    field(:min_quorum, quorum_type(), default: :majority)
    field(:allowed_proposers, :any | [atom()], default: :any)
    field(:allowed_modes, [:decision | :advisory], default: [:decision, :advisory])
    field(:match_patterns, [String.t()], default: [])
    field(:is_bootstrap, boolean(), default: false)
    field(:registered_by, String.t() | nil, default: nil)
    field(:registered_at, DateTime.t() | nil, default: nil)
  end

  @doc """
  Create a new TopicRule.

  ## Options

  - `:topic` (required) - The topic atom
  - `:required_evaluators` - List of evaluator modules that must participate
  - `:min_quorum` - `:majority`, `:supermajority`, `:unanimous`, or a positive integer
  - `:allowed_proposers` - `:any` or list of agent atoms that can propose
  - `:allowed_modes` - List of allowed modes (`:decision`, `:advisory`)
  - `:match_patterns` - Strings to match in descriptions for auto-routing
  - `:is_bootstrap` - Whether this is a bootstrap topic (cannot be deleted)
  - `:registered_by` - ID of the agent who registered this topic
  - `:registered_at` - When the topic was registered
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    %__MODULE__{
      topic: Map.fetch!(attrs, :topic),
      required_evaluators: Map.get(attrs, :required_evaluators, []),
      min_quorum: Map.get(attrs, :min_quorum, :majority),
      allowed_proposers: Map.get(attrs, :allowed_proposers, :any),
      allowed_modes: Map.get(attrs, :allowed_modes, [:decision, :advisory]),
      match_patterns: Map.get(attrs, :match_patterns, []),
      is_bootstrap: Map.get(attrs, :is_bootstrap, false),
      registered_by: Map.get(attrs, :registered_by),
      registered_at: Map.get(attrs, :registered_at, now)
    }
  end

  @doc """
  Check if a proposer is allowed to submit to this topic.
  """
  @spec proposer_allowed?(t(), atom() | String.t()) :: boolean()
  def proposer_allowed?(%__MODULE__{allowed_proposers: :any}, _proposer), do: true

  def proposer_allowed?(%__MODULE__{allowed_proposers: allowed}, proposer) when is_list(allowed) do
    proposer_atom =
      if is_binary(proposer) do
        String.to_existing_atom(proposer)
      else
        proposer
      end

    proposer_atom in allowed
  rescue
    ArgumentError -> false
  end

  @doc """
  Check if a mode is allowed for this topic.
  """
  @spec mode_allowed?(t(), :decision | :advisory) :: boolean()
  def mode_allowed?(%__MODULE__{allowed_modes: modes}, mode) do
    mode in modes
  end

  @doc """
  Convert quorum type to a numeric value given a council size.
  """
  @spec quorum_to_number(quorum_type(), pos_integer()) :: pos_integer()
  def quorum_to_number(quorum, _council_size) when is_integer(quorum) and quorum > 0, do: quorum
  def quorum_to_number(:majority, council_size), do: div(council_size, 2) + 1
  def quorum_to_number(:supermajority, council_size), do: ceil(council_size * 2 / 3)
  def quorum_to_number(:unanimous, council_size), do: council_size
end
