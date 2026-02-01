defmodule Arbor.Actions.Proposal do
  @moduledoc """
  Proposal submission operations as Jido actions.

  This module provides Jido-compatible actions for submitting proposals
  to the consensus council and revising them after feedback.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Submit` | Submit a proposal to the consensus council |
  | `Revise` | Resubmit a proposal after council requests changes |

  ## Architecture

  Git is the artifact store. Proposals reference git branches — the council
  reviews the diff (`git diff main..branch`), evidence chain, and test results.
  The agent commits to its worktree branch; the proposal points the council
  at that branch.

  ## Examples

      # Submit a proposal
      {:ok, result} = Arbor.Actions.Proposal.Submit.run(
        %{
          title: "Add caching to API calls",
          description: "Implements Redis-based caching for expensive API endpoints",
          branch: "hand/agent_001/caching-feature",
          evidence: ["evt_123", "evt_124"],
          urgency: "normal"
        },
        %{}
      )
      result.proposal_id  # => "prop_abc123..."

      # Revise after feedback
      {:ok, result} = Arbor.Actions.Proposal.Revise.run(
        %{
          proposal_id: "prop_abc123...",
          notes: "Added unit tests and fixed edge case handling",
          branch: "hand/agent_001/caching-feature"
        },
        %{}
      )

  ## Authorization

  - Submit: `arbor://actions/execute/proposal.submit`
  - Revise: `arbor://actions/execute/proposal.revise`
  """

  defmodule Submit do
    @moduledoc """
    Submit a proposal to the consensus council for review.

    Creates a proposal referencing a git branch. The consensus council
    evaluates the diff, evidence chain, and test results before voting.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `title` | string | yes | Short proposal title |
    | `description` | string | yes | Detailed description of the change |
    | `branch` | string | yes | Git branch with committed changes |
    | `evidence` | list | no | List of event IDs, analysis output, test results |
    | `urgency` | string | no | Urgency level: low, normal, high, critical (default: normal) |
    | `change_type` | string | no | Type: code_modification, config_change, etc. |

    ## Returns

    - `proposal_id` - The unique proposal identifier
    - `status` - Initial status (typically "evaluating")
    - `branch` - The branch reference
    """

    use Jido.Action,
      name: "proposal_submit",
      description: "Submit a proposal to the consensus council for review",
      category: "proposal",
      tags: ["proposal", "consensus", "submit", "review"],
      schema: [
        title: [
          type: :string,
          required: true,
          doc: "Short proposal title"
        ],
        description: [
          type: :string,
          required: true,
          doc: "Detailed description of the change"
        ],
        branch: [
          type: :string,
          required: true,
          doc: "Git branch with committed changes"
        ],
        evidence: [
          type: {:list, :string},
          default: [],
          doc: "List of event IDs, analysis output references, or test result IDs"
        ],
        urgency: [
          type: {:in, ["low", "normal", "high", "critical"]},
          default: "normal",
          doc: "Urgency level for the proposal"
        ],
        change_type: [
          type: :string,
          default: "code_modification",
          doc: "Type of change: code_modification, config_change, dependency_update, etc."
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Common.SafeAtom

    @allowed_urgencies [:low, :normal, :high, :critical]
    @allowed_change_types [
      :code_modification,
      :config_change,
      :dependency_update,
      :authorization_request,
      :infrastructure_change,
      :documentation_update
    ]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      %{title: title, description: description, branch: branch} = params

      evidence = params[:evidence] || []
      urgency = normalize_urgency(params[:urgency])
      change_type = normalize_change_type(params[:change_type])

      # Extract proposer from context (agent_id)
      proposer = Map.get(context, :agent_id, "unknown")

      Actions.emit_started(__MODULE__, %{title: title, branch: branch})

      # Build the proposal
      proposal_attrs = %{
        proposer: proposer,
        change_type: change_type,
        title: title,
        description: description,
        metadata: %{
          branch: branch,
          evidence: evidence,
          urgency: urgency
        }
      }

      case Arbor.Consensus.submit(proposal_attrs) do
        {:ok, proposal_id} ->
          result = %{
            proposal_id: proposal_id,
            status: "evaluating",
            branch: branch
          }

          Actions.emit_completed(__MODULE__, %{
            proposal_id: proposal_id,
            branch: branch
          })

          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp normalize_urgency(nil), do: :normal

    defp normalize_urgency(urgency) when is_binary(urgency) do
      case SafeAtom.to_allowed(urgency, @allowed_urgencies) do
        {:ok, atom} -> atom
        {:error, _} -> :normal
      end
    end

    defp normalize_urgency(urgency) when is_atom(urgency), do: urgency

    defp normalize_change_type(nil), do: :code_modification

    defp normalize_change_type(change_type) when is_binary(change_type) do
      case SafeAtom.to_allowed(change_type, @allowed_change_types) do
        {:ok, atom} -> atom
        {:error, _} -> :code_modification
      end
    end

    defp normalize_change_type(change_type) when is_atom(change_type), do: change_type

    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Proposal submission failed: #{inspect(reason)}"
  end

  defmodule Revise do
    @moduledoc """
    Resubmit a proposal after council requests changes.

    The agent revises in the same worktree, commits new changes,
    and resubmits. The council sees the updated diff.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `proposal_id` | string | yes | The proposal ID to revise |
    | `notes` | string | yes | Description of what changed |
    | `branch` | string | yes | Same branch with new commits |

    ## Returns

    - `proposal_id` - The proposal identifier
    - `status` - Updated status (typically "evaluating" again)
    - `revision` - Revision number
    """

    use Jido.Action,
      name: "proposal_revise",
      description: "Resubmit a proposal after council requests changes",
      category: "proposal",
      tags: ["proposal", "consensus", "revise", "resubmit"],
      schema: [
        proposal_id: [
          type: :string,
          required: true,
          doc: "The proposal ID to revise"
        ],
        notes: [
          type: :string,
          required: true,
          doc: "Description of what changed in this revision"
        ],
        branch: [
          type: :string,
          required: true,
          doc: "Same branch with new commits"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{proposal_id: proposal_id, notes: notes, branch: branch}, _context) do
      Actions.emit_started(__MODULE__, %{proposal_id: proposal_id})

      # First, get the existing proposal
      with {:ok, proposal} <- Arbor.Consensus.get_proposal(proposal_id),
           :ok <- verify_can_revise(proposal) do
        # Update the proposal with new metadata
        # Note: The actual revision mechanism depends on the consensus system
        # For now, we update the metadata to indicate a revision
        revision_number = get_revision_number(proposal) + 1

        # Resubmit the proposal with updated metadata
        updated_attrs = %{
          proposer: proposal.proposer,
          change_type: proposal.change_type,
          title: proposal.title,
          description: proposal.description,
          metadata:
            Map.merge(proposal.metadata || %{}, %{
              branch: branch,
              revision: revision_number,
              revision_notes: notes,
              revised_at: DateTime.to_iso8601(DateTime.utc_now())
            })
        }

        # Cancel the old proposal and submit a new one
        # (Or use a revision mechanism if the consensus system supports it)
        _ = Arbor.Consensus.cancel(proposal_id)

        case Arbor.Consensus.submit(updated_attrs) do
          {:ok, new_proposal_id} ->
            result = %{
              proposal_id: new_proposal_id,
              original_proposal_id: proposal_id,
              status: "evaluating",
              revision: revision_number,
              branch: branch
            }

            Actions.emit_completed(__MODULE__, %{
              proposal_id: new_proposal_id,
              revision: revision_number
            })

            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, format_error(reason)}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp verify_can_revise(proposal) do
      # Can only revise proposals that are in certain states
      case Arbor.Consensus.get_status(proposal.id) do
        {:ok, status} when status in [:pending, :rejected, :needs_changes] ->
          :ok

        {:ok, :approved} ->
          {:error, :already_approved}

        {:ok, status} ->
          {:error, {:invalid_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp get_revision_number(proposal) do
      case proposal.metadata do
        %{revision: rev} when is_integer(rev) -> rev
        _ -> 0
      end
    end

    defp format_error(:not_found), do: "Proposal not found"
    defp format_error(:already_approved), do: "Cannot revise an approved proposal"

    defp format_error({:invalid_status, status}),
      do: "Cannot revise proposal in status: #{status}"

    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Proposal revision failed: #{inspect(reason)}"
  end
end
