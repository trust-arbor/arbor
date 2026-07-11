defmodule Arbor.LLM.ToolLoopAuthorityTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}

  defmodule TwoToolAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "tool_authority_test"

    @impl true
    def complete(%Request{} = request, _opts) do
      case Enum.count(request.messages, &(&1.role == :tool)) do
        0 -> {:ok, tool_call("call_1", "first_action")}
        1 -> {:ok, tool_call("call_2", "second_action")}
        _ -> {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end

    defp tool_call(id, name) do
      %Response{
        text: "",
        finish_reason: :tool_calls,
        content_parts: [ContentPart.tool_call(id, name, %{"value" => name})],
        raw: %{}
      }
    end
  end

  defmodule CapturingExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:tool_execution, name, args, workdir, opts})
      {:ok, "executed #{name}"}
    end
  end

  defp client do
    Client.new(default_provider: TwoToolAdapter.provider())
    |> Client.register_adapter(TwoToolAdapter)
  end

  defp request do
    %Request{
      provider: TwoToolAdapter.provider(),
      model: "test",
      messages: [Message.new(:user, "run both tools")]
    }
  end

  defp tools do
    for name <- ["first_action", "second_action"] do
      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => name,
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }
    end
  end

  test "authorized runs forward immutable caller and scope on every tool invocation" do
    # Opaque authority value — ToolLoop must not inspect or reconstruct it.
    # Nested action lineage depends on the exact term being forwarded.
    opaque_run_authorization =
      {:opaque_run_authorization, "child-council-authority", make_ref()}

    authority = [
      authorization: true,
      execution_principal: "agent_executor",
      caller_id: "human_caller",
      author_id: "agent_architect",
      task_id: "task_scoped",
      session_id: "session_scoped"
    ]

    manifest = %{"version" => 1, "actions" => []}
    action_bindings = %{"first_action" => %{"module" => "Arbor.Actions.First"}}

    assert {:ok, result} =
             ToolLoop.run(
               client(),
               request(),
               authority ++
                 [
                   run_authorization: opaque_run_authorization,
                   execution_manifest: manifest,
                   execution_manifest_digest: "manifest-digest",
                   pinned_action_bindings: action_bindings,
                   tool_executor: CapturingExecutor,
                   tools: tools(),
                   workdir: "/workspace",
                   max_turns: 3
                 ]
             )

    expected_opts = [
      execution_principal: "agent_executor",
      agent_id: "agent_executor",
      caller_id: "human_caller",
      author_id: "agent_architect",
      task_id: "task_scoped",
      session_id: "session_scoped",
      run_authorization: opaque_run_authorization,
      execution_manifest: manifest,
      execution_manifest_digest: "manifest-digest",
      pinned_action_bindings: action_bindings
    ]

    assert_receive {:tool_execution, "first_action", %{"value" => "first_action"}, "/workspace",
                    first_opts}

    assert_receive {:tool_execution, "second_action", %{"value" => "second_action"}, "/workspace",
                    second_opts}

    assert Map.new(first_opts) == Map.new(expected_opts)
    assert Map.new(second_opts) == Map.new(expected_opts)
    # Exact term identity — not a reconstructed copy of authority fields.
    assert Keyword.fetch!(first_opts, :run_authorization) === opaque_run_authorization
    assert Keyword.fetch!(second_opts, :run_authorization) === opaque_run_authorization
    assert result.content == "done"
  end

  test "authorized runs fail closed instead of defaulting a missing caller to system" do
    assert {:error, {:missing_authorized_tool_binding, :caller_id}} =
             ToolLoop.run(client(), request(),
               authorization: true,
               execution_principal: "agent_executor",
               author_id: "agent_architect",
               task_id: "task_scoped",
               session_id: "session_scoped",
               tool_executor: CapturingExecutor,
               tools: tools()
             )

    refute_received {:tool_execution, _, _, _, _}
  end

  test "authorized runs reject invalid UTF-8 and NUL identity bindings" do
    for {key, value} <- [caller_id: <<255>>, author_id: "author\0id", task_id: "\0"] do
      opts =
        [
          authorization: true,
          execution_principal: "agent_executor",
          caller_id: "human_caller",
          author_id: "agent_architect",
          task_id: "task_scoped",
          session_id: "session_scoped",
          tool_executor: CapturingExecutor,
          tools: tools()
        ]
        |> Keyword.put(key, value)

      assert {:error, {:invalid_authorized_tool_binding, ^key}} =
               ToolLoop.run(client(), request(), opts)
    end

    refute_received {:tool_execution, _, _, _, _}
  end
end
