defmodule Arbor.Orchestrator.ActionsExecutorStructuredExecutionTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :security_regression

  alias Arbor.Common.ActionRegistry
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Persistence.BufferedStore

  defmodule GatedPolicy do
    @moduledoc false
    def confirmation_mode(_principal_id, _resource_uri, _opts), do: :gated
  end

  defmodule ConsensusStub do
    @moduledoc false
  end

  defmodule CallerDenySecurity do
    @moduledoc false

    def list_capabilities(_principal, _opts), do: {:ok, []}
    def capability_authorizes?(_capability, _resource, _opts), do: false

    def normalize_authorization_resource_uri(resource, opts) do
      Arbor.Security.normalize_authorization_resource_uri(resource, opts)
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_comms)
    ensure_action_registry_started!()
    ensure_session_classify_registered!()

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      start_security_child(
        Supervisor.child_spec(
          {BufferedStore, name: name, backend: nil, write_mode: :sync, collection: collection},
          id: name
        )
      )
    end

    signing_authority_owner_token = make_ref()

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.SigningAuthorityStateOwner,
           broker_token: signing_authority_owner_token},
          {Arbor.Security.SigningAuthorityBroker,
           state_owner_token: signing_authority_owner_token},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []}
        ] do
      start_security_child(child)
    end

    :ok
  end

  setup do
    previous = %{
      approval_guard_enabled: Application.get_env(:arbor_trust, :approval_guard_enabled),
      policy_module: Application.get_env(:arbor_trust, :policy_module),
      consensus_module: Application.get_env(:arbor_security, :consensus_module),
      escalation_enabled: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      interaction_router:
        Application.get_env(:arbor_security, :use_interaction_router_for_approval),
      signing_required: Application.get_env(:arbor_security, :capability_signing_required),
      strict_identity: Application.get_env(:arbor_security, :strict_identity_mode),
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      approval_timeout: Application.get_env(:arbor_orchestrator, :approval_timeout_ms),
      security_module: Application.get_env(:arbor_orchestrator, :security_module)
    }

    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_module, GatedPolicy)
    Application.put_env(:arbor_security, :consensus_module, ConsensusStub)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_orchestrator, :approval_timeout_ms, 2_000)
    Application.delete_env(:arbor_orchestrator, :security_module)

    on_exit(fn ->
      restore_env(:arbor_trust, :approval_guard_enabled, previous.approval_guard_enabled)
      restore_env(:arbor_trust, :policy_module, previous.policy_module)
      restore_env(:arbor_security, :consensus_module, previous.consensus_module)

      restore_env(
        :arbor_security,
        :consensus_escalation_enabled,
        previous.escalation_enabled
      )

      restore_env(
        :arbor_security,
        :use_interaction_router_for_approval,
        previous.interaction_router
      )

      restore_env(
        :arbor_security,
        :capability_signing_required,
        previous.signing_required
      )

      restore_env(:arbor_security, :strict_identity_mode, previous.strict_identity)
      restore_env(:arbor_security, :identity_verification, previous.identity_verification)
      restore_env(:arbor_orchestrator, :approval_timeout_ms, previous.approval_timeout)
      restore_env(:arbor_orchestrator, :security_module, previous.security_module)
    end)

    :ok
  end

  test "authorized execution formats execute/4 success and preserves structured success" do
    agent_id = unique_agent_id("structured_success")
    grant_session_classify!(agent_id)

    assert {:ok, formatted} =
             ActionsExecutor.execute(
               "session_classify",
               %{"input" => "/status"},
               File.cwd!(),
               agent_id: agent_id
             )

    assert Jason.decode!(formatted) == %{"input_type" => "command"}

    assert {:ok, structured} =
             ActionsExecutor.execute_structured(
               "session_classify",
               %{"input" => "/status"},
               File.cwd!(),
               agent_id: agent_id
             )

    assert structured == %{input_type: "command"}
  end

  test "unknown actions and caller-authority denials fail equivalently before execution" do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])
    :erlang.trace(self(), true, [:call])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
    end)

    unknown = "structured_action_that_does_not_exist"
    unknown_args = %{"credential" => "must-not-be-returned"}
    unknown_error = {:error, "Unknown action: #{unknown}"}

    assert ActionsExecutor.execute(unknown, unknown_args, File.cwd!()) == unknown_error

    assert ActionsExecutor.execute_structured(unknown, unknown_args, File.cwd!()) ==
             unknown_error

    Application.put_env(:arbor_orchestrator, :security_module, CallerDenySecurity)

    agent_id = unique_agent_id("authority_target")
    caller_id = unique_agent_id("authority_caller")
    opts = [agent_id: agent_id, caller_id: caller_id]

    assert {:error, formatted_error} =
             ActionsExecutor.execute(
               "session_classify",
               %{"input" => "must not execute"},
               File.cwd!(),
               opts
             )

    assert {:error, structured_error} =
             ActionsExecutor.execute_structured(
               "session_classify",
               %{"input" => "must not execute"},
               File.cwd!(),
               opts
             )

    assert structured_error == formatted_error
    assert structured_error =~ "Caller #{caller_id} lacks authority"
    refute_receive {:trace, _pid, :call, {Arbor.Actions, :authorize_and_execute, _args}}
  end

  test "approved retry preserves the structured action result" do
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)

    agent_id = unique_agent_id("structured_approval")
    grant_session_classify!(agent_id)

    execution =
      Task.async(fn ->
        ActionsExecutor.execute_structured(
          "session_classify",
          %{"input" => "approved structured result"},
          File.cwd!(),
          agent_id: agent_id
        )
      end)

    request = await_pending_request(agent_id)
    assert :ok = Arbor.Comms.InteractionRouter.respond(request.request_id, :approved)
    assert {:ok, %{input_type: "query"}} = Task.await(execution, 3_000)
  end

  defp grant_session_classify!(agent_id) do
    resource_uri = Arbor.Actions.canonical_uri_for(Arbor.Actions.Session.Classify, %{})
    assert {:ok, capability} = Arbor.Security.grant(principal: agent_id, resource: resource_uri)
    on_exit(fn -> Arbor.Security.revoke(capability.id) end)
    capability
  end

  defp await_pending_request(agent_id, attempts \\ 100)

  defp await_pending_request(_agent_id, 0), do: flunk("approval request did not appear")

  defp await_pending_request(agent_id, attempts) do
    case Enum.find(Arbor.Comms.InteractionRouter.pending(), &(&1.agent_id == agent_id)) do
      nil ->
        Process.sleep(10)
        await_pending_request(agent_id, attempts - 1)

      request ->
        request
    end
  end

  defp unique_agent_id(prefix) do
    "agent_#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp start_security_child(child) do
    case Supervisor.start_child(Arbor.Security.Supervisor, child) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} -> raise "failed to start security child: #{inspect(reason)}"
    end
  end

  defp ensure_action_registry_started! do
    unless Process.whereis(ActionRegistry) do
      start_supervised!(ActionRegistry)
    end
  end

  defp ensure_session_classify_registered! do
    for name <- ["session.classify", "session_classify"] do
      case ActionRegistry.resolve(name) do
        {:ok, _module} ->
          :ok

        {:error, :not_found} ->
          :ok = ActionRegistry.register(name, Arbor.Actions.Session.Classify)
      end
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
