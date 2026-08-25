defmodule Arbor.Agent.Executor.DecideCoreTest do
  @moduledoc """
  Pure table-tests for Executor decide. No GenServer, Security, or Memory.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Executor.DecideCore
  alias Arbor.Contracts.Memory.Intent

  @now ~U[2026-08-25 00:00:00Z]

  defp act_intent(opts \\ []) do
    Intent.action(
      Keyword.get(opts, :action, :file_read),
      Keyword.get(opts, :params, %{path: "/tmp/x"}),
      id: Keyword.get(opts, :id, "int_act"),
      created_at: @now,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp mental_intent(type, opts \\ []) do
    Intent.new(type,
      id: Keyword.get(opts, :id, "int_#{type}"),
      created_at: @now,
      reasoning: Keyword.get(opts, :reasoning, "n/a"),
      params: Keyword.get(opts, :params, %{})
    )
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        agent_id: "agent_test",
        sandbox_level: :standard,
        sender_verdict: :ok,
        reflex_verdict: :ok,
        auth_verdict: {:ok, :authorized},
        canonical_uri: "arbor://fs/read"
      },
      overrides
    )
  end

  describe "decide/2 — :act + kernel verdict" do
    test ":act + {:ok, :authorized} → {:execute, ...}" do
      assert {:execute, :file_read, params, :basic} =
               DecideCore.decide(act_intent(), snapshot())

      assert params.path == "/tmp/x"
      assert params.sandbox == :basic
    end

    test "security regression: :act + pending_approval is :ask, not :block" do
      decision =
        DecideCore.decide(
          act_intent(),
          snapshot(%{auth_verdict: {:ok, :pending_approval, "irq_1"}})
        )

      assert {:ask, "arbor://fs/read", %{approval_id: "irq_1"}} = decision
      refute match?({:block, :pending_approval}, decision)
      refute match?({:block, _}, decision)
    end

    test ":act + {:error, :denied} → {:block, :denied}" do
      assert {:block, :denied} =
               DecideCore.decide(act_intent(), snapshot(%{auth_verdict: {:error, :denied}}))
    end

    test ":act with no auth_verdict fails closed" do
      assert {:block, :missing_auth_verdict} =
               DecideCore.decide(act_intent(), snapshot(%{auth_verdict: nil}))
    end

    test ":act with missing action fails closed" do
      intent = mental_intent(:act, id: "int_no_action")

      assert {:block, :missing_action} =
               DecideCore.decide(intent, snapshot())
    end
  end

  describe "decide/2 — mental intents skip without auth" do
    test ":think / :wait / :reflect / :internal → {:skip, type} without an auth verdict" do
      for type <- [:think, :wait, :reflect, :internal] do
        assert {:skip, ^type} =
                 DecideCore.decide(
                   mental_intent(type),
                   snapshot(%{auth_verdict: nil, canonical_uri: nil})
                 )
      end
    end

    test "mental intents still honor a blocked reflex" do
      assert {:block, :reflex_denied} =
               DecideCore.decide(
                 mental_intent(:think),
                 snapshot(%{reflex_verdict: {:blocked, :test_reflex, :reflex_denied}})
               )
    end
  end

  describe "decide/2 — sender and reflex" do
    test "unauthorized source_agent → {:reject_sender, _}" do
      assert {:reject_sender, :unauthorized} =
               DecideCore.decide(
                 act_intent(),
                 snapshot(%{sender_verdict: {:error, :unauthorized}})
               )
    end

    test "sender rejection wins over an authorized auth_verdict" do
      assert {:reject_sender, :capability_not_found} =
               DecideCore.decide(
                 act_intent(),
                 snapshot(%{
                   sender_verdict: {:error, :capability_not_found},
                   auth_verdict: {:ok, :authorized}
                 })
               )
    end

    test "blocked reflex wins over authorized auth_verdict" do
      assert {:block, :dangerous_command} =
               DecideCore.decide(
                 act_intent(),
                 snapshot(%{
                   reflex_verdict: {:blocked, :shell_rm, :dangerous_command},
                   auth_verdict: {:ok, :authorized}
                 })
               )
    end
  end

  describe "decide/2 — heartbeat is not an auth exception" do
    test "security regression: heartbeat-tagged :act still requires the kernel" do
      intent = act_intent(metadata: %{"source" => "heartbeat"})

      assert {:block, :missing_auth_verdict} =
               DecideCore.decide(intent, snapshot(%{auth_verdict: nil}))

      assert {:ask, "arbor://fs/read", %{approval_id: "irq_hb"}} =
               DecideCore.decide(
                 intent,
                 snapshot(%{auth_verdict: {:ok, :pending_approval, "irq_hb"}})
               )

      assert {:execute, :file_read, _params, :basic} =
               DecideCore.decide(intent, snapshot())
    end
  end

  describe "new/2 and show/1" do
    test "accepts string-keyed snapshots" do
      state =
        DecideCore.new(act_intent(), %{
          "agent_id" => "agent_s",
          "sandbox_level" => "strict",
          "sender_verdict" => :ok,
          "reflex_verdict" => :ok,
          "auth_verdict" => {:ok, :authorized},
          "canonical_uri" => "arbor://fs/read"
        })

      assert {:execute, :file_read, params, :strict} = DecideCore.decide(state)
      assert params.sandbox == :strict
    end

    test "show/1 converts decisions to maps" do
      decision = DecideCore.decide(act_intent(), snapshot())
      shown = DecideCore.show(decision)

      assert shown.decision == :execute
      assert shown.action == :file_read
      assert shown.sandbox == :basic
    end

    test "invalid intent fails closed" do
      assert {:block, :invalid_intent} = DecideCore.decide(:not_an_intent, snapshot())
    end
  end

  describe "security regression: Executor source mapping" do
    test "Executor no longer maps pending_approval to blocked or auto-auths heartbeat" do
      path = Path.expand("../../../../lib/arbor/agent/executor.ex", __DIR__)
      src = File.read!(path)

      refute src =~ ~r/\{:blocked,\s*:pending_approval\}/,
             "Executor must not map kernel pending_approval to blocked/fail-intent"

      refute src =~ ~r/metadata:\s*%\{"source"\s*=>\s*"heartbeat"\}/,
             "Executor must not auto-authorize heartbeat-tagged intents"

      refute src =~ "Process.put(:arbor_executor_agent_id",
             "Executor must pass agent_id in the snapshot/dispatch args, not the process dictionary"

      refute src =~ "Process.get(:arbor_executor_agent_id"
    end

    test "ActionDispatch no longer reads executor identity from the process dictionary" do
      path = Path.expand("../../../../lib/arbor/agent/executor/action_dispatch.ex", __DIR__)
      src = File.read!(path)

      refute src =~ "Process.get(:arbor_executor_agent_id"
      refute src =~ "Process.get(:arbor_executor_sandbox_level"
    end
  end
end
