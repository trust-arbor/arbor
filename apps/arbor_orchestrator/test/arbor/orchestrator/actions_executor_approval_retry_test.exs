defmodule Arbor.Orchestrator.ActionsExecutorApprovalRetryTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Persistence.BufferedStore

  defmodule GatedPolicy do
    @moduledoc false
    def confirmation_mode(_principal_id, _resource_uri, _opts), do: :gated
  end

  defmodule ConsensusStub do
    @moduledoc false
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_comms)

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

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.SystemAuthority, []},
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
      approval_timeout: Application.get_env(:arbor_orchestrator, :approval_timeout_ms)
    }

    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, GatedPolicy)
    Application.put_env(:arbor_security, :consensus_module, ConsensusStub)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_orchestrator, :approval_timeout_ms, 2_000)

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

      restore_env(
        :arbor_security,
        :identity_verification,
        previous.identity_verification
      )

      restore_env(:arbor_orchestrator, :approval_timeout_ms, previous.approval_timeout)
    end)

    :ok
  end

  test "security regression: approval retries only the exact invocation without durable authority" do
    agent_id = "agent_approval_retry_#{System.unique_integer([:positive])}"
    action_module = Arbor.Actions.Session.Classify
    resource_uri = Arbor.Actions.canonical_uri_for(action_module, %{})

    assert {:ok, gated_capability} =
             Arbor.Security.grant(
               principal: agent_id,
               resource: resource_uri,
               constraints: %{}
             )

    on_exit(fn -> Arbor.Security.revoke(gated_capability.id) end)

    first =
      Task.async(fn ->
        ActionsExecutor.execute(
          "session_classify",
          %{"input" => "hello"},
          File.cwd!(),
          agent_id: agent_id
        )
      end)

    first_request = await_pending_request(agent_id)
    Process.sleep(25)
    assert :ok = Arbor.Comms.InteractionRouter.respond(first_request.request_id, :approved)

    assert {:ok, result} = Task.await(first, 3_000)
    assert Jason.decode!(result)["input_type"] == "query"

    assert {:ok, capabilities} = Arbor.Security.list_capabilities(agent_id)

    exact_caps = Enum.filter(capabilities, &(&1.resource_uri == resource_uri))
    assert Enum.map(exact_caps, & &1.id) == [gated_capability.id]

    second =
      Task.async(fn ->
        ActionsExecutor.execute(
          "session_classify",
          %{"input" => "hello again"},
          File.cwd!(),
          agent_id: agent_id
        )
      end)

    second_request = await_pending_request(agent_id)
    refute second_request.request_id == first_request.request_id
    Process.sleep(25)
    assert :ok = Arbor.Comms.InteractionRouter.respond(second_request.request_id, :denied)

    assert {:error, message} = Task.await(second, 3_000)
    assert message =~ "denied by the operator"
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

  defp start_security_child(child) do
    case Supervisor.start_child(Arbor.Security.Supervisor, child) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} -> raise "failed to start security child: #{inspect(reason)}"
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
