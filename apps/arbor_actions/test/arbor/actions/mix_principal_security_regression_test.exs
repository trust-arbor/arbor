defmodule Arbor.Actions.MixPrincipalSecurityRegressionTest do
  @moduledoc """
  Security regression: Mix Jido actions must not launch mix without an
  authorized principal.

  Parent behavior (must fail on checkout of the exact parent):
  Compile, Test, and Format call `run_with_required_workspace/5` (`run_mix/3`
  → Shell execute_direct / execute_spawn_capable) while ignoring context, so a
  direct `run/2` that only supplies a path proceeds past the principal gate.

  Fixed behavior: they require `authorized_principal`. The authorized path is
  `Arbor.Actions.authorize_and_execute/4` then existing Mix TCB
  (`run_with_required_workspace/5`). Missing envelope uses
  `Actions.unauthorized_message/1` and never falls back to execute_direct.
  Mix is not sent through `Shell.authorize_and_execute/3`. Host `run_mix/3`
  and `run_with_required_workspace/5` stay callable without a principal.
  """
  use Arbor.Actions.ActionCase, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Mix, as: MixAction

  @unauthorized_runs [
    {MixAction.Compile, %{path: "/nonexistent/project"}},
    {MixAction.Test, %{path: "/nonexistent/project"}},
    {MixAction.Format, %{path: "/nonexistent/project", check_only: true}}
  ]

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

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

    agent_id = "agent_p1d_mix_#{System.unique_integer([:positive])}"

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

  test "security regression: Mix action run/2 without the envelope does not call Shell.execute_direct" do
    for {module, params} <- @unauthorized_runs do
      {calls, result} =
        with_host_shell_trace(fn ->
          module.run(params, %{})
        end)

      assert {:error, "Unauthorized: :action_principal_authority_required"} = result,
             "#{inspect(module)} direct path-only run/2: #{inspect(result)}"

      assert calls == [], "#{inspect(module)} launched host shell: #{inspect(calls)}"
    end
  end

  test "security regression: Mix action run/2 with a spoofed agent_id does not call Shell.execute_direct" do
    for {module, params} <- @unauthorized_runs do
      {calls, result} =
        with_host_shell_trace(fn ->
          module.run(params, %{agent_id: "agent_spoof"})
        end)

      assert {:error, "Unauthorized: :action_principal_authority_required"} = result,
             "#{inspect(module)} spoofed agent_id run/2: #{inspect(result)}"

      assert calls == [], "#{inspect(module)} launched host shell: #{inspect(calls)}"
    end
  end

  test "security regression: host run_mix/run_with_required_workspace with no principal still run" do
    {calls, run_mix_result} =
      with_host_shell_trace(fn ->
        MixAction.run_mix("/nonexistent/project", ["compile"])
      end)

    assert {:error, :validation_resource_required} = run_mix_result
    refute :authorize_and_execute in calls

    {tcb_calls, tcb_result} =
      with_host_shell_trace(fn ->
        MixAction.run_with_required_workspace(
          "/nonexistent/project",
          ["compile"],
          %{path: "/nonexistent/project"},
          %{},
          []
        )
      end)

    assert {:error, :workspace_id_required} = tcb_result
    refute :authorize_and_execute in tcb_calls
  end

  test "security regression: authorized Compile uses Mix TCB and does not call Shell.authorize_and_execute",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, "arbor://action/mix/compile")

    {calls, result} =
      with_host_shell_trace(fn ->
        Arbor.Actions.authorize_and_execute(
          agent_id,
          MixAction.Compile,
          %{path: "/nonexistent/project"},
          %{agent_id: agent_id}
        )
      end)

    assert {:error, message} = result
    assert is_binary(message)
    refute message == "Unauthorized: :action_principal_authority_required"
    refute :authorize_and_execute in calls
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
    :erlang.trace_pattern({Arbor.Shell, :execute_spawn_capable, 3}, true, [])
    :erlang.trace_pattern({Arbor.Shell, :authorize_and_execute, 3}, true, [])
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
      :erlang.trace_pattern({Arbor.Shell, :execute_spawn_capable, 3}, false, [])
      :erlang.trace_pattern({Arbor.Shell, :authorize_and_execute, 3}, false, [])
    end
  end

  defp tracer_loop(parent, acc) do
    receive do
      {:trace, _pid, :call, {Arbor.Shell, fun, _args}}
      when fun in [:execute, :execute_direct, :execute_spawn_capable, :authorize_and_execute] ->
        tracer_loop(parent, [fun | acc])

      :done ->
        send(parent, {:host_shell_calls, Enum.reverse(acc)})
    after
      1_000 ->
        send(parent, {:host_shell_calls, Enum.reverse(acc)})
    end
  end
end
