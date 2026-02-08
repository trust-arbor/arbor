defmodule Arbor.Cartographer.ScoutTest do
  # No async since we're managing global processes
  use ExUnit.Case, async: false

  alias Arbor.Cartographer.{CapabilityRegistry, Scout}

  @moduletag :fast

  # We need to manage the lifecycle carefully since Scout depends on Registry
  setup do
    # Stop existing processes - must stop Scout first, then Registry
    safe_stop(Scout)
    safe_stop(CapabilityRegistry)
    # Also stop the supervisor if it's running
    safe_stop(Arbor.Cartographer.Supervisor)
    Process.sleep(100)

    # Start fresh registry first (Scout depends on it)
    case CapabilityRegistry.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Start Scout with fast intervals for testing
    {:ok, scout_pid} =
      case Scout.start_link(
             # Don't re-introspect during test
             introspection_interval: :timer.hours(1),
             # Don't update load during test
             load_update_interval: :timer.hours(1),
             custom_tags: [:test_env]
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

    # Wait for Scout to register with the registry
    wait_for_registration(20)

    on_exit(fn ->
      safe_stop(Scout)
      safe_stop(CapabilityRegistry)
      Process.sleep(50)
    end)

    {:ok, scout: scout_pid}
  end

  # Wait for Scout to register the node
  defp wait_for_registration(0), do: :ok

  defp wait_for_registration(attempts) do
    case CapabilityRegistry.get(Node.self()) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        Process.sleep(100)
        wait_for_registration(attempts - 1)
    end
  end

  describe "start_link/1" do
    test "starts the Scout process", %{scout: pid} do
      assert Process.alive?(pid)
      assert Process.whereis(Scout) == pid
    end
  end

  describe "hardware_info/0" do
    test "returns detected hardware" do
      {:ok, info} = Scout.hardware_info()

      assert Map.has_key?(info, :arch)
      assert Map.has_key?(info, :cpus)
      assert Map.has_key?(info, :memory_gb)
      assert Map.has_key?(info, :gpu)
      assert Map.has_key?(info, :accelerators)
    end
  end

  describe "capability_tags/0" do
    test "returns detected capability tags" do
      {:ok, tags} = Scout.capability_tags()

      assert is_list(tags)
      # Should have at least architecture tag
      assert Enum.any?(tags, fn t -> t in [:x86_64, :arm64, :arm32] end)
    end

    test "includes custom tags" do
      {:ok, tags} = Scout.capability_tags()

      assert :test_env in tags
    end
  end

  describe "add_custom_tags/1" do
    test "adds new custom tags" do
      :ok = Scout.add_custom_tags([:production, :gpu_optimized])

      {:ok, tags} = Scout.capability_tags()
      assert :production in tags
      assert :gpu_optimized in tags
    end

    test "tags persist and are unique" do
      :ok = Scout.add_custom_tags([:tag1])
      :ok = Scout.add_custom_tags([:tag1, :tag2])

      {:ok, tags} = Scout.capability_tags()
      assert :tag1 in tags
      assert :tag2 in tags
      # Should only have one :tag1
      assert Enum.count(tags, &(&1 == :tag1)) == 1
    end
  end

  describe "remove_custom_tags/1" do
    test "removes custom tags" do
      # We have :test_env from setup
      :ok = Scout.remove_custom_tags([:test_env])

      {:ok, tags} = Scout.capability_tags()
      refute :test_env in tags
    end

    test "does not remove hardware tags" do
      # Get current architecture tag
      {:ok, info} = Scout.hardware_info()
      arch_tag = info.arch

      # Try to remove it
      :ok = Scout.remove_custom_tags([arch_tag])

      # Should still have it (it's a hardware tag, not custom)
      {:ok, tags} = Scout.capability_tags()

      if arch_tag != :unknown do
        assert arch_tag in tags
      end
    end
  end

  describe "current_load/0" do
    test "returns a load score between 0 and 100" do
      load = Scout.current_load()

      assert is_float(load)
      assert load >= 0.0
      assert load <= 100.0
    end
  end

  describe "refresh/0" do
    test "triggers hardware re-detection" do
      # This should not crash
      :ok = Scout.refresh()

      # Give it a moment to process
      Process.sleep(50)

      # Should still have capabilities
      {:ok, tags} = Scout.capability_tags()
      assert is_list(tags)
    end
  end

  describe "registry integration" do
    test "registers node with registry on startup" do
      # Scout should have registered the current node
      {:ok, caps} = CapabilityRegistry.get(Node.self())

      assert caps.node == Node.self()
      assert is_list(caps.tags)
      assert is_float(caps.load)
      assert %DateTime{} = caps.registered_at
    end

    test "custom tags are reflected in registry" do
      :ok = Scout.add_custom_tags([:registry_test_tag])

      {:ok, caps} = CapabilityRegistry.get(Node.self())
      assert :registry_test_tag in caps.tags
    end
  end

  # Helper to stop a process safely
  defp safe_stop(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          Process.unlink(pid)
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
          _, _ -> :ok
        end
    end
  rescue
    _ -> :ok
  end
end
