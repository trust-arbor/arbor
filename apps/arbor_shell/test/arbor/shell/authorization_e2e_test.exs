defmodule Arbor.Shell.AuthorizationE2ETest do
  @moduledoc """
  End-to-end tests for shell authorization flow.

  Tests the full pipeline: agent -> authorize_and_execute/authorize_and_dispatch
  -> Security.authorize -> CapabilityStore lookup -> shell execution.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore

  setup do
    # Ensure Security processes are running
    ensure_security_started()

    # Disable features that interfere with minimal authorization tests
    prev_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled)
    prev_signing = Application.get_env(:arbor_security, :capability_signing_required)
    prev_identity = Application.get_env(:arbor_security, :strict_identity_mode)
    prev_approval = Application.get_env(:arbor_security, :approval_guard_enabled)
    prev_receipts = Application.get_env(:arbor_security, :invocation_receipts_enabled)

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)

    agent_id = "agent_shell_e2e_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      restore_config(:reflex_checking_enabled, prev_reflex)
      restore_config(:capability_signing_required, prev_signing)
      restore_config(:strict_identity_mode, prev_identity)
      restore_config(:approval_guard_enabled, prev_approval)
      restore_config(:invocation_receipts_enabled, prev_receipts)
    end)

    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # 1. Authorized execution
  # ===========================================================================

  describe "authorized execution" do
    test "agent with shell capability can execute commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      result = Arbor.Shell.authorize_and_execute(agent_id, "echo hello", sandbox: :none)

      assert {:ok, %{exit_code: 0, stdout: stdout}} = result
      assert String.trim(stdout) == "hello"
    end

    test "agent with wildcard shell capability can execute any command", %{agent_id: agent_id} do
      # A wildcard shell grant must be an EXPLICIT subtree wildcard (`/**`).
      # Post-C8 (2026-06-09, AuthDecision.uri_matches?/2), a concrete cap URI
      # grants ONLY its exact resource — `arbor://shell/exec` would match only
      # the bare `arbor://shell/exec`, not `arbor://shell/exec/echo`. Subtree
      # access (any command) requires the `/**` form.
      grant_shell_capability(agent_id, "arbor://shell/exec/**")

      result = Arbor.Shell.authorize_and_execute(agent_id, "echo wildcard", sandbox: :none)

      assert {:ok, %{exit_code: 0, stdout: stdout}} = result
      assert String.trim(stdout) == "wildcard"
    end
  end

  # ===========================================================================
  # 1b. Closed direct-executable policy
  # ===========================================================================

  describe "closed direct-executable policy" do
    test "a generic git grant cannot turn Git into an unbounded dispatch surface",
         %{agent_id: agent_id} do
      # Git can dispatch aliases, hooks, pagers, and helpers. Generic command
      # grants therefore cannot prove the exact child process. Schema-specific
      # Arbor.Actions.Git operations remain available through structured argv.
      grant_shell_capability(agent_id, "arbor://shell/exec/git")

      assert {:error, {:agent_executable_not_allowed, "git"}} =
               Arbor.Shell.authorize_and_execute(agent_id, "git --version", sandbox: :strict)
    end

    test "a compound command with config true fails closed without executing chained commands",
         %{agent_id: agent_id} do
      # Intentional security API break: config true routes compounds to the
      # CapShell unavailable path — no per-command execution of the retired
      # prototype. Chained ungranted `rm` must not run (and neither may `git`).
      with_compound_shell(true, fn ->
        grant_shell_capability(agent_id, "arbor://shell/exec/git")
        target = Path.join(System.tmp_dir!(), "e2e_escape_#{:erlang.unique_integer([:positive])}")
        File.rm(target)
        File.write!(target, "survive")

        try do
          assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                   Arbor.Shell.authorize_and_execute(agent_id, "git --version; rm #{target}")

          assert File.exists?(target), "compound fail-closed must not execute chained rm"
        after
          File.rm(target)
        end
      end)
    end
  end

  # ===========================================================================
  # 1c. Compound command execution (CapShell opt-in; default fail-closed)
  # ===========================================================================

  describe "compound command execution" do
    test "security regression: absent compound_shell_enabled rejects compounds at agent boundary",
         %{agent_id: agent_id} do
      # Compounds are rejected unconditionally at agent-authorized boundaries
      # with the CapShell unavailable error — independent of config and before
      # sandbox metacharacter checks. sandbox:none must not re-open execution.
      grant_shell_capability(agent_id, "arbor://shell/exec/**")

      with_compound_shell(:absent, fn ->
        marker =
          Path.join(
            System.tmp_dir!(),
            "e2e_capshell_closed_#{:erlang.unique_integer([:positive])}"
          )

        File.rm(marker)

        try do
          assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                   Arbor.Shell.authorize_and_execute(
                     agent_id,
                     "sleep 1; touch #{marker}",
                     sandbox: :basic
                   )

          assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                   Arbor.Shell.authorize_and_execute(
                     agent_id,
                     "sh -c 'sleep 1; touch #{marker}'",
                     sandbox: :none
                   )

          Process.sleep(1_500)
          refute File.exists?(marker), "delayed compound side effect must not execute"
        after
          File.rm(marker)
        end
      end)
    end

    test "security regression: explicit compound_shell_enabled true fails closed (no CapShell execution)",
         %{agent_id: agent_id} do
      # Intentional security API break: config true must NOT re-enable the
      # retired CapShell prototype. authorize_and_execute returns the stable
      # unavailable error without side effects.
      with_compound_shell(true, fn ->
        assert Arbor.Shell.compound_shell_enabled?()
        grant_shell_capability(agent_id, "arbor://shell/exec/git")

        marker =
          Path.join(
            System.tmp_dir!(),
            "e2e_capshell_true_#{:erlang.unique_integer([:positive])}"
          )

        File.rm(marker)

        try do
          assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                   Arbor.Shell.authorize_and_execute(
                     agent_id,
                     "git --version && touch #{marker}"
                   )

          Process.sleep(200)
          refute File.exists?(marker)
        after
          File.rm(marker)
        end
      end)
    end

    test "compound with config true fails closed even for builtin-led and all-builtin forms",
         %{agent_id: agent_id} do
      # Former positive CapShell cases (builtin gate-1 skip, all-builtin) are
      # intentionally broken: fail-closed before any CapShell/Bash work.
      with_compound_shell(true, fn ->
        grant_shell_capability(agent_id, "arbor://shell/exec/git")

        assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                 Arbor.Shell.authorize_and_execute(agent_id, "cd /tmp && git --version")

        assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                 Arbor.Shell.authorize_and_execute(agent_id, "cd /tmp && echo hi")
      end)
    end
  end

  # ===========================================================================
  # 1d. Public facade APIs for compound detection / CapShell execution
  # ===========================================================================

  describe "compound facade APIs" do
    test "compound_command?/1 detects metacharacters without importing Sandbox" do
      assert Arbor.Shell.compound_command?("sleep 1; touch /tmp/x")
      assert Arbor.Shell.compound_command?("echo a && echo b")
      assert Arbor.Shell.compound_command?("cat file | wc -l")
      refute Arbor.Shell.compound_command?("echo hello")
      refute Arbor.Shell.compound_command?("git --version")
    end

    test "execute_compound_with_capabilities/3 always fails closed (security API break)",
         %{agent_id: agent_id} do
      # Direct facade entry cannot bypass fail-closed — no CapShell execution,
      # no silent fallback. Marker must survive; return is the stable error.
      grant_shell_capability(agent_id, "arbor://shell/exec/git")

      marker =
        Path.join(System.tmp_dir!(), "e2e_facade_cap_#{:erlang.unique_integer([:positive])}")

      File.write!(marker, "survive")

      try do
        assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                 Arbor.Shell.execute_compound_with_capabilities(
                   agent_id,
                   "git --version; rm #{marker}"
                 )

        assert File.exists?(marker), "fail-closed facade must not run compound commands"

        assert {:error, {:compound_shell_unavailable, :security_boundary_incomplete}} =
                 Arbor.Shell.execute_compound_with_capabilities(
                   agent_id,
                   "git --version && echo facade-ok"
                 )
      after
        File.rm(marker)
      end
    end
  end

  # ===========================================================================
  # 2. Unauthorized execution
  # ===========================================================================

  describe "unauthorized execution" do
    test "agent without capability gets authorization error", %{agent_id: agent_id} do
      # No capability granted — should be blocked at authorization, not execution
      result = Arbor.Shell.authorize_and_execute(agent_id, "echo blocked", sandbox: :none)

      assert {:error, :unauthorized} = result
    end

    test "authorization error is returned before command runs", %{agent_id: agent_id} do
      # Use a command that would create a side effect if it ran
      marker = "/tmp/arbor_shell_auth_test_#{:erlang.unique_integer([:positive])}"
      File.rm(marker)

      try do
        result =
          Arbor.Shell.authorize_and_execute(agent_id, "touch #{marker}", sandbox: :none)

        assert {:error, :unauthorized} = result
        # Verify the command never ran
        refute File.exists?(marker)
      after
        File.rm(marker)
      end
    end
  end

  # ===========================================================================
  # 3. Specific command authorization
  # ===========================================================================

  describe "specific command authorization" do
    test "echo capability allows echo but blocks other commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      # echo should work
      assert {:ok, %{exit_code: 0}} =
               Arbor.Shell.authorize_and_execute(agent_id, "echo hello", sandbox: :none)

      # rm is outside the closed executable set and is rejected before auth.
      assert {:error, {:agent_executable_not_allowed, "rm"}} =
               Arbor.Shell.authorize_and_execute(agent_id, "rm -rf /", sandbox: :none)
    end

    test "ls capability allows ls but blocks echo", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/ls")

      assert {:ok, %{exit_code: _}} =
               Arbor.Shell.authorize_and_execute(agent_id, "ls /tmp", sandbox: :none)

      assert {:error, :unauthorized} =
               Arbor.Shell.authorize_and_execute(agent_id, "echo denied", sandbox: :none)
    end

    test "path-prefixed commands are stripped to base name", %{agent_id: agent_id} do
      # Granting "echo" capability should work even when command uses /bin/echo
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      assert {:ok, %{exit_code: 0, stdout: stdout}} =
               Arbor.Shell.authorize_and_execute(agent_id, "/bin/echo path_test", sandbox: :none)

      assert String.trim(stdout) == "path_test"
    end
  end

  # ===========================================================================
  # 4. Dispatch authorization
  # ===========================================================================

  describe "authorize_and_dispatch via authorize_and_execute_async" do
    test "authorized agent can execute async commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      result = Arbor.Shell.authorize_and_execute_async(agent_id, "echo async", sandbox: :none)

      assert {:ok, exec_id} = result
      assert is_binary(exec_id)
      assert String.starts_with?(exec_id, "exec_")

      # Wait for result
      {:ok, async_result} = Arbor.Shell.get_result(exec_id, wait: true, timeout: 5000)
      assert async_result.exit_code == 0
      assert String.contains?(async_result.stdout, "async")
    end

    test "unauthorized agent is blocked from async execution", %{agent_id: agent_id} do
      result = Arbor.Shell.authorize_and_execute_async(agent_id, "echo blocked", sandbox: :none)

      assert {:error, :unauthorized} = result
    end

    test "security regression: immediate cancellation owns and kills an authorized sleep", %{
      agent_id: agent_id
    } do
      grant_shell_capability(agent_id, "arbor://shell/exec/sleep")

      assert {:ok, exec_id} =
               Arbor.Shell.authorize_and_execute_async(agent_id, "sleep 1", sandbox: :none)

      assert {:ok, execution} = Arbor.Shell.ExecutionRegistry.get(exec_id)
      assert execution.status == :running
      refute Map.has_key?(execution, :pid)
      refute Map.has_key?(execution, :port)
      refute Map.has_key?(execution, :owner_pid)
      refute Map.has_key?(execution, :controller_pid)

      assert :ok = Arbor.Shell.kill(exec_id)
      assert eventually(fn -> Arbor.Shell.get_status(exec_id) == {:ok, :killed} end, 1_000)
      assert {:ok, %{killed: true, cancelled: true}} = Arbor.Shell.get_result(exec_id)

      # The original sleep deadline must not race a late completion over the
      # atomically claimed killed state.
      Process.sleep(1_200)
      assert {:ok, :killed} = Arbor.Shell.get_status(exec_id)
      assert {:ok, %{killed: true, cancelled: true}} = Arbor.Shell.get_result(exec_id)
    end

    test "security regression: registry projections never disclose cancellation handles", %{
      agent_id: agent_id
    } do
      grant_shell_capability(agent_id, "arbor://shell/exec/sleep")

      assert {:ok, exec_id} =
               Arbor.Shell.authorize_and_execute_async(agent_id, "sleep 5", sandbox: :none)

      assert {:ok, execution} = Arbor.Shell.ExecutionRegistry.get(exec_id)

      projection_text = inspect(execution)
      refute projection_text =~ "#PID<"
      refute projection_text =~ "#Port<"
      refute projection_text =~ "#Reference<"
      refute Map.has_key?(execution, :owner_pid)
      refute Map.has_key?(execution, :owner_ref)
      refute Map.has_key?(execution, :controller_pid)

      assert :ok = Arbor.Shell.kill(exec_id)
      assert eventually(fn -> Arbor.Shell.get_status(exec_id) == {:ok, :killed} end, 1_000)
    end

    test "security regression: foreign raw terminal completion cannot be forged", %{
      agent_id: agent_id
    } do
      grant_shell_capability(agent_id, "arbor://shell/exec/sleep")

      assert {:ok, exec_id} =
               Arbor.Shell.authorize_and_execute_async(agent_id, "sleep 2", sandbox: :none)

      registry = Process.whereis(Arbor.Shell.ExecutionRegistry)

      forged_reply =
        Task.async(fn ->
          raw_registry_call(
            registry,
            {:transition_status, exec_id, [:pending, :running], :completed,
             %{result: %{exit_code: 0}}}
          )
        end)
        |> Task.await()

      refute forged_reply == :ok
      assert {:ok, :running} = Arbor.Shell.get_status(exec_id)
      assert :ok = Arbor.Shell.kill(exec_id)
    end
  end

  describe "authorize_and_dispatch via authorize_and_execute_streaming" do
    test "authorized agent can execute streaming commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      result =
        Arbor.Shell.authorize_and_execute_streaming(
          agent_id,
          "echo streaming",
          stream_to: self(),
          sandbox: :none
        )

      assert {:ok, session_id} = result
      assert is_binary(session_id)

      assert_receive {:port_exit, ^session_id, 0, output}, 5_000
      assert String.contains?(output, "streaming")
    end

    test "unauthorized agent is blocked from streaming execution", %{agent_id: agent_id} do
      result =
        Arbor.Shell.authorize_and_execute_streaming(
          agent_id,
          "echo blocked",
          stream_to: self(),
          sandbox: :none
        )

      assert {:error, :unauthorized} = result
    end

    test "security regression: authorized streaming threads the hard byte ceiling", %{
      agent_id: agent_id
    } do
      grant_shell_capability(agent_id, "arbor://shell/exec/cat")

      root =
        Path.join(
          System.tmp_dir!(),
          "authorized_stream_cap_#{System.unique_integer([:positive])}"
        )

      input = Path.join(root, "one_megabyte.bin")
      File.mkdir_p!(root)
      File.write!(input, :binary.copy(<<0xFE>>, 1_048_576))

      try do
        assert {:ok, session_id} =
                 Arbor.Shell.authorize_and_execute_streaming(
                   agent_id,
                   "cat #{input}",
                   stream_to: self(),
                   max_output_bytes: 64,
                   timeout: 5_000,
                   sandbox: :none
                 )

        {delivered, metadata, retained} = collect_limited_stream(session_id, <<>>, nil)

        assert byte_size(delivered) == 64
        assert delivered == :binary.copy(<<0xFE>>, 64)
        assert retained == delivered
        assert metadata.output_bytes == 64
        assert metadata.max_output_bytes == 64
        assert metadata.output_limit_exceeded
        assert metadata.output_truncated
        refute_receive {:port_data, ^session_id, _extra}, 100
      after
        File.rm_rf!(root)
      end
    end

    test "security regression: completed and abandoned streams become terminal in registry", %{
      agent_id: agent_id
    } do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")
      grant_shell_capability(agent_id, "arbor://shell/exec/sleep")

      assert {:ok, completed_id} =
               Arbor.Shell.authorize_and_execute_streaming(
                 agent_id,
                 "echo tracked",
                 stream_to: self(),
                 timeout: 2_000
               )

      assert_receive {:port_exit, ^completed_id, 0, _output}, 2_000

      assert eventually(
               fn -> Arbor.Shell.get_status(completed_id) == {:ok, :completed} end,
               2_000
             )

      assert {:ok, abandoned_id} =
               Arbor.Shell.authorize_and_execute_streaming(
                 agent_id,
                 "sleep 5",
                 timeout: 100
               )

      assert eventually(
               fn -> Arbor.Shell.get_status(abandoned_id) == {:ok, :timed_out} end,
               2_000
             )

      {:ok, executions} = Arbor.Shell.list_executions()
      completed = Enum.find(executions, &(&1.id == completed_id))
      abandoned = Enum.find(executions, &(&1.id == abandoned_id))
      assert completed.status == :completed
      assert abandoned.status == :timed_out
      refute Map.has_key?(completed, :port_session_pid)
      refute Map.has_key?(abandoned, :port_session_pid)
    end

    test "security regression: unbounded streaming timeout rejects before registry work", %{
      agent_id: agent_id
    } do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")
      {:ok, before} = Arbor.Shell.list_executions()

      assert {:error, :invalid_stream_timeout} =
               Arbor.Shell.authorize_and_execute_streaming(
                 agent_id,
                 "echo never",
                 stream_to: self(),
                 timeout: :infinity
               )

      {:ok, after_attempt} = Arbor.Shell.list_executions()
      assert Enum.map(after_attempt, & &1.id) == Enum.map(before, & &1.id)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp grant_shell_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_shell_e2e_#{:erlang.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{test: true}
    }

    {:ok, :stored} = CapabilityStore.put(cap)
    cap
  end

  defp collect_limited_stream(session_id, delivered, metadata) do
    receive do
      {:port_data, ^session_id, chunk} ->
        collect_limited_stream(session_id, delivered <> chunk, metadata)

      {:port_output_limit, ^session_id, limit_metadata} ->
        collect_limited_stream(session_id, delivered, limit_metadata)

      {:port_exit, ^session_id, 137, retained} ->
        {delivered, metadata, retained}
    after
      5_000 -> flunk("timed out waiting for authorized capped stream")
    end
  end

  defp raw_registry_call(registry, request) do
    ref = make_ref()
    send(registry, {:"$gen_call", {self(), ref}, request})

    receive do
      {^ref, reply} -> reply
    after
      1_000 -> :no_reply
    end
  end

  defp eventually(predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(predicate, deadline)
  end

  defp do_eventually(predicate, deadline) do
    if predicate.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(predicate, deadline)
      else
        false
      end
    end
  end

  defp ensure_security_started do
    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    if Process.whereis(Arbor.Security.Supervisor) do
      for child <- security_children do
        try do
          case Supervisor.start_child(Arbor.Security.Supervisor, child) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, :already_present} -> :ok
            _other -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)

  # Restore Application env deterministically so compound_shell_enabled never
  # leaks across tests (async: false shared process state).
  defp with_compound_shell(value, fun) when is_function(fun, 0) do
    prev = Application.get_env(:arbor_shell, :compound_shell_enabled)

    case value do
      :absent -> Application.delete_env(:arbor_shell, :compound_shell_enabled)
      other -> Application.put_env(:arbor_shell, :compound_shell_enabled, other)
    end

    try do
      fun.()
    after
      if is_nil(prev),
        do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
        else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev)
    end
  end
end
