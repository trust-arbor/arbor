defmodule Arbor.Orchestrator.Handlers.LlmHandlerProviderUsageContextTest do
  @moduledoc """
  Behavioral tests for trusted provider_usage_context derivation in LlmHandler.

  Direct path uses a recording Dispatcher. Tool-loop path uses a capturing
  provider adapter that receives Client.complete opts.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.ActionRegistry
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule RecordingDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
    def calls, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()

    @impl true
    def dispatch(request, opts) do
      Agent.update(__MODULE__, fn calls -> [{request, opts} | calls] end)

      {:ok,
       %Response{
         text: "ok",
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end
  end

  defmodule CapturingAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @parent_key {__MODULE__, :parent}

    def set_parent(pid), do: :persistent_term.put(@parent_key, pid)
    def clear_parent, do: :persistent_term.erase(@parent_key)

    @impl true
    def provider, do: "llm_usage_context_capture"

    @impl true
    def complete(%Request{} = request, opts) do
      send(:persistent_term.get(@parent_key), {:adapter_complete_opts, opts})

      case Enum.find(Enum.reverse(request.messages), &(&1.role == :tool)) do
        nil ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call("c1", "tool_help", %{"probe" => "usage"})
             ],
             raw: %{}
           }}

        _ ->
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  defmodule CapturingExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:tool_execution, name, args, workdir, opts})
      {:ok, "ok"}
    end
  end

  setup do
    {:ok, _} = RecordingDispatcher.start_link()
    RecordingDispatcher.reset()
    CapturingAdapter.set_parent(self())
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)

    on_exit(fn ->
      Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
      CapturingAdapter.clear_parent()

      if Process.whereis(RecordingDispatcher) do
        Agent.stop(RecordingDispatcher)
      end
    end)

    :ok
  end

  test "direct path derives principal/task/correlation from RunAuthorization + run_id" do
    {node, graph, authority, context} = build_authority_fixture("direct_usage")

    assert %{status: :success} =
             LlmHandler.execute(node, context, graph,
               run_authorization: authority,
               run_id: "run_direct_corr"
             )

    assert [{_request, opts}] = RecordingDispatcher.calls()

    assert opts[:provider_usage_context] == %{
             principal_id: authority.execution_principal,
             task_id: authority.task_id,
             correlation_id: "run_direct_corr"
           }
  end

  # On base e976, Keyword.put only overwrote when trusted derivation produced a
  # non-nil map. When derivation yields nil (no RunAuthorization and no valid
  # run_id), the old path returned opts unchanged and leaked caller context.
  # That is the case that fails on the parent and passes after Keyword.delete.
  @tag :security_regression
  test "security regression: untrusted provider_usage_context is omitted when no trusted attribution can be derived" do
    node = build_node(%{})

    graph =
      %Graph{
        id: "usage-graph-untrusted-omit",
        nodes: %{node.id => node},
        edges: [],
        attrs: %{"goal" => "usage"}
      }
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    node = Map.fetch!(graph.nodes, node.id)
    context = build_context()

    assert %{status: :success} =
             LlmHandler.execute(node, context, graph,
               # No :run_authorization. Invalid run_id cannot become correlation.
               run_id: "",
               provider_usage_context: %{
                 principal_id: "agent_attacker",
                 task_id: "task_attacker",
                 correlation_id: "corr_attacker",
                 goal_id: "goal_attacker"
               }
             )

    assert [{_request, opts}] = RecordingDispatcher.calls()
    refute Keyword.has_key?(opts, :provider_usage_context)
  end

  test "valid authority overwrites conflicting caller provider_usage_context" do
    {node, graph, authority, context} = build_authority_fixture("overwrite_usage")

    assert %{status: :success} =
             LlmHandler.execute(node, context, graph,
               run_authorization: authority,
               run_id: "run_trusted_corr",
               provider_usage_context: %{
                 principal_id: "agent_attacker",
                 task_id: "task_attacker",
                 correlation_id: "corr_attacker",
                 goal_id: "goal_attacker"
               }
             )

    assert [{_request, opts}] = RecordingDispatcher.calls()
    ctx = Keyword.fetch!(opts, :provider_usage_context)
    assert ctx.principal_id == authority.execution_principal
    assert ctx.task_id == authority.task_id
    assert ctx.correlation_id == "run_trusted_corr"
    refute ctx.principal_id == "agent_attacker"
    refute Map.get(ctx, :goal_id) == "goal_attacker"
  end

  test "run_id only yields correlation attribution" do
    node = build_node(%{})

    graph =
      %Graph{
        id: "usage-graph-run-only",
        nodes: %{node.id => node},
        edges: [],
        attrs: %{"goal" => "usage"}
      }
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    node = Map.fetch!(graph.nodes, node.id)
    context = build_context()

    assert %{status: :success} =
             LlmHandler.execute(node, context, graph, run_id: "run_only_corr")

    assert [{_request, opts}] = RecordingDispatcher.calls()
    assert opts[:provider_usage_context] == %{correlation_id: "run_only_corr"}
  end

  test "tool-loop path derives trusted provider_usage_context on Client.complete opts" do
    unless Process.whereis(ActionRegistry), do: start_supervised!({ActionRegistry, []})

    case ActionRegistry.register_action(Arbor.Actions.Tool.Help) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      {:error, :core_locked} -> :ok
    end

    node =
      %Node{
        id: "tool_usage_ctx",
        attrs: %{
          "type" => "compute",
          "simulate" => "false",
          "prompt" => "Call help",
          "use_tools" => "true",
          "tools" => "tool_help",
          "max_turns" => "2",
          "llm_provider" => CapturingAdapter.provider(),
          "llm_model" => "test"
        }
      }

    graph =
      %Graph{
        id: "tool_usage_ctx_graph",
        nodes: %{node.id => node},
        edges: [],
        attrs: %{"goal" => "usage context"}
      }
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    node = Map.fetch!(graph.nodes, node.id)

    {:ok, authority} =
      RunAuthorization.new(graph,
        execution_principal: "agent_tool_usage",
        caller_id: "human_tool_usage",
        author_id: "author_tool_usage",
        task_id: "task_tool_usage",
        session_id: "session_tool_usage",
        workdir: File.cwd!()
      )

    context =
      Context.new(%{
        "session.llm_provider" => CapturingAdapter.provider(),
        "session.llm_model" => "test"
      })
      |> RunAuthorization.enforce_context(authority)

    client =
      Client.new(default_provider: CapturingAdapter.provider())
      |> Client.register_adapter(CapturingAdapter)

    # Tool-loop does not use the orchestrator dispatcher env.
    Application.delete_env(:arbor_orchestrator, :llm_dispatcher)

    assert %{status: :success} =
             LlmHandler.execute(node, context, graph,
               authorization: true,
               run_authorization: authority,
               run_id: "run_tool_corr",
               llm_client: client,
               tool_executor: CapturingExecutor,
               workdir: File.cwd!(),
               provider_usage_context: %{
                 principal_id: "agent_attacker",
                 task_id: "task_attacker",
                 correlation_id: "corr_attacker"
               }
             )

    assert_receive {:adapter_complete_opts, complete_opts}
    ctx = Keyword.fetch!(complete_opts, :provider_usage_context)
    assert ctx.principal_id == "agent_tool_usage"
    assert ctx.task_id == "task_tool_usage"
    assert ctx.correlation_id == "run_tool_corr"
    refute ctx.principal_id == "agent_attacker"
  end

  defp build_authority_fixture(suffix) do
    node = build_node(%{})

    graph =
      %Graph{
        id: "usage-graph-#{suffix}",
        nodes: %{node.id => node},
        edges: [],
        attrs: %{"goal" => "usage"}
      }
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    node = Map.fetch!(graph.nodes, node.id)

    {:ok, authority} =
      RunAuthorization.new(graph,
        execution_principal: "agent_#{suffix}",
        caller_id: "human_#{suffix}",
        author_id: "author_#{suffix}",
        task_id: "task_#{suffix}",
        session_id: "session_#{suffix}",
        workdir: File.cwd!()
      )

    context =
      build_context()
      |> RunAuthorization.enforce_context(authority)

    {node, graph, authority, context}
  end

  defp build_node(attrs) do
    %Node{
      id: "usage-node",
      attrs:
        Map.merge(
          %{
            "type" => "compute",
            "simulate" => "false",
            "prompt" => "hi"
          },
          attrs
        )
    }
  end

  defp build_context do
    Context.new(%{
      "session.llm_provider" => "anthropic",
      "session.llm_model" => "claude-opus-4-6",
      "session.llm_runtime" => :arbor
    })
  end
end
