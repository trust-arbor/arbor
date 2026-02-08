defmodule Arbor.CartographerTest do
  # No async since we're managing global processes
  use ExUnit.Case, async: false

  alias Arbor.Cartographer
  alias Arbor.Cartographer.{CapabilityRegistry, Scout}

  @moduletag :fast

  # Start fresh for each test
  setup do
    # Stop existing processes gracefully
    safe_stop(Arbor.Cartographer.Supervisor)
    safe_stop(Scout)
    safe_stop(CapabilityRegistry)

    # Longer delay to ensure processes are fully stopped
    Process.sleep(100)

    # Start the supervisor which starts Registry and Scout
    {:ok, sup} =
      Cartographer.start_link(
        introspection_interval: :timer.hours(1),
        load_update_interval: :timer.hours(1),
        custom_tags: [:test_mode]
      )

    # Verify the system is ready
    assert Process.whereis(CapabilityRegistry) != nil, "CapabilityRegistry not started"
    assert Process.whereis(Scout) != nil, "Scout not started"

    # Wait for Scout to complete registration (poll for up to 2 seconds)
    wait_for_registration(20)

    on_exit(fn ->
      safe_stop(Arbor.Cartographer.Supervisor)
      Process.sleep(50)
    end)

    {:ok, supervisor: sup}
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

  describe "lifecycle" do
    test "healthy? returns true when all components running" do
      assert Cartographer.healthy?()
    end

    test "get_scout returns Scout pid" do
      {:ok, pid} = Cartographer.get_scout()
      assert Process.alive?(pid)
    end
  end

  describe "detect_hardware/0" do
    test "returns hardware info" do
      {:ok, hw} = Cartographer.detect_hardware()

      assert hw.arch in [:x86_64, :arm64, :arm32, :unknown]
      assert is_integer(hw.cpus) and hw.cpus > 0
      assert is_float(hw.memory_gb) and hw.memory_gb > 0
    end
  end

  describe "detect_models/0" do
    test "returns list of models" do
      {:ok, models} = Cartographer.detect_models()
      assert is_list(models)
    end

    test "detects API keys from environment" do
      # Save current state
      original = System.get_env("ANTHROPIC_API_KEY")

      try do
        System.put_env("ANTHROPIC_API_KEY", "test_key")
        {:ok, models} = Cartographer.detect_models()
        assert {:api, :claude} in models
      after
        # Restore
        if original,
          do: System.put_env("ANTHROPIC_API_KEY", original),
          else: System.delete_env("ANTHROPIC_API_KEY")
      end
    end
  end

  describe "my_capabilities/0" do
    test "returns capability tags" do
      {:ok, tags} = Cartographer.my_capabilities()

      assert is_list(tags)
      # Should have at least architecture tag
      assert Enum.any?(tags, fn t -> t in [:x86_64, :arm64, :arm32] end)
    end

    test "includes custom tags" do
      {:ok, tags} = Cartographer.my_capabilities()
      assert :test_mode in tags
    end
  end

  describe "register_capabilities/1" do
    test "adds custom capabilities" do
      :ok = Cartographer.register_capabilities([:production, :gpu_cluster])

      {:ok, tags} = Cartographer.my_capabilities()
      assert :production in tags
      assert :gpu_cluster in tags
    end
  end

  describe "unregister_capabilities/1" do
    test "removes custom capabilities" do
      :ok = Cartographer.register_capabilities([:temp_tag])
      :ok = Cartographer.unregister_capabilities([:temp_tag])

      {:ok, tags} = Cartographer.my_capabilities()
      refute :temp_tag in tags
    end
  end

  describe "find_capable_nodes/2" do
    test "finds nodes with required capabilities" do
      # Current node should be registered
      {:ok, tags} = Cartographer.my_capabilities()
      # Use actual tags from current node
      if length(tags) > 0 do
        [first_tag | _] = tags
        {:ok, nodes} = Cartographer.find_capable_nodes([first_tag])
        assert Node.self() in nodes
      end
    end

    test "returns empty list for capabilities no node has" do
      {:ok, nodes} = Cartographer.find_capable_nodes([:nonexistent_capability_xyz])
      assert nodes == []
    end
  end

  describe "get_node_capabilities/1" do
    test "returns capabilities for current node" do
      {:ok, caps} = Cartographer.get_node_capabilities(Node.self())

      assert caps.node == Node.self()
      assert is_list(caps.tags)
      assert is_map(caps.hardware)
      assert is_float(caps.load)
    end

    test "returns error for unknown node" do
      assert {:error, :not_found} = Cartographer.get_node_capabilities(:nonexistent_node@host)
    end
  end

  describe "list_all_capabilities/0" do
    test "returns list including current node" do
      {:ok, all} = Cartographer.list_all_capabilities()

      assert is_list(all)
      assert length(all) >= 1

      nodes = Enum.map(all, & &1.node)
      assert Node.self() in nodes
    end
  end

  describe "nodes_with_tag/1" do
    test "finds nodes with tag" do
      {:ok, nodes} = Cartographer.nodes_with_tag(:test_mode)
      assert Node.self() in nodes
    end

    test "returns empty for unknown tag" do
      {:ok, nodes} = Cartographer.nodes_with_tag(:completely_unknown_tag)
      assert nodes == []
    end
  end

  describe "node_has_capabilities?/2" do
    test "returns true for matching capabilities" do
      {:ok, tags} = Cartographer.my_capabilities()

      if length(tags) > 0 do
        [tag | _] = tags
        assert Cartographer.node_has_capabilities?(Node.self(), [tag])
      end
    end

    test "returns false for missing capabilities" do
      refute Cartographer.node_has_capabilities?(Node.self(), [:impossible_cap])
    end
  end

  describe "load monitoring" do
    test "get_node_load returns load for registered node" do
      {:ok, load} = Cartographer.get_node_load(Node.self())
      assert is_float(load)
      assert load >= 0.0
      assert load <= 100.0
    end

    test "get_all_loads returns map with current node" do
      {:ok, loads} = Cartographer.get_all_loads()
      assert is_map(loads)
      assert Map.has_key?(loads, Node.self())
    end

    test "update_load does not crash" do
      assert :ok = Cartographer.update_load()
    end
  end

  describe "deploy/2" do
    defmodule TestAgent do
      use GenServer

      def start_link(args), do: GenServer.start_link(__MODULE__, args)

      def init(args), do: {:ok, args}
    end

    test "deploys agent when local node has required capabilities" do
      # Use capabilities that we know the local node has
      {:ok, tags} = Cartographer.my_capabilities()

      if length(tags) > 0 do
        [tag | _] = tags
        {:ok, pid} = Cartographer.deploy(TestAgent, needs: [tag], args: [name: "test"])
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end
    end

    test "deploys agent with no requirements" do
      {:ok, pid} = Cartographer.deploy(TestAgent, args: [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "returns error when required capabilities not available" do
      {:error, :no_capable_nodes} =
        Cartographer.deploy(TestAgent, needs: [:impossible_capability])
    end
  end

  describe "deploy_to_node/3" do
    defmodule TestAgent2 do
      use GenServer
      def start_link(args), do: GenServer.start_link(__MODULE__, args)
      def init(args), do: {:ok, args}
    end

    test "deploys to local node" do
      {:ok, pid} = Cartographer.deploy_to_node(TestAgent2, Node.self(), args: [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "returns error for remote node" do
      {:error, :remote_deployment_not_implemented} =
        Cartographer.deploy_to_node(TestAgent2, :remote@node, args: [])
    end
  end

  describe "authorize_deployment/2" do
    test "returns authorized when capabilities exist" do
      {:ok, tags} = Cartographer.my_capabilities()

      if length(tags) > 0 do
        [tag | _] = tags
        {:ok, :authorized} = Cartographer.authorize_deployment("test_agent", [tag])
      end
    end

    test "returns error when no capable nodes" do
      {:error, :no_capable_nodes} =
        Cartographer.authorize_deployment("test_agent", [:impossible_cap])
    end
  end

  describe "affinity (placeholder)" do
    test "set_affinity returns ok" do
      assert :ok = Cartographer.set_affinity(self(), :test_group)
    end

    test "clear_affinity returns ok" do
      assert :ok = Cartographer.clear_affinity(self())
    end

    test "agents_with_affinity returns empty list" do
      assert {:ok, []} = Cartographer.agents_with_affinity(:test_group)
    end
  end

  # Helper to stop a supervisor safely
  defp safe_stop(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          # Unlink to avoid exit signals
          Process.unlink(pid)
          Supervisor.stop(pid, :normal, 5000)
        catch
          :exit, _ -> :ok
          _, _ -> :ok
        end
    end
  rescue
    _ -> :ok
  end
end
