defmodule Arbor.Agent.Orchestration.PendingApproval do
  @moduledoc """
  Normalized approval request view for agent orchestration callers.

  This struct is an adapter over the existing approval backends. It is not a
  persistence model and must not become a third approval queue.
  """

  @type source :: :consensus | :interaction

  @type t :: %__MODULE__{
          id: String.t(),
          source: source(),
          agent_id: String.t() | nil,
          principal_id: String.t() | nil,
          approver_id: String.t() | nil,
          resource_uri: String.t() | nil,
          action: atom() | String.t() | nil,
          description: String.t() | nil,
          context: map(),
          metadata: map(),
          created_at: DateTime.t() | nil,
          status: atom()
        }

  @enforce_keys [:id, :source, :status]
  defstruct [
    :id,
    :source,
    :agent_id,
    :principal_id,
    :approver_id,
    :resource_uri,
    :action,
    :description,
    :created_at,
    context: %{},
    metadata: %{},
    status: :pending
  ]
end
