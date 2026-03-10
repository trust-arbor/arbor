defmodule Arbor.Memory.AuthorizationTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :integration

  @agent_id "test_agent_auth"
  @caller_id "agent_caller"

  setup do
    # When Security is fully running (cross-app umbrella tests), we need
    # to grant capabilities. When it's not running, authorize/2 permits by default.
    grant_memory_capabilities(@caller_id)
    :ok
  end

  describe "authorize_init/3" do
    test "delegates to init_for_agent when security permits" do
      # Security is not loaded in memory test env — authorize/2 returns :ok
      assert {:ok, _pid} = Arbor.Memory.authorize_init(@caller_id, @agent_id)
    end

    test "accepts options" do
      assert {:ok, _pid} =
               Arbor.Memory.authorize_init(@caller_id, "#{@agent_id}_opts",
                 max_entries: 100,
                 index_enabled: true,
                 graph_enabled: false
               )
    end
  end

  describe "authorize_cleanup/2" do
    test "delegates to cleanup_for_agent when security permits" do
      {:ok, _} = Arbor.Memory.init_for_agent("#{@agent_id}_cleanup")
      assert :ok = Arbor.Memory.authorize_cleanup(@caller_id, "#{@agent_id}_cleanup")
    end
  end

  describe "authorize_index/5" do
    setup do
      agent_id = "#{@agent_id}_index"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to index when security permits", %{agent_id: agent_id} do
      assert {:ok, _entry_id} =
               Arbor.Memory.authorize_index(
                 @caller_id,
                 agent_id,
                 "test content",
                 %{type: :fact}
               )
    end
  end

  describe "authorize_recall/4" do
    setup do
      agent_id = "#{@agent_id}_recall"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      Arbor.Memory.index(agent_id, "important test fact", %{type: :fact})
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to recall when security permits", %{agent_id: agent_id} do
      assert {:ok, _results} =
               Arbor.Memory.authorize_recall(@caller_id, agent_id, "test fact")
    end
  end

  describe "authorize_search/4" do
    setup do
      agent_id = "#{@agent_id}_search"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: true)

      Arbor.Memory.add_knowledge(agent_id, %{
        type: :fact,
        content: "searchable knowledge"
      })

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to search_knowledge when security permits", %{agent_id: agent_id} do
      assert {:ok, _results} =
               Arbor.Memory.authorize_search(@caller_id, agent_id, "searchable")
    end
  end

  describe "authorize_read/3" do
    setup do
      agent_id = "#{@agent_id}_read"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to load_working_memory when security permits", %{agent_id: agent_id} do
      result = Arbor.Memory.authorize_read(@caller_id, agent_id)
      # Should not return unauthorized
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_write/3" do
    setup do
      agent_id = "#{@agent_id}_write"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to save_working_memory when security permits", %{agent_id: agent_id} do
      # Load working memory first to get a valid struct
      wm = Arbor.Memory.WorkingMemoryStore.load_working_memory(agent_id)
      result = Arbor.Memory.authorize_write(@caller_id, agent_id, wm)
      # Should not return unauthorized
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_add_knowledge/3" do
    setup do
      agent_id = "#{@agent_id}_knowledge"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id, graph_enabled: true)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
      %{agent_id: agent_id}
    end

    test "delegates to add_knowledge when security permits", %{agent_id: agent_id} do
      assert {:ok, _node_id} =
               Arbor.Memory.authorize_add_knowledge(@caller_id, agent_id, %{
                 type: :fact,
                 content: "authorized knowledge"
               })
    end
  end

  describe "function signatures" do
    test "all authorize_* functions are exported" do
      exports = Arbor.Memory.__info__(:functions)

      assert {:authorize_init, 2} in exports or {:authorize_init, 3} in exports
      assert {:authorize_cleanup, 2} in exports
      assert {:authorize_index, 3} in exports or {:authorize_index, 5} in exports
      assert {:authorize_recall, 3} in exports or {:authorize_recall, 4} in exports
      assert {:authorize_search, 3} in exports or {:authorize_search, 4} in exports
      assert {:authorize_read, 2} in exports or {:authorize_read, 3} in exports
      assert {:authorize_write, 3} in exports
      assert {:authorize_add_knowledge, 3} in exports
    end
  end

  # Grant wildcard memory capabilities when Security is running.
  # When Security is not loaded, authorize/2 permits by default.
  defp grant_memory_capabilities(caller_id) do
    if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
         Process.whereis(Arbor.Security.CapabilityStore) != nil do
      memory_uris = [
        "arbor://memory/init",
        "arbor://memory/cleanup",
        "arbor://memory/index",
        "arbor://memory/recall",
        "arbor://memory/search",
        "arbor://memory/read",
        "arbor://memory/write",
        "arbor://memory/add_knowledge"
      ]

      for uri <- memory_uris do
        {:ok, cap} =
          Arbor.Contracts.Security.Capability.new(
            resource_uri: uri,
            principal_id: caller_id,
            actions: [:all]
          )

        Arbor.Security.CapabilityStore.put(cap)
      end
    end
  end
end
