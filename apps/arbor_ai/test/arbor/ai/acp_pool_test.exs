defmodule Arbor.AI.AcpPoolTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpPool

  @moduletag :fast

  # We test the pool using _skip_connect: true so no real agent processes spawn.
  # AcpSession.start_link with _skip_connect returns {:ok, pid} immediately.
  @test_client_opts [command: ["echo", "test"], _skip_connect: true]

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
      opts = [client_opts: @test_client_opts, agent_id: "agent_1", tool_modules: [ModA]]
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

    test "checkin tears down ToolServer" do
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

      # ToolServer should be stopped
      sessions = AcpPool.sessions()
      [info] = sessions
      assert info.tool_server_port == nil
      assert {:error, _} = tool_server_ping(port)
    end

    test "reused session gets a fresh ToolServer on checkout" do
      {:ok, session} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction]
        )

      sessions = AcpPool.sessions()
      [info] = sessions
      port1 = info.tool_server_port
      assert port1 != nil

      :ok = AcpPool.checkin(session)

      # Checkout again with same profile (will reuse session)
      {:ok, reused} =
        AcpPool.checkout(:test,
          client_opts: @test_client_opts,
          tool_modules: [TestToolAction]
        )

      assert reused == session

      sessions = AcpPool.sessions()
      [info] = sessions
      port2 = info.tool_server_port
      # New ToolServer on a (likely) different port
      assert port2 != nil
      assert {:ok, _} = tool_server_ping(port2)

      :ok = AcpPool.close_session(session)
    end

    test "auto-checkin on caller crash also tears down ToolServer" do
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

      _session =
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

      # Session should be auto-checked-in with ToolServer stopped
      sessions = AcpPool.sessions()
      [info] = sessions
      assert info.status == :idle
      assert info.taint == :tainted
      assert info.tool_server_port == nil
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
