defmodule Arbor.Orchestrator.Handlers.LlmHandlerToolTaintTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Security.Taint
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.LlmHandler
  alias Arbor.Signals.Taint, as: SignalTaint

  @moduletag :fast
  @moduletag :security_regression

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "llm_handler_tool_taint_test"

    def complete(%Request{} = request, _opts) do
      case Enum.any?(request.messages, &(&1.role == :tool)) do
        false ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call("tainted_call", "tool_help", %{
                 "topic" => "taint",
                 "detail" => true
               })
             ],
             raw: %{}
           }}

        true ->
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  defmodule CapturingExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:tool_execution, name, args, workdir, opts})
      {:ok, "captured"}
    end
  end

  setup do
    unless Process.whereis(ActionRegistry), do: start_supervised!({ActionRegistry, []})

    case ActionRegistry.register_action(Arbor.Actions.Tool.Help) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      {:error, :core_locked} -> :ok
    end

    :ok
  end

  test "derives one full LLM label for Outcome and every normalized tool parameter" do
    prompt_taint = %Taint{
      level: :untrusted,
      sensitivity: :confidential,
      sanitizations: 255,
      confidence: :verified,
      source: "authenticated_session",
      chain: ["user_message"]
    }

    irrelevant_taint = %Taint{level: :hostile, sensitivity: :restricted}

    {node, graph} =
      tool_graph(%{
        "prompt_context_key" => "turn.prompt",
        "system_prompt_context_key" => "turn.system"
      })

    authority = authority(graph)

    context =
      Context.new(
        %{
          "turn.prompt" => "Use the help tool",
          "turn.system" => "You are a tool caller",
          "unrelated.secret" => "must not affect this call"
        },
        taint: %{
          "turn.prompt" => prompt_taint,
          "turn.system" => %Taint{
            level: :trusted,
            sensitivity: :public,
            confidence: :verified
          },
          "unrelated.secret" => irrelevant_taint
        }
      )
      |> RunAuthorization.enforce_context(authority)

    expected =
      context
      |> Context.worst_taint(["turn.prompt", "turn.system"])
      |> SignalTaint.for_llm_output()

    assert %{status: :success, output_taint: ^expected} =
             LlmHandler.execute(node, context, graph,
               authorization: true,
               run_authorization: authority,
               llm_client: client(),
               tool_executor: CapturingExecutor,
               workdir: File.cwd!()
             )

    assert expected.level == :untrusted
    assert expected.sensitivity == :confidential
    assert expected.sanitizations == 0
    assert expected.confidence == :plausible
    assert expected.source == "llm_output"

    assert_receive {:tool_execution, "tool_help", args, _workdir, exec_opts}
    assert Keyword.fetch!(exec_opts, :taint) == expected
    assert Keyword.fetch!(exec_opts, :param_taint) == Map.new(Map.keys(args), &{&1, expected})
    refute Map.has_key?(context.values, "tool_taint")
  end

  test "nonempty message history replaces prompt and council inputs in the selector" do
    {node, graph} =
      simulated_graph(
        %{
          "messages_context_key" => "turn.messages",
          "prompt_context_key" => "turn.prompt",
          "perspective" => "security"
        },
        %{"mode" => "decision"}
      )

    context =
      Context.new(
        %{
          "turn.messages" => [%{"role" => "user", "content" => "history wins"}],
          "turn.prompt" => "not sent",
          "council.question" => "also not sent",
          "unrelated" => "not sent"
        },
        taint: %{
          "turn.messages" => %Taint{level: :trusted, sensitivity: :public},
          "turn.prompt" => %Taint{level: :hostile},
          "council.question" => %Taint{level: :hostile},
          "unrelated" => %Taint{level: :hostile}
        }
      )

    assert %{output_taint: output_taint} = LlmHandler.execute(node, context, graph, [])
    assert %Taint{level: :derived, sensitivity: :public, sanitizations: 0} = output_taint
  end

  test "decision perspective selects council.question instead of the prompt context key" do
    {node, graph} =
      simulated_graph(
        %{"prompt_context_key" => "turn.prompt", "perspective" => "security"},
        %{"mode" => "decision"}
      )

    context =
      Context.new(
        %{"turn.prompt" => "not sent", "council.question" => "review this"},
        taint: %{
          "turn.prompt" => %Taint{level: :trusted},
          "council.question" => %Taint{level: :hostile, sensitivity: :restricted}
        }
      )

    assert %{output_taint: output_taint} = LlmHandler.execute(node, context, graph, [])
    assert %Taint{level: :hostile, sensitivity: :restricted, sanitizations: 0} = output_taint
  end

  defp tool_graph(extra_attrs) do
    graph(
      Map.merge(
        %{
          "type" => "compute",
          "simulate" => "false",
          "use_tools" => "true",
          "tools" => "tool_help",
          "max_turns" => "2",
          "llm_provider" => Adapter.provider(),
          "llm_model" => "test"
        },
        extra_attrs
      ),
      %{}
    )
  end

  defp simulated_graph(attrs, graph_attrs) do
    graph(Map.merge(%{"type" => "compute", "simulate" => "true"}, attrs), graph_attrs)
  end

  defp graph(attrs, graph_attrs) do
    node = %Node{id: "taint_compute", attrs: attrs}

    compiled =
      %Graph{
        id: "taint_graph",
        nodes: %{node.id => node},
        edges: [],
        attrs: Map.put_new(graph_attrs, "goal", "taint")
      }
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    {Map.fetch!(compiled.nodes, node.id), compiled}
  end

  defp authority(graph) do
    {:ok, authority} =
      RunAuthorization.new(graph,
        execution_principal: "agent_tool_taint",
        caller_id: "human_tool_taint",
        author_id: "agent_tool_taint_author",
        task_id: "task_tool_taint",
        session_id: "session_tool_taint",
        workdir: File.cwd!()
      )

    authority
  end

  defp client do
    Client.new(default_provider: Adapter.provider())
    |> Client.register_adapter(Adapter)
  end
end
