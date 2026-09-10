defmodule Arbor.Dashboard.Components.GraduationComponent do
  @moduledoc """
  Socket-first presentation of owner-validated graduation evidence.

  The LiveView supplies public Trust results. This component neither fetches
  authority nor treats a suggestion identifier as permission.
  """
  use Phoenix.Component

  def mount(socket, agent_id \\ nil) do
    assign(socket, :graduation_review, %{
      agent_id: agent_id,
      rows: [],
      error: nil,
      feedback: nil
    })
  end

  def update_result(socket, {:ok, rows}) when is_list(rows) do
    assign(socket, :graduation_review, %{
      socket.assigns.graduation_review
      | rows: rows,
        error: nil
    })
  end

  def update_result(socket, {:error, reason}) do
    assign(socket, :graduation_review, %{
      socket.assigns.graduation_review
      | rows: [],
        error: error_message(reason)
    })
  end

  def update_decision(socket, operation, result) do
    assign(socket, :graduation_review, %{
      socket.assigns.graduation_review
      | feedback: decision_message(operation, result)
    })
  end

  attr(:review, :map, required: true)

  def graduation_panel(assigns) do
    ~H"""
    <section id="graduation-review" aria-labelledby="graduation-title" style="margin-bottom: 1.5rem;">
      <h4 id="graduation-title">Graduation review</h4>
      <p>
        Review each scope before enabling automatic execution. Capabilities and system ceilings still apply.
      </p>
      <button phx-click="graduation:refresh">Refresh review</button>
      <p :if={@review.feedback} id="graduation-feedback" role="status">{@review.feedback}</p>
      <p :if={@review.error} id="graduation-unavailable" role="status">{@review.error}</p>
      <p :if={!@review.error && @review.rows == []} id="graduation-empty">
        No approval evidence recorded for this agent.
      </p>
      <article
        :for={row <- @review.rows}
        data-graduation-scope={row.uri_prefix}
        style="padding: 1rem; margin-top: 0.75rem; border: 1px solid var(--aw-border, #333); border-radius: 6px;"
      >
        <strong>{row.uri_prefix}</strong>
        <dl style="display: grid; grid-template-columns: minmax(9rem, 1fr) 2fr; gap: 0.35rem 1rem;">
          <dt>Current mode</dt>
          <dd>{row.current_mode}</dd>
          <dt>System ceiling</dt>
          <dd>{row.security_ceiling}</dd>
          <dt>Verified human approvals</dt>
          <dd>{row.verified_human_approvals}</dd>
          <dt>Verified human rejections</dt>
          <dd>{row.rejections - row.unknown_rejections}</dd>
          <dt>Unverified answers</dt>
          <dd>{row.unknown_approvals} approvals / {row.unknown_rejections} rejections</dd>
          <dt>Current human streak</dt>
          <dd>{row.human_streak}</dd>
          <dt>Required human streak</dt>
          <dd>{required_streak(row.threshold)}</dd>
          <dt>Evidence revision</dt>
          <dd>{row.revision}</dd>
        </dl>
        <p>{status_message(row)}</p>
        <p :if={row.pending}>
          Suggestion: <code data-graduation-id={row.suggestion_id}>{row.suggestion_id}</code>
        </p>
        <div :if={row.pending} style="display: flex; gap: 0.75rem;">
          <button
            phx-click="graduation:accept"
            phx-value-prefix={row.uri_prefix}
            phx-value-suggestion_id={row.suggestion_id}
          >
            Accept automatic execution
          </button>
          <button
            phx-click="graduation:decline"
            phx-value-prefix={row.uri_prefix}
            phx-value-suggestion_id={row.suggestion_id}
          >
            Decline and lock scope
          </button>
        </div>
      </article>
    </section>
    """
  end

  defp required_streak(:never), do: "Never eligible"
  defp required_streak(n) when is_integer(n), do: max(n, 1)
  defp required_streak(_), do: "Unavailable"

  defp status_message(%{pending: true}),
    do:
      "Ready for your explicit decision. Declining locks this scope until it is explicitly unlocked."

  defp status_message(%{reason: reason}), do: reason_message(reason)

  defp reason_message(:never_graduate),
    do: "This scope requires confirmation every time and cannot graduate."

  defp reason_message(:ceiling_restricted),
    do: "The system ceiling prevents automatic execution for this scope."

  defp reason_message(:locked),
    do: "This scope is locked. An explicit unlock and new evidence are required."

  defp reason_message(:profile_frozen), do: "The agent's trust profile is frozen."
  defp reason_message(:policy_blocked), do: "Current policy blocks this scope."

  defp reason_message(:already_automatic),
    do: "Current policy already permits automatic execution."

  defp reason_message(:insufficient_human_evidence),
    do:
      "More consecutive verified human approvals are required. Unverified answers do not qualify."

  defp reason_message(:profile_changed),
    do: "The trust profile changed. New evidence is required for a fresh suggestion."

  defp reason_message(_), do: "No current actionable suggestion is available."

  defp decision_message(:accept, :ok), do: "Accepted. The automatic-execution rule was saved."
  defp decision_message(:decline, :ok), do: "Declined. This scope is locked against graduation."
  defp decision_message(_, {:error, reason}), do: error_message(reason)

  defp error_message(:graduation_authority_required),
    do:
      "Graduation review is unavailable without a current authenticated human session and permission for this agent."

  defp error_message(:graduation_store_outcome_unknown),
    do:
      "The save outcome is not yet confirmed. Review the current mode before retrying; the write may still complete."

  defp error_message({:trust_profile_persist_failed, _}),
    do:
      "The rule could not be saved. The suggestion remains pending; retry when storage is available."

  defp error_message(:stale_graduation_suggestion),
    do: "This suggestion is stale. Review the refreshed evidence before deciding."

  defp error_message(reason)
       when reason in [
              :locked,
              :never_graduate,
              :ceiling_restricted,
              :profile_frozen,
              :policy_blocked,
              :already_automatic,
              :insufficient_human_evidence,
              :profile_changed
            ],
       do: reason_message(reason)

  defp error_message(_), do: "Graduation review is unavailable. Refresh and try again."
end
