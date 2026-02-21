defmodule Arbor.Agent.MaintenanceServerTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.MaintenanceServer

  @moduletag :fast

  setup_all do
    ensure_registry(Arbor.Agent.MaintenanceRegistry)
    ensure_registry(Arbor.Agent.ActionCycleRegistry)
    :ok
  end

  setup do
    agent_id = "maint_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        case Registry.lookup(Arbor.Agent.MaintenanceRegistry, agent_id) do
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
    test "starts with required agent_id", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}

      {:ok, pid} = MaintenanceServer.start_link(agent_id: agent_id, name: name)
      assert Process.alive?(pid)
    end

    test "uses configured interval", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}

      {:ok, pid} =
        MaintenanceServer.start_link(
          agent_id: agent_id,
          name: name,
          maintenance_interval: 5_000
        )

      stats = MaintenanceServer.stats(pid)
      assert stats.interval == 5_000
    end
  end

  describe "stats/1" do
    test "returns initial stats", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}
      {:ok, pid} = MaintenanceServer.start_link(agent_id: agent_id, name: name)

      stats = MaintenanceServer.stats(pid)
      assert stats.agent_id == agent_id
      assert stats.tick_count == 0
      assert stats.last_run_at == nil
      assert is_map(stats.config)
    end
  end

  describe "run_now/1" do
    test "forces immediate maintenance execution", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}

      {:ok, pid} =
        MaintenanceServer.start_link(
          agent_id: agent_id,
          name: name,
          maintenance_interval: 300_000
        )

      # Run immediately
      MaintenanceServer.run_now(pid)

      # Give it a moment to process
      Process.sleep(50)

      stats = MaintenanceServer.stats(pid)
      assert stats.tick_count >= 1
      assert stats.last_run_at != nil
      assert is_integer(stats.last_duration_ms)
    end
  end

  describe "update_config/2" do
    test "updates configuration at runtime", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}

      {:ok, pid} =
        MaintenanceServer.start_link(
          agent_id: agent_id,
          name: name,
          maintenance_interval: 300_000
        )

      :ok = MaintenanceServer.update_config(pid, %{thought_ttl: 100})

      stats = MaintenanceServer.stats(pid)
      assert stats.config.thought_ttl == 100
    end
  end

  describe "timer behavior" do
    test "timer fires at configured interval", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}

      {:ok, pid} =
        MaintenanceServer.start_link(
          agent_id: agent_id,
          name: name,
          maintenance_interval: 100
        )

      # Wait for at least 2 ticks
      Process.sleep(350)

      stats = MaintenanceServer.stats(pid)
      assert stats.tick_count >= 2
    end
  end

  describe "configuration" do
    test "reads from Application env with fallback defaults", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}
      {:ok, pid} = MaintenanceServer.start_link(agent_id: agent_id, name: name)

      stats = MaintenanceServer.stats(pid)
      config = stats.config

      assert config.thought_ttl == 50
      assert config.dedup_threshold == 0.9
      assert config.max_wm_entries == 100
    end

    test "opts override Application env", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}

      {:ok, pid} =
        MaintenanceServer.start_link(
          agent_id: agent_id,
          name: name,
          maintenance_thought_ttl: 25,
          maintenance_max_wm_entries: 50
        )

      stats = MaintenanceServer.stats(pid)
      assert stats.config.thought_ttl == 25
      assert stats.config.max_wm_entries == 50
    end
  end

  describe "maintenance results" do
    test "results are tracked in stats", %{agent_id: agent_id} do
      name = {:via, Registry, {Arbor.Agent.MaintenanceRegistry, agent_id}}

      {:ok, pid} =
        MaintenanceServer.start_link(
          agent_id: agent_id,
          name: name,
          maintenance_interval: 300_000
        )

      MaintenanceServer.run_now(pid)
      Process.sleep(50)

      stats = MaintenanceServer.stats(pid)
      assert is_map(stats.last_results)
      assert Map.has_key?(stats.last_results, :pruned_thoughts)
      assert Map.has_key?(stats.last_results, :trimmed_wm)
      assert Map.has_key?(stats.last_results, :deduped_sk)
      assert Map.has_key?(stats.last_results, :consolidation)
    end
  end
end
