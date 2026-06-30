defmodule Arbor.Shell.CapShellTest do
  @moduledoc """
  Prototype tests for capability-checked compound shell execution
  (`Arbor.Shell.CapShell`). Proves the security invariants the spike found:
  compound commands run when caps cover every command, and a denied command is
  blocked even inside a pipe or `$(…)` substitution — the escape hatches the
  single-command sandbox hard-rejects.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore
  alias Arbor.Shell.CapShell

  defp allow_all_paths, do: [paths: fn _ -> true end]

  setup do
    {:ok, _} = Application.ensure_all_started(:bash)
    ensure_security_started()

    prev = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)

    on_exit(fn ->
      restore_config(:reflex_checking_enabled, prev.reflex)
      restore_config(:capability_signing_required, prev.signing)
      restore_config(:strict_identity_mode, prev.identity)
      restore_config(:approval_guard_enabled, prev.approval)
      restore_config(:invocation_receipts_enabled, prev.receipts)
    end)

    {:ok, agent_id: "agent_capshell_#{:erlang.unique_integer([:positive])}"}
  end

  describe "compound commands run when caps cover every command" do
    test "a pipeline of an allowed builtin + granted external runs", %{agent_id: agent_id} do
      # echo is a shell builtin (always allowed); grep is external (needs a cap).
      grant(agent_id, "arbor://shell/exec/grep")

      assert {:ok, r} = CapShell.run(agent_id, "echo hello | grep hello", allow_all_paths())
      assert r.success?
      assert r.stdout =~ "hello"
    end

    test "git && echo runs when git is granted (git was blocked by the old :strict list)",
         %{agent_id: agent_id} do
      grant(agent_id, "arbor://shell/exec/git")

      assert {:ok, r} = CapShell.run(agent_id, "git --version && echo ok", allow_all_paths())
      assert r.success?
      assert r.stdout =~ "ok"
    end
  end

  describe "denied commands are blocked across the escape hatches" do
    test "a denied command inside $(…) substitution does NOT execute", %{agent_id: agent_id} do
      # echo (builtin) allowed; rm NOT granted. The classic injection escape.
      target = tmp_file("subst")
      File.write!(target, "survive")

      assert {:ok, r} = CapShell.run(agent_id, "echo x=$(rm #{target})", allow_all_paths())

      assert File.exists?(target),
             "rm inside $(…) must be blocked by the capability policy"

      assert r.stderr =~ "not allowed"
      File.rm(target)
    end

    test "a denied command in a pipe is blocked", %{agent_id: agent_id} do
      assert {:ok, r} = CapShell.run(agent_id, "echo hi | rm -rf /tmp/capshell_nope", allow_all_paths())
      assert r.stderr =~ "not allowed"
    end

    test "an external command with no capability is denied", %{agent_id: agent_id} do
      # no grants — git is external and not held.
      target = tmp_file("nocap")
      File.write!(target, "survive")

      assert {:ok, r} = CapShell.run(agent_id, "git --version", allow_all_paths())
      assert r.stderr =~ "not allowed"
      File.rm(target)
    end

    test "the absolute floor blocks rm even when explicitly granted", %{agent_id: agent_id} do
      grant(agent_id, "arbor://shell/exec/rm")
      target = tmp_file("floor")
      File.write!(target, "survive")

      assert {:ok, r} = CapShell.run(agent_id, "rm #{target}", allow_all_paths())

      assert File.exists?(target),
             "rm must be blocked by the absolute floor even when the cap is granted"

      assert r.stderr =~ "not allowed"
      File.rm(target)
    end
  end

  describe "filesystem path policy" do
    test "a redirect to a denied path is blocked", %{agent_id: agent_id} do
      denied = tmp_file("redir")
      File.rm(denied)

      # path policy denies anything containing the denied marker.
      paths = [paths: fn p -> not String.contains?(p, Path.basename(denied)) end]

      assert {:ok, _r} = CapShell.run(agent_id, "echo pwned > #{denied}", paths)
      refute File.exists?(denied), "redirect to a path-policy-denied target must be blocked"
    end

    test "a redirect to an allowed path succeeds", %{agent_id: agent_id} do
      allowed = tmp_file("ok")
      File.rm(allowed)

      assert {:ok, _r} = CapShell.run(agent_id, "echo good > #{allowed}", paths: fn _ -> true end)
      assert File.exists?(allowed)
      assert File.read!(allowed) =~ "good"
      File.rm(allowed)
    end
  end

  describe "parse errors" do
    test "unparseable input returns a parse error", %{agent_id: agent_id} do
      assert {:error, {:parse_error, _msg}} = CapShell.run(agent_id, "if then fi fi )(", allow_all_paths())
    end
  end

  # ── helpers ──

  defp tmp_file(tag),
    do: Path.join(System.tmp_dir!(), "capshell_#{tag}_#{:erlang.unique_integer([:positive])}")

  defp grant(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_capshell_#{:erlang.unique_integer([:positive])}",
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

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)
end
