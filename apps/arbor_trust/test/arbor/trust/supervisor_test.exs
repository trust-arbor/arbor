defmodule Arbor.Trust.SupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust.Supervisor, as: TrustSupervisor

  @moduletag :fast

  # Start the supervisor for tests that need a running instance
  setup do
    case TrustSupervisor.start_link([]) do
      {:ok, pid} ->
        on_exit(fn ->
          try do
            if Process.alive?(pid), do: Supervisor.stop(pid, :normal)
          catch
            :exit, _ -> :ok
          end
        end)

        {:ok, pid: pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid: pid}
    end
  end

  describe "running?/0" do
    test "returns true when supervisor is started" do
      assert TrustSupervisor.running?() == true
    end
  end

  describe "status/0" do
    test "returns status map for all components" do
      status = TrustSupervisor.status()
      assert is_map(status)
      assert Map.has_key?(status, :supervisor)
      assert Map.has_key?(status, :store)
      assert Map.has_key?(status, :manager)
      assert Map.has_key?(status, :event_store)
      assert Map.has_key?(status, :event_handler)
      assert Map.has_key?(status, :circuit_breaker)
      assert Map.has_key?(status, :decay)
      assert Map.has_key?(status, :capability_sync)
    end

    test "supervisor reports as running" do
      status = TrustSupervisor.status()
      assert match?({:running, _pid}, status.supervisor)
    end

    test "core components report as running" do
      status = TrustSupervisor.status()
      assert match?({:running, _pid}, status.store)
      assert match?({:running, _pid}, status.manager)
    end
  end

  describe "init/1" do
    test "disabled supervisor starts no children" do
      # Start a separate supervisor with enabled: false
      # We can't use the real supervisor name, so we test init directly
      assert {:ok, {%{strategy: :one_for_one}, []}} = TrustSupervisor.init(enabled: false)
    end

    test "enabled supervisor builds children list" do
      {:ok, {%{strategy: :one_for_one}, children}} = TrustSupervisor.init([])
      # Should have at least Store, EventStore, Manager
      assert length(children) >= 3
    end

    test "optional components can be disabled" do
      {:ok, {_, children_all}} = TrustSupervisor.init([])
      {:ok, {_, children_some}} = TrustSupervisor.init(
        circuit_breaker_enabled: false,
        decay_enabled: false,
        event_handler_enabled: false,
        capability_sync_enabled: false
      )
      # Fewer children when optionals disabled
      assert length(children_some) < length(children_all)
    end
  end
end
