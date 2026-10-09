defmodule Arbor.Agent.IntentDispatcherPrincipalSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{ActionCycleServer, ActionCycleSupervisor, IntentDispatcher}
  alias Arbor.Contracts.Memory.{Intent, Percept}
  alias Arbor.Contracts.Security.{AuthContext, SignedRequest}

  @moduletag :fast
  @moduletag :security_regression
  @nested_action_name "security_regression.agent_nested_coding_validation"

  defmodule NestedCodingValidationAction do
    use Jido.Action,
      name: "agent_nested_coding_validation",
      description: "Runs a nested coding validation command",
      schema: [
        command: [type: :string, required: true],
        cwd: [type: :string, required: true]
      ]

    @impl true
    def run(params, context) do
      Arbor.Actions.authorize_and_execute(
        Map.fetch!(context, :agent_id),
        Arbor.Actions.Shell.Execute,
        %{command: params.command, sandbox: :none, cwd: params.cwd},
        context
      )
    end
  end

  setup do
    ensure_runtime_started()
    previous = security_config()
    configure_minimal_security()

    previous_authorizer = Application.fetch_env(:arbor_shell, :agent_authorizer)
    Application.put_env(:arbor_shell, :agent_authorizer, Arbor.Actions.Shell)

    {:ok, identity} = Arbor.Security.generate_identity(name: "action-cycle-r4")
    :ok = Arbor.Security.register_identity_fixture(identity)
    :ok = Arbor.Security.store_signing_key_fixture(identity.agent_id, identity.private_key)
    signer = Arbor.Security.make_signer(identity.agent_id, identity.private_key)

    marker =
      Path.join(
        System.tmp_dir!(),
        "action_cycle_r4_#{System.unique_integer([:positive])}"
      )

    File.rm(marker)

    on_exit(fn ->
      restore_security_config(previous)

      case previous_authorizer do
        {:ok, authorizer} -> Application.put_env(:arbor_shell, :agent_authorizer, authorizer)
        :error -> Application.delete_env(:arbor_shell, :agent_authorizer)
      end

      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.revoke_all_fixture(identity.agent_id)
      end

      if Process.whereis(Arbor.Trust.Store) do
        Arbor.Trust.Store.delete_profile(identity.agent_id)
      end

      if Process.whereis(Arbor.Security.Identity.Registry) do
        Arbor.Security.deregister_identity_fixture(identity.agent_id)
      end

      _ = Arbor.Security.delete_signing_key_fixture(identity.agent_id)

      File.rm(marker)
    end)

    {:ok, identity: identity, signer: signer, marker: marker}
  end

  test "security regression: typed caller executes childless Shell without scalar scope leakage",
       %{identity: identity} do
    agent_id = identity.agent_id
    command = "echo intent-dispatch-authorized"
    resource = shell_resource(command)
    authorize_agent(agent_id, [resource])
    cwd = admit_workdir!(agent_id, ["read"])
    intent = shell_intent(command, cwd)

    assert {:ok, %Percept{outcome: :failure, error: :authenticated_principal_required}} =
             IntentDispatcher.dispatch(agent_id, intent)

    context = verified_context(identity, resource)

    assert {:ok, %Percept{outcome: :success} = success} =
             IntentDispatcher.dispatch(agent_id, intent, context: context)

    assert success.data.result.stdout =~ "intent-dispatch-authorized"

    assert {:ok, %Percept{outcome: :failure, error: :authenticated_principal_required}} =
             IntentDispatcher.dispatch(agent_id, intent)
  end

  test "security regression: typed caller principal mismatch fails before Shell side effects", %{
    identity: identity,
    marker: marker
  } do
    command = "touch #{marker}"
    resource = shell_resource(command)
    authorize_agent(identity.agent_id, [resource])
    context = verified_context(identity, resource)
    other_id = "agent_forged_#{System.unique_integer([:positive])}"

    assert {:ok,
            %Percept{
              outcome: :failure,
              error: {:principal_context_mismatch, ^other_id, [asserted_id]}
            }} =
             IntentDispatcher.dispatch(other_id, shell_intent(command), context: context)

    assert asserted_id == identity.agent_id
    refute File.exists?(marker)
  end

  test "security regression: verified context survives nested coding Shell validation", %{
    identity: identity
  } do
    :ok =
      Arbor.Common.ActionRegistry.register(
        @nested_action_name,
        NestedCodingValidationAction,
        %{}
      )

    on_exit(fn ->
      if Process.whereis(Arbor.Common.ActionRegistry) do
        Arbor.Common.ActionRegistry.deregister(@nested_action_name)
      end
    end)

    command = "echo nested-coding-validation-authorized"
    outer_resource = Arbor.Actions.canonical_uri_for(NestedCodingValidationAction, %{})
    authorize_agent(identity.agent_id, [outer_resource, shell_resource(command)])
    cwd = admit_workdir!(identity.agent_id, ["read"])

    intent =
      Intent.action(
        :"security_regression.agent_nested_coding_validation",
        %{command: command, cwd: cwd},
        capability: outer_resource
      )

    context = verified_context(identity, outer_resource)

    assert {:ok, %Percept{outcome: :success} = percept} =
             IntentDispatcher.dispatch(identity.agent_id, intent, context: context)

    assert percept.data.result.stdout =~ "nested-coding-validation-authorized"
  end

  test "security regression: full ActionCycleServer maps shell execute and performs authorized side effect",
       %{identity: identity, signer: signer, marker: _marker} do
    authorize_agent(identity.agent_id, ["arbor://shell/exec/touch"])
    cwd = admit_workdir!(identity.agent_id, ["read", "write"])
    marker = Path.join(cwd, "cycle-side-effect")
    File.rm(marker)
    server = start_cycle_server(identity.agent_id, signer, marker, cwd)

    assert :ok =
             ActionCycleServer.enqueue_percept(server, %{type: :test, content: "run shell intent"})

    assert eventually(fn -> File.exists?(marker) end),
           "the public ActionCycleServer cycle never executed its canonical shell/execute intent; stats=#{inspect(cycle_stats(server))}"

    assert eventually(fn -> ActionCycleServer.stats(server).cycle_count >= 1 end)

    # The proof exists only in the owned cycle task context. It does not create
    # process-global scalar authority for later callers.
    assert {:error, :authenticated_principal_required} =
             Arbor.Actions.authorize_and_execute(
               identity.agent_id,
               Arbor.Actions.Shell.Execute,
               %{command: "echo cycle-authority-leaked", sandbox: :none},
               %{agent_id: identity.agent_id}
             )
  end

  test "security regression: full ActionCycleServer with typed identity but no profile or grant is denied",
       %{identity: identity, signer: signer, marker: marker} do
    command = "touch #{marker}"

    assert {:error, :unauthorized} =
             Arbor.Actions.authorize_and_execute(
               identity.agent_id,
               Arbor.Actions.Shell.Execute,
               %{command: command, sandbox: :none},
               verified_context(identity, shell_resource(command))
             )

    server = start_cycle_server(identity.agent_id, signer, marker)

    assert :ok = ActionCycleServer.enqueue_percept(server, %{type: :test})

    assert eventually(fn ->
             stats = ActionCycleServer.stats(server)
             stats.cycle_count >= 1 and not stats.cycle_in_flight
           end)

    refute File.exists?(marker)
  end

  test "security regression: ActionCycle normal stop closes its bootstrap slot", %{
    identity: identity
  } do
    bootstrap = issue_action_cycle_bootstrap!(identity)

    assert {:ok, server} =
             ActionCycleSupervisor.start_server(identity.agent_id,
               signing_authority_bootstrap: bootstrap
             )

    assert :sys.get_state(server).signing_authority == nil

    assert {:error, :authority_already_claimed} =
             Arbor.Security.claim_signing_authority(bootstrap)

    assert :ok = ActionCycleSupervisor.stop_server(identity.agent_id)
    assert eventually(fn -> ActionCycleSupervisor.lookup(identity.agent_id) == :error end)

    assert {:error, :bootstrap_not_found} =
             Arbor.Security.claim_signing_authority(bootstrap)
  end

  test "security regression: ActionCycle crash restart reclaims bootstrap without exposing bearer",
       %{
         identity: identity
       } do
    bootstrap = issue_action_cycle_bootstrap!(identity)

    assert {:ok, first} =
             ActionCycleSupervisor.start_server(identity.agent_id,
               signing_authority_bootstrap: bootstrap
             )

    assert :sys.get_state(first).signing_authority == nil

    assert {:error, :authority_already_claimed} =
             Arbor.Security.claim_signing_authority(bootstrap)

    ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first, _}, 1_000

    assert eventually(fn ->
             case ActionCycleSupervisor.lookup(identity.agent_id) do
               {:ok, pid} when pid != first -> Process.alive?(pid)
               _ -> false
             end
           end)

    {:ok, second} = ActionCycleSupervisor.lookup(identity.agent_id)
    assert :sys.get_state(second).signing_authority == nil

    assert {:error, :authority_already_claimed} =
             Arbor.Security.claim_signing_authority(bootstrap)

    assert :ok = ActionCycleSupervisor.stop_server(identity.agent_id)

    assert {:error, :bootstrap_not_found} =
             Arbor.Security.claim_signing_authority(bootstrap)
  end

  defp start_cycle_server(agent_id, signer, marker, cwd \\ nil) do
    name = {:via, Registry, {Arbor.Agent.ActionCycleRegistry, agent_id}}
    calls = :atomics.new(1, signed: false)

    llm_fn = fn _context ->
      case :atomics.add_get(calls, 1, 1) do
        1 ->
          intent = %{
            "capability" => "shell",
            "op" => "execute",
            "target" => "touch #{marker}",
            "reason" => "public ActionCycleServer regression"
          }

          intent =
            if is_binary(cwd), do: Map.put(intent, "params", %{"cwd" => cwd}), else: intent

          {:ok,
           %{
             "mental_actions" => [],
             "intent" => intent,
             "wait" => false
           }}

        _ ->
          {:ok, %{"mental_actions" => [], "intent" => nil, "wait" => true}}
      end
    end

    {:ok, server} =
      ActionCycleServer.start_link(
        agent_id: agent_id,
        name: name,
        signer: signer,
        llm_fn: llm_fn,
        action_cycle_timeout: 5_000
      )

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    server
  end

  defp issue_action_cycle_bootstrap!(identity) do
    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :action_cycle,
        owner: self()
      )

    {:ok, bootstrap} = Arbor.Security.issue_signing_authority_bootstrap(proof)
    bootstrap
  end

  defp shell_intent(command, cwd \\ nil) do
    params = %{command: command, sandbox: :none}
    params = if is_binary(cwd), do: Map.put(params, :cwd, cwd), else: params

    Intent.action(:shell_execute, params, capability: "arbor://shell")
  end

  defp shell_resource(command) do
    {:ok, resource} =
      Arbor.Actions.Shell.Execute.authorization_resource(%{command: command, sandbox: :none})

    resource
  end

  defp verified_context(identity, resource) do
    {:ok, signed_request} =
      SignedRequest.sign(resource, identity.agent_id, identity.private_key)

    assert {:ok, identity.agent_id} == Arbor.Security.verify_request(signed_request)

    auth_context =
      AuthContext.new(identity.agent_id, signed_request: signed_request)
      |> AuthContext.mark_verified()

    %{
      agent_id: identity.agent_id,
      signed_request: signed_request,
      auth_context: auth_context
    }
  end

  defp admit_workdir!(agent_id, operations) when is_list(operations) do
    root =
      Path.join(System.tmp_dir!(), "intent_dispatch_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    {:ok, cwd} = Arbor.Common.SafePath.resolve_real(root)
    {:ok, profile} = Arbor.Trust.Store.get_profile(agent_id)

    rules =
      Enum.reduce(operations, profile.rules, fn operation, acc ->
        Map.put(acc, "arbor://fs/#{operation}#{cwd}", :auto)
      end)

    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: rules})

    Enum.each(operations, fn operation ->
      assert {:ok, _capability} =
               Arbor.Security.grant_fixture(
                 principal: agent_id,
                 resource: "arbor://fs/#{operation}#{cwd}/**"
               )
    end)

    on_exit(fn -> File.rm_rf(cwd) end)
    cwd
  end

  defp authorize_agent(agent_id, resources) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    rules = Enum.reduce(resources, profile.rules, &Map.put(&2, &1, :auto))
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: rules})

    Enum.each(resources, fn resource ->
      assert {:ok, _capability} =
               Arbor.Security.grant_fixture(principal: agent_id, resource: resource)
    end)
  end

  defp cycle_stats(server) do
    ActionCycleServer.stats(server)
  rescue
    error -> {:stats_unavailable, Exception.message(error)}
  catch
    kind, reason -> {:stats_unavailable, {kind, reason}}
  end

  defp eventually(fun, attempts \\ 120)
  defp eventually(fun, _attempts) when not is_function(fun, 0), do: false
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp ensure_runtime_started do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    {:ok, _} = Application.ensure_all_started(:arbor_shell)
    {:ok, _} = Application.ensure_all_started(:arbor_agent)

    security_backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: security_backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_present, _id}} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(name)}: #{inspect(reason)}"
      end
    end

    signing_authority_owner_token = make_ref()

    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.SigningAuthorityStateOwner, broker_token: signing_authority_owner_token},
      {Arbor.Security.SigningAuthorityBroker, state_owner_token: signing_authority_owner_token},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    for {module, opts} <- security_children do
      unless Process.whereis(module) do
        case Supervisor.start_child(Arbor.Security.Supervisor, {module, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(module)}: #{inspect(reason)}"
        end
      end
    end

    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    unless Process.whereis(Arbor.Common.ActionRegistry) do
      start_supervised!(Arbor.Common.ActionRegistry)
    end

    unless Process.whereis(Arbor.Agent.ActionCycleRegistry) do
      start_supervised!({Registry, keys: :unique, name: Arbor.Agent.ActionCycleRegistry})
    end

    unless Process.whereis(Arbor.Agent.ActionCycleSupervisor) do
      start_supervised!(Arbor.Agent.ActionCycleSupervisor)
    end

    unless Process.whereis(Arbor.Shell.ExecutablePolicy) do
      start_supervised!({Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")})
    end

    unless Process.whereis(Arbor.Shell.ExecutionRegistry) do
      start_supervised!(Arbor.Shell.ExecutionRegistry)
    end

    unless Process.whereis(Arbor.Shell.PortSessionSupervisor) do
      start_supervised!(
        {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
      )
    end
  end

  defp security_config do
    %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }
  end

  defp configure_minimal_security do
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    # This slice proves explicit grant + profile enforcement. Disable JIT
    # policy minting so an absent grant cannot become an :ask capability while
    # the approval subsystem is intentionally disabled for childless execution.
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, false)
  end

  defp restore_security_config(previous) do
    restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
    restore(:arbor_security, :capability_signing_required, previous.signing)
    restore(:arbor_security, :identity_verification, previous.identity_verification)
    restore(:arbor_security, :strict_identity_mode, previous.identity)
    restore(:arbor_security, :uri_registry_enforcement, previous.uri_registry)
    restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
    restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
    restore(:arbor_security, :invocation_receipts_enabled, previous.receipts)
    restore(:arbor_trust, :approval_guard_enabled, previous.trust_guard)
    restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
