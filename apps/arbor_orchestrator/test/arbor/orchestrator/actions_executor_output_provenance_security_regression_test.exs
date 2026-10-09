defmodule Arbor.Orchestrator.ActionsExecutorOutputProvenanceSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Orchestrator.TestFixtures.{ProvenanceIngress, ProvenanceSink}
  alias Arbor.Trust.Store, as: TrustStore

  setup do
    unless Process.whereis(ActionRegistry), do: start_supervised!(ActionRegistry)
    unless Process.whereis(TrustStore), do: start_supervised!(TrustStore)
    registry_owner = Process.whereis(ActionRegistry)
    trust_owner = Process.whereis(TrustStore)
    snapshot = ActionRegistry.snapshot()

    on_exit(fn ->
      if Process.alive?(registry_owner) and Process.whereis(ActionRegistry) == registry_owner,
        do: ActionRegistry.restore(snapshot)
    end)

    for module <- [ProvenanceIngress, ProvenanceSink] do
      registry_name = "test.#{module.name()}"

      case ActionRegistry.resolve(registry_name) do
        {:ok, ^module} ->
          :ok

        {:error, :not_found} ->
          :ok = ActionRegistry.register(registry_name, module)

        other ->
          flunk("provenance fixture name already belongs to another action: #{inspect(other)}")
      end
    end

    settings = [
      {:arbor_orchestrator, :provenance_probe_owner, self()},
      {:arbor_orchestrator, :provenance_probe_drift, false},
      {:arbor_orchestrator, :provenance_probe_idempotency, :idempotent}
    ]

    prior =
      Enum.map(settings, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    on_exit(fn ->
      Enum.each(prior, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    Enum.each(settings, fn {app, key, value} -> Application.put_env(app, key, value) end)

    agent_id = "agent_bound_provenance_#{System.unique_integer([:positive])}"

    resources =
      Enum.map([ProvenanceIngress, ProvenanceSink], &Arbor.Actions.canonical_uri_for(&1, %{}))

    {:ok, profile} = Profile.new(agent_id)
    :ok = TrustStore.store_profile(%{profile | rules: Map.new(resources, &{&1, :auto})})

    for resource <- resources do
      Arbor.Orchestrator.TestCapabilities.grant_capability(agent_id, resource)
    end

    Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(agent_id)
    root = Path.join(System.tmp_dir!(), "bound_provenance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      Arbor.Orchestrator.TestCapabilities.revoke_all(agent_id)

      if Process.alive?(trust_owner) and Process.whereis(TrustStore) == trust_owner,
        do: TrustStore.delete_profile(agent_id)

      File.rm_rf!(root)
    end)

    %{agent_id: agent_id, root: root}
  end

  test "security regression: post-effect descriptor drift cannot erase ingress provenance", c do
    Application.put_env(:arbor_orchestrator, :provenance_probe_drift, true)
    run = run!(c)
    assert_received :ingress_effect
    assert run.final_outcome.status == :fail, inspect(run.final_outcome)
    assert run.final_outcome.failure_reason =~ "taint_blocked"
    assert run.taint["incoming.payload"].level == :hostile
    refute_received :provenance_read
    refute_received :control_effect
  end

  test "unchanged ingress retains declared provenance at the downstream control gate", c do
    run = run!(c)
    assert_received :ingress_effect
    assert_received :provenance_read
    assert run.final_outcome.status == :fail, inspect(run.final_outcome)
    assert run.final_outcome.failure_reason =~ "taint_blocked"
    assert run.taint["incoming.payload"].level == :untrusted
    refute_received :control_effect
  end

  test "security regression: invalid bindings never become absent optional provenance" do
    for binding <- [nil, %{}, %{action_name: "unknown"}] do
      assert ActionsExecutor.output_taint_bound(binding, %{}) == :hostile
    end
  end

  test "security regression: failed or malformed provenance callbacks remain hostile" do
    {:ok, binding} = ActionsExecutor.resolve_execution_binding("test.#{ProvenanceIngress.name()}")

    for failure <- ["raise", "exit", "throw", "malformed"] do
      assert ActionsExecutor.output_taint_bound(binding, %{"failure" => failure}) == :hostile
    end
  end

  test "a verified action with no optional provenance callback still returns nil" do
    {:ok, binding} = ActionsExecutor.resolve_execution_binding("test.#{ProvenanceSink.name()}")
    assert ActionsExecutor.output_taint_bound(binding, %{}) == nil
  end

  defp run!(c) do
    dot = """
    digraph Provenance {
      start [shape=Mdiamond]
      ingress [type=exec, target=action, action="test.bound_provenance_ingress", output_prefix="incoming"]
      copy [type=transform, transform=identity, source_key="incoming.payload", output_key="payload"]
      sink [type=exec, target=action, action="test.bound_provenance_sink", context_keys="payload"]
      done [shape=Msquare]
      start -> ingress -> copy -> sink -> done
    }
    """

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               agent_id: c.agent_id,
               workdir: c.root,
               logs_root: Path.join(c.root, "logs"),
               resumable: false,
               initial_values: %{"session.agent_id" => c.agent_id}
             )

    result
  end
end
