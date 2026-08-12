defmodule Arbor.Agent.RuntimeAdmission.IntentCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.RuntimeAdmission.IntentCore

  @moduletag :fast

  @target "agent_testtarget01"
  @fp_a "fp_aaa"
  @fp_b "fp_bbb"

  test "fence first rejects admit" do
    assert {:error, :target_fenced} =
             IntentCore.admit(%{}, %{@target => "op1"}, true, true, @target, @fp_a, "rai_1", 0, 10)
  end

  test "not ready rejects" do
    assert {:error, :runtime_admission_not_ready} =
             IntentCore.admit(%{}, %{}, true, false, @target, @fp_a, "rai_1", 0, 10)

    assert {:error, :fence_not_ready} =
             IntentCore.admit(%{}, %{}, false, true, @target, @fp_a, "rai_1", 0, 10)
  end

  test "admit then same fingerprint joins; different conflicts" do
    assert {:ok, :admitted, intent, intents, [{:launch_owner, _}]} =
             IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    assert intent.intent_id == "rai_1"

    assert {:ok, :joined, ^intent, ^intents, []} =
             IntentCore.admit(intents, %{}, true, true, @target, @fp_a, "rai_2", 1, 10)

    assert {:error, :conflict} =
             IntentCore.admit(intents, %{}, true, true, @target, @fp_b, "rai_3", 1, 10)
  end

  test "non_idle and settle" do
    {:ok, :admitted, _i, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    assert IntentCore.non_idle?(intents, @target)

    assert {:ok, done, cleared} =
             IntentCore.settle(intents, @target, "rai_1", {:applied, self()})

    assert done.phase == :terminal
    refute IntentCore.non_idle?(cleared, @target)
  end

  test "bind_worker requires authenticated owner and exact fingerprint" do
    {:ok, :admitted, _intent, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    worker = spawn(fn -> :ok end)

    # Not yet owner_live
    assert {:error, :conflict} =
             IntentCore.bind_worker(intents, @target, "rai_1", @fp_a, self(), worker)

    {:ok, :adopted, _, live} =
      IntentCore.adopt_owner(intents, %{}, true, true, @target, "rai_1", @fp_a, self())

    # Foreign owner cannot bind
    foreign = spawn(fn -> :ok end)

    assert {:error, :not_owner} =
             IntentCore.bind_worker(live, @target, "rai_1", @fp_a, foreign, worker)

    # Wrong fingerprint
    assert {:error, :conflict} =
             IntentCore.bind_worker(live, @target, "rai_1", @fp_b, self(), worker)

    assert {:ok, running} =
             IntentCore.bind_worker(live, @target, "rai_1", @fp_a, self(), worker)

    assert running[@target].worker_pid == worker

    # Authenticate: only bound worker passes
    assert :ok =
             IntentCore.authenticate_worker(running, @target, "rai_1", @fp_a, worker)

    assert {:error, :not_owner} =
             IntentCore.authenticate_worker(running, @target, "rai_1", @fp_a, self())
  end

  test "adopt rejects when fenced; rebinds idle owner" do
    assert {:error, :target_fenced} =
             IntentCore.adopt_owner(%{}, %{@target => "op"}, true, true, @target, "rai_1", @fp_a, self())

    assert {:ok, :adopted, intent, intents} =
             IntentCore.adopt_owner(%{}, %{}, true, true, @target, "rai_1", @fp_a, self())

    assert intent.phase == :owner_live
    assert Map.has_key?(intents, @target)
  end

  test "unknown start classification" do
    assert IntentCore.classify_unknown_start("rai_1", {:exact, "rai_1"}) == :applied
    assert IntentCore.classify_unknown_start("rai_1", :bare) == :conflict
    assert IntentCore.classify_unknown_start("rai_1", {:other, "rai_2"}) == :conflict
    assert IntentCore.classify_unknown_start("rai_1", :not_running) == :not_applied
  end

  test "rebind_owners accepts a fully valid unique inventory" do
    snaps = [
      %{
        intent_id: "rai_1",
        target_agent_id: @target,
        fingerprint: "fp_" <> String.duplicate("a", 16),
        owner_pid: self()
      }
    ]

    assert {:ok, intents} = IntentCore.rebind_owners(%{}, snaps)
    assert intents[@target].phase == :outcome_unknown
    assert IntentCore.non_idle?(intents, @target)
  end

  test "security regression: rebind_owners fails closed on malformed snapshot" do
    # Missing owner_pid / bad shapes must not silently skip and mark ready.
    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: @target,
                 fingerprint: "fp_" <> String.duplicate("a", 16)
               }
             ])

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "not-rai",
                 target_agent_id: @target,
                 fingerprint: "fp_" <> String.duplicate("a", 16),
                 owner_pid: self()
               }
             ])

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: "bad_target",
                 fingerprint: "fp_" <> String.duplicate("a", 16),
                 owner_pid: self()
               }
             ])

    assert {:error, :invalid_inventory} = IntentCore.rebind_owners(%{}, :not_a_list)
  end

  test "security regression: rebind_owners fails closed on duplicate target last-wins" do
    fp = "fp_" <> String.duplicate("b", 16)

    snaps = [
      %{
        intent_id: "rai_1",
        target_agent_id: @target,
        fingerprint: fp,
        owner_pid: self()
      },
      %{
        intent_id: "rai_2",
        target_agent_id: @target,
        fingerprint: fp,
        owner_pid: self()
      }
    ]

    # Must not overwrite the first owner with the second.
    assert {:error, :duplicate_target} = IntentCore.rebind_owners(%{}, snaps)
  end

  test "security regression: rebind_owners fails closed on duplicate intent_id" do
    fp = "fp_" <> String.duplicate("c", 16)

    snaps = [
      %{
        intent_id: "rai_same",
        target_agent_id: "agent_target_a",
        fingerprint: fp,
        owner_pid: self()
      },
      %{
        intent_id: "rai_same",
        target_agent_id: "agent_target_b",
        fingerprint: fp,
        owner_pid: self()
      }
    ]

    assert {:error, :duplicate_intent_id} = IntentCore.rebind_owners(%{}, snaps)
  end

  test "security regression: rebind_owners fails closed on inventory overflow" do
    fp = "fp_" <> String.duplicate("d", 16)

    snaps =
      for i <- 1..257 do
        %{
          intent_id: "rai_#{i}",
          target_agent_id: "agent_t#{i}",
          fingerprint: fp,
          owner_pid: self()
        }
      end

    assert {:error, :inventory_overflow} = IntentCore.rebind_owners(%{}, snaps)
  end

  test "security regression: rebind_owners rejects non-empty base map" do
    fp = "fp_" <> String.duplicate("e", 16)

    assert {:error, :invalid_inventory} =
             IntentCore.rebind_owners(%{"agent_x" => %{}}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: @target,
                 fingerprint: fp,
                 owner_pid: self()
               }
             ])
  end
end
