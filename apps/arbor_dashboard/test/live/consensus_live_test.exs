defmodule Arbor.Dashboard.Live.ConsensusLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "ConsensusLive" do
    test "renders consensus dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "Consensus"
      assert html =~ "Council deliberation and decisions"
    end

    test "shows tab buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "Proposals"
      assert html =~ "Decisions"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "Total proposals"
      assert html =~ "Active councils"
      assert html =~ "Approved"
      assert html =~ "Rejected"
    end

    test "shows status filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "filter-status"
      assert html =~ "All"
      assert html =~ "Pending"
    end

    test "tab switching works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/consensus")

      html = render_click(view, "select-tab", %{"tab" => "decisions"})
      assert html =~ "decisions-stream"

      html = render_click(view, "select-tab", %{"tab" => "proposals"})
      assert html =~ "proposals-stream"
    end
  end

  describe "ConsensusLive mount grant policy (H11b regression)" do
    alias Arbor.Dashboard.Live.ConsensusLive

    test "security regression (H11b): mount does NOT auto-grant any /admin capability" do
      # H11b: previously, mounting /consensus auto-granted arbor://consensus/admin
      # to the current OIDC user — admin-by-visit. That re-opened the hole H11
      # closed in the OIDC login flow. Visiting a dashboard route is not a
      # trust event.
      resources = ConsensusLive.mount_grant_resources()

      assert resources == [],
             "ConsensusLive mount must grant no capabilities on visit — H11b regression. " <>
               "Got: #{inspect(resources)}"

      for resource <- resources do
        refute String.contains?(resource, "/admin"),
               "ConsensusLive mount auto-grants admin capability " <>
                 "#{inspect(resource)} — H11b regression."
      end
    end
  end

  describe "always-allow authorization decision (H13 regression)" do
    alias Arbor.Dashboard.Live.ConsensusLive

    test "security regression (H13): non-:authorized decisions deny the auto-promote" do
      # H13: the "Always Allow" event used to call Trust.Store.always_allow/2
      # unconditionally — any actor that could approve a proposal could
      # permanently set the agent's trust profile to :auto for any resource.
      # The fix gates the mutation behind arbor://trust/auto_promote. The pure
      # decision function below is the gate; this test pins every non-OK
      # AuthDecision / Security.authorize result shape to the deny outcome.
      for decision <- [
            {:error, :not_found},
            {:error, :no_capability},
            {:error, :security_unavailable},
            {:error, :no_actor},
            {:ok, :pending_approval, "cap_123"},
            {:requires_approval, %{id: "cap_x"}}
          ] do
        assert {:error, :unauthorized_auto_promote} =
                 ConsensusLive.authorize_auto_promote_decision(decision),
               "H13 regression: decision #{inspect(decision)} must deny auto-promote"
      end
    end

    test ":authorized passes the gate" do
      assert :ok = ConsensusLive.authorize_auto_promote_decision(:authorized)
      assert :ok = ConsensusLive.authorize_auto_promote_decision({:ok, :authorized})
    end
  end
end
