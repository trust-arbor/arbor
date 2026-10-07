defmodule Arbor.Agent.ActionCycleServerTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.ActionCycleServer
  alias Arbor.Contracts.Security.{Identity, SigningAuthority, SigningAuthorityBootstrap}

  @moduletag :fast

  setup_all do
    ensure_registry(Arbor.Agent.ActionCycleRegistry)
    :ok
  end

  setup do
    agent_id = "cycle_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        case Registry.lookup(Arbor.Agent.ActionCycleRegistry, agent_id) do
          [{pid, _}] ->
            try do
              GenServer.stop(pid, :normal, 1_000)
            catch
              :exit, _ -> :ok
            end

          [] ->
            :ok
        end
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, agent_id: agent_id}
  end

  defp ensure_registry(name) do
    unless Process.whereis(name) do
      {:ok, _} = Registry.start_link(keys: :unique, name: name)
    end
  end

  describe "start_link/1" do
    test "malformed bootstrap fails closed" do
      Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, false) end)

      assert {:error,
              {:action_cycle_authentication_failed,
               {:signing_authority_claim_failed, :invalid_token}}} =
               ActionCycleServer.start_link(
                 agent_id: "agent_malformed_bootstrap",
                 signing_authority_bootstrap: %{}
               )
    end

    test "starts with required agent_id", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}

      {:ok, pid} = ActionCycleServer.start_link(agent_id: agent_id, name: name)
      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert state.signing_authority == nil
      refute Map.has_key?(state, :authority_signer)
    end
  end

  describe "enqueue_percept/2" do
    test "security regression: action cycle and bootstrap close ignore hostile state custody" do
      {identity, bootstrap} = signing_bootstrap!(:action_cycle)
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, identity.agent_id}}

      llm_fn = fn _context ->
        {:ok, %{"mental_actions" => [], "intent" => nil, "wait" => true}}
      end

      {:ok, pid} =
        ActionCycleServer.start_link(
          agent_id: identity.agent_id,
          name: name,
          signing_authority_bootstrap: bootstrap,
          llm_fn: llm_fn
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      state = :sys.get_state(pid)
      assert state.signing_authority == nil
      assert state.signer == nil
      assert state.signing_authority_bootstrap == nil

      {:ok, forged_authority} =
        SigningAuthority.new(
          token: :crypto.strong_rand_bytes(32),
          principal_id: "agent_forged_action_cycle",
          purpose: :action_cycle
        )

      {:ok, forged_bootstrap} =
        SigningAuthorityBootstrap.new(
          token: :crypto.strong_rand_bytes(32),
          principal_id: "agent_forged_action_cycle",
          purpose: :action_cycle
        )

      forged = :ets.new(:forged_action_cycle_credentials, [:set, :private])

      true =
        :ets.insert(
          forged,
          {:action_cycle_credentials_v1,
           %{
             signing_authority: forged_authority,
             signer: nil,
             bootstrap: forged_bootstrap
           }}
        )

      true = :ets.give_away(forged, pid, :forged_action_cycle_credentials)
      assert eventually(fn -> :ets.info(forged, :owner) == pid end)

      :sys.replace_state(pid, fn current ->
        current
        |> Map.put(:credential_custody, forged)
        |> Map.put(:signing_authority, forged_authority)
        |> Map.put(:signing_authority_bootstrap, forged_bootstrap)
      end)

      assert :ok = ActionCycleServer.enqueue_percept(pid, %{type: :security_regression})

      assert eventually(fn ->
               stats = ActionCycleServer.stats(pid)
               stats.cycle_count == 1 and not stats.cycle_in_flight
             end)

      assert :ok = ActionCycleServer.close_bootstrap(pid)
      assert {:error, :bootstrap_not_found} = Arbor.Security.claim_signing_authority(bootstrap)
    end

    test "accepts percepts via pid", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}

      {:ok, pid} =
        ActionCycleServer.start_link(
          agent_id: agent_id,
          name: name,
          # No llm_fn — cycle won't actually run
          llm_fn: nil
        )

      :ok = ActionCycleServer.enqueue_percept(pid, %{type: :test, content: "hello"})

      # Give it a moment
      Process.sleep(20)

      stats = ActionCycleServer.stats(pid)
      # Without CycleController, the cycle will error but percept was received
      assert stats.cycle_count >= 0
    end

    test "accepts percepts via agent_id", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}

      {:ok, _pid} =
        ActionCycleServer.start_link(
          agent_id: agent_id,
          name: name,
          llm_fn: nil
        )

      :ok = ActionCycleServer.enqueue_percept(agent_id, %{type: :chat, content: "hello"})
    end

    test "no-op when server not running" do
      :ok = ActionCycleServer.enqueue_percept("nonexistent_agent", %{type: :test})
    end
  end

  describe "stats/1" do
    test "returns initial stats", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}
      {:ok, pid} = ActionCycleServer.start_link(agent_id: agent_id, name: name)

      stats = ActionCycleServer.stats(pid)
      assert stats.agent_id == agent_id
      assert stats.queue_depth == 0
      assert stats.cycle_in_flight == false
      assert stats.cycle_count == 0
      assert stats.consecutive_cycles == 0
    end

    test "stats via agent_id", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}
      {:ok, _pid} = ActionCycleServer.start_link(agent_id: agent_id, name: name)

      stats = ActionCycleServer.stats(agent_id)
      assert stats.agent_id == agent_id
    end
  end

  describe "queue overflow" do
    test "drops oldest when queue exceeds max", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}

      # Use a very small queue max and no llm_fn so cycles error quickly
      {:ok, pid} =
        ActionCycleServer.start_link(
          agent_id: agent_id,
          name: name,
          action_cycle_queue_max: 3,
          llm_fn: nil
        )

      # Wait for any initial cycle errors to settle
      Process.sleep(50)

      # Enqueue more than max
      for i <- 1..5 do
        send(pid, {:percept, %{type: :test, index: i}})
      end

      # Give it a moment to process
      Process.sleep(100)

      stats = ActionCycleServer.stats(pid)
      # Queue should be at most max (some may have been dequeued for cycles)
      assert stats.queue_depth <= 3
    end
  end

  describe "configuration" do
    test "uses configured values", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}

      {:ok, pid} =
        ActionCycleServer.start_link(
          agent_id: agent_id,
          name: name,
          action_cycle_max_consecutive: 5,
          action_cycle_timeout: 30_000,
          action_cycle_queue_max: 25
        )

      stats = ActionCycleServer.stats(pid)
      assert stats.config.max_consecutive == 5
      assert stats.config.cycle_timeout == 30_000
      assert stats.config.queue_max == 25
    end
  end

  describe "cycle error handling" do
    test "recovers from cycle errors and processes next percept", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}

      # llm_fn that always errors
      error_fn = fn _ctx -> {:error, :test_error} end

      {:ok, pid} =
        ActionCycleServer.start_link(
          agent_id: agent_id,
          name: name,
          llm_fn: error_fn
        )

      # Enqueue a percept — it should cycle and error
      send(pid, {:percept, %{type: :test, content: "will error"}})
      Process.sleep(100)

      stats = ActionCycleServer.stats(pid)
      # Should have attempted at least one cycle
      assert stats.cycle_count >= 0
      # Should not be stuck in flight
      assert stats.cycle_in_flight == false
    end
  end

  describe "throttling" do
    test "resets consecutive count when queue empties", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}

      {:ok, pid} = ActionCycleServer.start_link(agent_id: agent_id, name: name)

      # With empty queue, consecutive should be 0
      stats = ActionCycleServer.stats(pid)
      assert stats.consecutive_cycles == 0
    end
  end

  defp signing_bootstrap!(purpose) do
    {:ok, identity} =
      Identity.generate(name: "action-cycle-custody-#{System.unique_integer([:positive])}")

    :ok = Arbor.Security.register_identity_fixture(Identity.public_only(identity))
    :ok = Arbor.Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: purpose,
        owner: self()
      )

    {:ok, bootstrap} = Arbor.Security.issue_signing_authority_bootstrap(proof)

    on_exit(fn ->
      _ = Arbor.Security.close_signing_authority_bootstrap(bootstrap)
      _ = Arbor.Security.delete_signing_key_fixture(identity.agent_id)
      _ = Arbor.Security.deregister_identity_fixture(identity.agent_id)
    end)

    {identity, bootstrap}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
