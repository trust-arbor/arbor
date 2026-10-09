defmodule Arbor.Orchestrator.Engine.NativeParameterizedResourceSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Security

  @action "native_resource_probe"
  @resource "arbor://action/test/native_resource_probe/allowed"

  alias Arbor.Orchestrator.Test.{
    NativeResourceCustomExecHandler,
    NativeResourceCustomActionsExecutor
  }

  setup_all do
    # Keep the real registry owner alive through each test's restore callback.
    # Its central table owner may otherwise retain entries after a test-owned
    # GenServer has stopped before on_exit executes.
    unless Process.whereis(ActionRegistry), do: start_supervised!(ActionRegistry)
    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)
    unless Process.whereis(Arbor.Trust.PolicyHost), do: start_supervised!(Arbor.Trust.PolicyHost)
    unless Process.whereis(Arbor.Trust.Manager), do: start_supervised!(Arbor.Trust.Manager)
    :ok
  end

  setup do
    snapshot = ActionRegistry.snapshot()
    on_exit(fn -> if Process.whereis(ActionRegistry), do: ActionRegistry.restore(snapshot) end)

    for {name, module} <- [
          {@action, Arbor.Actions.Test.NativeResourceProbe},
          {"native_resource_facade_probe", Arbor.Actions.Test.NativeResourceFacadeProbe}
        ] do
      case ActionRegistry.resolve(name) do
        {:ok, ^module} -> :ok
        {:error, :not_found} -> :ok = ActionRegistry.register(name, module)
      end
    end

    Process.register(self(), :native_resource_probe_observer)

    env = [
      {:arbor_security, :identity_verification, false},
      {:arbor_security, :capability_signing_required, false},
      {:arbor_security, :strict_identity_mode, false},
      {:arbor_security, :uri_registry_enforcement, false},
      {:arbor_security, :reflex_checking_enabled, false},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_trust, :approval_guard_enabled, true},
      {:arbor_trust, :policy_module, Arbor.Trust.Policy},
      {:arbor_trust, :policy_enforcer_enabled, true},
      {:arbor_actions, :default_taint_policy, :strict}
    ]

    for {app, key, value} <- env do
      old = Application.fetch_env(app, key)

      on_exit(fn ->
        case old do
          {:ok, previous} -> Application.put_env(app, key, previous)
          :error -> Application.delete_env(app, key)
        end
      end)

      Application.put_env(app, key, value)
    end

    suffix = System.unique_integer([:positive, :monotonic])
    assert {:ok, identity} = Identity.generate(name: "native-resource-#{suffix}")
    assert :ok = Security.register_identity_fixture(Identity.public_only(identity))
    principal = identity.agent_id
    task = "native-resource-task-#{suffix}"
    session = "native-resource-session-#{suffix}"

    assert {:ok, _} =
             Arbor.Trust.ensure_trust_profile(principal,
               baseline: :block,
               rules: %{@resource => :allow}
             )

    assert Arbor.Trust.effective_mode(principal, @resource) == :allow

    on_exit(fn ->
      Security.revoke_by_task_fixture(task)
      Arbor.Trust.delete_trust_profile(principal)
      _ = Security.deregister_identity_fixture(principal)
    end)

    # This generic middleware fixture supplies trusted in-process source control
    # only. Actual native notice role/custody is covered by the Agent journey.
    opts = [
      authorization: true,
      agent_id: principal,
      caller_id: principal,
      task_id: task,
      session_id: session,
      workdir: File.cwd!(),
      authorizer: fn _principal, _type -> :ok end,
      # Session-scoped execution signs a one-use JIT grant payload and the
      # action resource with the caller's registered key.
      signer: fn payload ->
        SignedRequest.sign(payload, identity.agent_id, identity.private_key)
      end,
      resumable: false,
      conversation_source: %{
        session_pid: self(),
        generation: make_ref(),
        handle: {self(), make_ref()}
      }
    ]

    %{principal: principal, task: task, session: session, opts: opts}
  end

  test "security regression: public Engine resolves the exact parameterized grant without a coarse grant or second charge",
       c do
    cap = grant!(c, @resource, constraints: %{rate_limit: 2})
    assert {:ok, result} = Arbor.Orchestrator.run(dot("allowed", "valid"), c.opts)
    assert result.final_outcome.status == :success
    assert_received {:native_resource_probe_ran, %{target: "allowed", mode: "valid"}}
    # Actual action admission used one allowance; middleware resource resolution
    # did not spend a second one. Observe the same public Security boundary.
    assert {:ok, :authorized} =
             Security.authorize(c.principal, @resource, :execute,
               task_id: c.task,
               session_id: c.session
             )

    assert {:error, _} =
             Security.authorize(c.principal, @resource, :execute,
               task_id: c.task,
               session_id: c.session
             )

    assert :ok = Security.revoke_fixture(cap.id)
  end

  test "security regression: sibling and coarse grants never authorize the resolved resource",
       c do
    for resource <- [
          "arbor://action/test/native_resource_probe/sibling",
          "arbor://action/test/native_resource_probe"
        ] do
      cap = grant!(c, resource)
      assert {:ok, result} = Arbor.Orchestrator.run(dot("allowed", "valid"), c.opts)
      assert result.final_outcome.status == :fail
      assert result.final_outcome.failure_reason =~ "native_action_preflight_refused"
      refute_received {:native_resource_probe_ran, _}
      assert :ok = Security.revoke_fixture(cap.id)
    end

    assert {:ok, no_grant} = Arbor.Orchestrator.run(dot("allowed", "valid"), c.opts)
    assert no_grant.final_outcome.status == :fail
    refute_received {:native_resource_probe_ran, _}
  end

  test "security regression: exact runtime context arguments win before resource lookup and execution",
       c do
    grant!(c, @resource)

    graph =
      String.replace(
        dot("sibling", "valid"),
        "param.mode=",
        "context_keys=\"choice.target\", param.mode="
      )

    assert {:ok, result} =
             Arbor.Orchestrator.run(
               graph,
               Keyword.put(c.opts, :initial_values, %{"choice.target" => "allowed"})
             )

    assert result.final_outcome.status == :success
    assert_received {:native_resource_probe_ran, %{target: "allowed", mode: "valid"}}
  end

  test "security regression: present resource hook refusal, malformed and oversized outputs fail closed without canonical fallback",
       c do
    grant!(c, "arbor://action/test/native_resource_probe")

    for mode <- ["error", "malformed", "oversized"] do
      assert {:ok, result} = Arbor.Orchestrator.run(dot("allowed", mode), c.opts)
      assert result.final_outcome.status == :fail
      refute_received {:native_resource_probe_ran, _}
    end
  end

  test "security regression: declared Actions facade owner admits an autonomous exact grant once",
       c do
    grant!(c, @resource, constraints: %{rate_limit: 2})
    opts = pinned_facade_opts!(Keyword.delete(c.opts, :conversation_source))
    assert {:ok, result} = Arbor.Orchestrator.run(facade_dot(), opts)
    assert result.final_outcome.status == :success
    assert_received {:native_resource_probe_ran, %{target: "allowed", mode: "valid"}}

    assert {:ok, :authorized} =
             Security.authorize(c.principal, @resource, :execute,
               task_id: c.task,
               session_id: c.session
             )

    assert {:error, _} =
             Security.authorize(c.principal, @resource, :execute,
               task_id: c.task,
               session_id: c.session
             )
  end

  test "security regression: declared owner retains no-grant, sibling, caller and blocked Trust gates",
       c do
    opts = pinned_facade_opts!(Keyword.delete(c.opts, :conversation_source))

    for uri <- [nil, "arbor://action/test/native_resource_probe/sibling"] do
      cap = if uri, do: grant!(c, uri), else: nil
      assert {:ok, result} = Arbor.Orchestrator.run(facade_dot(), opts)
      assert result.final_outcome.status == :fail
      refute_received {:native_resource_probe_ran, _}
      if cap, do: Security.revoke_fixture(cap.id)
    end

    grant!(c, @resource)

    assert {:ok, caller_denied} =
             Arbor.Orchestrator.run(
               facade_dot(),
               Keyword.put(opts, :caller_id, c.principal <> "_other")
             )

    assert caller_denied.final_outcome.status == :fail
    refute_received {:native_resource_probe_ran, _}
    assert {:ok, _} = Arbor.Trust.ensure_trust_profile(c.principal, baseline: :block, rules: %{})
    assert Arbor.Trust.effective_mode(c.principal, @resource) == :block
    assert {:ok, trust_denied} = Arbor.Orchestrator.run(facade_dot(), opts)
    assert trust_denied.final_outcome.status == :fail
    refute_received {:native_resource_probe_ran, _}
  end

  test "security regression: graph/context/options cannot spoof owner metadata and malformed code declaration refuses",
       c do
    grant!(c, @resource)

    opts =
      c.opts
      |> Keyword.delete(:conversation_source)
      |> Keyword.put(:authorization_admission_owner, :actions_facade)
      |> Keyword.put(:initial_values, %{"authorization_admission_owner" => "actions_facade"})

    graph =
      String.replace(
        dot("allowed", "valid"),
        "param.target=",
        "authorization_admission_owner=actions_facade, param.target="
      )

    assert {:ok, ordinary} = Arbor.Orchestrator.run(graph, opts)
    assert ordinary.final_outcome.status == :fail
    refute_received {:native_resource_probe_ran, _}

    :ok =
      ActionRegistry.register(
        "native_resource_malformed_owner_probe",
        Arbor.Actions.Test.NativeResourceMalformedOwnerProbe
      )

    malformed =
      String.replace(
        facade_dot(),
        "native_resource_facade_probe",
        "native_resource_malformed_owner_probe"
      )

    assert {:error, {:execution_classification_failed, "effect", :invalid_action_admission_owner}} =
             Arbor.Orchestrator.run(malformed, opts)

    refute_received {:native_resource_probe_ran, _}
  end

  test "security regression: declared facade owner cannot defer to injected handlers or executors",
       c do
    grant!(c, @resource)
    opts = pinned_facade_opts!(Keyword.delete(c.opts, :conversation_source))
    alias Arbor.Orchestrator.Handlers.Registry
    handlers = Registry.snapshot_fixtures()
    on_exit(fn -> Registry.restore_fixtures(handlers) end)

    assert {:error, {:unbound_authorized_override, :actions_executor}} =
             Arbor.Orchestrator.run(
               facade_dot(),
               Keyword.put(opts, :actions_executor, NativeResourceCustomActionsExecutor)
             )

    refute_received :custom_facade_executor_effect
    refute_received {:native_resource_probe_ran, _}

    :ok = Registry.register_fixture("exec", NativeResourceCustomExecHandler)

    assert {:error, {:unbound_custom_handler, "effect"}} =
             Arbor.Orchestrator.run(facade_dot(), opts)

    :ok = Registry.unregister_fixture("exec")

    on_event = fn
      %{type: :pipeline_started} ->
        Registry.register_fixture("exec", NativeResourceCustomExecHandler)

      _ ->
        :ok
    end

    assert {:ok, handler_denied} =
             Arbor.Orchestrator.run(facade_dot(), Keyword.put(opts, :on_event, on_event))

    assert handler_denied.final_outcome.status == :fail
    assert handler_denied.final_outcome.failure_reason =~ "handler execution binding rejected"
    refute_received :custom_facade_handler_effect
    refute_received {:native_resource_probe_ran, _}
  end

  test "security regression: reviewed current action binding cannot omit or change the declared owner",
       c do
    grant!(c, @resource)
    assert {:ok, graph} = Arbor.Orchestrator.compile(facade_dot())
    module = Arbor.Actions.Test.NativeResourceFacadeProbe
    assert {:ok, descriptor} = Arbor.Actions.runtime_descriptor(module)
    assert descriptor["authorization_admission_owner"] == "actions_facade"

    assert {:ok, catalog} =
             Arbor.Orchestrator.CodingPlan.ActionCatalog.snapshot(modules: [module])

    alias Arbor.Orchestrator.CodingPlan.ExecutionManifest
    hash = Arbor.Orchestrator.Engine.RunAuthorization.graph_hash(graph)
    assert {:ok, {manifest, _digest}} = ExecutionManifest.build(graph, catalog, hash)

    assert {:ok, positive} =
             Arbor.Orchestrator.run(
               graph,
               Keyword.merge(Keyword.delete(c.opts, :conversation_source),
                 execution_manifest: manifest,
                 execution_manifest_digest: elem(ExecutionManifest.digest(manifest), 1)
               )
             )

    assert positive.final_outcome.status == :success
    assert_received {:native_resource_probe_ran, _}

    for mutate <- [
          &Map.delete(&1, "authorization_admission_owner"),
          &Map.put(&1, "authorization_admission_owner", "ordinary")
        ] do
      changed = update_in(manifest["actions"], &Enum.map(&1, mutate))
      assert {:ok, digest} = ExecutionManifest.digest(changed)

      assert {:error, _} =
               Arbor.Orchestrator.run(
                 graph,
                 Keyword.merge(Keyword.delete(c.opts, :conversation_source),
                   execution_manifest: changed,
                   execution_manifest_digest: digest
                 )
               )

      refute_received {:native_resource_probe_ran, _}
    end
  end

  test "security regression: nil or partial native owner pins cannot be repaired by graph options",
       c do
    grant!(c, @resource)
    opts = Keyword.delete(c.opts, :conversation_source)
    assert {:ok, unpinned} = Arbor.Orchestrator.run(facade_dot(), opts)
    assert unpinned.final_outcome.status == :fail
    assert unpinned.final_outcome.failure_reason =~ "invalid_action_authorization_resource"
    refute_received {:native_resource_probe_ran, _}

    assert {:ok, graph} = Arbor.Orchestrator.compile(facade_dot())
    partial = Keyword.put(opts, :execution_manifest_digest, String.duplicate("a", 64))
    assert {:ok, ^partial} = Arbor.Orchestrator.pin_native_execution(graph, partial)
    assert {:error, :invalid_execution_manifest_binding} = Arbor.Orchestrator.run(graph, partial)
    refute_received {:native_resource_probe_ran, _}

    assert {:ok, ordinary_graph} = Arbor.Orchestrator.compile(dot("allowed", "valid"))
    assert {:ok, ^opts} = Arbor.Orchestrator.pin_native_execution(ordinary_graph, opts)
  end

  test "security regression: runtime owner snapshot binds graph and actual loaded code", c do
    grant!(c, @resource)
    opts = pinned_facade_opts!(Keyword.delete(c.opts, :conversation_source))
    changed_graph = String.replace(facade_dot(), "target=\"allowed\"", "target=\"sibling\"")
    assert changed_graph != facade_dot()
    assert {:error, _} = Arbor.Orchestrator.run(changed_graph, opts)
    refute_received {:native_resource_probe_ran, _}

    manifest = Keyword.fetch!(opts, :execution_manifest)

    changed =
      update_in(manifest["actions"], fn actions ->
        Enum.map(actions, &Map.put(&1, "beam_sha256", String.duplicate("0", 64)))
      end)

    assert {:ok, digest} = Arbor.Orchestrator.CodingPlan.ExecutionManifest.digest(changed)

    assert {:error, _} =
             Arbor.Orchestrator.run(
               facade_dot(),
               Keyword.merge(opts, execution_manifest: changed, execution_manifest_digest: digest)
             )

    refute_received {:native_resource_probe_ran, _}
  end

  test "security regression: native owner keeps every extra capability and final hostile control taint gate",
       c do
    grant!(c, @resource)

    extra_graph =
      String.replace(facade_dot(), "max_retries=0", "max_retries=0, capabilities=missing_extra")

    assert {:ok, compiled} = Arbor.Orchestrator.compile(extra_graph)

    assert {:ok, opts} =
             Arbor.Orchestrator.pin_native_execution(
               compiled,
               Keyword.delete(c.opts, :conversation_source)
             )

    assert {:ok, denied} = Arbor.Orchestrator.run(compiled, opts)
    assert denied.final_outcome.status == :fail
    assert denied.final_outcome.failure_reason =~ "arbor://orchestrator/execute/missing_extra"
    refute_received {:native_resource_probe_ran, _}

    grant!(c, "arbor://orchestrator/execute/missing_extra")
    assert {:ok, positive} = Arbor.Orchestrator.run(compiled, opts)
    assert positive.final_outcome.status == :success
    assert_received {:native_resource_probe_ran, _}

    tainted_graph =
      String.replace(facade_dot(), "param.mode=", "context_keys=\"choice.target\", param.mode=")

    assert {:ok, compiled} = Arbor.Orchestrator.compile(tainted_graph)

    assert {:ok, opts} =
             Arbor.Orchestrator.pin_native_execution(
               compiled,
               Keyword.delete(c.opts, :conversation_source)
             )

    opts =
      Keyword.merge(opts,
        initial_values: %{"choice.target" => "allowed"},
        initial_taint: %{"choice.target" => :hostile}
      )

    assert {:ok, taint_denied} = Arbor.Orchestrator.run(compiled, opts)
    assert taint_denied.final_outcome.status == :fail
    assert taint_denied.final_outcome.failure_reason =~ "taint_blocked"
    refute_received {:native_resource_probe_ran, _}
  end

  defp pinned_facade_opts!(opts) do
    assert {:ok, graph} = Arbor.Orchestrator.compile(facade_dot())
    assert {:ok, pinned} = Arbor.Orchestrator.pin_native_execution(graph, opts)
    assert is_map(Keyword.fetch!(pinned, :execution_manifest))
    pinned
  end

  defp facade_dot,
    do: String.replace(dot("allowed", "valid"), @action, "native_resource_facade_probe")

  defp grant!(c, resource, options \\ []) do
    assert {:ok, cap} =
             Security.grant_fixture(
               Keyword.merge(
                 [
                   principal: c.principal,
                   resource: resource,
                   task_id: c.task,
                   session_id: c.session
                 ],
                 options
               )
             )

    cap
  end

  defp dot(target, mode) do
    """
    digraph NativeResourceProbe {
      start [shape=Mdiamond]
      effect [type=exec, target=action, action=#{@action}, max_retries=0,
        param.target=#{Jason.encode!(target)}, param.mode=#{Jason.encode!(mode)}]
      done [shape=Msquare]
      start -> effect -> done
    }
    """
  end
end
