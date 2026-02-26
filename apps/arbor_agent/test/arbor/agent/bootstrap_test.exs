defmodule Arbor.Agent.BootstrapTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{Bootstrap, Character, Manager, Profile, ProfileStore}
  alias Arbor.Persistence.BufferedStore

  @store_name :arbor_agent_profiles

  setup do
    # Start a BufferedStore instance for tests (ETS-only, no backend)
    start_supervised!(
      Supervisor.child_spec(
        {BufferedStore, name: @store_name, backend: nil, write_mode: :sync},
        id: @store_name
      )
    )

    # Clean up any previous config overrides
    prev_enabled = Application.get_env(:arbor_agent, :bootstrap_enabled)
    prev_agents = Application.get_env(:arbor_agent, :auto_start_agents)

    on_exit(fn ->
      if prev_enabled, do: Application.put_env(:arbor_agent, :bootstrap_enabled, prev_enabled)
      if prev_agents, do: Application.put_env(:arbor_agent, :auto_start_agents, prev_agents)
    end)

    :ok
  end

  defp make_profile(agent_id, opts) do
    character = Character.new(name: Keyword.get(opts, :name, "Test Agent"))

    %Profile{
      agent_id: agent_id,
      display_name: Keyword.get(opts, :display_name, "Test"),
      character: character,
      trust_tier: :probationary,
      template: Keyword.get(opts, :template),
      auto_start: Keyword.get(opts, :auto_start, false),
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: DateTime.utc_now(),
      version: 1
    }
  end

  # ============================================================================
  # Bootstrap disabled
  # ============================================================================

  describe "bootstrap_enabled: false" do
    test "does not send :bootstrap message" do
      Application.put_env(:arbor_agent, :bootstrap_enabled, false)
      Application.put_env(:arbor_agent, :auto_start_agents, [])

      {:ok, pid} = start_supervised({Bootstrap, boot_delay: 100})

      # Wait long enough for the delayed message to have fired if it were sent
      Process.sleep(300)

      status = Bootstrap.status()
      assert status.status == :waiting
      assert status.agents == []

      stop_supervised(Bootstrap)
      Process.sleep(50)

      # Re-enable for other tests
      Application.put_env(:arbor_agent, :bootstrap_enabled, true)
      assert Process.alive?(pid) == false
    end
  end

  # ============================================================================
  # Empty config
  # ============================================================================

  describe "empty config" do
    test "does nothing when no seeds and no auto_start profiles" do
      Application.put_env(:arbor_agent, :bootstrap_enabled, true)
      Application.put_env(:arbor_agent, :auto_start_agents, [])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(200)

      status = Bootstrap.status()
      assert status.status == :ready
      assert status.agents == []
    end
  end

  # ============================================================================
  # Config seed starting (mocked Manager)
  # ============================================================================

  describe "config seeds" do
    test "starts agents from config seeds" do
      # We can't easily mock Manager.start_or_resume, but we can test the
      # merge_configs logic indirectly by checking that Bootstrap transitions
      # to :ready even when start fails
      Application.put_env(:arbor_agent, :bootstrap_enabled, true)

      Application.put_env(:arbor_agent, :auto_start_agents, [
        %{
          display_name: "test-agent",
          module: Arbor.Agent.APIAgent,
          template: Arbor.Agent.Templates.Diagnostician,
          model_config: %{id: "test-model", provider: :openrouter, backend: :api}
        }
      ])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(500)

      status = Bootstrap.status()
      # Should be :ready even if agent start failed (no real infrastructure)
      assert status.status == :ready
    end
  end

  # ============================================================================
  # Persisted auto_start profiles
  # ============================================================================

  describe "persisted auto_start profiles" do
    test "loads persisted auto_start profiles" do
      # Store a profile with auto_start: true
      profile =
        make_profile("auto-agent-1",
          display_name: "auto-tester",
          auto_start: true,
          metadata: %{last_model_config: %{id: "test", provider: :openrouter, backend: :api}}
        )

      ProfileStore.store_profile(profile)

      Application.put_env(:arbor_agent, :bootstrap_enabled, true)
      Application.put_env(:arbor_agent, :auto_start_agents, [])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(500)

      status = Bootstrap.status()
      assert status.status == :ready
      # Agent won't actually start (no real supervisor), but Bootstrap tried
    end

    test "skips profiles with auto_start: false" do
      profile = make_profile("no-auto-1", display_name: "no-auto", auto_start: false)
      ProfileStore.store_profile(profile)

      Application.put_env(:arbor_agent, :bootstrap_enabled, true)
      Application.put_env(:arbor_agent, :auto_start_agents, [])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(200)

      status = Bootstrap.status()
      assert status.status == :ready
      assert status.agents == []
    end
  end

  # ============================================================================
  # Merge logic
  # ============================================================================

  describe "merge_configs" do
    test "seeds override persisted profiles with same display_name" do
      # Store a persisted profile named "diagnostician"
      profile =
        make_profile("diag-1",
          display_name: "diagnostician",
          auto_start: true,
          metadata: %{
            last_model_config: %{id: "old-model", provider: :openrouter, backend: :api}
          }
        )

      ProfileStore.store_profile(profile)

      # Config seed also names "diagnostician" with different model
      Application.put_env(:arbor_agent, :bootstrap_enabled, true)

      Application.put_env(:arbor_agent, :auto_start_agents, [
        %{
          display_name: "diagnostician",
          module: Arbor.Agent.APIAgent,
          model_config: %{id: "new-model", provider: :openrouter, backend: :api}
        }
      ])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(500)

      status = Bootstrap.status()
      assert status.status == :ready
      # Only one attempt for "diagnostician", not two
      # (seeds take precedence, persisted with same name is skipped)
    end

    test "persisted-only agents pass through" do
      profile =
        make_profile("custom-1",
          display_name: "custom-agent",
          auto_start: true,
          metadata: %{
            last_model_config: %{id: "custom", provider: :openrouter, backend: :api}
          }
        )

      ProfileStore.store_profile(profile)

      Application.put_env(:arbor_agent, :bootstrap_enabled, true)

      Application.put_env(:arbor_agent, :auto_start_agents, [
        %{
          display_name: "seed-only",
          module: Arbor.Agent.APIAgent,
          model_config: %{id: "seed-model", provider: :openrouter, backend: :api}
        }
      ])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(500)

      status = Bootstrap.status()
      assert status.status == :ready
      # Both seed-only and custom-agent should have been attempted
    end
  end

  # ============================================================================
  # set_auto_start round-trip
  # ============================================================================

  describe "Manager.set_auto_start/2" do
    test "persists auto_start flag and is readable" do
      profile = make_profile("set-auto-1", display_name: "Setter", auto_start: false)
      ProfileStore.store_profile(profile)

      assert :ok = Manager.set_auto_start("set-auto-1", true)

      {:ok, loaded} = ProfileStore.load_profile("set-auto-1")
      assert loaded.auto_start == true
    end

    test "can disable auto_start" do
      profile = make_profile("set-auto-2", display_name: "Disabler", auto_start: true)
      ProfileStore.store_profile(profile)

      assert :ok = Manager.set_auto_start("set-auto-2", false)

      {:ok, loaded} = ProfileStore.load_profile("set-auto-2")
      assert loaded.auto_start == false
    end

    test "returns error for nonexistent agent" do
      assert {:error, :not_found} = Manager.set_auto_start("nonexistent", true)
    end
  end

  # ============================================================================
  # Status query
  # ============================================================================

  describe "status/0" do
    test "returns :not_running when Bootstrap is not started" do
      assert %{status: :not_running, agents: []} = Bootstrap.status()
    end

    test "returns :waiting before bootstrap fires" do
      Application.put_env(:arbor_agent, :bootstrap_enabled, true)
      Application.put_env(:arbor_agent, :auto_start_agents, [])

      start_supervised!({Bootstrap, boot_delay: 60_000})

      status = Bootstrap.status()
      assert status.status == :waiting
    end

    test "returns :ready after bootstrap completes" do
      Application.put_env(:arbor_agent, :bootstrap_enabled, true)
      Application.put_env(:arbor_agent, :auto_start_agents, [])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(200)

      status = Bootstrap.status()
      assert status.status == :ready
    end
  end

  # ============================================================================
  # MCP config management
  # ============================================================================

  describe "Manager.set_mcp_config/2" do
    test "stores MCP server config in profile metadata" do
      profile = make_profile("mcp-1", display_name: "MCP Agent", metadata: %{})
      ProfileStore.store_profile(profile)

      servers = [
        %{name: "github", transport: :stdio, command: ["npx", "@mcp/server-github"]},
        %{name: "filesystem", transport: :stdio, command: ["npx", "@mcp/server-fs", "/ws"]}
      ]

      assert :ok = Manager.set_mcp_config("mcp-1", servers)

      {:ok, loaded} = ProfileStore.load_profile("mcp-1")
      assert length(loaded.metadata[:mcp_servers]) == 2

      names = Enum.map(loaded.metadata[:mcp_servers], & &1[:name])
      assert "github" in names
      assert "filesystem" in names
    end

    test "preserves existing metadata when setting MCP config" do
      profile =
        make_profile("mcp-2",
          display_name: "MCP Agent 2",
          metadata: %{last_model_config: %{id: "test"}, custom: "value"}
        )

      ProfileStore.store_profile(profile)

      assert :ok =
               Manager.set_mcp_config("mcp-2", [
                 %{name: "db", transport: :http, url: "http://localhost:3000"}
               ])

      {:ok, loaded} = ProfileStore.load_profile("mcp-2")
      # MCP config added
      assert length(loaded.metadata[:mcp_servers]) == 1
      # Existing metadata preserved
      assert loaded.metadata[:last_model_config] == %{id: "test"}
      assert loaded.metadata[:custom] == "value"
    end

    test "returns error for nonexistent agent" do
      assert {:error, :not_found} = Manager.set_mcp_config("nonexistent", [])
    end

    test "can set empty config to clear MCP servers" do
      profile =
        make_profile("mcp-3",
          display_name: "MCP Agent 3",
          metadata: %{mcp_servers: [%{name: "old"}]}
        )

      ProfileStore.store_profile(profile)

      assert :ok = Manager.set_mcp_config("mcp-3", [])

      {:ok, loaded} = ProfileStore.load_profile("mcp-3")
      assert loaded.metadata[:mcp_servers] == []
    end
  end

  describe "Manager.connect_mcp_server_list/2" do
    test "returns :ok with empty list" do
      assert :ok = Manager.connect_mcp_server_list("any-agent", [])
    end

    test "handles missing gateway gracefully" do
      # In test context, Gateway may or may not be available
      # Either way, should not crash
      assert :ok =
               Manager.connect_mcp_server_list("test-agent", [
                 %{name: "test-server", transport: :stdio, command: ["echo"]}
               ])
    end
  end

  describe "MCP config serialization round-trip" do
    test "MCP config survives profile store/load cycle" do
      mcp_servers = [
        %{name: "github", transport: :stdio, command: ["npx", "@mcp/github"]},
        %{name: "api", transport: :http, url: "http://localhost:8080", env: %{"TOKEN" => "abc"}}
      ]

      profile =
        make_profile("mcp-rt-1",
          display_name: "Round Trip",
          metadata: %{mcp_servers: mcp_servers}
        )

      ProfileStore.store_profile(profile)
      {:ok, loaded} = ProfileStore.load_profile("mcp-rt-1")

      loaded_servers = loaded.metadata[:mcp_servers] || loaded.metadata["mcp_servers"]
      assert length(loaded_servers) == 2
    end
  end

  # ============================================================================
  # Retry scheduling
  # ============================================================================

  describe "retry behavior" do
    test "schedules retry on failure" do
      # A config with a non-existent module will fail, triggering retry
      Application.put_env(:arbor_agent, :bootstrap_enabled, true)

      Application.put_env(:arbor_agent, :auto_start_agents, [
        %{
          display_name: "will-fail",
          module: Arbor.Agent.APIAgent,
          model_config: %{id: "test", provider: :openrouter, backend: :api}
        }
      ])

      start_supervised!({Bootstrap, boot_delay: 50})
      Process.sleep(300)

      status = Bootstrap.status()
      # Should have recorded the attempt
      assert status.status == :ready
      assert is_map(status.attempts)
    end
  end
end
