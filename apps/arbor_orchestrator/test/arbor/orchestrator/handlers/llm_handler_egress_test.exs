defmodule Arbor.Orchestrator.Handlers.LlmHandlerEgressTest do
  @moduledoc """
  Verifies the egress gate fires on the REAL compute-node LLM path
  (2026-06-14 URI-addressing-vs-classification decision).

  This is the orphan-path guard: the egress gate was first wired only into the
  action executor (`authorize_and_execute`), but the heartbeat/pipeline LLM calls
  go through `LlmHandler` (compute nodes), which had no authorization at all.
  These tests drive `LlmHandler.execute/4` and assert that, when egress
  enforcement is on and the agent lacks standing, the node HALTS before any LLM
  dispatch happens — and that with enforcement off, the call proceeds normally.

  A recording dispatcher (installed via Application env, as in the dispatcher
  test) confirms whether the LLM was actually reached.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule RecordingDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()

    @impl true
    def dispatch(request, opts) do
      Agent.update(__MODULE__, fn calls -> [{request, opts} | calls] end)

      {:ok,
       %Arbor.LLM.Response{
         text: "from RecordingDispatcher",
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end
  end

  defmodule ExactRouteDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    @impl true
    def dispatch(request, opts) do
      route = Application.fetch_env!(:arbor_orchestrator, :_test_exact_route)
      test_pid = Application.fetch_env!(:arbor_orchestrator, :_test_egress_pid)
      result = Keyword.fetch!(opts, :route_authorizer).(route)
      send(test_pid, {:exact_route_dispatch, request, result})

      case result do
        :allow ->
          {:ok,
           %Arbor.LLM.Response{
             text: "from ExactRouteDispatcher",
             finish_reason: :stop,
             usage: %{input_tokens: 1, output_tokens: 1}
           }}

        _denied ->
          {:error, :route_authorization_denied}
      end
    end
  end

  # Trust stub: no egress standing for anyone -> external egress asks.
  defmodule NoEgressStandingPolicy do
    def confirmation_mode(_principal, _uri), do: :auto
    def egress_mode(_principal, _tier), do: :ask
  end

  setup do
    {:ok, _} = RecordingDispatcher.start_link()
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)

    prev_enforce = Application.get_env(:arbor_security, :egress_gate_enforcing)
    prev_policy = Application.get_env(:arbor_trust, :policy_module)
    Application.put_env(:arbor_trust, :policy_module, NoEgressStandingPolicy)

    on_exit(fn ->
      Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
      Application.delete_env(:arbor_orchestrator, :_test_exact_route)
      Application.delete_env(:arbor_orchestrator, :_test_egress_pid)

      case prev_enforce do
        nil -> Application.delete_env(:arbor_security, :egress_gate_enforcing)
        v -> Application.put_env(:arbor_security, :egress_gate_enforcing, v)
      end

      case prev_policy do
        nil -> Application.delete_env(:arbor_trust, :policy_module)
        v -> Application.put_env(:arbor_trust, :policy_module, v)
      end
    end)

    :ok
  end

  defp build_node, do: %{id: "egress-node", attrs: %{"simulate" => "false", "prompt" => "hi"}}
  defp build_graph, do: %{attrs: %{"goal" => "g"}}

  # A fresh agent id with no granted capabilities -> no egress standing.
  defp build_context do
    Arbor.Orchestrator.Engine.Context.new(%{
      "session.agent_id" => "agent_egress_compute_#{System.unique_integer([:positive])}",
      "session.llm_provider" => "anthropic",
      "session.llm_model" => "claude-opus-4-6",
      "session.llm_runtime" => :arbor
    })
  end

  test "enforcing + no standing: compute-node LLM call HALTS before dispatch, surfaces a refusal" do
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    outcome = LlmHandler.execute(build_node(), build_context(), build_graph(), [])

    # The crucial assertion: the LLM was never reached — the gate halted first.
    assert RecordingDispatcher.calls() == []
    # UX: surfaced as a clear refusal (not a silent empty response). partial_success
    # so the message reaches context (last_response / llm.content) + pipeline completes.
    assert outcome.status == :partial_success
    assert outcome.notes =~ "Egress blocked"
    assert outcome.context_updates["last_response"] =~ "Egress blocked"
    assert outcome.context_updates["llm.content"] =~ "Egress blocked"
    assert outcome.context_updates["egress_blocked"] == true
  end

  test "dark by default: the same call proceeds and reaches the LLM" do
    # enforcing flag unset -> default false
    outcome = LlmHandler.execute(build_node(), build_context(), build_graph(), [])

    assert outcome.status == :success
    assert [{%Arbor.LLM.Request{}, _opts}] = RecordingDispatcher.calls()
  end

  test "an allowed original provider cannot authorize a different router-selected provider" do
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    context =
      Arbor.Orchestrator.Engine.Context.new(%{
        "session.agent_id" => "agent_exact_route_#{System.unique_integer([:positive])}",
        "session.llm_provider" => "lmstudio",
        "session.llm_model" => "local-model",
        "session.llm_runtime" => :arbor
      })

    outcome =
      LlmHandler.execute(build_node(), context, build_graph(),
        provider_route_input: %{assembled: "by-an-upstream-caller"}
      )

    # The initial defense-in-depth gate admits the original on-host provider.
    assert outcome.status == :success
    assert [{%Arbor.LLM.Request{provider: "lmstudio"}, opts}] = RecordingDispatcher.calls()

    authorizer = Keyword.fetch!(opts, :route_authorizer)

    local_route = %{
      provider: %Arbor.Contracts.LLM.ProviderEntry{
        id: :lmstudio,
        ref: "local-model",
        auth: :none,
        runtimes: [:arbor]
      }
    }

    external_route = %{
      provider: %Arbor.Contracts.LLM.ProviderEntry{
        id: :anthropic,
        ref: "claude-opus-4-6",
        auth: :api_key,
        runtimes: [:arbor]
      }
    }

    assert :allow = authorizer.(local_route)
    assert {:requires_approval, :egress} = authorizer.(external_route)
  end

  test "router mode ignores a stale blocked session provider and authorizes the exact route" do
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    exact_local_route = %{
      provider: %Arbor.Contracts.LLM.ProviderEntry{
        id: :lmstudio,
        ref: "local-fallback",
        auth: :none,
        runtimes: [:arbor]
      }
    }

    Application.put_env(:arbor_orchestrator, :llm_dispatcher, ExactRouteDispatcher)
    Application.put_env(:arbor_orchestrator, :_test_exact_route, exact_local_route)
    Application.put_env(:arbor_orchestrator, :_test_egress_pid, self())

    context =
      Arbor.Orchestrator.Engine.Context.new(%{
        "session.agent_id" => "agent_stale_provider_#{System.unique_integer([:positive])}",
        "session.llm_provider" => "anthropic",
        "session.llm_model" => "stale-cloud-model",
        "session.llm_runtime" => :arbor
      })

    outcome =
      LlmHandler.execute(build_node(), context, build_graph(),
        provider_route_input: %{assembled: "by-an-upstream-caller"}
      )

    # Legacy mode would stop at the stale external session provider. Router mode
    # reaches Dispatch and lets each selected/fallback destination decide itself.
    assert outcome.status == :success

    assert_receive {:exact_route_dispatch, %Arbor.LLM.Request{provider: "anthropic"}, :allow}
  end

  test "router mode installs a deterministic denial for missing or malformed principals" do
    route = %{
      provider: %Arbor.Contracts.LLM.ProviderEntry{
        id: :lmstudio,
        ref: "local-model",
        auth: :none,
        runtimes: [:arbor]
      }
    }

    Application.put_env(:arbor_orchestrator, :llm_dispatcher, ExactRouteDispatcher)
    Application.put_env(:arbor_orchestrator, :_test_exact_route, route)
    Application.put_env(:arbor_orchestrator, :_test_egress_pid, self())

    for invalid_principal <- [nil, "", " ", "system", 123] do
      context =
        Arbor.Orchestrator.Engine.Context.new(%{
          "session.agent_id" => invalid_principal,
          "session.llm_provider" => "lmstudio",
          "session.llm_model" => "local-model",
          "session.llm_runtime" => :arbor
        })

      outcome =
        LlmHandler.execute(build_node(), context, build_graph(),
          provider_route_input: %{assembled: "by-an-upstream-caller"}
        )

      assert outcome.status == :fail

      assert_receive {:exact_route_dispatch, _request,
                      {:error, {:egress_blocked, :external_provider, :invalid_principal}}}
    end
  end

  test "router input fails closed when the node would bypass Dispatch through ToolLoop" do
    node = put_in(build_node(), [:attrs, "use_tools"], "true")

    outcome =
      LlmHandler.execute(node, build_context(), build_graph(),
        provider_route_input: %{assembled: "by-an-upstream-caller"}
      )

    assert outcome.status == :fail

    assert outcome.failure_reason ==
             "ProviderRouter dispatch is not supported for tool-loop calls"

    assert RecordingDispatcher.calls() == []
  end
end
