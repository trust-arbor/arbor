defmodule Arbor.Contracts.Coding.TaskOutcomeRegistry do
  @moduledoc """
  Closed registry for coding-task compatibility statuses and `TaskOutcome` codes.

  Ordered compatibility lists are part of the public migration surface. The
  outcome specs are the single source of truth for disposition, phase, origin,
  and retry semantics.
  """

  @terminal_statuses ~w(
    approval_denied
    change_committed
    declined
    human_review_required
    no_changes
    pr_created
    pr_failed
    review_failed
    review_rejected
    review_requires_rework
    rework_exhausted
    validation_capacity_exceeded
    validation_failed
  )

  # Coding parity still accepts the legacy report status `cancelled`. The
  # canonical outer TaskOutcome code is `task_cancelled`, which is intentionally
  # not a parity terminal status.
  @parity_terminal_statuses ~w(
    approval_denied
    cancelled
    change_committed
    declined
    human_review_required
    no_changes
    pr_created
    pr_failed
    review_failed
    review_rejected
    review_requires_rework
    rework_exhausted
    validation_capacity_exceeded
    validation_failed
  )

  @pipeline_error_codes ~w(
    pipeline_error
    committed_change_materialization_failed
    council_review_failed
    draft_pr_failed
    review_tier_invalid_or_missing
    worker_provider_account_exhausted
    worker_provider_session_id_missing
    worker_recovery_continuity_invalid
    worker_recovery_reopen_failed
    worker_recovery_send_failed
    worker_recovery_summary_failed
    worker_send_recovery_exhausted
    worker_stale_close_failed
    worker_stop_reason_not_end_turn
    worker_turn_no_progress
    workspace_missing
  )

  @transcript_terminal_statuses ~w(
    success
    provider_error
    timeout
    inactivity_timeout
    stream_callback_failure
    stream_callback_timeout
    prompt_exit
    client_down
    cancelled
  )

  @terminal_specs %{
    "approval_denied" => %{
      disposition: "rejected",
      phase: "commit",
      origin: "operator",
      retry: "none"
    },
    "change_committed" => %{
      disposition: "succeeded",
      phase: "commit",
      origin: "arbor",
      retry: "none"
    },
    "declined" => %{disposition: "rejected", phase: "control", origin: "operator", retry: "none"},
    "human_review_required" => %{
      disposition: "requires_input",
      phase: "review",
      origin: "reviewer",
      retry: "none"
    },
    "no_changes" => %{
      disposition: "succeeded",
      phase: "worker_turn",
      origin: "worker",
      retry: "none"
    },
    "pr_created" => %{disposition: "succeeded", phase: "adoption", origin: "arbor", retry: "none"},
    "pr_failed" => %{
      disposition: "failed",
      phase: "adoption",
      origin: "arbor",
      retry: "after_external_change"
    },
    "review_failed" => %{
      disposition: "failed",
      phase: "review",
      origin: "reviewer",
      retry: "after_external_change"
    },
    "review_rejected" => %{
      disposition: "rejected",
      phase: "review",
      origin: "reviewer",
      retry: "none"
    },
    "review_requires_rework" => %{
      disposition: "requires_input",
      phase: "review",
      origin: "reviewer",
      retry: "same_session"
    },
    "rework_exhausted" => %{
      disposition: "failed",
      phase: "review",
      origin: "runtime",
      retry: "new_session"
    },
    "validation_capacity_exceeded" => %{
      disposition: "requires_input",
      phase: "validation",
      origin: "validator",
      retry: "after_external_change"
    },
    "validation_failed" => %{
      disposition: "failed",
      phase: "validation",
      origin: "validator",
      retry: "same_session"
    }
  }

  @pipeline_specs %{
    "pipeline_error" => %{
      disposition: "failed",
      phase: "control",
      origin: "runtime",
      retry: "new_session"
    },
    "committed_change_materialization_failed" => %{
      disposition: "failed",
      phase: "review",
      origin: "arbor",
      retry: "after_external_change"
    },
    "council_review_failed" => %{
      disposition: "failed",
      phase: "review",
      origin: "reviewer",
      retry: "after_external_change"
    },
    "draft_pr_failed" => %{
      disposition: "failed",
      phase: "adoption",
      origin: "arbor",
      retry: "after_external_change"
    },
    "review_tier_invalid_or_missing" => %{
      disposition: "failed",
      phase: "review",
      origin: "reviewer",
      retry: "after_external_change"
    },
    "worker_provider_account_exhausted" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "provider",
      retry: "new_session"
    },
    "worker_provider_session_id_missing" => %{
      disposition: "failed",
      phase: "worker_start",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_recovery_continuity_invalid" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "runtime",
      retry: "new_session"
    },
    "worker_recovery_reopen_failed" => %{
      disposition: "failed",
      phase: "worker_start",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_recovery_send_failed" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_recovery_summary_failed" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "worker",
      retry: "new_session"
    },
    "worker_send_recovery_exhausted" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "runtime",
      retry: "new_session"
    },
    "worker_stale_close_failed" => %{
      disposition: "failed",
      phase: "cleanup",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_stop_reason_not_end_turn" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_turn_no_progress" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "worker",
      retry: "same_session"
    },
    "workspace_missing" => %{
      disposition: "failed",
      phase: "workspace",
      origin: "arbor",
      retry: "after_external_change"
    }
  }

  @outer_specs %{
    "task_cancelled" => %{
      disposition: "cancelled",
      phase: "control",
      origin: "operator",
      retry: "none"
    },
    "task_owner_died" => %{
      disposition: "failed",
      phase: "control",
      origin: "runtime",
      retry: "new_session"
    },
    "task_runner_failed" => %{
      disposition: "failed",
      phase: "control",
      origin: "runtime",
      retry: "new_session"
    },
    "approval_owner_terminated" => %{
      disposition: "failed",
      phase: "control",
      origin: "runtime",
      retry: "after_external_change"
    },
    "task_finalization_failed" => %{
      disposition: "failed",
      phase: "cleanup",
      origin: "runtime",
      retry: "after_external_change"
    },
    "invalid_terminal_evidence" => %{
      disposition: "failed",
      phase: "control",
      origin: "runtime",
      retry: "none"
    },
    "worker_model_mismatch" => %{
      disposition: "failed",
      phase: "worker_start",
      origin: "provider",
      retry: "new_session"
    }
  }

  @specs Map.merge(Map.merge(@terminal_specs, @pipeline_specs), @outer_specs)

  @doc "Return compatibility terminal statuses in their historical order."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Return coding parity terminal statuses in their historical order."
  @spec parity_terminal_statuses() :: [String.t()]
  def parity_terminal_statuses, do: @parity_terminal_statuses

  @doc "Return coding result statuses recognized by compatibility parsers."
  @spec coding_result_statuses() :: [String.t()]
  def coding_result_statuses, do: @terminal_statuses ++ ["pipeline_error"]

  @doc "Return stable pipeline-error codes in their historical order."
  @spec pipeline_error_codes() :: [String.t()]
  def pipeline_error_codes, do: @pipeline_error_codes

  @doc "Return ACP transcript terminal statuses in their historical order."
  @spec transcript_terminal_statuses() :: [String.t()]
  def transcript_terminal_statuses, do: @transcript_terminal_statuses

  @doc "Return every registered TaskOutcome code in deterministic order."
  @spec registered_codes() :: [String.t()]
  def registered_codes, do: @specs |> Map.keys() |> Enum.sort()

  @doc "Look up the exact disposition, phase, origin, and retry spec for a code."
  @spec spec(term()) :: {:ok, map()} | :error
  def spec(code) when is_binary(code) do
    case Map.fetch(@specs, code) do
      {:ok, value} -> {:ok, Map.put(value, :code, code)}
      :error -> :error
    end
  end

  def spec(_code), do: :error

  @doc "Alias for `spec/1` for callers that prefer lookup terminology."
  @spec lookup(term()) :: {:ok, map()} | :error
  def lookup(code), do: spec(code)

  @doc "Whether a status is a canonical coding TaskOutcome terminal status."
  @spec terminal_status?(term()) :: boolean()
  def terminal_status?(status), do: is_binary(status) and status in @terminal_statuses

  @doc "Whether a status is accepted by the legacy-compatible coding parity projection."
  @spec parity_terminal_status?(term()) :: boolean()
  def parity_terminal_status?(status),
    do: is_binary(status) and status in @parity_terminal_statuses

  @spec coding_result_status?(term()) :: boolean()
  def coding_result_status?(status), do: is_binary(status) and status in coding_result_statuses()

  @spec pipeline_error_code?(term()) :: boolean()
  def pipeline_error_code?(code), do: is_binary(code) and code in @pipeline_error_codes

  @spec transcript_terminal_status?(term()) :: boolean()
  def transcript_terminal_status?(status),
    do: is_binary(status) and status in @transcript_terminal_statuses

  @spec registered_code?(term()) :: boolean()
  def registered_code?(code), do: is_binary(code) and Map.has_key?(@specs, code)

  @spec terminal_spec(term()) :: {:ok, map()} | :error
  def terminal_spec(status) do
    if terminal_status?(status), do: spec(status), else: :error
  end

  @spec pipeline_error_spec(term()) :: {:ok, map()} | :error
  def pipeline_error_spec(code) do
    if pipeline_error_code?(code), do: spec(code), else: :error
  end
end
