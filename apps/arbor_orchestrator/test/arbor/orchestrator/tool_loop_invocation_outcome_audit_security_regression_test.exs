defmodule Arbor.Orchestrator.ToolLoopInvocationOutcomeAuditSecurityRegressionTest do
  @moduledoc """
  Security regression (D5 follow-up, 2026-09-27), end to end: ToolLoop's
  durable tool-invocation record read "refused" for every failed call, even
  when the dispatched action had started its effect. Drives the real stack —
  ToolLoop, ArborActionsExecutor, ActionsExecutor, Arbor.Actions and the
  Security auditor — and reads the durable tool and action outcomes together.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Trust.Profile
  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}
  alias Arbor.Security.CapabilityStore
  alias Arbor.Trust.Store, as: TrustStore

  @resource "arbor://action/test/tool-audit-outcome-probe"
  @action_name "tool_audit_outcome_probe"
  @script_key {__MODULE__, :behaviour}

  defmodule ProbeAction do
    use Jido.Action,
      name: "tool_audit_outcome_probe",
      description: "Scripted admitted behaviour for tool audit outcome tests",
      schema: [behaviour: [type: :string, required: true]]

    @impl true
    def run(%{behaviour: "raise"}, _context), do: raise("probe exploded mid-effect")
    def run(%{behaviour: "error"}, _context), do: {:error, :probe_rejected_input}
    def run(%{behaviour: "succeed"}, _context), do: {:ok, %{done: true}}

    @doc false
    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/tool-audit-outcome-probe"}
  end

  defmodule Sink do
    @moduledoc false
    def persist_security_invocation(event) do
      send(Application.fetch_env!(:arbor_security, :tool_audit_outcome_owner), {:audit, event})
      {:ok, event["id"]}
    end
  end

  # One probe call with the scripted behaviour, then a final answer.
  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter
    @script_key {Arbor.Orchestrator.ToolLoopInvocationOutcomeAuditSecurityRegressionTest,
                 :behaviour}

    def provider, do: "tool_audit_outcome_test"

    def complete(%Request{messages: messages}, _opts) do
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           raw: %{},
           content_parts: [
             ContentPart.tool_call("probe_call", "tool_audit_outcome_probe", %{
               "behaviour" => :persistent_term.get(@script_key)
             })
           ]
         }}
      end
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(TrustStore), do: start_supervised!(TrustStore)
    unless Process.whereis(ActionRegistry), do: start_supervised!(ActionRegistry)

    # Every restore is registered before the step it undoes.
    registry_snapshot = ActionRegistry.snapshot()

    on_exit(fn ->
      if Process.whereis(ActionRegistry), do: :ok = ActionRegistry.restore(registry_snapshot)
      :persistent_term.erase(@script_key)
    end)

    case ActionRegistry.resolve(@action_name) do
      {:ok, ProbeAction} -> :ok
      {:error, :not_found} -> :ok = ActionRegistry.register(@action_name, ProbeAction)
    end

    env = [
      {:arbor_llm, :tool_invocation_auditor, Arbor.Security},
      {:arbor_security, :invocation_audit_mode, :required},
      {:arbor_security, :invocation_audit_sink, Sink},
      {:arbor_security, :tool_audit_outcome_owner, self()},
      {:arbor_security, :reflex_checking_enabled, false},
      {:arbor_security, :capability_signing_required, false},
      {:arbor_security, :identity_verification, false},
      {:arbor_security, :strict_identity_mode, false},
      {:arbor_security, :uri_registry_enforcement, false},
      {:arbor_security, :consensus_escalation_enabled, false},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_trust, :approval_guard_enabled, false},
      {:arbor_trust, :policy_enforcer_enabled, true}
    ]

    previous = Map.new(env, fn {app, key, _} -> {{app, key}, Application.fetch_env(app, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    Enum.each(env, fn {app, key, value} -> Application.put_env(app, key, value) end)

    agent_id = "agent_tool_audit_outcome_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      CapabilityStore.revoke_all(agent_id)
      if Process.whereis(TrustStore), do: TrustStore.delete_profile(agent_id)
    end)

    {:ok, profile} = Profile.new(agent_id)
    :ok = TrustStore.store_profile(%{profile | rules: %{@resource => :auto}})
    assert {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: @resource)

    %{agent_id: agent_id}
  end

  test "security regression: a tool call whose action crashed mid-effect is unknown, not refused",
       %{agent_id: agent_id} do
    run_probe(agent_id, "raise")

    assert %{tool: "unknown", action: "interrupted", action_admitted?: true, linked?: true} =
             audit_summary()
  end

  test "security regression: a tool call whose action returned an error is failed, not refused",
       %{agent_id: agent_id} do
    run_probe(agent_id, "error")

    assert %{tool: "failed", action: "failed", action_admitted?: true, linked?: true} =
             audit_summary()
  end

  test "a tool call refused before admission stays refused" do
    run_probe("agent_tool_audit_outcome_no_grant_#{System.unique_integer([:positive])}", "raise")

    assert %{tool: "refused", action: "refused", action_admitted?: false} = audit_summary()
  end

  test "a successful tool call is completed", %{agent_id: agent_id} do
    run_probe(agent_id, "succeed")
    assert %{tool: "completed", action: "completed", action_admitted?: true} = audit_summary()
  end

  defp run_probe(agent_id, behaviour) do
    :persistent_term.put(@script_key, behaviour)

    client = Client.new(default_provider: Adapter.provider()) |> Client.register_adapter(Adapter)

    request = %Request{
      provider: Adapter.provider(),
      model: "test",
      messages: [Message.new(:user, "run the probe")]
    }

    assert {:ok, _response} =
             ToolLoop.run(client, request,
               tools: [],
               max_turns: 3,
               agent_id: agent_id,
               workdir: File.cwd!()
             )
  end

  # Durable outcomes of the ToolLoop tool frame and its nested action frame.
  defp audit_summary do
    events = drain([])
    by_surface = Enum.group_by(events, & &1["surface"])
    [tool_id] = by_surface["tool"] |> Enum.map(& &1["invocation_id"]) |> Enum.uniq()
    action_events = Map.get(by_surface, "action", [])

    %{
      tool: outcome(by_surface["tool"]),
      action: outcome(action_events),
      action_admitted?: Enum.any?(action_events, &(&1["stage"] == "effect_admitted")),
      linked?: Enum.all?(action_events, &(&1["parent_invocation_id"] == tool_id))
    }
  end

  defp outcome(events) do
    Enum.find_value(events || [], fn
      %{"stage" => "outcome", "outcome" => outcome} -> outcome
      _other -> nil
    end)
  end

  defp drain(acc) do
    receive do
      {:audit, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
