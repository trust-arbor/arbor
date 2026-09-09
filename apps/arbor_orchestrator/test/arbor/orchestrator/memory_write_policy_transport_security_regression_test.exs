defmodule Arbor.Orchestrator.MemoryWritePolicyTransportSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.{ExecHandler, LlmHandler, PipelineRunHandler, SubgraphHandler}

  @moduletag :fast

  defmodule CaptureExecutor do
    def execute(name, args, _workdir, opts) do
      send(self(), {:executed, name, args, opts})
      {:ok, "captured"}
    end
  end

  defmodule FabricatedToolAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "memory_write_transport_test"

    def complete(%Request{} = request, opts) do
      observer = Process.whereis(__MODULE__)
      send(observer, {:provider_opts, opts})

      case Enum.find(request.messages, &(&1.role == :tool)) do
        nil ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call("fabricated", "memory_remember", %{
                 "content" => "private input must not become an unscoped fact",
                 "type" => "fact",
                 "memory_write_policy" => "allow"
               })
             ],
             raw: %{}
           }}

        result ->
          send(observer, {:tool_result, result})
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  defmodule RouteDispatcher do
    @behaviour Arbor.LLM.Dispatcher

    def dispatch(request, opts) do
      send(self(), {:dispatch_opts, opts})

      route = %{
        provider: request.provider,
        model: "test",
        runtime: request.runtime,
        destination: request.provider
      }

      case Keyword.get(opts, :route_authorizer, fn _ -> :allow end).(route) do
        :allow -> {:ok, %Response{text: "local route allowed", finish_reason: :stop}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  test "security regression: exec forwards source policy despite conflicting graph data" do
    node = %Node{
      id: "memory",
      attrs: %{
        "target" => "action",
        "action" => "memory_remember",
        "memory_write_policy" => "allow",
        "param.memory_write_policy" => "allow"
      }
    }

    context = Context.new(%{"memory_write_policy" => "allow"})

    assert %{status: :success} =
             ExecHandler.execute(node, context, %Graph{},
               actions_executor: CaptureExecutor,
               memory_write_policy: :deny
             )

    assert_received {:executed, "memory_remember", _args, opts}
    assert Keyword.fetch!(opts, :memory_write_policy) == :deny

    assert %{status: :success} =
             ExecHandler.execute(node, context, %Graph{}, actions_executor: CaptureExecutor)

    assert_received {:executed, "memory_remember", _args, legacy_opts}
    refute Keyword.has_key?(legacy_opts, :memory_write_policy)
  end

  test "security regression: fabricated unadvertised tool reaches the real memory write gate" do
    Process.register(self(), FabricatedToolAdapter)

    client =
      Client.new(default_provider: FabricatedToolAdapter.provider())
      |> Client.register_adapter(FabricatedToolAdapter)

    node = %Node{
      id: "llm",
      attrs: %{
        "simulate" => "false",
        "prompt" => "test",
        "use_tools" => "true",
        "tools" => "tool_help",
        "max_turns" => "2",
        "memory_write_policy" => "allow",
        "llm_provider" => FabricatedToolAdapter.provider(),
        "llm_model" => "test"
      }
    }

    assert %{status: :success} =
             LlmHandler.execute(node, Context.new(), %Graph{},
               llm_client: client,
               authorization: false,
               memory_write_policy: :deny
             )

    assert_received {:tool_result, result}
    assert inspect(result) =~ "private_turn_memory_write_denied"
    assert_received {:provider_opts, provider_opts}
    refute Keyword.has_key?(provider_opts, :memory_write_policy)
  end

  for {handler, type} <- [
        {SubgraphHandler, "graph.compose"},
        {PipelineRunHandler, "pipeline.run"}
      ] do
    @handler handler
    @child_type type
    test "security regression: #{@child_type} retains deny in the actual child Engine" do
      source = """
      digraph Child {
        start [shape=Mdiamond]
        remember [type="exec", target="action", action="memory_remember",
          param.content="private data", param.type="fact", memory_write_policy="allow"]
        done [shape=Msquare]
        start -> remember -> done
      }
      """

      node = %Node{
        id: "child",
        attrs: %{
          "type" => @child_type,
          "source_key" => "child_source",
          "memory_write_policy" => "allow"
        }
      }

      outcome =
        @handler.execute(node, Context.new(%{"child_source" => source}), %Graph{},
          memory_write_policy: :deny,
          resumable: false
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "private_turn_memory_write_denied"
    end
  end

  test "security regression: native runtime launch is denied while local runtime remains usable" do
    configure_route_dispatcher!()

    for policy <- [:deny, :invalid_policy] do
      native = direct_node("acp")
      outcome = LlmHandler.execute(native, Context.new(), %Graph{}, memory_write_policy: policy)
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "memory_write_policy_runtime_unsupported"
    end

    assert %{status: :success} =
             LlmHandler.execute(direct_node("arbor"), Context.new(), %Graph{},
               memory_write_policy: :deny
             )

    assert_received {:dispatch_opts, opts}
    refute Keyword.has_key?(opts, :memory_write_policy)
  end

  test "security regression: legacy ACP provider cannot use the arbor runtime" do
    configure_route_dispatcher!()

    for policy <- [:deny, :invalid_policy] do
      outcome =
        LlmHandler.execute(direct_node("arbor", "acp"), Context.new(), %Graph{},
          memory_write_policy: policy
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "memory_write_policy_runtime_unsupported"
    end

    assert %{status: :success} =
             LlmHandler.execute(direct_node("arbor", "acp"), Context.new(), %Graph{}, [])
  end

  test "security regression: fallback callback denies scalar and projected ACP providers" do
    configure_route_dispatcher!()

    assert %{status: :success} =
             LlmHandler.execute(direct_node("arbor"), Context.new(), %Graph{},
               memory_write_policy: :deny
             )

    assert_received {:dispatch_opts, opts}
    authorize_route = Keyword.fetch!(opts, :route_authorizer)

    for provider <- ["acp", :acp, %{id: :legacy}] do
      assert {:error, :memory_write_policy_runtime_unsupported} =
               authorize_route.(%{
                 provider: provider,
                 destination: "acp",
                 runtime: "arbor",
                 model: "test"
               })
    end

    assert :allow =
             authorize_route.(%{
               provider: "lmstudio",
               destination: "lmstudio",
               runtime: "arbor",
               model: "test"
             })
  end

  defp configure_route_dispatcher! do
    previous = Application.fetch_env(:arbor_orchestrator, :llm_dispatcher)
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RouteDispatcher)

    on_exit(fn ->
      case previous do
        {:ok, module} -> Application.put_env(:arbor_orchestrator, :llm_dispatcher, module)
        :error -> Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
      end
    end)
  end

  defp direct_node(runtime, provider \\ "lmstudio") do
    %Node{
      id: "direct",
      attrs: %{
        "simulate" => "false",
        "prompt" => "test",
        "llm_runtime" => runtime,
        "llm_provider" => provider,
        "llm_model" => "test"
      }
    }
  end
end
