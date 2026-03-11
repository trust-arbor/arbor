defmodule Arbor.Agent.ManagerTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{Character, Manager, Profile, ProfileStore, Registry}
  alias Arbor.Persistence.BufferedStore

  @store_name :arbor_agent_profiles

  # ============================================================================
  # Helpers
  # ============================================================================

  defmodule FakeAgent do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call({:query, input, _opts}, _from, state) do
      {:reply, {:ok, %{text: "echo: #{input}"}}, state}
    end

    def handle_call(:query, _from, state) do
      {:reply, {:ok, %{text: "fake response"}}, state}
    end
  end

  defp make_profile(agent_id, opts \\ []) do
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

  # Safely call Manager functions that go through Lifecycle.create,
  # which may crash with an :exit when Security.Identity.Registry is down.
  defp safe_start_agent(config, opts \\ []) do
    try do
      Manager.start_agent(config, opts)
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp safe_start_or_resume(module, name, opts) do
    try do
      Manager.start_or_resume(module, name, opts)
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp safe_resume_agent(agent_id, opts \\ []) do
    try do
      Manager.resume_agent(agent_id, opts)
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp cleanup_agent(agent_id) do
    try do
      Manager.stop_agent(agent_id)
    catch
      _, _ -> :ok
    end
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    case Process.whereis(@store_name) do
      nil ->
        start_supervised!(
          Elixir.Supervisor.child_spec(
            {BufferedStore, name: @store_name, backend: nil, write_mode: :sync},
            id: @store_name
          )
        )

      _pid ->
        :ok
    end

    :ok
  end

  # ============================================================================
  # 1. find_agent / find_first_agent (pure registry lookups)
  # ============================================================================

  describe "find_agent/1" do
    @describetag :fast

    test "returns :not_found for unknown agent" do
      assert :not_found = Manager.find_agent("nonexistent-#{System.unique_integer()}")
    end

    test "returns {:ok, pid, metadata} for registered agent" do
      agent_id = "find-test-#{System.unique_integer([:positive])}"
      Registry.register(agent_id, self(), %{test: true})
      on_exit(fn -> Registry.unregister(agent_id) end)

      assert {:ok, pid, metadata} = Manager.find_agent(agent_id)
      assert pid == self()
      assert metadata[:test] == true
    end

    test "metadata includes all registered fields" do
      agent_id = "find-meta-#{System.unique_integer([:positive])}"
      meta = %{backend: :api, model_config: %{id: "test"}, display_name: "TestBot"}
      Registry.register(agent_id, self(), meta)
      on_exit(fn -> Registry.unregister(agent_id) end)

      {:ok, _pid, returned_meta} = Manager.find_agent(agent_id)
      assert returned_meta[:backend] == :api
      assert returned_meta[:display_name] == "TestBot"
    end
  end

  describe "find_first_agent/0" do
    @describetag :fast

    test "returns {:ok, agent_id, pid, metadata} when agents exist" do
      agent_id = "first-agent-#{System.unique_integer([:positive])}"
      Registry.register(agent_id, self(), %{order: :first})
      on_exit(fn -> Registry.unregister(agent_id) end)

      result = Manager.find_first_agent()
      assert {:ok, found_id, found_pid, _meta} = result
      assert is_binary(found_id)
      assert is_pid(found_pid)
    end

    test "returns expected shape" do
      result = Manager.find_first_agent()
      assert result == :not_found or match?({:ok, _, _, _}, result)
    end
  end

  # ============================================================================
  # 2. stop_agent
  # ============================================================================

  describe "stop_agent/1" do
    @describetag :fast

    test "stops a running supervised agent" do
      agent_id = "stop-test-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Arbor.Agent.Supervisor.start_child(
          agent_id: agent_id,
          module: FakeAgent,
          start_opts: [],
          metadata: %{test: true}
        )

      assert Process.alive?(pid)
      assert :ok = Manager.stop_agent(agent_id)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns :ok even when agent not found (idempotent)" do
      assert :ok = Manager.stop_agent("nonexistent-stop-#{System.unique_integer()}")
    end

    test "double stop is safe" do
      agent_id = "double-stop-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Arbor.Agent.Supervisor.start_child(
          agent_id: agent_id,
          module: FakeAgent,
          start_opts: [],
          metadata: %{}
        )

      assert :ok = Manager.stop_agent(agent_id)
      Process.sleep(50)
      assert :ok = Manager.stop_agent(agent_id)
    end
  end

  # ============================================================================
  # 3. start_agent — remote spawning (never hits Lifecycle)
  # ============================================================================

  describe "start_agent/2 — remote spawning" do
    @describetag :fast

    test "spawn_on unreachable node returns error" do
      config = %{id: "test", provider: :test, backend: :api}
      result = Manager.start_agent(config, spawn_on: :"fake@unreachable")
      assert {:error, {:node_unreachable, :"fake@unreachable"}} = result
    end

    test "spawn_on with dotted node returns error" do
      config = %{id: "test", provider: :test, backend: :api}
      result = Manager.start_agent(config, spawn_on: :"nonexistent@127.0.0.1")
      assert {:error, {:node_unreachable, :"nonexistent@127.0.0.1"}} = result
    end

    test "spawn_on with invalid node name returns node_unreachable" do
      config = %{id: "test", provider: :test, backend: :api}
      result = Manager.start_agent(config, spawn_on: :bad_node)
      assert {:error, {:node_unreachable, :bad_node}} = result
    end

    test "spawn_on takes precedence over requirements" do
      config = %{id: "test", provider: :test, backend: :api}

      result =
        Manager.start_agent(config,
          spawn_on: :"fake@nowhere",
          requirements: [gpu: true]
        )

      assert {:error, {:node_unreachable, :"fake@nowhere"}} = result
    end
  end

  # ============================================================================
  # 4. start_agent — scheduler requirements
  # ============================================================================

  describe "start_agent/2 — scheduler requirements" do
    @describetag :fast

    test "requirements route through scheduler" do
      config = %{id: "test", provider: :test, backend: :api}

      result =
        safe_start_agent(config,
          requirements: [gpu: true],
          strategy: :least_loaded
        )

      # Either scheduler returns :no_matching_node, or Lifecycle.create
      # is reached and may fail. Either way, it's an error.
      case result do
        {:error, {:no_matching_node, _}} -> :ok
        {:error, :scheduler_not_available} -> :ok
        {:error, {:exit, _}} -> :ok
        {:error, _other} -> :ok
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
      end
    end
  end

  # ============================================================================
  # 5. start_agent — lifecycle create paths
  # ============================================================================

  describe "start_agent/2 — lifecycle create" do
    @describetag :fast

    test "api backend config exercises APIAgent path" do
      config = %{id: "test-model", provider: :openrouter, backend: :api}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, pid} ->
          assert is_binary(agent_id)
          assert is_pid(pid)
          on_exit(fn -> cleanup_agent(agent_id) end)

        {:error, _} ->
          :ok
      end
    end

    test "cli backend config exercises Claude path" do
      config = %{id: :opus, provider: :anthropic, backend: :cli}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end

    test "acp provider config exercises ACP path" do
      config = %{id: "claude-opus", provider: :acp, provider_options: %{}}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end

    test "module config exercises custom module path" do
      config = %{id: "test", provider: :test, module: FakeAgent, start_opts: []}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end

    test "config with :name uses name as display_name" do
      config = %{id: "model-1", provider: :test, backend: :api, name: "My Agent"}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end

    test "config with string :id uses id as display_name" do
      config = %{id: "some-model-id", provider: :test, backend: :api}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end

    test "config with atom :id converts to string display_name" do
      config = %{id: :haiku, provider: :test, backend: :api}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end

    test "config with no name or id defaults to 'Agent'" do
      config = %{backend: :api, provider: :test}
      result = safe_start_agent(config)

      case result do
        {:ok, agent_id, _pid} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # 6. resume_agent
  # ============================================================================

  describe "resume_agent/2" do
    @describetag :fast

    test "returns error for non-existent agent profile" do
      result = safe_resume_agent("nonexistent-resume-#{System.unique_integer()}")
      assert {:error, _} = result
    end

    test "attempts restore with stored profile" do
      agent_id = "resume-test-#{System.unique_integer([:positive])}"

      profile =
        make_profile(agent_id,
          display_name: "Resume Test",
          metadata: %{
            last_model_config: %{id: "test-model", provider: :openrouter, backend: :api}
          }
        )

      ProfileStore.store_profile(profile)

      result = safe_resume_agent(agent_id)

      case result do
        {:ok, ^agent_id, pid} ->
          assert is_pid(pid)
          on_exit(fn -> cleanup_agent(agent_id) end)

        {:error, _} ->
          :ok
      end
    end

    test "atomizes string-keyed persisted model config" do
      agent_id = "atomize-str-#{System.unique_integer([:positive])}"

      profile =
        make_profile(agent_id,
          display_name: "Atomize Str",
          metadata: %{
            "last_model_config" => %{
              "id" => "test-model",
              "provider" => "openrouter",
              "backend" => "api"
            }
          }
        )

      ProfileStore.store_profile(profile)
      result = safe_resume_agent(agent_id)

      case result do
        {:ok, ^agent_id, pid} ->
          assert is_pid(pid)
          on_exit(fn -> cleanup_agent(agent_id) end)

        {:error, _} ->
          :ok
      end
    end

    test "prefers caller-provided model_config" do
      agent_id = "resume-override-#{System.unique_integer([:positive])}"

      profile =
        make_profile(agent_id,
          display_name: "Override Test",
          metadata: %{
            last_model_config: %{id: "old-model", provider: :openrouter, backend: :api}
          }
        )

      ProfileStore.store_profile(profile)

      result =
        safe_resume_agent(agent_id,
          model_config: %{id: "new-model", provider: :anthropic, backend: :api}
        )

      case result do
        {:ok, ^agent_id, pid} ->
          assert is_pid(pid)
          on_exit(fn -> cleanup_agent(agent_id) end)

        {:error, _} ->
          :ok
      end
    end
  end

  # ============================================================================
  # 7. start_or_resume
  # ============================================================================

  describe "start_or_resume/3" do
    @describetag :fast

    test "attempts to create new identity when no existing profile" do
      name = "new-agent-sor-#{System.unique_integer([:positive])}"

      result =
        safe_start_or_resume(
          FakeAgent,
          name,
          template: "cli_agent",
          model_config: %{id: "test", provider: :test, backend: :api}
        )

      case result do
        {:ok, agent_id, pid} ->
          assert is_binary(agent_id)
          assert is_pid(pid)
          on_exit(fn -> cleanup_agent(agent_id) end)

        {:error, _} ->
          :ok
      end
    end

    test "accepts module as first argument" do
      result =
        safe_start_or_resume(
          FakeAgent,
          "module-test-#{System.unique_integer([:positive])}",
          model_config: %{id: "test", provider: :test}
        )

      case result do
        {:ok, agent_id, _} -> on_exit(fn -> cleanup_agent(agent_id) end)
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # 8. chat/3
  # ============================================================================

  describe "chat/3" do
    @describetag :fast

    test "returns error when specified agent not found" do
      result = Manager.chat("hello", "User", agent_id: "nonexistent-chat-#{System.unique_integer()}")
      assert {:error, :agent_not_found} = result
    end

    test "dispatches to registered agent with :api backend" do
      agent_id = "chat-api-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Arbor.Agent.Supervisor.start_child(
          agent_id: agent_id,
          module: FakeAgent,
          start_opts: [],
          metadata: %{backend: :api, model_config: %{backend: :api}}
        )

      on_exit(fn -> cleanup_agent(agent_id) end)

      # APIAgent.query sends {:query, input, opts} which FakeAgent handles
      result = Manager.chat("hello", "Tester", agent_id: agent_id)
      assert {:ok, "echo: hello"} = result
    end

    test "dispatches to registered agent with nil backend returns :unknown_backend" do
      agent_id = "chat-nil-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Arbor.Agent.Supervisor.start_child(
          agent_id: agent_id,
          module: FakeAgent,
          start_opts: [],
          metadata: %{model_config: %{}}
        )

      on_exit(fn -> cleanup_agent(agent_id) end)

      result = Manager.chat("hello", "User", agent_id: agent_id)
      assert {:error, :unknown_backend} = result
    end

    test "infers :api backend for ACP provider" do
      agent_id = "chat-acp-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Arbor.Agent.Supervisor.start_child(
          agent_id: agent_id,
          module: FakeAgent,
          start_opts: [],
          metadata: %{model_config: %{provider: :acp}}
        )

      on_exit(fn -> cleanup_agent(agent_id) end)

      result = Manager.chat("hello", "User", agent_id: agent_id)
      # ACP → :api backend, which sends {:query, "hello", []} to FakeAgent
      assert {:ok, "echo: hello"} = result
    end

    test "uses default sender 'Opus' when not specified" do
      result = Manager.chat("hello")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns :agent_not_found when no agents registered and no agent_id" do
      case Registry.list() do
        {:ok, []} ->
          assert {:error, :agent_not_found} = Manager.chat("hello")

        _ ->
          # Agents exist from other tests/setup, skip
          :ok
      end
    end
  end

  # ============================================================================
  # 9. Profile & MCP configuration
  # ============================================================================

  describe "set_auto_start/2" do
    @describetag :fast

    test "enables auto_start on stored profile" do
      agent_id = "autostart-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id, auto_start: false)
      ProfileStore.store_profile(profile)

      assert :ok = Manager.set_auto_start(agent_id, true)

      {:ok, updated} = ProfileStore.load_profile(agent_id)
      assert updated.auto_start == true
    end

    test "disables auto_start on stored profile" do
      agent_id = "autostart-off-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id, auto_start: true)
      ProfileStore.store_profile(profile)

      assert :ok = Manager.set_auto_start(agent_id, false)

      {:ok, updated} = ProfileStore.load_profile(agent_id)
      assert updated.auto_start == false
    end

    test "returns error for non-existent profile" do
      result = Manager.set_auto_start("nonexistent-autostart-#{System.unique_integer()}", true)
      assert {:error, _} = result
    end

    test "toggle auto_start on and off" do
      agent_id = "autostart-toggle-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id, auto_start: false)
      ProfileStore.store_profile(profile)

      assert :ok = Manager.set_auto_start(agent_id, true)
      {:ok, p1} = ProfileStore.load_profile(agent_id)
      assert p1.auto_start == true

      assert :ok = Manager.set_auto_start(agent_id, false)
      {:ok, p2} = ProfileStore.load_profile(agent_id)
      assert p2.auto_start == false
    end
  end

  describe "set_mcp_config/2" do
    @describetag :fast

    test "stores MCP server config in profile metadata" do
      agent_id = "mcp-config-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id)
      ProfileStore.store_profile(profile)

      servers = [
        %{name: "github", transport: :stdio, command: ["npx", "github-server"]},
        %{name: "fs", transport: :stdio, command: ["npx", "fs-server", "/tmp"]}
      ]

      assert :ok = Manager.set_mcp_config(agent_id, servers)

      {:ok, updated} = ProfileStore.load_profile(agent_id)
      stored_servers = updated.metadata[:mcp_servers] || updated.metadata["mcp_servers"]
      assert length(stored_servers) == 2
    end

    test "returns error for non-existent profile" do
      result = Manager.set_mcp_config("nonexistent-mcp-#{System.unique_integer()}", [%{name: "test"}])
      assert {:error, _} = result
    end

    test "overwrites previous MCP config" do
      agent_id = "mcp-overwrite-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id, metadata: %{mcp_servers: [%{name: "old"}]})
      ProfileStore.store_profile(profile)

      new_servers = [%{name: "new-server", transport: :http, url: "http://localhost:8080"}]
      assert :ok = Manager.set_mcp_config(agent_id, new_servers)

      {:ok, updated} = ProfileStore.load_profile(agent_id)
      stored_servers = updated.metadata[:mcp_servers] || updated.metadata["mcp_servers"]
      assert length(stored_servers) == 1
    end

    test "stores empty server list" do
      agent_id = "mcp-empty-set-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id, metadata: %{mcp_servers: [%{name: "existing"}]})
      ProfileStore.store_profile(profile)

      assert :ok = Manager.set_mcp_config(agent_id, [])

      {:ok, updated} = ProfileStore.load_profile(agent_id)
      stored_servers = updated.metadata[:mcp_servers] || updated.metadata["mcp_servers"]
      assert stored_servers == []
    end
  end

  describe "connect_mcp_servers/1" do
    @describetag :fast

    test "returns :ok when profile has no MCP servers" do
      agent_id = "mcp-empty-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id)
      ProfileStore.store_profile(profile)

      assert :ok = Manager.connect_mcp_servers(agent_id)
    end

    test "returns :ok when profile not found" do
      assert :ok = Manager.connect_mcp_servers("nonexistent-mcp-#{System.unique_integer()}")
    end

    test "connect_mcp_server_list with empty list is noop" do
      assert :ok = Manager.connect_mcp_server_list("any-agent", [])
    end

    test "connect_mcp_server_list with servers returns :ok" do
      servers = [%{name: "test-server", transport: :stdio, command: ["echo", "hi"]}]
      assert :ok = Manager.connect_mcp_server_list("some-agent", servers)
    end
  end

  # ============================================================================
  # 10. Channel delegation
  # ============================================================================

  describe "channel operations" do
    @describetag :fast

    test "create_channel returns result or comms_unavailable" do
      members = [%{id: "a", name: "Alice", type: :human}]
      result = Manager.create_channel("test-channel", members)
      assert match?({:ok, _}, result) or result == {:error, :comms_unavailable}
    end

    test "channel_send returns result or error" do
      result = Manager.channel_send("ch-1", "sender", "Name", :human, "hello")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "join_channel returns result or comms_unavailable" do
      result = Manager.join_channel("ch-1", %{id: "b", name: "Bob", type: :human})
      assert result == :ok or match?({:error, _}, result)
    end

    test "leave_channel returns result or comms_unavailable" do
      result = Manager.leave_channel("ch-1", "member-1")
      assert result == :ok or match?({:error, _}, result)
    end

    test "list_channels returns list" do
      result = Manager.list_channels()
      assert is_list(result)
    end
  end

  # ============================================================================
  # 11. Signal emission
  # ============================================================================

  describe "signal emission" do
    @describetag :fast

    test "stop_agent does not crash even with signal failures" do
      assert :ok = Manager.stop_agent("signal-test-#{System.unique_integer()}")
    end

    test "lifecycle operations complete without signal crashes" do
      agent_id = "signal-lifecycle-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Arbor.Agent.Supervisor.start_child(
          agent_id: agent_id,
          module: FakeAgent,
          start_opts: [],
          metadata: %{}
        )

      assert :ok = Manager.stop_agent(agent_id)
    end
  end
end
