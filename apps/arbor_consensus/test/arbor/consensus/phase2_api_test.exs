defmodule Arbor.Consensus.Phase2APITest do
  @moduledoc """
  Integration tests for the Phase 2 agent-facing API:
  propose/2, ask/2, await/2, and the Helpers module.
  """
  # async: false — propose/2 fails closed without an authenticated :caller_id, so
  # propose_and_await/2 here authenticates for real (starts Security, toggles
  # capability_signing_required, grants the cap). Those touch global Security
  # processes/config, so this file must not race other async tests.
  use ExUnit.Case, async: false

  alias Arbor.Consensus.{Coordinator, Helpers}
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Security

  @propose_caller_id "agent_phase2_propose_caller"

  setup_all do
    # Start all security processes so Security.healthy?() is true and the
    # consensus facade's propose/2 cap check runs through real enforcement
    # (no permissive fallback). Order matters: Identity.Registry before
    # SystemAuthority. Mirrors the AuthorizationE2ETest setup.
    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    for {mod, opts} <- security_children do
      unless Process.whereis(mod) do
        case Supervisor.start_child(Arbor.Security.Supervisor, {mod, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> raise "Failed to start #{mod}: #{inspect(reason)}"
        end
      end
    end

    Process.sleep(20)

    unless Security.healthy?() do
      raise "Security.healthy?() returned false after starting all processes"
    end

    :ok
  end

  setup do
    {_es_pid, es_name} = TestHelpers.start_test_event_store()

    {_pid, name} =
      TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.AlwaysApproveBackend,
        config: [evaluation_timeout_ms: 5_000]
      )

    %{coordinator: name, event_store: es_name}
  end

  # ============================================================================
  # Coordinator.await/2
  # ============================================================================

  describe "await/2" do
    test "returns decision when proposal is already decided", %{coordinator: coord} do
      {:ok, id} =
        Coordinator.submit(
          %{proposer: "agent_1", topic: :code_modification, description: "Test await"},
          server: coord
        )

      # Wait for decision via polling first
      TestHelpers.wait_for_decision(coord, id)

      # Now await should return immediately since it's already decided
      assert {:ok, decision} = Coordinator.await(id, server: coord, timeout: 1_000)
      assert decision.decision in [:approved, :rejected]
      assert decision.proposal_id == id
    end

    test "waits for decision on in-progress proposal", %{coordinator: coord} do
      {:ok, id} =
        Coordinator.submit(
          %{proposer: "agent_1", topic: :code_modification, description: "Test await blocking"},
          server: coord
        )

      # await should block and return the decision
      assert {:ok, decision} = Coordinator.await(id, server: coord, timeout: 10_000)
      assert decision.decision in [:approved, :rejected]
      assert decision.proposal_id == id
    end

    test "returns :not_found for unknown proposal", %{coordinator: coord} do
      assert {:error, :not_found} =
               Coordinator.await("prop_nonexistent", server: coord, timeout: 1_000)
    end

    test "returns :timeout when decision takes too long" do
      {_es_pid, _es_name} = TestHelpers.start_test_event_store()

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 30_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{proposer: "agent_1", topic: :code_modification, description: "Slow test"},
          server: coord
        )

      # Very short timeout — should time out before the slow backend finishes
      assert {:error, :timeout} = Coordinator.await(id, server: coord, timeout: 100)
    end

    test "multiple waiters receive the same decision", %{coordinator: coord} do
      {:ok, id} =
        Coordinator.submit(
          %{proposer: "agent_1", topic: :code_modification, description: "Multi-waiter"},
          server: coord
        )

      parent = self()

      # Spawn 3 concurrent waiters
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            result = Coordinator.await(id, server: coord, timeout: 10_000)
            send(parent, {:waiter_result, i, result})
            result
          end)
        end

      results = Task.await_many(tasks, 15_000)

      # All should get the same decision
      assert Enum.all?(results, fn {:ok, d} -> d.proposal_id == id end)

      decisions = Enum.map(results, fn {:ok, d} -> d.decision end)
      assert Enum.uniq(decisions) |> length() == 1
    end
  end

  # ============================================================================
  # Helpers module
  # ============================================================================

  describe "Helpers.propose_and_await/2" do
    test "submits and returns the decision in one call", %{coordinator: coord} do
      # propose/2 fails closed without an authenticated :caller_id, so we
      # authenticate for REAL: Security is up (assert it), signing is relaxed
      # for the test, and we grant the caller the arbor://consensus/propose cap.
      # propose_and_await/2 threads :caller_id through to propose/2, which routes
      # to authorize_propose/3 → real cap check → Coordinator.submit.
      assert Security.healthy?(),
             "Security must be up so the propose cap check runs through real enforcement"

      original_signing = Application.get_env(:arbor_security, :capability_signing_required)
      Application.put_env(:arbor_security, :capability_signing_required, false)

      {:ok, _cap} =
        Security.grant(
          principal: @propose_caller_id,
          resource: "arbor://consensus/propose"
        )

      on_exit(fn ->
        if Process.whereis(Arbor.Security.CapabilityStore) do
          Arbor.Security.CapabilityStore.revoke_all(@propose_caller_id)
        end

        if is_nil(original_signing) do
          Application.delete_env(:arbor_security, :capability_signing_required)
        else
          Application.put_env(:arbor_security, :capability_signing_required, original_signing)
        end
      end)

      assert {:ok, decision} =
               Helpers.propose_and_await(
                 %{
                   proposer: @propose_caller_id,
                   topic: :code_modification,
                   description: "propose_and_await test"
                 },
                 server: coord,
                 timeout: 10_000,
                 caller_id: @propose_caller_id
               )

      assert decision.decision in [:approved, :rejected]
    end

    test "returns error for invalid proposal", %{coordinator: coord} do
      # Missing required fields
      result = Helpers.propose_and_await(%{}, server: coord, timeout: 5_000)
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # await_decision test helper
  # ============================================================================

  describe "TestHelpers.await_decision/3" do
    test "works as drop-in replacement for wait_for_decision", %{coordinator: coord} do
      {:ok, id} =
        Coordinator.submit(
          %{proposer: "agent_1", topic: :code_modification, description: "Helper test"},
          server: coord
        )

      assert {:ok, decision} = TestHelpers.await_decision(coord, id)
      assert decision.proposal_id == id
    end
  end
end
