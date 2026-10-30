defmodule Arbor.Security.OperatorResolutionSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security

  defmodule CapturingRouter do
    @moduledoc false
    @behaviour Arbor.Security.Contracts.InteractionRouter

    @impl true
    def request(attrs, opts) do
      send(self(), {:operator_regression_router, attrs, opts})
      {:ok, "irq_operator_resolution"}
    end
  end

  defmodule CapturingConsensus do
    @moduledoc false

    def healthy?, do: true

    def submit(proposal, opts) do
      send(self(), {:operator_regression_consensus, proposal, opts})
      {:ok, "proposal_operator_resolution"}
    end
  end

  defmodule CapturingEventLog do
    @moduledoc false
    @behaviour Arbor.Security.Contracts.EventLogAdapter

    @impl true
    def persist_security_event(type, data) do
      send(self(), {:operator_regression_event, type, data})
      :ok
    end

    @impl true
    def read_security_events(_opts), do: {:ok, []}
  end

  defmodule NoCallbackResolver do
    @moduledoc false
  end

  defmodule ExactResolver do
    @moduledoc false

    def resolve_operator(principal_id) do
      send(self(), {:operator_regression_resolver, principal_id})
      {:ok, "  human_operator_exact  "}
    end
  end

  defmodule ScenarioResolver do
    @moduledoc false

    def resolve_operator(principal_id) do
      scenario = Process.get({__MODULE__, :scenario})
      send(self(), {:operator_regression_resolver, principal_id, scenario})

      case scenario do
        {:raise, detail} -> raise ArgumentError, detail
        {:exit, detail} -> exit(detail)
        {:throw, detail} -> throw(detail)
        {:return, result} -> result
      end
    end
  end

  setup do
    keys = [
      :operator_resolver,
      :consensus_escalation_enabled,
      :consensus_module,
      :use_interaction_router_for_approval,
      :interaction_router,
      :invocation_receipts_enabled,
      :event_log_adapter
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_capabilities, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_capabilities, key, value)
        {key, :error} -> Application.delete_env(:arbor_capabilities, key)
      end)
    end)

    Application.put_env(:arbor_capabilities, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_capabilities, :consensus_module, CapturingConsensus)
    Application.put_env(:arbor_capabilities, :use_interaction_router_for_approval, true)
    Application.put_env(:arbor_capabilities, :interaction_router, CapturingRouter)
    Application.put_env(:arbor_capabilities, :invocation_receipts_enabled, true)
    Application.put_env(:arbor_capabilities, :event_log_adapter, CapturingEventLog)

    # Use the app's ordinary identity-verification settings and signed capability
    # fixture. A setup failure must fail here, before the resolver assertion.
    principal_id = "agent_operator_resolution_#{System.unique_integer([:positive])}"
    resource_uri = "arbor://code/write/operator_resolution/#{principal_id}"

    assert {:ok, capability} =
             Security.grant_fixture(
               principal: principal_id,
               resource: resource_uri,
               constraints: %{requires_approval: true}
             )

    assert CapturingConsensus.healthy?()
    assert function_exported?(CapturingRouter, :request, 2)

    %{principal_id: principal_id, resource_uri: resource_uri, capability: capability}
  end

  test "security regression: an absent or unusable operator resolver cannot dispatch approval",
       context do
    resolvers = [
      :missing,
      nil,
      __MODULE__.UnavailableResolver,
      NoCallbackResolver,
      "not-a-module",
      %{}
    ]

    for resolver <- resolvers do
      if resolver == :missing do
        Application.delete_env(:arbor_capabilities, :operator_resolver)
      else
        Application.put_env(:arbor_capabilities, :operator_resolver, resolver)
      end

      assert {:error, :operator_resolver_unavailable} = authorize(context), inspect(resolver)
      assert_no_submission_or_receipt(context, :operator_resolver_unavailable)
    end
  end

  test "security regression: configured resolver failures are normalized without dispatch",
       %{principal_id: principal_id} = context do
    Application.put_env(:arbor_capabilities, :operator_resolver, ScenarioResolver)

    scenarios = [
      {:return, {:error, %{private_operator_detail: "must stay private"}}},
      {:return, :ok},
      {:return, "raw-human-id"},
      {:return, {:ok, nil}},
      {:return, {:ok, 42}},
      {:return, {:ok, ""}},
      {:return, {:ok, " \t\n"}},
      {:return, {:ok, <<255>>}},
      {:raise, "private operator exception"},
      {:exit, {:private_operator_exit, "must stay private"}},
      {:throw, {:private_operator_throw, "must stay private"}}
    ]

    for scenario <- scenarios do
      Process.put({ScenarioResolver, :scenario}, scenario)
      assert Process.get({ScenarioResolver, :scenario}) == scenario

      assert {:error, :operator_resolution_failed} = authorize(context), inspect(scenario)
      assert_received {:operator_regression_resolver, ^principal_id, ^scenario}
      assert_no_submission_or_receipt(context, :operator_resolution_failed)
    end
  end

  test "a valid resolver routes the exact human identifier and preserves the authorizing principal",
       %{principal_id: principal_id, resource_uri: resource_uri, capability: capability} = context do
    Application.put_env(:arbor_capabilities, :operator_resolver, ExactResolver)

    assert {:ok, :pending_approval, "irq_operator_resolution"} = authorize(context)
    assert_received {:operator_regression_resolver, ^principal_id}
    assert_received {:operator_regression_router, attrs, []}
    assert attrs.user_id == "  human_operator_exact  "
    assert attrs.agent_id == principal_id
    assert attrs.resource_uri == resource_uri
    assert attrs.kind == :approval
    assert attrs.metadata.principal_id == principal_id
    assert attrs.metadata.capability_id == capability.id
    assert attrs.metadata.approval_context.principal_id == principal_id
    refute_received {:operator_regression_consensus, _, _}
    refute_received {:operator_regression_receipt, _}

    assert_received {:operator_regression_event, :authorization_pending,
                     %{principal_id: ^principal_id, resource_uri: ^resource_uri}}
  end

  defp authorize(%{principal_id: principal_id, resource_uri: resource_uri}) do
    Security.authorize(principal_id, resource_uri, :execute,
      receipt_callback: fn receipt -> send(self(), {:operator_regression_receipt, receipt}) end
    )
  end

  defp assert_no_submission_or_receipt(
         %{principal_id: principal_id, resource_uri: resource_uri},
         reason
       ) do
    refute_received {:operator_regression_router, _, _}
    refute_received {:operator_regression_consensus, _, _}
    refute_received {:operator_regression_receipt, _}
    refute_received {:operator_regression_event, :authorization_pending, _}
    refute_received {:operator_regression_event, :invocation_receipt, _}

    expected_reason = inspect(reason)

    assert_received {:operator_regression_event, :authorization_denied,
                     %{
                       principal_id: ^principal_id,
                       resource_uri: ^resource_uri,
                       reason: ^expected_reason
                     }}
  end
end
