defmodule Arbor.Shell.CapShellSecurityRegressionTest do
  @moduledoc """
  Security regressions for CapShell fail-closed (intentional API break).

  With broad shell capability and `compound_shell_enabled: true`, every public
  CapShell execution entry must return
  `{:error, {:compound_shell_unavailable, :security_boundary_incomplete}}`
  without side effects. Finite delayed/noisy commands must not create markers,
  output files, or Bash sessions.

  These tests fail on exact parent `dab2d315` (opt-in CapShell still executes)
  and pass on the fail-closed candidate.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore
  alias Arbor.Shell.CapShell

  @unavailable {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  # Outer wait after finite delayed commands (sleep 1) — bounded, not open-ended.
  @side_effect_wait_ms 1_500

  setup do
    ensure_security_started()

    prev = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled),
      compound: Application.get_env(:arbor_shell, :compound_shell_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_shell, :compound_shell_enabled, true)

    agent_id = "agent_capshell_sec_#{:erlang.unique_integer([:positive])}"
    grant_shell_capability(agent_id, "arbor://shell/exec/**")

    on_exit(fn ->
      restore_security(:reflex_checking_enabled, prev.reflex)
      restore_security(:capability_signing_required, prev.signing)
      restore_security(:strict_identity_mode, prev.identity)
      restore_security(:approval_guard_enabled, prev.approval)
      restore_security(:invocation_receipts_enabled, prev.receipts)

      if is_nil(prev.compound),
        do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
        else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev.compound)
    end)

    {:ok, agent_id: agent_id}
  end

  describe "security regression: config true still fail-closed" do
    test "direct facade + authorize_and_execute + CapShell.run all return unavailable",
         %{agent_id: agent_id} do
      assert Arbor.Shell.compound_shell_enabled?()

      command = "echo a && echo b"

      assert @unavailable =
               Arbor.Shell.execute_compound_with_capabilities(agent_id, command)

      assert @unavailable =
               Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :basic)

      assert @unavailable = CapShell.run(agent_id, command)
    end

    test "security regression: finite delayed touch never creates marker or session",
         %{agent_id: agent_id} do
      marker =
        Path.join(
          System.tmp_dir!(),
          "capshell_sec_touch_#{:erlang.unique_integer([:positive])}"
        )

      File.rm(marker)

      sessions_before = bash_session_count()
      command = "sleep 1; touch #{marker}"

      try do
        assert @unavailable =
                 Arbor.Shell.execute_compound_with_capabilities(agent_id, command)

        assert @unavailable =
                 Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :basic)

        assert @unavailable = CapShell.run(agent_id, command)

        Process.sleep(@side_effect_wait_ms)

        refute File.exists?(marker),
               "delayed compound touch must not execute under fail-closed CapShell"

        assert bash_session_count() <= sessions_before,
               "Bash.Session.list count must not grow from fail-closed CapShell entry"
      after
        File.rm(marker)
      end
    end

    test "security regression: noisy compound never creates output file or session",
         %{agent_id: agent_id} do
      out =
        Path.join(
          System.tmp_dir!(),
          "capshell_sec_noise_#{:erlang.unique_integer([:positive])}"
        )

      File.rm(out)

      sessions_before = bash_session_count()
      # Finite compound that parent dab2d315 would execute via CapShell and write
      # `out`. Avoid generators like `yes` (can hang under Bash pipe ownership).
      command = "printf 'noise\\n' | cat > #{out}"

      try do
        assert @unavailable =
                 Arbor.Shell.execute_compound_with_capabilities(agent_id, command)

        assert @unavailable =
                 Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :basic)

        assert @unavailable = CapShell.run(agent_id, command)

        Process.sleep(200)

        refute File.exists?(out),
               "compound output redirect must not write under fail-closed CapShell"

        assert bash_session_count() <= sessions_before,
               "Bash.Session.list count must not grow from fail-closed CapShell entry"
      after
        File.rm(out)
      end
    end
  end

  # ── helpers ──

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

  defp grant_shell_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_capshell_sec_#{:erlang.unique_integer([:positive])}",
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

  defp restore_security(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security(key, value), do: Application.put_env(:arbor_security, key, value)
end
