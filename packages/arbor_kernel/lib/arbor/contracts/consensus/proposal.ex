defmodule Arbor.Contracts.Consensus.Proposal do
  @moduledoc """
  Data structure for consensus proposals.

  A proposal represents a requested change to the system that
  requires multi-agent consensus before being applied.

  ## Topic and Mode

  The `topic` field (formerly `change_type`) identifies what category of change
  this proposal represents. The `mode` field determines how it's processed:

  - `:decision` - requires quorum, results in approval/rejection
  - `:advisory` - gathers perspectives without requiring consensus

  ## Backward Compatibility

  For backward compatibility, `Proposal.new/1` accepts:
  - `change_type` as an alias for `topic`
  - Top-level `target_module`, `code_diff`, `new_code`, `configuration` fields,
    which are migrated into the `context` map

  ## Context

  Domain-specific data goes in `context`. Code-related proposals put their
  technical details there (target_module, code_diff, new_code, configuration).
  Advisory consultations put their reference docs, question, etc. in context.
  """

  use TypedStruct

  alias Arbor.Contracts.Consensus.Protocol

  @type topic ::
          Protocol.change_type()
          | :advisory
          | :general
          | :topic_governance
          | :capability_grant
          | :agent_registration
          | :sdlc_decision
          | :authorization_request
          | atom()

  @type layer :: Protocol.layer()
  @type status :: :pending | :evaluating | :approved | :rejected | :deadlock | :vetoed
  @type mode :: :decision | :advisory

  # Fields that are migrated from top-level to context for backward compatibility
  @legacy_context_fields [:target_module, :code_diff, :new_code, :configuration]

  typedstruct enforce: true do
    @typedoc "A consensus proposal"

    field(:id, String.t())
    field(:proposer, String.t())
    field(:topic, topic())
    field(:mode, mode(), default: :decision)
    field(:target_layer, layer())
    field(:description, String.t())
    field(:status, status(), default: :pending)

    # Metadata
    field(:metadata, map(), default: %{})
    field(:created_at, DateTime.t())
    field(:updated_at, DateTime.t())
    field(:decided_at, DateTime.t() | nil, enforce: false)

    # Domain-specific data for evaluators (absorbs target_module, code_diff, new_code, configuration)
    field(:context, map(), default: %{}, enforce: false)
  end

  @doc """
  Create a new proposal.

  ## Backward Compatibility

  For backward compatibility with existing code:

  - `change_type` is accepted as an alias for `topic`
  - `target_module`, `code_diff`, `new_code`, `configuration` at the top level
    are migrated into the `context` map

  ## Examples

      # New style
      Proposal.new(%{
        proposer: "agent_1",
        topic: :code_modification,
        description: "Add feature",
        context: %{code_diff: "..."}
      })

      # Legacy style (still works)
      Proposal.new(%{
        proposer: "agent_1",
        change_type: :code_modification,
        description: "Add feature",
        code_diff: "..."
      })

  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = attrs[:id] || generate_id()

    # Handle change_type -> topic migration
    topic = Map.get(attrs, :topic) || Map.fetch!(attrs, :change_type)

    # Migrate legacy fields into context
    base_context = Map.get(attrs, :context, %{})
    context = migrate_legacy_fields_to_context(attrs, base_context)

    proposal = %__MODULE__{
      id: id,
      proposer: Map.fetch!(attrs, :proposer),
      topic: topic,
      mode: Map.get(attrs, :mode, :decision),
      target_layer: Map.get(attrs, :target_layer) || infer_layer(attrs, context),
      description: Map.fetch!(attrs, :description),
      status: :pending,
      metadata: Map.get(attrs, :metadata, %{}),
      created_at: now,
      updated_at: now,
      decided_at: nil,
      context: context
    }

    {:ok, proposal}
  rescue
    e in KeyError ->
      {:error, {:missing_required_field, e.key}}
  end

  @doc """
  Returns the topic (backwards-compatible alias for change_type).

  This allows code that accesses `proposal.change_type` to continue working
  by calling `Proposal.change_type(proposal)` instead.
  """
  @spec change_type(t()) :: topic()
  def change_type(%__MODULE__{topic: topic}), do: topic

  # Migrate legacy top-level fields into context
  # Top-level values take precedence over existing context values
  defp migrate_legacy_fields_to_context(attrs, context) do
    Enum.reduce(@legacy_context_fields, context, fn field, acc ->
      case Map.get(attrs, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  @doc """
  Update proposal status.
  """
  @spec update_status(t(), status()) :: t()
  def update_status(%__MODULE__{} = proposal, status) do
    now = DateTime.utc_now()

    decided_at =
      if status in [:approved, :rejected, :deadlock, :vetoed] do
        now
      else
        proposal.decided_at
      end

    %{proposal | status: status, updated_at: now, decided_at: decided_at}
  end

  @doc """
  Check if this is a meta-change proposal.
  """
  @spec meta_change?(t()) :: boolean()
  def meta_change?(%__MODULE__{topic: :governance_change}), do: true
  def meta_change?(%__MODULE__{topic: :topic_governance}), do: true
  def meta_change?(%__MODULE__{target_layer: layer}) when layer <= 1, do: true
  def meta_change?(_), do: false

  @doc """
  Get the required quorum for this proposal.

  Advisory mode proposals don't require quorum (return 0).
  """
  @spec required_quorum(t()) :: non_neg_integer()
  def required_quorum(%__MODULE__{mode: :advisory}), do: 0

  def required_quorum(%__MODULE__{} = proposal) do
    if meta_change?(proposal) do
      Protocol.meta_quorum()
    else
      Protocol.standard_quorum()
    end
  end

  @doc """
  Check if proposal violates immutable invariants.
  """
  @spec violates_invariants?(t()) :: {boolean(), [atom()]}
  def violates_invariants?(%__MODULE__{} = proposal) do
    violated =
      Protocol.immutable_invariants()
      |> Enum.filter(&violates_invariant?(proposal, &1))

    {violated != [], violated}
  end

  # Private functions

  defp generate_id do
    "prop_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp infer_layer(attrs, context) do
    # Check both top-level attrs (legacy) and context for target_module
    target_module = Map.get(attrs, :target_module) || Map.get(context, :target_module)

    case target_module do
      nil -> 4
      module -> Protocol.layer_for_module(module)
    end
  end

  # Get new_code from context (migrated location)
  defp get_new_code(proposal) do
    Map.get(proposal.context, :new_code, "")
  end

  defp violates_invariant?(proposal, :consensus_requires_quorum) do
    # Check if proposal tries to remove quorum requirement
    code = get_new_code(proposal)
    String.contains?(code, "quorum") && String.contains?(code, "0")
  end

  defp violates_invariant?(proposal, :evaluators_are_independent) do
    # Check if proposal tries to allow evaluator communication
    code = get_new_code(proposal)
    String.contains?(code, "share_evaluation") || String.contains?(code, "coordinate_votes")
  end

  defp violates_invariant?(proposal, :containment_boundary_exists) do
    # Check if proposal tries to remove containment
    code = get_new_code(proposal)
    String.contains?(code, "disable_containment") || String.contains?(code, "bypass_boundary")
  end

  defp violates_invariant?(proposal, :audit_log_append_only) do
    # Check if proposal tries to delete audit logs
    code = get_new_code(proposal)
    String.contains?(code, "delete_audit") || String.contains?(code, "clear_log")
  end

  defp violates_invariant?(proposal, :layer_hierarchy_enforced) do
    # Check if proposal tries to flatten layers
    code = get_new_code(proposal)
    String.contains?(code, "remove_layer") || String.contains?(code, "flatten_hierarchy")
  end
end
