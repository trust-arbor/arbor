defmodule Arbor.Orchestrator.Engine.Outcome do
  @moduledoc false

  @type status :: :success | :partial_success | :retry | :fail | :skipped

  @type t :: %__MODULE__{
          status: status(),
          preferred_label: String.t() | nil,
          suggested_next_ids: [String.t()],
          context_updates: map(),
          notes: String.t() | nil,
          failure_reason: String.t() | nil
        }

  defstruct status: :success,
            preferred_label: nil,
            suggested_next_ids: [],
            context_updates: %{},
            notes: nil,
            failure_reason: nil
end
