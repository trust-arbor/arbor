defmodule Arbor.Orchestrator.Handlers.LlmHandlerProviderFallbackTest do
  @moduledoc """
  Host-configured provider fallback at call time: a node pinning a provider
  this host cannot call is rerouted to the first available fallback, and the
  actual route is recorded in `llm.provider` / `llm.model` so downstream
  consumers (council `reviewer_outcomes`) name the provider that voted.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Response
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
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
       %Response{text: "ok", finish_reason: :stop, usage: %{input_tokens: 1, output_tokens: 1}}}
    end
  end

  @env_keys [
    :llm_dispatcher,
    :llm_provider_availability,
    :llm_fallback_providers,
    :llm_provider_fallbacks
  ]

  setup do
    previous = Map.new(@env_keys, &{&1, Application.get_env(:arbor_orchestrator, &1)})
    {:ok, _} = RecordingDispatcher.start_link()
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:arbor_orchestrator, k)
        {k, v} -> Application.put_env(:arbor_orchestrator, k, v)
      end)

      if Process.whereis(RecordingDispatcher), do: Agent.stop(RecordingDispatcher)
    end)

    :ok
  end

  defp run(attrs) do
    node = %Node{
      id: "seat",
      attrs: Map.merge(%{"type" => "compute", "simulate" => "false", "prompt" => "review"}, attrs)
    }

    graph =
      %Graph{id: "fallback-graph", nodes: %{node.id => node}, edges: [], attrs: %{"goal" => "g"}}
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    node = Map.fetch!(graph.nodes, node.id)

    context =
      Context.new(%{
        "session.llm_provider" => "anthropic",
        "session.llm_model" => "claude-opus-4-6",
        "session.llm_runtime" => :arbor
      })

    LlmHandler.execute(node, context, graph, run_id: "run_fallback")
  end

  test "an unavailable pinned provider is rerouted and the actual route is recorded" do
    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn p ->
      p == "xai_oauth"
    end)

    Application.put_env(:arbor_orchestrator, :llm_fallback_providers, [{"xai_oauth", "grok-4.6"}])
    Application.put_env(:arbor_orchestrator, :llm_provider_fallbacks, %{})

    assert %{status: :success, context_updates: updates} =
             run(%{"llm_provider" => "ollama", "llm_model" => "glm-5.2:cloud"})

    assert [{request, _opts}] = RecordingDispatcher.calls()
    assert request.provider == "xai_oauth"
    assert request.model == "grok-4.6"
    assert updates["llm.provider"] == "xai_oauth"
    assert updates["llm.model"] == "grok-4.6"
    assert %{action: :provider_fallback} = updates["__routing_decision__"]
  end

  test "an available pinned provider is left alone" do
    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn _ -> true end)
    Application.put_env(:arbor_orchestrator, :llm_fallback_providers, [{"xai_oauth", "grok-4.6"}])

    assert %{status: :success, context_updates: updates} =
             run(%{"llm_provider" => "ollama", "llm_model" => "glm-5.2:cloud"})

    assert [{request, _}] = RecordingDispatcher.calls()
    assert request.provider == "ollama"
    assert updates["llm.provider"] == "ollama"
    refute Map.has_key?(updates, "__routing_decision__")
  end

  test "a session-default provider (no llm_provider attr) is never rerouted" do
    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn _ -> false end)
    Application.put_env(:arbor_orchestrator, :llm_fallback_providers, [{"xai_oauth", "grok-4.6"}])

    assert %{context_updates: updates} = run(%{})

    assert [{request, _}] = RecordingDispatcher.calls()
    assert request.provider == "anthropic"
    refute Map.has_key?(updates, "__routing_decision__")
  end

  test "llm_fallback=false pins the provider even when unavailable" do
    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn _ -> false end)
    Application.put_env(:arbor_orchestrator, :llm_fallback_providers, [{"xai_oauth", "grok-4.6"}])

    assert %{context_updates: updates} =
             run(%{"llm_provider" => "ollama", "llm_model" => "m", "llm_fallback" => "false"})

    assert [{request, _}] = RecordingDispatcher.calls()
    assert request.provider == "ollama"
    refute Map.has_key?(updates, "__routing_decision__")
  end
end
