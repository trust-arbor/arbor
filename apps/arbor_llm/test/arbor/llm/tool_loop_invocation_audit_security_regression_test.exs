defmodule Arbor.LLM.ToolLoopInvocationAuditSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "invocation_audit_test"
    def complete(request, _opts) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      else
        {:ok, %Response{text: "", finish_reason: :tool_calls, raw: %{},
          content_parts: [ContentPart.tool_call("provider_call_123", "synthetic_export", %{})]}}
      end
    end
  end

  defmodule Executor do
    def execute(_name, _args, _cwd, opts) do
      send(self(), {:export_effect, opts})
      {:ok, "exported"}
    end
  end

  defmodule Auditor do
    def with_invocation_audit(attributes, _fun) do
      send(self(), {:audit_attempt, attributes})
      {:error, :invocation_audit_unavailable}
    end
  end

  setup do
    old = Application.fetch_env(:arbor_llm, :tool_invocation_auditor)
    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:arbor_llm, :tool_invocation_auditor, value)
        :error -> Application.delete_env(:arbor_llm, :tool_invocation_auditor)
      end
    end)
    :ok
  end

  test "security regression: non-Actions executor cannot dispatch without required durable audit" do
    Application.put_env(:arbor_llm, :tool_invocation_auditor, Auditor)
    assert {:ok, _} = run()
    assert_receive {:audit_attempt, %{provider_call_id: "provider_call_123", tool: "synthetic_export"}}
    refute_receive {:export_effect, _}
  end

  test "security regression: missing required auditor refuses rather than falling back to raw dispatch" do
    Application.put_env(:arbor_llm, :tool_invocation_auditor, __MODULE__.Missing)
    assert {:ok, _} = run()
    refute_receive {:export_effect, _}
  end

  test "provider call identity reaches a deliberately standalone executor" do
    Application.put_env(:arbor_llm, :tool_invocation_auditor, :disabled)
    assert {:ok, _} = run()
    assert_receive {:export_effect, opts}
    assert opts[:provider_call_id] == "provider_call_123"
  end

  defp run do
    client = Client.new(default_provider: Adapter.provider()) |> Client.register_adapter(Adapter)
    request = %Request{provider: Adapter.provider(), model: "test",
      messages: [Message.new(:user, "use the tool")]}
    tools = [%{"type" => "function", "function" => %{"name" => "synthetic_export",
      "description" => "synthetic export", "parameters" => %{"type" => "object", "properties" => %{}}}}]
    ToolLoop.run(client, request, tool_executor: Executor, tools: tools, max_turns: 3,
      agent_id: "agent_audit_test", workdir: "/tmp")
  end
end
