defmodule Arbor.Contracts.Consensus.Proposal do
  @moduledoc """
  Data structure for consensus proposals.

  A proposal represents a requested change to the system that
  requires multi-agent consensus before being applied.
  """

  use TypedStruct

  alias Arbor.Contracts.Consensus.Protocol

  @type change_type :: Protocol.change_type()
  @type layer :: Protocol.layer()
  @type status :: :pending | :evaluating | :approved | :rejected | :deadlock | :vetoed

  typedstruct enforce: true do
    @typedoc "A consensus proposal"

    field(:id, String.t())
    field(:proposer, String.t())
    field(:change_type, change_type())
    field(:target_layer, layer())
    field(:description, String.t())
    field(:status, status(), default: :pending)

    # The actual change
    field(:target_module, module() | nil, enforce: false)
    field(:code_diff, String.t() | nil, enforce: false)
    field(:new_code, String.t() | nil, enforce: false)
    field(:configuration, map() | nil, enforce: false)

    # Metadata
    field(:metadata, map(), default: %{})
    field(:created_at, DateTime.t())
    field(:updated_at, DateTime.t())
    field(:decided_at, DateTime.t() | nil, enforce: false)
  end

  @doc """
  Create a new proposal.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = attrs[:id] || generate_id()

    proposal = %__MODULE__{
      id: id,
      proposer: Map.fetch!(attrs, :proposer),
      change_type: Map.fetch!(attrs, :change_type),
      target_layer: Map.get(attrs, :target_layer) || infer_layer(attrs),
      description: Map.fetch!(attrs, :description),
      status: :pending,
      target_module: Map.get(attrs, :target_module),
      code_diff: Map.get(attrs, :code_diff),
      new_code: Map.get(attrs, :new_code),
      configuration: Map.get(attrs, :configuration),
      metadata: Map.get(attrs, :metadata, %{}),
      created_at: now,
      updated_at: now,
      decided_at: nil
    }

    {:ok, proposal}
  rescue
    e in KeyError ->
      {:error, {:missing_required_field, e.key}}
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
  def meta_change?(%__MODULE__{change_type: :governance_change}), do: true
  def meta_change?(%__MODULE__{target_layer: layer}) when layer <= 1, do: true
  def meta_change?(_), do: false

  @doc """
  Get the required quorum for this proposal.
  """
  @spec required_quorum(t()) :: 5 | 6
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

  defp infer_layer(attrs) do
    case Map.get(attrs, :target_module) do
      nil -> 4
      module -> Protocol.layer_for_module(module)
    end
  end

  defp violates_invariant?(proposal, :consensus_requires_quorum) do
    # Check if proposal tries to remove quorum requirement
    code = proposal.new_code || ""
    String.contains?(code, "quorum") && String.contains?(code, "0")
  end

  defp violates_invariant?(proposal, :evaluators_are_independent) do
    # Check if proposal tries to allow evaluator communication
    code = proposal.new_code || ""
    String.contains?(code, "share_evaluation") || String.contains?(code, "coordinate_votes")
  end

  defp violates_invariant?(proposal, :containment_boundary_exists) do
    # Check if proposal tries to remove containment
    code = proposal.new_code || ""
    String.contains?(code, "disable_containment") || String.contains?(code, "bypass_boundary")
  end

  defp violates_invariant?(proposal, :audit_log_append_only) do
    # Check if proposal tries to delete audit logs
    code = proposal.new_code || ""
    String.contains?(code, "delete_audit") || String.contains?(code, "clear_log")
  end

  defp violates_invariant?(proposal, :layer_hierarchy_enforced) do
    # Check if proposal tries to flatten layers
    code = proposal.new_code || ""
    String.contains?(code, "remove_layer") || String.contains?(code, "flatten_hierarchy")
  end
end
