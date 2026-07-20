defmodule Arbor.AI.AcpPoolTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpPool
  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.Config
  alias Arbor.AI.AcpSession.GrokSandbox
  alias Arbor.Common.SafePath

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

  # Observes graceful AcpSession.close/terminate client teardown. Raw
  # Process.exit(:kill) skips terminate/2 and never invokes disconnect/1.
  defmodule DisconnectClient do
    @moduledoc false

    def start_link(opts) do
      Agent.start_link(fn -> opts end)
    end

    def disconnect(client) do
      opts = Agent.get(client, & &1)

      if is_pid(opts[:test_pid]) do
        send(opts[:test_pid], {:pool_client_disconnect, client})
      end

      Agent.stop(client, :normal)
    end
  end

  defmodule ScopeToolAction do
    @moduledoc false
    def to_tool do
      %{
        name: "scope_tool",
        description: "workspace scope probe",
        parameters_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    def run(_params, _context), do: {:ok, %{ok: true}}
  end

  defmodule GrokPoolProbeClient do
    @moduledoc false

    def start_link(opts), do: Agent.start_link(fn -> opts end)

    def new_session(_client, _cwd, _opts) do
      {:ok, %{"sessionId" => "grok-pool-session"}}
    end

    def load_session(_client, session_id, _cwd, _opts) do
      {:ok, %{"sessionId" => session_id}}
    end

    def set_config_option(_client, _session_id, _key, _value), do: :ok
    def cancel(_client, _session_id), do: :ok
    def prompt(_client, _session_id, _content, _opts), do: {:ok, %{"text" => "ok"}}

    def disconnect(client) do
      Agent.stop(client, :normal)
      :ok
    end
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

  defp fixture_suffix do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp fixture_path(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{fixture_suffix()}")

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp temp_path(prefix) do
    path = fixture_path(prefix)
    File.mkdir_p!(path)
    path
  end

  defp create_git_repo! do
    repository = temp_path("arbor-ai-grok-repo")

    run_git!(["init", "-b", "main"], repository)
    run_git!(["config", "user.name", "Acp Test"], repository)
    run_git!(["config", "user.email", "acp-test@example.com"], repository)

    File.write!(Path.join(repository, "README.md"), "grok fixture\n")
    run_git!(["add", "README.md"], repository)
    run_git!(["commit", "-q", "-m", "fixture", "--no-gpg-sign"], repository)

    repository
  end

  defp run_git!(args, repository) do
    case System.cmd("git", args, cd: repository, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        flunk("git #{Enum.join(args, " ")} failed in #{repository} (#{status}): #{output}")
    end
  end

  defp create_linked_fixture! do
    repository = create_git_repo!()
    branch = "grok-test-#{fixture_suffix()}"
    worktree = fixture_path("arbor-ai-grok-worktree")

    run_git!(["worktree", "add", "-b", branch, worktree], repository)

    {canonical_path(repository), canonical_path(worktree)}
  end

  defp canonical_path(path) do
    case SafePath.resolve_real(path) do
      {:ok, canonical_path} ->
        canonical_path

      {:error, reason} ->
        flunk("failed to canonicalize path #{path}: #{inspect(reason)}")
    end
  end

  defp probe_client_opts(overrides) do
    {:ok, trusted_opts} = Config.resolve(:grok, [])
    Keyword.merge(trusted_opts, overrides)
  end

  defp create_temporary_workspace_isolation! do
    home = temp_path("arbor-ai-grok-home")
    grok_home = Path.join(home, ".grok")
    previous_grok_home = System.get_env("GROK_HOME")

    System.put_env("GROK_HOME", grok_home)

    on_exit(fn ->
      if previous_grok_home do
        System.put_env("GROK_HOME", previous_grok_home)
      else
        System.delete_env("GROK_HOME")
      end

      File.rm_rf!(home)
    end)
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

    test "security regression: non-grok checkouts ignore grok authority and keep caller-owned authority fields" do
      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 grok_sandbox_authority: :literal
               )

      session_state = :sys.get_state(session)
      assert Keyword.get(session_state.opts, :grok_sandbox_authority) == :literal

      :ok = AcpPool.close_session(session)
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

    test "security regression: grok checkout adopts authority to the pool process" do
      create_temporary_workspace_isolation!()

      original_client_module = Application.get_env(:arbor_ai, :acp_client_module)
      Application.put_env(:arbor_ai, :acp_client_module, GrokPoolProbeClient)

      on_exit(fn ->
        if original_client_module do
          Application.put_env(:arbor_ai, :acp_client_module, original_client_module)
        else
          Application.delete_env(:arbor_ai, :acp_client_module)
        end
      end)

      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)
      pool_pid = Process.whereis(AcpPool)

      assert {:ok, session} =
               AcpPool.checkout(
                 :grok,
                 workspace: {:directory, worktree_root},
                 client_opts: probe_client_opts(test_pid: self(), _skip_connect: false),
                 grok_sandbox_authority: authority
               )

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      session_state = :sys.get_state(session)
      transferred_authority = Keyword.get(session_state.opts, :grok_sandbox_authority)

      assert session_state.owner == pool_pid
      assert is_map(transferred_authority)
      assert transferred_authority.owner == pool_pid
      assert transferred_authority.reference != authority.reference
      assert transferred_authority.owner != self()

      :ok = AcpPool.checkin(session)
      :ok = AcpPool.close_session(session)
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

  describe "settle_task_sessions/3" do
    test "settles only exact task+agent idle matches, cleans indexes, and terminates processes" do
      restart_pool!(default_max: 5, default_idle_timeout_ms: 300_000)

      task_id = "settle-task-#{System.unique_integer([:positive])}"
      agent_id = "settle-agent-#{System.unique_integer([:positive])}"
      other_task = "other-task-#{System.unique_integer([:positive])}"
      other_agent = "other-agent-#{System.unique_integer([:positive])}"
      cwd = temp_path("acp-settle-cwd")

      assert {:ok, match1} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 task_id: task_id,
                 agent_id: agent_id,
                 cwd: cwd,
                 affinity_key: "settle-affinity-#{System.unique_integer([:positive])}"
               )

      assert {:ok, match2} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 task_id: task_id,
                 agent_id: agent_id,
                 cwd: Path.join(cwd, "alt")
               )

      assert {:ok, other_by_task} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 task_id: other_task,
                 agent_id: agent_id,
                 cwd: cwd
               )

      assert {:ok, other_by_agent} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 task_id: task_id,
                 agent_id: other_agent,
                 cwd: cwd
               )

      assert :ok = AcpPool.checkin(match1)
      assert :ok = AcpPool.checkin(match2)
      assert :ok = AcpPool.checkin(other_by_task)
      assert :ok = AcpPool.checkin(other_by_agent)

      assert length(AcpPool.sessions()) == 4

      assert {:ok, receipt} = AcpPool.settle_task_sessions(task_id, agent_id)
      assert receipt["status"] == "settled"
      assert receipt["task_id"] == task_id
      assert receipt["agent_id"] == agent_id
      assert receipt["principal_id"] == agent_id
      assert receipt["settled_count"] == 2
      refute Map.has_key?(receipt, "pid")
      refute Map.has_key?(receipt, :pid)

      refute Process.alive?(match1)
      refute Process.alive?(match2)
      assert Process.alive?(other_by_task)
      assert Process.alive?(other_by_agent)

      remaining = AcpPool.sessions()
      assert length(remaining) == 2

      assert Enum.all?(remaining, fn info ->
               not (info.task_id == task_id and info.agent_id == agent_id)
             end)

      status = AcpPool.status()
      assert status[:test].total == 2
      assert status[:test].idle == 2
      assert status[:test].checked_out == 0

      # Exact-scope only: unrelated idle entries remain reusable.
      assert {:ok, reused} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 task_id: other_task,
                 agent_id: agent_id,
                 cwd: cwd
               )

      assert reused == other_by_task
    end

    test "no matches and repeated settle are idempotent success" do
      task_id = "missing-task-#{System.unique_integer([:positive])}"
      agent_id = "missing-agent-#{System.unique_integer([:positive])}"

      assert {:ok, receipt1} = AcpPool.settle_task_sessions(task_id, agent_id)
      assert receipt1["settled_count"] == 0
      assert receipt1["status"] == "settled"

      assert {:ok, receipt2} = AcpPool.settle_task_sessions(task_id, agent_id)
      assert receipt2["settled_count"] == 0
      assert receipt2 == receipt1
    end

    test "busy matching sessions refuse without removing any matching entries" do
      task_id = "busy-task-#{System.unique_integer([:positive])}"
      agent_id = "busy-agent-#{System.unique_integer([:positive])}"
      cwd = temp_path("acp-settle-busy")

      assert {:ok, busy} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 task_id: task_id,
                 agent_id: agent_id,
                 cwd: cwd
               )

      assert {:ok, idle} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 task_id: task_id,
                 agent_id: agent_id,
                 cwd: Path.join(cwd, "idle")
               )

      assert :ok = AcpPool.checkin(idle)

      assert {:error, :sessions_busy} = AcpPool.settle_task_sessions(task_id, agent_id)

      # Atomic busy refusal: neither the busy nor the idle match was removed.
      assert Process.alive?(busy)
      assert Process.alive?(idle)

      sessions = AcpPool.sessions()
      assert length(sessions) == 2

      assert Enum.any?(sessions, &(&1.pid == busy and &1.status == :checked_out))
      assert Enum.any?(sessions, &(&1.pid == idle and &1.status == :idle))

      :ok = AcpPool.checkin(busy)

      assert {:ok, receipt} = AcpPool.settle_task_sessions(task_id, agent_id)
      assert receipt["settled_count"] == 2
      refute Process.alive?(busy)
      refute Process.alive?(idle)
      assert AcpPool.sessions() == []
    end

    test "rejects blank or non-binary task/agent ids" do
      assert {:error, :invalid_task_agent} = AcpPool.settle_task_sessions("", "agent")
      assert {:error, :invalid_task_agent} = AcpPool.settle_task_sessions("task", "  ")
      assert {:error, :invalid_task_agent} = AcpPool.settle_task_sessions(nil, "agent")
      assert {:error, :invalid_task_agent} = AcpPool.settle_task_sessions("task", :agent)
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

      assert {:error, {:invalid, :tool_modules, :bad_entry}} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 tool_modules: ["Elixir.ModA"]
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

    test "security regression: max=2 three exact-task profiles progress via idle LRU eviction" do
      # Default production max is 2 with a long idle timeout. Exact task profiles
      # are never compatible across tasks, so without idle eviction a third task
      # would pool_exhausted while two idle sessions still occupy capacity.
      restart_pool!(default_max: 2, default_idle_timeout_ms: 300_000)

      agent = "coding_agent_max2_#{System.unique_integer([:positive])}"
      base = [client_opts: @test_client_opts, agent_id: agent, model: "coder"]

      {:ok, s1} =
        AcpPool.checkout(
          :test,
          base ++ [task_id: "task_1", cwd: "/tmp/t1_#{System.unique_integer([:positive])}"]
        )

      :ok = AcpPool.checkin(s1)

      # Ensure distinct last_active ordering for LRU
      Process.sleep(5)

      {:ok, s2} =
        AcpPool.checkout(
          :test,
          base ++ [task_id: "task_2", cwd: "/tmp/t2_#{System.unique_integer([:positive])}"]
        )

      :ok = AcpPool.checkin(s2)
      refute s1 == s2

      assert AcpPool.status()[:test].total == 2
      assert AcpPool.status()[:test].idle == 2
      assert AcpPool.status()[:test].max == 2

      # Third independent task must progress by evicting the LRU idle session
      {:ok, s3} =
        AcpPool.checkout(
          :test,
          base ++ [task_id: "task_3", cwd: "/tmp/t3_#{System.unique_integer([:positive])}"]
        )

      assert Process.alive?(s3)
      refute s3 == s1
      refute s3 == s2

      # Pool remains bounded at max=2 after eviction + mint
      status = AcpPool.status()[:test]
      assert status.total <= 2
      assert status.max == 2
      assert length(AcpPool.sessions()) <= 2

      # Evicted LRU (s1) must be fully cleaned from indexes immediately;
      # process death is bounded-eventual (graceful close is async).
      refute Enum.any?(AcpPool.sessions(), &(&1.pid == s1))
      assert_process_exits(s1, 1_000)

      :ok = AcpPool.checkin(s3)
    end

    test "security regression: capacity eviction uses graceful close (client disconnect)" do
      # Distinguishes safe_close/AcpSession.close from Process.exit(:kill):
      # only the graceful path runs terminate/2 → client disconnect/1.
      original = Application.get_env(:arbor_ai, :acp_client_module)
      Application.put_env(:arbor_ai, :acp_client_module, DisconnectClient)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_ai, :acp_client_module, original),
          else: Application.delete_env(:arbor_ai, :acp_client_module)
      end)

      restart_pool!(default_max: 1, default_idle_timeout_ms: 300_000)

      agent = "coding_agent_evict_#{System.unique_integer([:positive])}"
      client_opts = [test_pid: self()]

      {:ok, s1} =
        AcpPool.checkout(:test,
          client_opts: client_opts,
          agent_id: agent,
          task_id: "evict_1",
          cwd: "/tmp/evict_1_#{System.unique_integer([:positive])}"
        )

      :ok = AcpPool.checkin(s1)
      refute_receive {:pool_client_disconnect, _}, 30

      {:ok, s2} =
        AcpPool.checkout(:test,
          client_opts: client_opts,
          agent_id: agent,
          task_id: "evict_2",
          cwd: "/tmp/evict_2_#{System.unique_integer([:positive])}"
        )

      refute s2 == s1
      refute Enum.any?(AcpPool.sessions(), &(&1.pid == s1))

      assert_receive {:pool_client_disconnect, _client}, 1_000
      assert_process_exits(s1, 1_000)
      assert Process.alive?(s2)

      :ok = AcpPool.checkin(s2)
    end

    test "security regression: binary workspace checkout binds canonical session cwd" do
      workspace =
        Path.join(System.tmp_dir!(), "acp_pool_ws_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      expected_cwd = Path.expand(workspace)

      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: workspace,
                 agent_id: "ws_agent",
                 task_id: "ws_task"
               )

      assert Process.alive?(session)

      [info] = AcpPool.sessions()
      assert info.pid == session
      assert info.cwd == expected_cwd
      assert info.task_id == "ws_task"

      # Pool binds profile-canonical cwd and never forwards binary :workspace.
      session_state = :sys.get_state(session)
      assert Keyword.get(session_state.opts, :cwd) == expected_cwd
      refute Keyword.has_key?(session_state.opts, :workspace)
      assert session_state.workspace == nil

      :ok = AcpPool.close_session(session)
    end

    test "security regression: cwd nil + binary workspace binds profile cwd to session" do
      workspace =
        Path.join(System.tmp_dir!(), "acp_pool_ws_nil_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      expected_cwd = Path.expand(workspace)

      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 cwd: nil,
                 workspace: workspace,
                 agent_id: "ws_nil_agent",
                 task_id: "ws_nil_task"
               )

      [info] = AcpPool.sessions()
      assert info.cwd == expected_cwd

      session_state = :sys.get_state(session)
      assert Keyword.get(session_state.opts, :cwd) == expected_cwd
      refute Keyword.has_key?(session_state.opts, :workspace)
      assert session_state.workspace == nil

      :ok = AcpPool.close_session(session)
    end

    test "security regression: whitespace/relative workspace canonicalizes into session opts" do
      rel_name = "acp_pool_rel_ws_#{System.unique_integer([:positive])}"
      abs = Path.expand(rel_name)
      File.mkdir_p!(abs)
      on_exit(fn -> File.rm_rf(abs) end)

      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: "  #{rel_name}  ",
                 agent_id: "ws_rel_agent",
                 task_id: "ws_rel_task"
               )

      [info] = AcpPool.sessions()
      assert info.cwd == abs

      session_state = :sys.get_state(session)
      assert Keyword.get(session_state.opts, :cwd) == abs
      refute Keyword.has_key?(session_state.opts, :workspace)

      :ok = AcpPool.close_session(session)
    end

    test "security regression: structured directory workspace reaches AcpSession plan" do
      dir =
        Path.join(System.tmp_dir!(), "acp_pool_dir_plan_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      expected = Path.expand(dir)

      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: {:directory, "  #{dir}  "},
                 agent_id: "dir_agent",
                 task_id: "dir_task"
               )

      [info] = AcpPool.sessions()
      assert info.cwd == expected

      session_state = :sys.get_state(session)
      assert Keyword.get(session_state.opts, :cwd) == expected
      assert Keyword.get(session_state.opts, :workspace) == {:directory, expected}
      assert session_state.workspace == {:directory, expected}

      :ok = AcpPool.close_session(session)
    end

    test "security regression: distinct structured workspace plans never reuse" do
      dir_a =
        Path.join(System.tmp_dir!(), "acp_pool_plan_a_#{System.unique_integer([:positive])}")

      dir_b =
        Path.join(System.tmp_dir!(), "acp_pool_plan_b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)
      on_exit(fn -> File.rm_rf(dir_a) end)
      on_exit(fn -> File.rm_rf(dir_b) end)

      base = [
        client_opts: @test_client_opts,
        agent_id: "plan_agent",
        task_id: "same_task"
      ]

      assert {:ok, s1} =
               AcpPool.checkout(:test, base ++ [workspace: {:directory, dir_a}])

      :ok = AcpPool.checkin(s1)

      assert {:ok, s2} =
               AcpPool.checkout(:test, base ++ [workspace: {:directory, dir_b}])

      refute s2 == s1

      :ok = AcpPool.close_session(s1)
      :ok = AcpPool.close_session(s2)
    end

    test "security regression: malformed structured workspace is rejected before spawn" do
      assert {:error, {:invalid, :workspace, :bad_type}} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: {:other, "/tmp/x"}
               )

      assert {:error, {:invalid, :workspace, :unknown_worktree_keys}} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: {:worktree, [branch: "ok", not_allowed: true]}
               )

      assert AcpPool.sessions() == []
    end

    test "security regression: explicit cwd wins over binary workspace alias" do
      workspace =
        Path.join(System.tmp_dir!(), "acp_pool_ws_alias_#{System.unique_integer([:positive])}")

      explicit_cwd =
        Path.join(
          System.tmp_dir!(),
          "acp_pool_cwd_explicit_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace)
      File.mkdir_p!(explicit_cwd)
      on_exit(fn -> File.rm_rf(workspace) end)
      on_exit(fn -> File.rm_rf(explicit_cwd) end)

      expected_cwd = Path.expand(explicit_cwd)

      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: workspace,
                 cwd: explicit_cwd,
                 agent_id: "ws_cwd_agent",
                 task_id: "ws_cwd_task"
               )

      [info] = AcpPool.sessions()
      assert info.cwd == expected_cwd

      session_state = :sys.get_state(session)
      # Explicit :cwd is profile-bound; binary :workspace is dropped at spawn.
      assert Keyword.get(session_state.opts, :cwd) == expected_cwd
      refute Keyword.has_key?(session_state.opts, :workspace)

      :ok = AcpPool.close_session(session)
    end

    test "security regression: post-spawn deadline expiry uses graceful close" do
      # Hits cleanup_expired_spawn after await_ready fails on a post-spawn
      # startup deadline. Process.exit(:kill) yields DOWN :killed; safe_close
      # yields AcpSession.close stop reason :normal (proven fail on fe189128).
      original = Application.get_env(:arbor_ai, :acp_client_module)
      Application.put_env(:arbor_ai, :acp_client_module, StartupClient)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_ai, :acp_client_module, original),
          else: Application.delete_env(:arbor_ai, :acp_client_module)
      end)

      test_pid = self()

      checkout_task =
        Task.async(fn ->
          AcpPool.checkout(:test,
            timeout: 40,
            client_opts: [start_mode: :stall, test_pid: test_pid]
          )
        end)

      assert_receive {:pool_start_stalled, startup_worker}, 500

      session_pid =
        case Process.info(startup_worker, :links) do
          {:links, links} -> Enum.find(links, &(is_pid(&1) and &1 != startup_worker))
          _ -> nil
        end

      assert is_pid(session_pid)
      ref = Process.monitor(session_pid)

      assert {:error, _reason} = Task.await(checkout_task, 1_000)

      assert_receive {:DOWN, ^ref, :process, ^session_pid, reason}, 1_000
      assert reason == :normal
      assert AcpPool.sessions() == []
    end

    test "security regression: structured directory + tools binds ToolServer workspace" do
      dir =
        Path.join(System.tmp_dir!(), "acp_pool_dir_tools_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      expected = Path.expand(dir)

      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: {:directory, dir},
                 tool_modules: [ScopeToolAction],
                 agent_id: "dir_tools_agent",
                 task_id: "dir_tools_task"
               )

      [info] = AcpPool.sessions()
      assert info.cwd == expected
      assert is_integer(info.tool_server_port)

      session_state = :sys.get_state(session)
      assert Keyword.get(session_state.opts, :cwd) == expected
      assert Keyword.get(session_state.opts, :workspace) == {:directory, expected}

      :ok = AcpPool.close_session(session)
    end

    test "security regression: structured worktree + tools is rejected fail-closed" do
      assert {:error, {:invalid, :workspace, :worktree_tools_unscoped}} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 workspace: {:worktree, [branch: "tools-blocked"]},
                 tool_modules: [ScopeToolAction],
                 agent_id: "wt_tools_agent",
                 task_id: "wt_tools_task"
               )

      assert AcpPool.sessions() == []
    end

    test "security regression: canonical model is bound; caller owner is ignored" do
      caller = self()
      pool_pid = Process.whereis(AcpPool)

      assert {:ok, session} =
               AcpPool.checkout(:test,
                 client_opts: @test_client_opts,
                 model: "  spaced-model  ",
                 owner: caller,
                 agent_id: "owner_model_agent",
                 task_id: "owner_model_task"
               )

      session_state = :sys.get_state(session)
      assert Keyword.get(session_state.opts, :model) == "spaced-model"
      # Pool process owns lifecycle; caller-supplied owner must not win.
      assert session_state.owner == pool_pid
      refute session_state.owner == caller

      [info] = AcpPool.sessions()
      assert info.model == "spaced-model"

      :ok = AcpPool.close_session(session)
    end

    test "security regression: busy sessions at max still exhaust; idle only is evictable" do
      restart_pool!(default_max: 2, default_idle_timeout_ms: 300_000)

      agent = "coding_agent_busy_#{System.unique_integer([:positive])}"
      base = [client_opts: @test_client_opts, agent_id: agent, model: "coder"]

      {:ok, busy1} =
        AcpPool.checkout(
          :test,
          base ++ [task_id: "busy_1", cwd: "/tmp/b1_#{System.unique_integer([:positive])}"]
        )

      {:ok, busy2} =
        AcpPool.checkout(
          :test,
          base ++ [task_id: "busy_2", cwd: "/tmp/b2_#{System.unique_integer([:positive])}"]
        )

      assert {:error, :pool_exhausted} =
               AcpPool.checkout(
                 :test,
                 base ++ [task_id: "busy_3", cwd: "/tmp/b3_#{System.unique_integer([:positive])}"]
               )

      assert AcpPool.status()[:test].total == 2
      assert AcpPool.status()[:test].checked_out == 2
      assert Process.alive?(busy1)
      assert Process.alive?(busy2)
    end
  end

  defp restart_pool!(opts) do
    _ = stop_supervised(AcpPool)

    start_supervised!(
      {AcpPool,
       Keyword.merge(
         [
           default_max: 3,
           default_idle_timeout_ms: 500,
           cleanup_interval_ms: 100_000
         ],
         opts
       )}
    )
  end

  defp assert_process_exits(pid, timeout_ms)
       when is_pid(pid) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if Process.alive?(pid) do
        Process.sleep(10)
        :alive
      else
        :dead
      end
    end)
    |> Enum.find(fn
      :dead -> true
      :alive -> System.monotonic_time(:millisecond) >= deadline
    end)
    |> case do
      :dead ->
        :ok

      :alive ->
        flunk("expected #{inspect(pid)} to exit within #{timeout_ms}ms")
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
