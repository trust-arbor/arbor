defmodule Arbor.Dashboard.Live.ChatLive.HelpersTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Live.ChatLive.Helpers, as: H

  @moduletag :fast

  describe "approval card helpers" do
    defp approval(trust, extra \\ %{}) do
      %{
        id: "irq_1",
        proposer: "agent_test",
        resource_uri: "arbor://fs/write/report.md",
        metadata: Map.merge(%{gate: :trust_policy, reason: :policy_gated, trust: trust}, extra)
      }
    end

    test "approval_why names the matched trust rule" do
      why =
        H.approval_why(
          approval(%{
            effective_mode: :ask,
            baseline: :ask,
            matched_rule: %{prefix: "arbor://fs/write", mode: :ask}
          })
        )

      assert why == "Asking because your trust rule for arbor://fs/write is ask."
    end

    test "approval_why mentions a restrictive security ceiling" do
      why =
        H.approval_why(
          approval(%{
            effective_mode: :ask,
            baseline: :allow,
            matched_rule: %{prefix: "arbor://shell", mode: :allow},
            ceiling_match: %{prefix: "arbor://shell", mode: :ask}
          })
        )

      assert why =~ "your trust rule for arbor://shell is allow"
      assert why =~ "(security ceiling arbor://shell: ask)"
    end

    test "approval_why falls back to the baseline when no rule matched" do
      why = H.approval_why(approval(%{effective_mode: :ask, baseline: :ask}))
      assert why == "Asking because no trust rule matches, so the ask baseline applies."
    end

    test "approval_why explains a per-capability constraint" do
      why =
        H.approval_why(approval(%{effective_mode: :auto}, %{gate: :capability_constraint}))

      assert why == "Asking because the granted capability requires approval per use."
    end

    test "approval_why tolerates string keys from JSON round-trips" do
      card = %{
        "metadata" => %{
          "gate" => "trust_policy",
          "trust" => %{"matched_rule" => %{"prefix" => "arbor://fs/write", "mode" => "ask"}}
        }
      }

      assert H.approval_why(card) == "Asking because your trust rule for arbor://fs/write is ask."
    end

    test "approval_why has a generic fallback with no metadata" do
      assert H.approval_why(%{id: "x"}) == "Requires your approval"
    end

    test "risk badges lead with reversibility" do
      badges =
        H.approval_risk_badges(
          approval(%{
            profile: %{
              reversibility: :irreversible,
              blast_radius: :critical,
              effect_class: :process_spawn
            }
          })
        )

      assert [
               %{label: "one-way", tone: :danger},
               %{label: "blast: critical", tone: :danger},
               %{label: "process spawn", tone: :muted}
             ] = badges
    end

    test "risk badges are empty without a profile" do
      assert H.approval_risk_badges(approval(%{effective_mode: :ask})) == []
      assert H.approval_risk_badges(%{}) == []
    end

    test "approval_irreversible? and graduation follow the profile" do
      one_way =
        approval(%{profile: %{reversibility: :irreversible, graduation_threshold: :never}})

      undoable = approval(%{profile: %{reversibility: :reversible, graduation_threshold: 3}})

      assert H.approval_irreversible?(one_way)
      refute H.approval_irreversible?(undoable)
      refute H.approval_irreversible?(%{})

      assert H.approval_graduation_possible?(one_way) == false
      assert H.approval_graduation_possible?(undoable) == true
      assert H.approval_graduation_possible?(%{}) == nil
    end

    test "approval_target shows the concrete target only when it adds information" do
      assert H.approval_target(approval(%{}, %{target: "/workspace/report.md"})) ==
               "/workspace/report.md"

      assert H.approval_target(approval(%{}, %{target: "arbor://fs/write/report.md"})) == nil
      assert H.approval_target(approval(%{})) == nil
    end
  end

  describe "message_style/3 — agent-initiated notification (A1 notify channel)" do
    test "renders distinctly in single-agent mode" do
      style = H.message_style(:notification, nil, false)
      assert style =~ "dashed"
      assert style =~ "italic"
      # not the assistant/user style
      refute style =~ "rgba(74, 255, 158"
    end

    test "stays distinct in group mode (wins over the group-mode catch-all)" do
      style = H.message_style(:notification, nil, true)
      assert style =~ "dashed"
      # the group-mode default is a solid 3px accent, not dashed
      refute style == H.message_style(:assistant, nil, true)
    end

    test "accepts a string role too" do
      assert H.message_style("notification", nil, false) ==
               H.message_style(:notification, nil, false)
    end

    test "normal roles are unaffected" do
      assert H.message_style(:user, nil, false) =~ "margin-left"
      assert H.message_style(:assistant, nil, false) =~ "rgba(74, 255, 158"
    end
  end

  describe "role_label/1 — notification" do
    test "labels an agent-initiated notification with the thought affordance" do
      assert H.role_label(:notification) == "💭 Agent"
      assert H.role_label("notification") == "💭 Agent"
    end

    test "other roles unchanged" do
      assert H.role_label(:user) == "You"
      assert H.role_label(:assistant) == "Agent"
      assert H.role_label(:anything_else) == "System"
    end
  end
end
