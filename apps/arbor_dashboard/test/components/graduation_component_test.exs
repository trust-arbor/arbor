defmodule Arbor.Dashboard.Components.GraduationComponentTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Arbor.Dashboard.Components.GraduationComponent

  @moduletag :fast

  test "unconfirmed save is distinct from acknowledged persistence failure and does not expose backend details" do
    socket = GraduationComponent.mount(%Phoenix.LiveView.Socket{}, "agent_review")

    uncertain =
      GraduationComponent.update_decision(
        socket,
        :accept,
        {:error, :graduation_store_outcome_unknown}
      )

    html = panel(uncertain)
    assert html =~ "save outcome is not yet confirmed"
    assert html =~ "write may still complete"
    refute html =~ "rule could not be saved"

    failed =
      GraduationComponent.update_decision(
        socket,
        :accept,
        {:error, {:trust_profile_persist_failed, %{secret: "do-not-display"}}}
      )

    html = panel(failed)
    assert html =~ "rule could not be saved"
    assert html =~ "suggestion remains pending"
    refute html =~ "do-not-display"
    refute html =~ "write may still complete"
  end

  test "ceiling and never-graduate reasons explain why evidence cannot become an action" do
    for {reason, message} <- [
          ceiling_restricted: "system ceiling prevents automatic execution",
          never_graduate: "requires confirmation every time and cannot graduate",
          locked: "explicit unlock and new evidence are required"
        ] do
      row = %{
        uri_prefix: "arbor://code/write",
        current_mode: :ask,
        security_ceiling: :ask,
        verified_human_approvals: 7,
        rejections: 3,
        unknown_rejections: 2,
        unknown_approvals: 4,
        human_streak: 7,
        threshold: 5,
        revision: 14,
        pending: false,
        reason: reason,
        suggestion_id: nil
      }

      socket =
        %Phoenix.LiveView.Socket{}
        |> GraduationComponent.mount("agent_review")
        |> GraduationComponent.update_result({:ok, [row]})

      html = panel(socket)
      assert html =~ message
      assert html =~ "Unverified answers"
      refute html =~ "phx-click=\"graduation:accept\""
      refute html =~ "phx-click=\"graduation:decline\""
    end
  end

  test "unavailable status clears prior evidence and mounting another target clears feedback" do
    socket =
      %Phoenix.LiveView.Socket{}
      |> GraduationComponent.mount("agent_old")
      |> GraduationComponent.update_decision(:accept, :ok)
      |> GraduationComponent.update_result({:error, :graduation_authority_required})

    assert panel(socket) =~ "unavailable without a current authenticated human session"
    refute panel(socket) =~ "No approval evidence recorded"
    fresh = GraduationComponent.mount(socket, "agent_new")
    assert fresh.assigns.graduation_review.agent_id == "agent_new"
    assert fresh.assigns.graduation_review.rows == []
    assert fresh.assigns.graduation_review.feedback == nil
  end

  defp panel(socket),
    do:
      render_component(&GraduationComponent.graduation_panel/1,
        review: socket.assigns.graduation_review
      )
end
