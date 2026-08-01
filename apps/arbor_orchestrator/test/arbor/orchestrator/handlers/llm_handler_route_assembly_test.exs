defmodule Arbor.Orchestrator.Handlers.LlmHandlerRouteAssemblyTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule RecordingDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    # Unlinked named Agent owned by this test module. setup starts it; on_exit
    # stops it explicitly. Avoid Agent.start_link (test-process link) and avoid
    # broad rescue/catch that would hide owner death.
    def start do
      case Agent.start(fn -> [] end, name: __MODULE__) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          :ok = stop_pid(pid)
          Agent.start(fn -> [] end, name: __MODULE__)
      end
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> stop_pid(pid)
      end
    end

    def calls, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    defp stop_pid(pid) do
      if Process.alive?(pid) do
        Agent.stop(pid)
      else
        :ok
      end
    end

    @impl true
    def dispatch(request, opts) do
      Agent.update(__MODULE__, fn calls -> [{request, opts} | calls] end)

      spoof? =
        Application.get_env(:arbor_orchestrator, :_test_legacy_spoof_executed_route)

      usage =
        case {Keyword.get(opts, :provider_route_input), spoof?} do
          {nil, true} ->
            %{
              :input_tokens => 1,
              :output_tokens => 1,
              "arbor.executed_route" => %{
                "provider" => "attacker",
                "provider_ref" => "spoofed-ref",
                "model" => "spoofed-model",
                "runtime" => "arbor",
                "attempt" => "primary",
                "route_identity" => "router_selected",
                "provider_confirmed" => false
              }
            }

          {nil, _} ->
            %{input_tokens: 1, output_tokens: 1}

          {_input, _} ->
            route = %{
              "provider" => "provider_a",
              "provider_ref" => "wire-primary",
              "model" => "primary",
              "runtime" => "arbor",
              "attempt" => "primary",
              "route_identity" => "router_selected",
              "provider_confirmed" => false
            }

            route =
              if Application.get_env(:arbor_orchestrator, :_test_confirmed_route) do
                route
                |> Map.put("provider_ref", "wire-primary")
                |> Map.put("provider_confirmed", true)
                |> Map.put("confirmed_model", "wire-primary")
              else
                route
              end

            route =
              case Application.get_env(:arbor_orchestrator, :_test_route_override) do
                override when is_map(override) -> override
                _ -> route
              end

            %{
              :input_tokens => 1,
              :output_tokens => 1,
              "arbor.executed_route" => route
            }
        end

      {:ok,
       %Arbor.LLM.Response{
         text: "assembled ok",
         finish_reason: :stop,
         usage: usage
       }}
    end
  end

  defmodule IncompleteRouteDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    @impl true
    def dispatch(_request, _opts) do
      {:ok,
       %Arbor.LLM.Response{
         text: "incomplete",
         finish_reason: :stop,
         usage: %{
           :input_tokens => 1,
           :output_tokens => 1,
           "arbor.executed_route" => %{
             "provider" => "provider_a",
             "model" => "primary"
           }
         }
       }}
    end
  end

  setup do
    {:ok, _} = RecordingDispatcher.start()
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)

    prior_profile = Application.get_env(:arbor_ai, :provider_route_profile)

    on_exit(fn ->
      Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
      Application.delete_env(:arbor_orchestrator, :_test_legacy_spoof_executed_route)
      Application.delete_env(:arbor_orchestrator, :_test_confirmed_route)
      Application.delete_env(:arbor_orchestrator, :_test_route_override)
      _ = RecordingDispatcher.stop()

      case prior_profile do
        nil -> Application.delete_env(:arbor_ai, :provider_route_profile)
        value -> Application.put_env(:arbor_ai, :provider_route_profile, value)
      end
    end)

    :ok
  end

  defp route_node, do: %{id: "route-node", attrs: %{"simulate" => "false", "prompt" => "hi"}}
  defp graph, do: %{attrs: %{"goal" => "g"}}

  defp context do
    Arbor.Orchestrator.Engine.Context.new(%{
      "session.agent_id" => "agent_route_assembly_#{System.unique_integer([:positive])}",
      "session.llm_provider" => "session-provider",
      "session.llm_model" => "session-model",
      "session.llm_runtime" => :arbor
    })
  end

  test "disabled profile preserves legacy dispatch without provider_route_input" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})

    outcome = LlmHandler.execute(route_node(), context(), graph(), [])
    assert outcome.status == :success
    assert [{_request, opts}] = RecordingDispatcher.calls()
    refute Keyword.has_key?(opts, :provider_route_input)
    refute Map.has_key?(outcome.context_updates, "turn.executed_route")
    refute Map.has_key?(outcome.context_updates, "session.llm_provider")
    refute Map.has_key?(outcome.context_updates, "session.llm_model")
  end

  test "disabled/legacy spoof of arbor.executed_route does not rewrite attribution" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})
    Application.put_env(:arbor_orchestrator, :_test_legacy_spoof_executed_route, true)

    outcome = LlmHandler.execute(route_node(), context(), graph(), [])
    assert outcome.status == :success
    assert [{_request, opts}] = RecordingDispatcher.calls()
    refute Keyword.has_key?(opts, :provider_route_input)

    usage = outcome.context_updates["session.usage"]
    assert usage["provider"] == "session-provider"
    assert usage["model"] == "session-model"
    refute Map.has_key?(usage, "arbor.executed_route")
    refute Map.has_key?(outcome.context_updates, "turn.executed_route")
    refute Map.has_key?(outcome.context_updates, "session.llm_provider")
    refute Map.has_key?(outcome.context_updates, "session.llm_model")
  end

  test "enabled assembly failure is terminal and never reaches dispatcher" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog: [],
      scoreboard: [],
      providers: [],
      params: %{}
    })

    outcome = LlmHandler.execute(route_node(), context(), graph(), [])
    assert outcome.status == :fail
    assert outcome.failure_reason =~ "Provider route assembly failed"
    assert RecordingDispatcher.calls() == []
  end

  test "explicit provider_route_input still installs authorizer and attributes executed route" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})

    outcome =
      LlmHandler.execute(
        route_node(),
        context(),
        graph(),
        provider_route_input: %{assembled: "by-test"}
      )

    assert outcome.status == :success
    assert [{_request, opts}] = RecordingDispatcher.calls()
    assert Keyword.has_key?(opts, :provider_route_input)
    assert is_function(Keyword.fetch!(opts, :route_authorizer), 1)

    usage = outcome.context_updates["session.usage"]
    assert usage["provider"] == "provider_a"
    assert usage["model"] == "primary"
    assert usage["arbor.executed_route"]["provider"] == "provider_a"
    assert usage["arbor.executed_route"]["provider_ref"] == "wire-primary"
    assert usage["arbor.executed_route"]["runtime"] == "arbor"
    assert usage["arbor.executed_route"]["attempt"] == "primary"
    assert usage["arbor.executed_route"]["route_identity"] == "router_selected"
    assert usage["arbor.executed_route"]["provider_confirmed"] == false
    assert outcome.context_updates["turn.executed_route"]["model"] == "primary"
    # Persistent session defaults are not rewritten.
    refute Map.has_key?(outcome.context_updates, "session.llm_provider")
    refute Map.has_key?(outcome.context_updates, "session.llm_model")
    refute Map.has_key?(outcome.context_updates, "session.llm_runtime")
  end

  test "confirmed executed route survives sanitizer into usage and context" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})
    Application.put_env(:arbor_orchestrator, :_test_confirmed_route, true)

    outcome =
      LlmHandler.execute(
        route_node(),
        context(),
        graph(),
        provider_route_input: %{assembled: "by-test"}
      )

    assert outcome.status == :success
    executed = outcome.context_updates["session.usage"]["arbor.executed_route"]
    assert executed["provider_confirmed"] == true
    assert executed["model"] == "primary"
    assert executed["provider_ref"] == "wire-primary"
    assert executed["confirmed_model"] == "wire-primary"
    assert outcome.context_updates["turn.executed_route"]["model"] == "primary"
    assert outcome.context_updates["turn.executed_route"]["confirmed_model"] == "wire-primary"
  end

  test "security regression: confirmed route requires exact model and rejects alias conflicts" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})

    routes = [
      %{
        "provider" => "provider_a",
        "provider_ref" => "wire-primary",
        "model" => "primary",
        "runtime" => "arbor",
        "attempt" => "primary",
        "route_identity" => "router_selected",
        "provider_confirmed" => true,
        "confirmed_model" => "primary"
      },
      %{
        "provider" => "provider_a",
        "provider_ref" => "primary",
        "model" => "primary",
        "runtime" => "arbor",
        "attempt" => "primary",
        "route_identity" => "router_selected",
        "provider_confirmed" => true,
        "confirmed_model" => "primary",
        :confirmed_model => "attacker-model"
      }
    ]

    Enum.each(routes, fn route ->
      Application.put_env(:arbor_orchestrator, :_test_route_override, route)

      outcome =
        LlmHandler.execute(
          route_node(),
          context(),
          graph(),
          provider_route_input: %{assembled: "by-test"}
        )

      assert outcome.status == :success
      refute Map.has_key?(outcome.context_updates["session.usage"], "arbor.executed_route")
      refute Map.has_key?(outcome.context_updates, "turn.executed_route")
      Application.delete_env(:arbor_orchestrator, :_test_route_override)
    end)
  end

  test "incomplete executed_route evidence is ignored even in router mode" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, IncompleteRouteDispatcher)

    outcome =
      LlmHandler.execute(
        route_node(),
        context(),
        graph(),
        provider_route_input: %{assembled: "by-test"}
      )

    assert outcome.status == :success
    usage = outcome.context_updates["session.usage"]
    assert usage["provider"] == "session-provider"
    assert usage["model"] == "session-model"
    refute Map.has_key?(usage, "arbor.executed_route")
    refute Map.has_key?(outcome.context_updates, "turn.executed_route")
  end

  test "tool-loop still rejects provider router mode" do
    node = put_in(route_node(), [:attrs, "use_tools"], "true")

    outcome =
      LlmHandler.execute(
        node,
        context(),
        graph(),
        provider_route_input: %{assembled: "by-test"}
      )

    assert outcome.status == :fail

    assert outcome.failure_reason ==
             "ProviderRouter dispatch is not supported for tool-loop calls"

    assert RecordingDispatcher.calls() == []
  end
end
