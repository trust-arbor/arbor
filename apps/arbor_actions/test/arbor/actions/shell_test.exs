defmodule Arbor.Actions.ShellTest do
  use Arbor.Actions.ActionCase, async: false
  @moduletag :fast

  alias Arbor.Actions.Shell

  # Start shell system for tests
  setup_all do
    # Ensure shell system is running
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _} = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end

    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    if Process.whereis(Arbor.Trust.Store) == nil do
      start_supervised!(Arbor.Trust.Store)
    end

    previous = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    on_exit(fn ->
      restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
      restore(:arbor_security, :capability_signing_required, previous.signing)
      restore(:arbor_security, :strict_identity_mode, previous.identity)
      restore(:arbor_security, :uri_registry_enforcement, previous.uri_registry)
      restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
      restore(:arbor_trust, :approval_guard_enabled, previous.trust_guard)
      restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
    end)

    agent_id = "agent_shell_execute_#{System.unique_integer([:positive])}"
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)

    :ok =
      Arbor.Trust.Store.store_profile(%{
        profile
        | rules: Map.put(profile.rules, "arbor://shell/exec/**", :auto)
      })

    {:ok, _capability} =
      Arbor.Security.grant(principal: agent_id, resource: "arbor://shell/exec/**")

    {:ok, agent_context: %{agent_id: agent_id}}
  end

  describe "Execute" do
    test "runs a simple command", %{agent_context: context} do
      assert {:ok, result} = Shell.Execute.run(%{command: "echo hello"}, context)
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "hello")
      refute result.timed_out
    end

    test "security regression: timeout 0 falls back instead of exit 137", %{
      agent_context: context
    } do
      # Same class of bug as ACP create_session: optional tool args filled with
      # 0 must not become an immediate Port kill.
      assert {:ok, result} =
               Shell.Execute.run(%{command: "echo not-killed", timeout: 0}, context)

      assert result.exit_code == 0
      refute result.timed_out
      assert result.stdout =~ "not-killed"
    end

    test "captures stderr", %{agent_context: context} do
      assert {:ok, result} =
               Shell.Execute.run(%{command: "ls /nonexistent_path_12345"}, context)

      assert result.exit_code != 0
      assert result.stderr != "" or String.contains?(result.stdout, "No such file")
    end

    test "respects timeout", %{agent_context: context} do
      # Action boundary floors sub-second timeouts; use >= 1000ms here.
      assert {:ok, result} =
               Shell.Execute.run(%{command: "sleep 5", timeout: 1000}, context)

      assert result.timed_out
    end

    test "uses working directory", %{agent_context: context} do
      assert {:ok, result} = Shell.Execute.run(%{command: "pwd", cwd: "/tmp"}, context)

      assert String.contains?(result.stdout, "/tmp") or
               String.contains?(result.stdout, "/private/tmp")
    end

    test "rejects environment overrides at the generic agent boundary", %{
      agent_context: context
    } do
      assert {:error, message} =
               Shell.Execute.run(
                 %{command: "printenv TEST_VAR", env: %{"TEST_VAR" => "test_value"}},
                 context
               )

      assert message =~ "environment overrides are unavailable"
    end

    test "validates action metadata" do
      assert Shell.Execute.name() == "shell_execute"
      assert Shell.Execute.description() =~ "shell command"
      assert Shell.Execute.category() == "shell"
      assert "shell" in Shell.Execute.tags()
    end

    test "generates tool schema" do
      tool = Shell.Execute.to_tool()
      assert is_map(tool)
      assert tool[:name] == "shell_execute"
      assert is_map(tool[:parameters_schema])
    end

    test "context can override options", %{agent_context: agent_context} do
      context = Map.put(agent_context, :cwd, "/tmp")
      assert {:ok, result} = Shell.Execute.run(%{command: "pwd"}, context)
      assert String.contains?(result.stdout, "tmp")
    end

    test "schema declares max_output_bytes and forwards a tight ceiling", %{
      agent_context: context
    } do
      tool = Shell.Execute.to_tool()
      schema = tool[:parameters_schema] || tool["parameters_schema"] || %{}
      props = schema[:properties] || schema["properties"] || %{}

      assert Map.has_key?(props, :max_output_bytes) or Map.has_key?(props, "max_output_bytes")

      # Finite producer without shell metacharacters. 200 bytes crosses the
      # 128-byte ceiling.
      burst = String.duplicate("x", 200)

      assert {:ok, result} =
               Shell.Execute.run(
                 %{
                   command: "printf #{burst}",
                   max_output_bytes: 128,
                   sandbox: :none,
                   timeout: 5_000
                 },
                 context
               )

      assert result.killed == true
      assert result.timed_out == false
      assert result.output_limit_exceeded == true
      assert result.output_truncated == true
      assert result.exit_code == 137
      assert byte_size(result.stdout) <= 128
      assert byte_size(result.stdout) > 0
      # stderr_to_stdout: retained stream is stdout; stderr result is empty.
      assert result.stderr == ""
    end

    test "security regression: adapter clamps max_output_bytes via Arbor.Shell facade", %{
      agent_context: context
    } do
      # Oversized positive ceiling must be accepted and clamped (not rejected)
      # through the public Shell facade — not a duplicated L6 hard-max constant.
      hard_max = Arbor.Shell.max_output_bytes_limit()
      assert hard_max == 16_777_216
      assert Arbor.Shell.normalize_max_output_bytes(hard_max * 2) == hard_max

      assert {:ok, result} =
               Shell.Execute.run(
                 %{
                   command: "echo clamp-ok",
                   max_output_bytes: hard_max * 2,
                   sandbox: :none,
                   timeout: 5_000
                 },
                 context
               )

      assert result.exit_code == 0
      assert result.stdout =~ "clamp-ok"
      assert result.output_limit_exceeded == false
      assert result.output_truncated == false
      assert result.killed == false
    end

    test "returns additive killed/output-limit metadata on normal completion", %{
      agent_context: context
    } do
      assert {:ok, result} =
               Shell.Execute.run(%{command: "echo meta", sandbox: :none}, context)

      assert result.exit_code == 0
      assert result.timed_out == false
      assert result.killed == false
      assert result.output_limit_exceeded == false
      assert result.output_truncated == false
    end
  end

  describe "authorize_command/3" do
    setup do
      {:ok, _} = Application.ensure_all_started(:arbor_security)
      {:ok, _} = Application.ensure_all_started(:arbor_trust)

      if Process.whereis(Arbor.Trust.Store) == nil do
        start_supervised!(Arbor.Trust.Store)
      end

      prev = %{
        reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
        signing: Application.get_env(:arbor_security, :capability_signing_required),
        identity: Application.get_env(:arbor_security, :strict_identity_mode),
        uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
        escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
        trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
        trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
      }

      Application.put_env(:arbor_security, :reflex_checking_enabled, false)
      Application.put_env(:arbor_security, :capability_signing_required, false)
      Application.put_env(:arbor_security, :strict_identity_mode, false)
      Application.put_env(:arbor_security, :uri_registry_enforcement, false)
      Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

      on_exit(fn ->
        restore(:arbor_security, :reflex_checking_enabled, prev.reflex)
        restore(:arbor_security, :capability_signing_required, prev.signing)
        restore(:arbor_security, :strict_identity_mode, prev.identity)
        restore(:arbor_security, :uri_registry_enforcement, prev.uri_registry)
        restore(:arbor_security, :consensus_escalation_enabled, prev.escalation)
        restore(:arbor_trust, :approval_guard_enabled, prev.trust_guard)
        restore(:arbor_trust, :policy_enforcer_enabled, prev.trust_enforcer)
      end)

      agent_id = "agent_shell_approval_#{System.unique_integer([:positive])}"
      resource_uri = "arbor://shell/exec/grep"

      {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
      rules = Map.put(profile.rules, resource_uri, :auto)
      :ok = Arbor.Trust.Store.store_profile(%{profile | rules: rules})
      {:ok, _cap} = Arbor.Security.grant(principal: agent_id, resource: resource_uri)

      {:ok, agent_id: agent_id, resource_uri: resource_uri}
    end

    test "forwards approved invocation context into trust authorization", %{
      agent_id: agent_id,
      resource_uri: resource_uri
    } do
      assert {:error, :unauthorized} =
               Shell.authorize_command(agent_id, "grep needle README.md")

      assert {:ok, :authorized} =
               Shell.authorize_command(agent_id, "grep needle README.md",
                 approved_invocation: %{
                   request_id: "irq_validation",
                   principal_id: agent_id,
                   resource_uri: resource_uri,
                   decision: :approved
                 }
               )
    end

    test "security regression: Execute does not re-auth after approved_invocation", %{
      agent_id: agent_id
    } do
      # Shell is always-locked: even an :auto trust rule + held capability still
      # requires a one-shot approved_invocation marker. Pre-fix, authorize_command
      # accepted the marker but Shell.Execute then called Shell.authorize_and_execute,
      # which re-ran Security.authorize without Trust.ApprovalGuard — re-asking or
      # denying and leaving coding validation stuck at
      # "pending approval after approval".
      echo_uri = "arbor://shell/exec/echo"
      {:ok, profile} = Arbor.Trust.Store.get_profile(agent_id)

      :ok =
        Arbor.Trust.Store.store_profile(%{
          profile
          | rules: Map.put(profile.rules, echo_uri, :auto)
        })

      {:ok, _cap} = Arbor.Security.grant(principal: agent_id, resource: echo_uri)

      command = "echo shell-approval-ok"

      # No marker → gated: either pending_approval (escalated IRQ) or unauthorized.
      # Must NOT auto-run, and must NOT return the old misleading "try again and
      # the user will be prompted" string for plain :unauthorized.
      case Shell.Execute.run(%{command: command, sandbox: :none}, %{agent_id: agent_id}) do
        {:ok, :pending_approval, proposal_id} ->
          assert is_binary(proposal_id)

        {:error, msg} when is_binary(msg) ->
          refute msg =~ "will be submitted for user review"

        other ->
          flunk("expected gated shell without marker, got: #{inspect(other)}")
      end

      # With the exact approved-invocation marker, Execute must run without a
      # second Trust/Security re-auth that would re-ask.
      assert {:ok, result} =
               Shell.Execute.run(%{command: command, sandbox: :none}, %{
                 agent_id: agent_id,
                 approved_invocation: %{
                   request_id: "irq_shell_exec_regression",
                   principal_id: agent_id,
                   resource_uri: echo_uri,
                   decision: :approved
                 }
               })

      assert result.exit_code == 0
      assert result.stdout =~ "shell-approval-ok"
    end

    test "security regression: Execute with agent context rejects compounds as unavailable", %{
      agent_id: agent_id
    } do
      # Agent-authorized compounds always fail closed with the CapShell
      # unavailable string — independent of compound_shell_enabled.
      sleep_uri = "arbor://shell/exec/sleep"
      touch_uri = "arbor://shell/exec/touch"
      {:ok, profile} = Arbor.Trust.Store.get_profile(agent_id)

      :ok =
        Arbor.Trust.Store.store_profile(%{
          profile
          | rules:
              profile.rules
              |> Map.put(sleep_uri, :auto)
              |> Map.put(touch_uri, :auto)
              |> Map.put("arbor://shell/exec/**", :auto)
        })

      {:ok, _cap} = Arbor.Security.grant(principal: agent_id, resource: "arbor://shell/exec/**")

      prev = Application.get_env(:arbor_shell, :compound_shell_enabled)
      Application.delete_env(:arbor_shell, :compound_shell_enabled)

      marker =
        Path.join(
          System.tmp_dir!(),
          "actions_capshell_closed_#{System.unique_integer([:positive])}"
        )

      File.rm(marker)

      unavailable =
        "Compound shell execution is unavailable (security boundary incomplete). Use individual non-compound commands; CapShell is intentionally fail-closed."

      try do
        assert {:error, ^unavailable} =
                 Shell.Execute.run(
                   %{command: "sleep 1; touch #{marker}", sandbox: :basic},
                   %{
                     agent_id: agent_id,
                     approved_invocation: %{
                       request_id: "irq_capshell_closed_regression",
                       principal_id: agent_id,
                       resource_uri: "arbor://shell/exec/sleep",
                       decision: :approved
                     }
                   }
                 )

        Process.sleep(1_500)
        refute File.exists?(marker), "action must not route compound to unbounded CapShell"
      after
        File.rm(marker)

        if is_nil(prev),
          do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
          else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev)
      end
    end
  end

  describe "ExecuteScript" do
    @unavailable "Compound shell execution is unavailable (security boundary incomplete). Use individual non-compound commands; CapShell is intentionally fail-closed."

    test "is fail-closed unavailable (intentional security API break)" do
      script = """
      echo "line 1"
      echo "line 2"
      """

      assert Shell.ExecuteScript.run(%{script: script}, %{}) == {:error, @unavailable}

      assert Shell.ExecuteScript.run(%{script: "exit 42", sandbox: :none}, %{}) ==
               {:error, @unavailable}
    end

    test "does not create temporary script files" do
      before =
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "arbor_script_"))

      assert Shell.ExecuteScript.run(%{script: "echo test"}, %{}) == {:error, @unavailable}

      after_files =
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "arbor_script_"))

      assert after_files == before
    end

    test "validates action metadata" do
      assert Shell.ExecuteScript.name() == "shell_execute_script"
      assert Shell.ExecuteScript.description() =~ "script"
      assert "script" in Shell.ExecuteScript.tags()
    end

    test "generates tool schema" do
      tool = Shell.ExecuteScript.to_tool()
      assert is_map(tool)
      assert tool[:name] == "shell_execute_script"
    end
  end

  describe "Execute sandbox" do
    test "blocks dangerous commands", %{agent_context: context} do
      assert {:error, message} =
               Shell.Execute.run(%{command: "rm -rf /", sandbox: :basic}, context)

      assert message =~ "not allowed"
    end

    test "strict sandbox restricts to allowlist", %{agent_context: context} do
      assert {:error, message} =
               Shell.Execute.run(%{command: "curl http://example.com", sandbox: :strict}, context)

      assert message =~ "not allowed"
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
