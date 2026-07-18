defmodule Arbor.AI.AcpPoolTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpPool

  @moduletag :fast

  # We test the pool using _skip_connect: true so no real agent processes spawn.
  # AcpSession.start_link with _skip_connect returns {:ok, pid} immediately.
  @test_client_opts [command: ["echo", "test"], _skip_connect: true]

  defmodule StartupClient do
    @moduledoc false

    def start_link(opts) do
      case opts[:start_mode] do
        :stall ->
          send(opts[:test_pid], {:pool_start_stalled, self()})
          Process.sleep(:infinity)

        _other ->
          Agent.start_link(fn -> opts end)
      end
    end

    def disconnect(client), do: Agent.stop(client, :normal)
  end

  setup do
    # Start the DynamicSupervisor and Pool for each test
    start_supervised!(Arbor.AI.AcpPool.Supervisor)

    pool =
      start_supervised!(
        {AcpPool,
         [
           default_max: 3,
           default_idle_timeout_ms: 500,
           cleanup_interval_ms: 100_000
         ]}
      )

    {:ok, pool: pool}
  end

  describe "checkout/2" do
    @tag timeout: 2_000
    test "security regression: stalled startup is killed without wedging pool or supervisor", %{
      pool: pool
    } do
      original = Application.get_env(:arbor_ai, :acp_client_module)
      Application.put_env(:arbor_ai, :acp_client_module, StartupClient)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_ai, :acp_client_module, original),
          else: Application.delete_env(:arbor_ai, :acp_client_module)
      end)

      assert {:error, _reason} =
               AcpPool.checkout(:test,
                 timeout: 40,
                 client_opts: [start_mode: :stall, test_pid: self()]
               )

      assert_receive {:pool_start_stalled, startup_worker}, 200
      Process.sleep(75)
      refute Process.alive?(startup_worker)

      assert {:ok, %{active: 0}} =
               Task.async(fn ->
                 DynamicSupervisor.count_children(Arbor.AI.AcpPool.Supervisor)
               end)
               |> Task.yield(200)

      assert {:ok, %{}} = Task.async(fn -> AcpPool.status() end) |> Task.yield(200)
      assert Process.alive?(pool)
      assert AcpPool.sessions() == []
    end

    test "security regression: an expired queued checkout never creates an orphan lease", %{
      pool: pool
    } do
      :ok = :sys.suspend(pool)
      on_exit(fn -> safely_resume(pool) end)

      result =
        try do
          AcpPool.checkout(:test, client_opts: @test_client_opts, timeout: 10)
        catch
          :exit, {:timeout, _call} -> {:error, :timeout}
        end

      assert {:error, :timeout} = result
      :ok = :sys.resume(pool)
      Process.sleep(30)
      assert AcpPool.sessions() == []
    end

    test "creates a new session when pool is empty" do
      assert {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert is_pid(session)
      assert Process.alive?(session)
    end

    test "returns different sessions for sequential checkouts" do
      assert {:ok, s1} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert {:ok, s2} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      refute s1 == s2
    end

    test "returns error when pool is exhausted" do
      # max is 3
      assert {:ok, _} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert {:ok, _} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert {:ok, _} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert {:error, :pool_exhausted} = AcpPool.checkout(:test, client_opts: @test_client_opts)
    end

    test "different providers have independent pools" do
      assert {:ok, _} = AcpPool.checkout(:test_a, client_opts: @test_client_opts)
      assert {:ok, _} = AcpPool.checkout(:test_a, client_opts: @test_client_opts)
      assert {:ok, _} = AcpPool.checkout(:test_a, client_opts: @test_client_opts)
      assert {:error, :pool_exhausted} = AcpPool.checkout(:test_a, client_opts: @test_client_opts)

      # test_b still has capacity
      assert {:ok, _} = AcpPool.checkout(:test_b, client_opts: @test_client_opts)
    end
  end

  defp safely_resume(pool) do
    if Process.alive?(pool), do: :sys.resume(pool)
  catch
    :exit, _reason -> :ok
  end

  describe "checkin/1" do
    test "makes session available for reuse" do
      assert {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert :ok = AcpPool.checkin(session)

      # Same session should be reused
      assert {:ok, reused} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert reused == session
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = AcpPool.checkin(self())
    end

    test "frees pool capacity after checkin" do
      # Fill pool
      sessions =
        for _ <- 1..3 do
          {:ok, s} = AcpPool.checkout(:test, client_opts: @test_client_opts)
          s
        end

      assert {:error, :pool_exhausted} = AcpPool.checkout(:test, client_opts: @test_client_opts)

      # Check in one
      :ok = AcpPool.checkin(hd(sessions))

      # Now we can checkout again
      assert {:ok, _} = AcpPool.checkout(:test, client_opts: @test_client_opts)
    end

    test "security regression: recovery sessions are removed instead of returned idle" do
      assert {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)

      :sys.replace_state(session, fn state -> %{state | status: :recovery_required} end)

      assert :ok = AcpPool.checkin(session)
      assert AcpPool.sessions() == []

      Process.sleep(50)
      refute Process.alive?(session)
    end
  end

  describe "close_session/1" do
    test "removes session from pool" do
      assert {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      assert :ok = AcpPool.close_session(session)

      # Session should no longer be alive (or stopping)
      Process.sleep(50)
      refute Process.alive?(session)
    end

    test "frees pool capacity" do
      sessions =
        for _ <- 1..3 do
          {:ok, s} = AcpPool.checkout(:test, client_opts: @test_client_opts)
          s
        end

      assert {:error, :pool_exhausted} = AcpPool.checkout(:test, client_opts: @test_client_opts)

      :ok = AcpPool.close_session(hd(sessions))

      assert {:ok, _} = AcpPool.checkout(:test, client_opts: @test_client_opts)
    end
  end

  describe "status/0" do
    test "returns empty status for no sessions" do
      assert %{} = AcpPool.status()
    end

    test "tracks idle and checked_out counts" do
      {:ok, s1} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      {:ok, _s2} = AcpPool.checkout(:test, client_opts: @test_client_opts)

      status = AcpPool.status()
      assert status[:test].checked_out == 2
      assert status[:test].idle == 0
      assert status[:test].total == 2
      assert status[:test].max == 3

      :ok = AcpPool.checkin(s1)

      status = AcpPool.status()
      assert status[:test].checked_out == 1
      assert status[:test].idle == 1
    end
  end

  describe "crash recovery" do
    test "session crash removes it from pool" do
      {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      :ok = AcpPool.checkin(session)

      # Kill the session
      Process.exit(session, :kill)
      Process.sleep(50)

      # Pool should have removed it
      status = AcpPool.status()
      assert status[:test].total == 0
    end

    test "caller crash auto-checkins the session" do
      # Spawn a caller that checks out a session then dies
      test_pid = self()

      caller =
        spawn(fn ->
          {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)
          send(test_pid, {:session, session})
          # Wait to be killed
          Process.sleep(:infinity)
        end)

      _session =
        receive do
          {:session, s} -> s
        end

      # Verify it's checked out
      status = AcpPool.status()
      assert status[:test].checked_out == 1

      # Kill the caller
      Process.exit(caller, :kill)
      Process.sleep(50)

      # Session should be auto-checked-in (idle)
      status = AcpPool.status()
      assert status[:test].idle == 1
      assert status[:test].checked_out == 0
    end
  end

  describe "profile-based matching" do
    test "sessions with same profile are reused" do
      # No tools: tool-enabled sessions are closed on checkin (not reused).
      opts = [client_opts: @test_client_opts, agent_id: "agent_1", task_id: "task_same"]
      {:ok, s1} = AcpPool.checkout(:test, opts)
      :ok = AcpPool.checkin(s1)

      # Same profile → reuse
      {:ok, s2} = AcpPool.checkout(:test, opts)
      assert s1 == s2
    end

    test "sessions with different agent_ids are not reused" do
      {:ok, s1} = AcpPool.checkout(:test, client_opts: @test_client_opts, agent_id: "agent_1")
      :ok = AcpPool.checkin(s1)

      # Different agent → mint fresh
      {:ok, s2} = AcpPool.checkout(:test, client_opts: @test_client_opts, agent_id: "agent_2")
      refute s1 == s2
    end

    test "sessions with different tool sets are not reused" do
      {:ok, s1} = AcpPool.checkout(:test, client_opts: @test_client_opts, tool_modules: [ModA])
      :ok = AcpPool.checkin(s1)

      {:ok, s2} = AcpPool.checkout(:test, client_opts: @test_client_opts, tool_modules: [ModB])
      refute s1 == s2
    end

    test "sessions with different trust domains are not reused" do
      {:ok, s1} = AcpPool.checkout(:test, client_opts: @test_client_opts, trust_domain: :internal)
      :ok = AcpPool.checkin(s1)

      {:ok, s2} = AcpPool.checkout(:test, client_opts: @test_client_opts, trust_domain: :external)
      refute s1 == s2
    end

    test "security regression: different task/cwd/model/immutable config cannot reuse" do
      base = [client_opts: @test_client_opts, agent_id: "agent_x"]

      {:ok, s1} =
        AcpPool.checkout(:test, base ++ [task_id: "task_a", cwd: "/tmp/wt_a", model: "m1"])

      :ok = AcpPool.checkin(s1)

      {:ok, s_task} =
        AcpPool.checkout(:test, base ++ [task_id: "task_b", cwd: "/tmp/wt_a", model: "m1"])

      refute s_task == s1
      :ok = AcpPool.close_session(s_task)

      {:ok, s_cwd} =
        AcpPool.checkout(:test, base ++ [task_id: "task_a", cwd: "/tmp/wt_b", model: "m1"])

      refute s_cwd == s1
      :ok = AcpPool.close_session(s_cwd)

      {:ok, s_model} =
        AcpPool.checkout(:test, base ++ [task_id: "task_a", cwd: "/tmp/wt_a", model: "m2"])

      refute s_model == s1
      :ok = AcpPool.close_session(s_model)

      {:ok, s_cfg} =
        AcpPool.checkout(:test,
          agent_id: "agent_x",
          task_id: "task_a",
          cwd: "/tmp/wt_a",
          model: "m1",
          client_opts: Keyword.put(@test_client_opts, :extra, :different)
        )

      refute s_cfg == s1
      :ok = AcpPool.close_session(s_cfg)

      # Same complete profile still reuses the original idle session
      {:ok, s_same} =
        AcpPool.checkout(:test, base ++ [task_id: "task_a", cwd: "/tmp/wt_a", model: "m1"])

      assert s_same == s1
    end

    test "security regression: nil agent_id is not a wildcard for non-nil identity" do
      {:ok, s_nil} = AcpPool.checkout(:test, client_opts: @test_client_opts, agent_id: nil)
      :ok = AcpPool.checkin(s_nil)

      {:ok, s_named} =
        AcpPool.checkout(:test, client_opts: @test_client_opts, agent_id: "agent_named")

      refute s_named == s_nil
    end

    test "security regression: malformed cwd/task/tools rejected before pool reuse" do
      assert {:error, {:invalid, :cwd, :blank}} =
               AcpPool.checkout(:test, client_opts: @test_client_opts, cwd: "  ")

      assert {:error, {:invalid, :cwd, :bad_type}} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 cwd: false,
                 workspace: "/tmp/valid"
               )

      assert {:error, {:invalid, :task_id, :blank}} =
               AcpPool.checkout(:test, client_opts: @test_client_opts, task_id: "")

      assert {:error, {:invalid, :task_id, :bad_type}} =
               AcpPool.checkout(:test, client_opts: @test_client_opts, task_id: %{id: 1})

      assert {:error, {:invalid, :tool_modules, :bad_entry}} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 tool_modules: [ModA, 42]
               )

      # Pool remains empty — no session minted for malformed scope
      assert AcpPool.sessions() == []
    end

    test "security regression: two tasks cannot inherit prior provider cwd/session process" do
      agent = "coding_agent_#{System.unique_integer([:positive])}"
      cwd_a = "/tmp/task_a_#{System.unique_integer([:positive])}"
      cwd_b = "/tmp/task_b_#{System.unique_integer([:positive])}"

      {:ok, task_a_session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          agent_id: agent,
          task_id: "task_a",
          cwd: cwd_a,
          model: "coder"
        )

      :ok = AcpPool.checkin(task_a_session)
      assert Process.alive?(task_a_session)

      {:ok, task_b_session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          agent_id: agent,
          task_id: "task_b",
          cwd: cwd_b,
          model: "coder"
        )

      # Different task must mint a fresh local process — never the prior task's idle session
      refute task_b_session == task_a_session
      assert Process.alive?(task_b_session)

      sessions = AcpPool.sessions()
      task_b_info = Enum.find(sessions, &(&1.pid == task_b_session))
      assert task_b_info.task_id == "task_b"
      assert task_b_info.cwd == Path.expand(cwd_b)

      # Prior task session remains idle under its own profile and is not adopted
      task_a_info = Enum.find(sessions, &(&1.pid == task_a_session))
      assert task_a_info.status == :idle
      assert task_a_info.task_id == "task_a"
      assert task_a_info.cwd == Path.expand(cwd_a)
    end
  end

  describe "affinity" do
    test "affinity_key returns the same session" do
      {:ok, s1} = AcpPool.checkout(:test, client_opts: @test_client_opts, affinity_key: "sticky")
      :ok = AcpPool.checkin(s1)

      {:ok, s2} = AcpPool.checkout(:test, client_opts: @test_client_opts, affinity_key: "sticky")
      assert s1 == s2
    end

    test "different affinity_keys get different sessions" do
      {:ok, s1} = AcpPool.checkout(:test, client_opts: @test_client_opts, affinity_key: "key_a")
      :ok = AcpPool.checkin(s1)

      {:ok, s2} = AcpPool.checkout(:test, client_opts: @test_client_opts, affinity_key: "key_b")
      refute s1 == s2
    end

    test "security regression: invalid affinity session state is propagated before fallback" do
      {:ok, session} =
        AcpPool.checkout(:test, client_opts: @test_client_opts, affinity_key: "broken")

      :ok = AcpPool.checkin(session)
      :sys.replace_state(session, fn state -> %{state | status: :recovery_required} end)

      assert {:ok, replacement} =
               AcpPool.checkout(:test, client_opts: @test_client_opts, affinity_key: "broken")

      refute replacement == session
      assert length(AcpPool.sessions()) == 1
    end

    test "security regression: affinity cannot cross agent/trust/cwd/task" do
      {:ok, s1} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          affinity_key: "shared",
          agent_id: "agent_a",
          trust_domain: :internal,
          task_id: "task_1",
          cwd: "/tmp/a"
        )

      :ok = AcpPool.checkin(s1)

      assert {:error, :affinity_conflict} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 affinity_key: "shared",
                 agent_id: "agent_b",
                 trust_domain: :internal,
                 task_id: "task_1",
                 cwd: "/tmp/a"
               )

      assert {:error, :affinity_conflict} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 affinity_key: "shared",
                 agent_id: "agent_a",
                 trust_domain: :external,
                 task_id: "task_1",
                 cwd: "/tmp/a"
               )

      assert {:error, :affinity_conflict} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 affinity_key: "shared",
                 agent_id: "agent_a",
                 trust_domain: :internal,
                 task_id: "task_2",
                 cwd: "/tmp/a"
               )

      assert {:error, :affinity_conflict} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 affinity_key: "shared",
                 agent_id: "agent_a",
                 trust_domain: :internal,
                 task_id: "task_1",
                 cwd: "/tmp/b"
               )

      # Original affinity session remains the sole entry
      sessions = AcpPool.sessions()
      assert length(sessions) == 1
      assert hd(sessions).pid == s1
      assert hd(sessions).status == :idle
    end

    test "security regression: busy affinity does not duplicate or overwrite" do
      opts = [
        client_opts: @test_client_opts,
        affinity_key: "busy_key",
        agent_id: "agent_busy",
        task_id: "task_busy"
      ]

      {:ok, s1} = AcpPool.checkout(:test, opts)

      assert {:error, :affinity_busy} = AcpPool.checkout(:test, opts)

      sessions = AcpPool.sessions()
      assert length(sessions) == 1
      assert hd(sessions).pid == s1
      assert hd(sessions).status == :checked_out
      assert hd(sessions).checkout_count == 1
    end
  end

  describe "sessions/0" do
    test "returns session details with profile info" do
      {:ok, _} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          agent_id: "test_agent",
          tool_modules: [ModA]
        )

      sessions = AcpPool.sessions()
      assert length(sessions) == 1

      [session] = sessions
      assert session.provider == :test
      assert session.agent_id == "test_agent"
      assert session.tool_count == 1
      assert is_binary(session.name)
      assert is_binary(session.urn)
      assert session.status == :checked_out
      assert session.checkout_count == 1
    end
  end

  describe "idle cleanup" do
    test "closes sessions idle longer than timeout" do
      {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      :ok = AcpPool.checkin(session)

      # Trigger cleanup by sending the message directly
      # (idle_timeout_ms is 500ms in our test config)
      Process.sleep(600)
      send(Process.whereis(AcpPool), :cleanup_idle)
      Process.sleep(50)

      status = AcpPool.status()
      assert status == %{} or status[:test] == nil or status[:test].total == 0
    end
  end

  describe "tool server lifecycle" do
    # Define a test action module inline
    defmodule TestToolAction do
      @moduledoc false
      def to_tool do
        %{
          name: "pool_test_tool",
          description: "Test tool for pool integration",
          parameters_schema: %{"type" => "object", "properties" => %{}}
        }
      end

      def run(_params, _context), do: {:ok, %{ok: true}}
    end

    test "checkout with tool_modules starts a ToolServer" do
      {:ok, session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction]
        )

      sessions = AcpPool.sessions()
      [info] = sessions
      assert info.tool_server_port != nil
      assert is_integer(info.tool_server_port)
      assert info.tool_count == 1

      # Clean up
      :ok = AcpPool.close_session(session)
    end

    test "checkout without tool_modules has no ToolServer" do
      {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)

      sessions = AcpPool.sessions()
      [info] = sessions
      assert info.tool_server_port == nil

      :ok = AcpPool.close_session(session)
    end

    test "closing session stops the ToolServer" do
      {:ok, session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction]
        )

      sessions = AcpPool.sessions()
      [info] = sessions
      port = info.tool_server_port
      assert port != nil

      # Verify the tool server is reachable
      assert {:ok, _} = tool_server_ping(port)

      # Close the session (should also stop tool server)
      :ok = AcpPool.close_session(session)
      Process.sleep(50)

      # Tool server should no longer be reachable
      assert {:error, _} = tool_server_ping(port)
    end
  end

  describe "session sanitization on checkin" do
    test "checkin marks session as tainted" do
      {:ok, session} = AcpPool.checkout(:test, client_opts: @test_client_opts)

      sessions = AcpPool.sessions()
      [info] = sessions
      assert info.taint == :clean

      :ok = AcpPool.checkin(session)

      sessions = AcpPool.sessions()
      [info] = sessions
      assert info.taint == :tainted
    end

    test "checkin tears down ToolServer and closes tool-enabled session" do
      {:ok, session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction]
        )

      sessions = AcpPool.sessions()
      [info] = sessions
      port = info.tool_server_port
      assert port != nil
      assert {:ok, _} = tool_server_ping(port)

      :ok = AcpPool.checkin(session)
      Process.sleep(50)

      # Tool-enabled sessions must not remain idle after ToolServer teardown
      assert AcpPool.sessions() == []
      assert {:error, _} = tool_server_ping(port)
      refute Process.alive?(session)
    end

    test "security regression: tool-enabled checkin closes session; later checkout is new pid/endpoint" do
      {:ok, session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction],
          agent_id: "tool_agent",
          task_id: "task_tools"
        )

      sessions = AcpPool.sessions()
      [info] = sessions
      port1 = info.tool_server_port
      assert port1 != nil

      :ok = AcpPool.checkin(session)
      Process.sleep(50)

      assert AcpPool.sessions() == []
      refute Process.alive?(session)
      assert {:error, _} = tool_server_ping(port1)

      # Next checkout must mint a fresh AcpSession + ToolServer endpoint
      {:ok, next} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction],
          agent_id: "tool_agent",
          task_id: "task_tools"
        )

      refute next == session
      assert Process.alive?(next)

      sessions = AcpPool.sessions()
      [info2] = sessions
      port2 = info2.tool_server_port
      assert port2 != nil
      assert {:ok, _} = tool_server_ping(port2)

      :ok = AcpPool.close_session(next)
    end

    test "security regression: tool-bound idle entry is closed not checked out" do
      # Simulate a stale pool entry that still has tool_modules on the profile
      # (should never remain idle after checkin, but defensive path must mint).
      {:ok, session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction],
          agent_id: "stale_tools",
          task_id: "task_stale"
        )

      # Force the entry idle without going through checkin close path by
      # replacing pool state — then a later compatible checkout must close it.
      pool = Process.whereis(AcpPool)

      :sys.replace_state(pool, fn state ->
        {ref, entry} =
          Enum.find_value(state.sessions, fn {r, e} ->
            if e.pid == session, do: {r, e}
          end)

        # Stop the live ToolServer so the entry looks like post-teardown stale
        if entry.tool_server, do: Arbor.AI.AcpPool.ToolServer.stop(entry.tool_server.ref)

        sessions =
          Map.put(state.sessions, ref, %{
            entry
            | status: :idle,
              checked_out_by: nil,
              tool_server: nil,
              taint: :tainted
          })

        %{state | sessions: sessions}
      end)

      Process.sleep(30)

      {:ok, next} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction],
          agent_id: "stale_tools",
          task_id: "task_stale"
        )

      # Must mint a new process — never hand out the stale tool-bound pid
      refute next == session
      refute Process.alive?(session)
      assert Process.alive?(next)

      :ok = AcpPool.close_session(next)
    end

    test "auto-checkin on caller crash closes tool-enabled session" do
      test_pid = self()

      caller =
        spawn(fn ->
          {:ok, session} =
            AcpPool.checkout(:test,
              client_opts: @test_client_opts,
              tool_modules: [TestToolAction]
            )

          send(test_pid, {:session, session})
          Process.sleep(:infinity)
        end)

      session =
        receive do
          {:session, s} -> s
        end

      sessions = AcpPool.sessions()
      [info] = sessions
      port = info.tool_server_port
      assert port != nil

      # Kill the caller
      Process.exit(caller, :kill)
      Process.sleep(100)

      # Tool-enabled auto-checkin must close/remove, not return idle
      assert AcpPool.sessions() == []
      assert {:error, _} = tool_server_ping(port)
      refute Process.alive?(session)
    end
  end

  describe "distributed discovery (single-node)" do
    test "cluster_status returns local status" do
      {:ok, _} = AcpPool.checkout(:test, client_opts: @test_client_opts)
      status = AcpPool.cluster_status()

      assert is_map(status)
      assert Map.has_key?(status, Node.self())
      assert status[Node.self()][:test].total == 1
    end

    test "cluster_sessions returns sessions with node info" do
      {:ok, _} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          agent_id: "cluster_test"
        )

      sessions = AcpPool.cluster_sessions()
      assert length(sessions) == 1
      [session] = sessions
      assert session.node == Node.self()
      assert session.agent_id == "cluster_test"
    end

    test "cluster_checkout with :local returns {ok, pid, node}" do
      assert {:ok, pid, node} =
               AcpPool.cluster_checkout(:test, client_opts: @test_client_opts, node: :local)

      assert is_pid(pid)
      assert node == Node.self()
    end

    test "cluster_checkout with :any falls back to local" do
      assert {:ok, pid, node} =
               AcpPool.cluster_checkout(:test, client_opts: @test_client_opts, node: :any)

      assert is_pid(pid)
      assert node == Node.self()
    end

    test "cluster_checkout with :any returns pool_exhausted when full" do
      for _ <- 1..3 do
        {:ok, _, _} = AcpPool.cluster_checkout(:test, client_opts: @test_client_opts, node: :any)
      end

      # No remote nodes, so :any can't find anything
      assert {:error, :pool_exhausted} =
               AcpPool.cluster_checkout(:test, client_opts: @test_client_opts, node: :any)
    end

    test "cluster_checkout defaults to :local" do
      assert {:ok, pid, node} =
               AcpPool.cluster_checkout(:test, client_opts: @test_client_opts)

      assert is_pid(pid)
      assert node == Node.self()
    end

    test "cluster_checkout with specific node targets local node" do
      assert {:ok, pid, node} =
               AcpPool.cluster_checkout(:test,
                 client_opts: @test_client_opts,
                 node: Node.self()
               )

      assert is_pid(pid)
      assert node == Node.self()
    end

    test "cluster_checkin works for local sessions" do
      {:ok, pid, _node} =
        AcpPool.cluster_checkout(:test, client_opts: @test_client_opts)

      assert :ok = AcpPool.cluster_checkin(pid)

      status = AcpPool.cluster_status()
      assert status[Node.self()][:test].idle == 1
    end
  end

  # Helper to ping a tool server
  defp tool_server_ping(port) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "ping",
        "params" => %{}
      })

    Req.post("http://127.0.0.1:#{port}",
      body: body,
      headers: [{"content-type", "application/json"}],
      receive_timeout: 2_000
    )
  rescue
    _ -> {:error, :unreachable}
  catch
    :exit, _ -> {:error, :unreachable}
  end
end
