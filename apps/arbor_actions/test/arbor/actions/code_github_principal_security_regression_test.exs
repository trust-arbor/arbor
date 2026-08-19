defmodule Arbor.Actions.CodeGithubPrincipalSecurityRegressionTest do
  @moduledoc """
  Security regression: Code.CompileAndTest and Github.PR must not launch
  through trusted-system Shell.execute/execute_direct.

  Parent behavior (must fail on checkout of the exact parent):
  both actions call `Arbor.Shell.execute/2` without an authorized principal,
  so a direct `run/2` starts a host process.

  Fixed behavior: they require `authorized_principal` and use
  `Arbor.Shell.authorize_and_execute/3`. If that API cannot run mix/gh,
  they return its error and never fall back to execute.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Code
  alias Arbor.Actions.Github

  @code_resource "arbor://code/compile"
  @github_resource "arbor://action/github/pr"

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    previous = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      trust_approval: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    agent_id = "agent_p1b_code_github_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(agent_id)
      end

      if Process.whereis(Arbor.Trust.Store) do
        Arbor.Trust.Store.delete_profile(agent_id)
      end

      restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
      restore(:arbor_security, :capability_signing_required, previous.signing)
      restore(:arbor_security, :identity_verification, previous.identity)
      restore(:arbor_security, :strict_identity_mode, previous.strict)
      restore(:arbor_security, :uri_registry_enforcement, previous.uri)
      restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
      restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
      restore(:arbor_trust, :approval_guard_enabled, previous.trust_approval)
      restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
    end)

    {:ok, agent_id: agent_id}
  end

  test "security regression: CompileAndTest.run/2 without the envelope does not call Shell.execute/execute_direct" do
    {calls, result} =
      with_host_shell_trace(fn ->
        Code.CompileAndTest.run(
          %{file: "lib/my_module.ex", compile_only: true},
          %{worktree_path: "/nonexistent/path", agent_id: "agent_spoof"}
        )
      end)

    assert {:error, "Code compile requires a facade-issued authenticated principal envelope."} =
             result

    assert calls == []
  end

  test "security regression: Github.PR.run/2 without the envelope does not call Shell.execute/execute_direct" do
    {calls, result} =
      with_host_shell_trace(fn ->
        Github.PR.run(
          %{path: "/nonexistent/repo", title: "Spoofed PR"},
          %{agent_id: "agent_spoof"}
        )
      end)

    assert {:error, "GitHub PR requires a facade-issued authenticated principal envelope."} =
             result

    assert calls == []
  end

  test "security regression: authorized CompileAndTest returns the mix policy error and does not fall back to execute",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, @code_resource)

    {calls, result} =
      with_host_shell_trace(fn ->
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Code.CompileAndTest,
          %{file: "lib/my_module.ex", compile_only: true},
          %{agent_id: agent_id, worktree_path: "/nonexistent/path"}
        )
      end)

    assert {:error, {:agent_executable_not_allowed, "mix"}} = result
    assert calls == []
  end

  test "security regression: authorized Github.PR returns the gh policy error and does not fall back to execute",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, @github_resource)

    {calls, result} =
      with_host_shell_trace(fn ->
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Github.PR,
          %{path: "/nonexistent/repo", title: "Authorized PR"},
          %{agent_id: agent_id}
        )
      end)

    assert {:error, "Failed to open PR: {:agent_executable_not_allowed, \"gh\"}"} = result
    assert calls == []
  end

  defp authorize_agent(agent_id, resource) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: %{resource => :auto}})
    assert {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: resource)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp with_host_shell_trace(fun) do
    parent = self()

    tracer =
      spawn_link(fn ->
        tracer_loop(parent, [])
      end)

    :erlang.trace_pattern({Arbor.Shell, :execute, 2}, true, [])
    :erlang.trace_pattern({Arbor.Shell, :execute_direct, 3}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      send(tracer, :done)

      receive do
        {:host_shell_calls, calls} -> {calls, result}
      after
        1_000 -> flunk("timed out waiting for host-shell tracer")
      end
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Arbor.Shell, :execute, 2}, false, [])
      :erlang.trace_pattern({Arbor.Shell, :execute_direct, 3}, false, [])
    end
  end

  defp tracer_loop(parent, acc) do
    receive do
      {:trace, _pid, :call, {Arbor.Shell, fun, _args}}
      when fun in [:execute, :execute_direct] ->
        tracer_loop(parent, [fun | acc])

      :done ->
        send(parent, {:host_shell_calls, Enum.reverse(acc)})
    after
      1_000 ->
        send(parent, {:host_shell_calls, Enum.reverse(acc)})
    end
  end
end
