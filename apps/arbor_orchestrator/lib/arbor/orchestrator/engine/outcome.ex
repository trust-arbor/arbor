defmodule Arbor.Orchestrator.Engine.Outcome do
  @moduledoc false

  @type status :: :success | :partial_success | :retry | :fail | :skipped

  @type t :: %__MODULE__{
          status: status(),
          preferred_label: String.t() | nil,
          suggested_next_ids: [String.t()],
          context_updates: map(),
          notes: String.t() | nil,
          failure_reason: String.t() | nil,
          # A bare level atom (ingress actions declare a level) or a full
          # %Arbor.Contracts.Security.Taint{} (reductions); the engine normalizes.
          output_taint: atom() | Arbor.Contracts.Security.Taint.t() | nil,
          # Reductions to apply to EXISTING context keys (not this node's outputs),
          # e.g. a human-approved gate reducing reviewed data via :human_review.
          # List of {context_key, target_level, reason}; the engine applies each
          # (lowering only) and emits :taint_reduced. Taint-rebuild Phase 4.
          taint_reductions: [{String.t(), atom(), atom()}]
        }

  defstruct status: :success,
            preferred_label: nil,
            suggested_next_ids: [],
            context_updates: %{},
            notes: nil,
            failure_reason: nil,
            # Provenance taint of this node's outputs (taint-tracking-rebuild
            # Phase 1). Set by ingress handlers (web -> :untrusted, LLM ->
            # :derived); the engine records it on the output context keys.
            output_taint: nil,
            taint_reductions: []
end
