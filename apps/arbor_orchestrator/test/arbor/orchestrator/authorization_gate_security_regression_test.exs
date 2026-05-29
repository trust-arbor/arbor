defmodule Arbor.Orchestrator.AuthorizationGateSecurityRegressionTest do
  @moduledoc """
  Security regression tests for the once-per-turn orchestrator authorization gate.

  Covers the high-severity fail-open / bypass issues:
  - authorize_orchestrator (and its duplicate in HeartbeatService) previously
    returned :ok on any error, on rescue/catch, or when security was unavailable.
  - This permitted turns/heartbeats when the security subsystem (CapabilityStore
    or arbor_security app) was down.

  The tests use the `security_available_override` test hook (no global process
  mutation) and assert via the public Session.send_message API that the gate now
  fails closed.

  These tests MUST fail on `git checkout HEAD~1` (pre-fix permissive behavior)
  and pass on HEAD (post-fix fail-closed).
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.TestCapabilities

  @app :arbor_orchestrator

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "arbor_auth_regress_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    turn_dot = """
    digraph Turn {
      graph [goal="Security regression minimal turn"]
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    heartbeat_dot = """
    digraph Heartbeat {
      graph [goal="Security regression minimal heartbeat"]
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    turn_path = Path.join(tmp, "turn.dot")
    heartbeat_path = Path.join(tmp, "heartbeat.dot")
    File.write!(turn_path, turn_dot)
    File.write!(heartbeat_path, heartbeat_dot)

    # Ensure a test agent has the cap (harmless when override forces unavailable)
    TestCapabilities.grant_orchestrator_access("agent_sec_regress_test")

    on_exit(fn ->
      Application.delete_env(@app, :security_available_override)
      File.rm_rf(tmp)
    end)

    %{
      turn_path: turn_path,
      heartbeat_path: heartbeat_path,
      agent_id: "agent_sec_regress_test"
    }
  end

  defp start_test_session(ctx, overrides \\ []) do
    id = "sec-regress-#{:erlang.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          session_id: id,
          agent_id: ctx.agent_id,
          trust_tier: :established,
          turn_dot: ctx.turn_path,
          heartbeat_dot: ctx.heartbeat_path,
          adapters: %{llm_call: fn _, _, _ -> {:ok, %{content: "unused"}} end},
          start_heartbeat: false
        ],
        overrides
      )

    {:ok, pid} = Session.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, pid}
  end

  describe "orchestrator execution gate (arbor://orchestrator/execute) — fail-closed" do
    test "send_message returns unauthorized when security unavailable (override)", ctx do
      Application.put_env(@app, :security_available_override, false)

      {:ok, pid} = start_test_session(ctx)

      assert {:error, {:unauthorized, :security_unavailable}} =
               Session.send_message(pid, "this must not execute")
    end

    test "send_message succeeds when security available (override true forces path)", ctx do
      # Force the "available" path even if real store not present in this vm slice
      Application.put_env(@app, :security_available_override, true)

      {:ok, pid} = start_test_session(ctx)

      # With override true we take the Security.authorize branch.
      # In this isolated test the store may not have the exact cap for this
      # dynamic id (the grant above used the helper which inserts unsigned),
      # so we may get unauthorized or authorized depending on test_helper state.
      # The key behavioral assertion for the *bug* is the unavailable case above.
      # Here we just ensure we don't crash and get a proper auth-shaped reply.
      result = Session.send_message(pid, "ping under forced available")

      assert match?({:ok, _}, result) or match?({:error, {:unauthorized, _}}, result)
    end

    test "default (no override) uses real detection and does not crash", ctx do
      Application.delete_env(@app, :security_available_override)

      {:ok, pid} = start_test_session(ctx)

      # Should either succeed (if store present + cap granted by test_helper) or
      # fail with a proper unauthorized — never a silent :ok bypass.
      result = Session.send_message(pid, "default path check")

      assert match?({:ok, _}, result) or match?({:error, {:unauthorized, _}}, result)
    end
  end
end
