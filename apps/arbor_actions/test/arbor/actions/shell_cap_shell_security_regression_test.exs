defmodule Arbor.Actions.ShellCapShellSecurityRegressionTest do
  @moduledoc """
  Security regression: Actions.Shell compound/script residual bypasses.

  With broad shell capability, agent action surfaces must return a **stable
  exact** compound-shell unavailable failure and must not produce delayed
  filesystem side effects — for `compound_shell_enabled` true **and** false,
  and for `sandbox: :none`.

  Residual proofs (must fail on exact parent `9f91f62` and pass on candidate):
  - `authorize_command/3` rejects compounds before Trust (DOT shell handler path)
  - `Execute` with config false + sandbox:none cannot run nested `sh -c` compounds
  - `ExecuteScript` is fail-closed before temp-file/auth/process work
  """
  use Arbor.Actions.ActionCase, async: false
  @moduletag :fast

  alias Arbor.Actions.Shell

  @unavailable_tuple {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}

  @unavailable_message "Compound shell execution is unavailable (security boundary incomplete). Use individual non-compound commands; CapShell is intentionally fail-closed."

  @side_effect_wait_ms 1_500

  setup_all do
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

    prev = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled),
      compound: Application.get_env(:arbor_shell, :compound_shell_enabled)
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

      if is_nil(prev.compound),
        do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
        else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev.compound)
    end)

    agent_id = "agent_actions_capshell_sec_#{System.unique_integer([:positive])}"

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)

    :ok =
      Arbor.Trust.Store.store_profile(%{
        profile
        | rules:
            profile.rules
            |> Map.put("arbor://shell/exec/sleep", :auto)
            |> Map.put("arbor://shell/exec/touch", :auto)
            |> Map.put("arbor://shell/exec/sh", :auto)
            |> Map.put("arbor://shell/exec/bash", :auto)
            |> Map.put("arbor://shell/exec/**", :auto)
      })

    {:ok, _cap} = Arbor.Security.grant(principal: agent_id, resource: "arbor://shell/exec/**")

    {:ok, agent_id: agent_id}
  end

  test "security regression: Execute config true + sandbox:none returns exact unavailable and no delayed side effect",
       %{agent_id: agent_id} do
    assert_execute_residual_closed(agent_id, true)
  end

  test "security regression: Execute config false + sandbox:none returns exact unavailable and no delayed side effect",
       %{agent_id: agent_id} do
    assert_execute_residual_closed(agent_id, false)
  end

  test "security regression: Execute empty context + config true + sandbox:none rejects compound before emit/auth" do
    assert_execute_empty_context_compound_closed(true)
  end

  test "security regression: Execute empty context + config false + sandbox:none rejects compound before emit/auth" do
    assert_execute_empty_context_compound_closed(false)
  end

  test "security regression: authorize_command rejects compounds before Trust (DOT shell path)",
       %{agent_id: agent_id} do
    # Parent authorized leading token; DOT shell handler then ran /bin/sh -c.
    # Nested interpreter forms must also fail closed when the string carries
    # metacharacters (static leading-token grants are not a runtime proof).
    with_compound_shell(false, fn ->
      assert @unavailable_tuple =
               Shell.authorize_command(agent_id, "sleep 1; touch /tmp/x", [])

      assert @unavailable_tuple =
               Shell.authorize_command(agent_id, "sh -c 'sleep 1; touch /tmp/x'", sandbox: :none)

      assert @unavailable_tuple =
               Shell.authorize_command(agent_id, "echo a && echo b")
    end)
  end

  test "security regression: Execute rejects env-fed eval with no delayed background side effect",
       %{agent_id: agent_id} do
    marker =
      Path.join(
        System.tmp_dir!(),
        "actions_env_eval_#{System.unique_integer([:positive])}"
      )

    File.rm(marker)
    command = ~S(sh -c 'eval "$PAYLOAD"')
    env = %{"PAYLOAD" => "sleep 0.2 && touch #{marker} &"}

    try do
      result =
        Shell.Execute.run(
          %{command: command, sandbox: :none, env: env},
          %{
            agent_id: agent_id,
            approved_invocation: %{
              request_id: "irq_actions_env_eval",
              principal_id: agent_id,
              resource_uri: "arbor://shell/exec/sh",
              decision: :approved
            }
          }
        )

      Process.sleep(700)

      refute File.exists?(marker),
             "Shell.Execute env-fed eval launched a delayed background marker"

      assert result == {:error, "Generic agent shell executable is not allowed: sh"}
    after
      File.rm(marker)
    end
  end

  test "security regression: nested dispatch wrappers cannot tunnel to an interpreter",
       %{agent_id: agent_id} do
    marker =
      Path.join(
        System.tmp_dir!(),
        "actions_nested_wrapper_#{System.unique_integer([:positive])}"
      )

    File.rm(marker)
    command = "env nice /bin/sh -c 'touch #{marker}'"

    try do
      result =
        Shell.Execute.run(
          %{command: command, sandbox: :none},
          %{
            agent_id: agent_id,
            approved_invocation: %{
              request_id: "irq_actions_nested_wrapper",
              principal_id: agent_id,
              resource_uri: "arbor://shell/exec/env",
              decision: :approved
            }
          }
        )

      Process.sleep(200)
      refute File.exists?(marker), "nested env/nice/sh wrapper executed a marker"
      assert result == {:error, "Generic agent shell executable is not allowed: env"}

      for wrapper <- [
            "/usr/bin/env /bin/sh -c true",
            "command /bin/sh -c true",
            "exec /bin/sh -c true",
            "nice /bin/sh -c true",
            "nohup /bin/sh -c true",
            "timeout 1 /bin/sh -c true",
            "xargs /bin/sh -c true"
          ] do
        assert {:error, {:agent_executable_not_allowed, _name}} =
                 Shell.authorize_command(agent_id, wrapper, sandbox: :none)
      end
    after
      File.rm(marker)
    end
  end

  test "security regression: ExecuteScript is fail-closed before temp-file/auth/process work",
       %{agent_id: agent_id} do
    marker =
      Path.join(
        System.tmp_dir!(),
        "actions_execscript_sec_#{System.unique_integer([:positive])}"
      )

    File.rm(marker)
    tmp_before = arbor_script_tmp_count()

    script = """
    sleep 1
    touch #{marker}
    """

    try do
      # No agent — still unavailable (no system-only script escape hatch).
      assert Shell.ExecuteScript.run(%{script: script, sandbox: :none}, %{}) ==
               {:error, @unavailable_message}

      assert Shell.ExecuteScript.run(
               %{script: script, sandbox: :none},
               %{
                 agent_id: agent_id,
                 approved_invocation: %{
                   request_id: "irq_execscript_sec",
                   principal_id: agent_id,
                   resource_uri: "arbor://shell/exec/bash",
                   decision: :approved
                 }
               }
             ) == {:error, @unavailable_message}

      Process.sleep(@side_effect_wait_ms)
      refute File.exists?(marker)
      assert arbor_script_tmp_count() <= tmp_before
    after
      File.rm(marker)
    end
  end

  test "security regression: Execute config true ordinary compound returns exact unavailable",
       %{agent_id: agent_id} do
    with_compound_shell(true, fn ->
      assert Arbor.Shell.compound_shell_enabled?()

      marker =
        Path.join(
          System.tmp_dir!(),
          "actions_capshell_ord_#{System.unique_integer([:positive])}"
        )

      File.rm(marker)

      try do
        result =
          Shell.Execute.run(
            %{command: "sleep 1; touch #{marker}", sandbox: :basic},
            %{
              agent_id: agent_id,
              approved_invocation: %{
                request_id: "irq_capshell_ord",
                principal_id: agent_id,
                resource_uri: "arbor://shell/exec/sleep",
                decision: :approved
              }
            }
          )

        assert result == {:error, @unavailable_message}
        Process.sleep(@side_effect_wait_ms)
        refute File.exists?(marker)
      after
        File.rm(marker)
      end
    end)
  end

  test "ordinary single-command Execute still works", %{agent_id: agent_id} do
    assert {:ok, result} =
             Shell.Execute.run(
               %{command: "echo actions-single-ok", sandbox: :none},
               %{
                 agent_id: agent_id,
                 approved_invocation: %{
                   request_id: "irq_single_ok",
                   principal_id: agent_id,
                   resource_uri: "arbor://shell/exec/echo",
                   decision: :approved
                 }
               }
             )

    assert result.exit_code == 0
    assert result.stdout =~ "actions-single-ok"
  end

  defp assert_execute_residual_closed(agent_id, config_value) do
    with_compound_shell(config_value, fn ->
      marker =
        Path.join(
          System.tmp_dir!(),
          "actions_capshell_sec_#{System.unique_integer([:positive])}"
        )

      File.rm(marker)

      # Nested interpreter form: parent authorized leading `sh` only and
      # sandbox:none executed the full compound via the system shell.
      command = "sh -c 'sleep 1; touch #{marker}'"

      try do
        result =
          Shell.Execute.run(
            %{command: command, sandbox: :none},
            %{
              agent_id: agent_id,
              approved_invocation: %{
                request_id: "irq_capshell_sec_regression",
                principal_id: agent_id,
                resource_uri: "arbor://shell/exec/sh",
                decision: :approved
              }
            }
          )

        assert result == {:error, @unavailable_message}

        Process.sleep(@side_effect_wait_ms)

        refute File.exists?(marker),
               "action path must not execute delayed compound (config=#{inspect(config_value)}, sandbox:none)"
      after
        File.rm(marker)
      end
    end)
  end

  # Missing agent_id must not grant implicit system authority for compounds.
  # Pre-fix: call_shell fell through to Arbor.Shell.execute/2 with sandbox:none
  # and could create delayed markers / sessions / approvals.
  defp assert_execute_empty_context_compound_closed(config_value) do
    with_compound_shell(config_value, fn ->
      marker =
        Path.join(
          System.tmp_dir!(),
          "actions_empty_ctx_#{System.unique_integer([:positive])}"
        )

      File.rm(marker)
      sessions_before = bash_session_count()
      execs_before = execution_count()

      command = "sh -c 'sleep 1; touch #{marker}'"

      try do
        # Explicit empty context — no agent_id, no approved_invocation.
        assert Shell.Execute.run(%{command: command, sandbox: :none}, %{}) ==
                 {:error, @unavailable_message}

        # Also plain sequencing form.
        assert Shell.Execute.run(
                 %{command: "sleep 1; touch #{marker}", sandbox: :none},
                 %{}
               ) == {:error, @unavailable_message}

        Process.sleep(@side_effect_wait_ms)

        refute File.exists?(marker),
               "empty-context Execute must not run compounds (config=#{inspect(config_value)})"

        assert bash_session_count() <= sessions_before
        assert execution_count() <= execs_before
      after
        File.rm(marker)
      end
    end)
  end

  defp bash_session_count do
    case Code.ensure_loaded(Bash.Session) do
      {:module, _} ->
        if function_exported?(Bash.Session, :list, 0) or
             function_exported?(Bash.Session, :list, 1) do
          length(Bash.Session.list())
        else
          0
        end

      _ ->
        0
    end
  end

  defp execution_count do
    case Arbor.Shell.list_executions([]) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp with_compound_shell(value, fun) when is_function(fun, 0) do
    prev = Application.get_env(:arbor_shell, :compound_shell_enabled)
    Application.put_env(:arbor_shell, :compound_shell_enabled, value)

    try do
      fun.()
    after
      if is_nil(prev),
        do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
        else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev)
    end
  end

  defp arbor_script_tmp_count do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.count(&String.starts_with?(&1, "arbor_script_"))
  rescue
    _ -> 0
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
