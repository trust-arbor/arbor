defmodule Arbor.Agent.LifecycleCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.LifecycleCore

  defp desired(id, auto_start), do: %{agent_id: id, auto_start: auto_start}
  defp actual(id, identity_present), do: %{agent_id: id, identity_present: identity_present}

  describe "reconcile/3 — G1 (desired-running but absent)" do
    test "an auto_start agent with no live process → :start" do
      intents = LifecycleCore.reconcile([desired("a", true)], [])

      assert intents == [%{agent_id: "a", action: :start, reason: :desired_running_but_absent}]
    end

    test "a NON-auto_start absent agent → no intent (not forced to run)" do
      assert LifecycleCore.reconcile([desired("a", false)], []) == []
    end

    test "an auto_start agent that IS live → no intent (leave alone)" do
      assert LifecycleCore.reconcile([desired("a", true)], [actual("a", true)]) == []
    end

    test "g1_policy: :leave_alone suppresses the restart (report-only)" do
      assert LifecycleCore.reconcile([desired("a", true)], [], g1_policy: :leave_alone) == []
    end
  end

  describe "reconcile/3 — G2 (identity-gone zombie)" do
    test "a live agent whose identity is gone → :reap" do
      intents = LifecycleCore.reconcile([], [actual("z", false)])

      assert intents == [%{agent_id: "z", action: :reap, reason: :identity_gone}]
    end

    test "a live agent with identity present → no intent" do
      assert LifecycleCore.reconcile([], [actual("z", true)]) == []
    end
  end

  describe "reconcile/3 — interaction + invariants" do
    test "reap wins over restart: an auto_start agent that is live but identity-gone → :reap only" do
      intents = LifecycleCore.reconcile([desired("a", true)], [actual("a", false)])

      # exactly one intent, and it's the reap — NOT a duplicate start+reap
      assert intents == [%{agent_id: "a", action: :reap, reason: :identity_gone}]
    end

    test "no agent appears in more than one intent" do
      desired = [desired("a", true), desired("b", true), desired("c", false)]
      actual = [actual("a", true), actual("d", false), actual("e", true)]

      intents = LifecycleCore.reconcile(desired, actual)
      ids = Enum.map(intents, & &1.agent_id)

      assert ids == Enum.uniq(ids)
      # b: auto_start + absent → :start ; d: live + identity gone → :reap ; others consistent
      assert Enum.sort(intents) ==
               Enum.sort([
                 %{agent_id: "b", action: :start, reason: :desired_running_but_absent},
                 %{agent_id: "d", action: :reap, reason: :identity_gone}
               ])
    end

    test "empty snapshots → no intents" do
      assert LifecycleCore.reconcile([], []) == []
    end
  end

  describe "summarize/1" do
    test "counts actions by kind" do
      intents = [
        %{agent_id: "a", action: :start, reason: :desired_running_but_absent},
        %{agent_id: "b", action: :reap, reason: :identity_gone},
        %{agent_id: "c", action: :reap, reason: :identity_gone}
      ]

      assert LifecycleCore.summarize(intents) == %{start: 1, reap: 2}
    end
  end
end
