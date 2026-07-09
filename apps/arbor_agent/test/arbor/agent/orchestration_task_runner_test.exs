defmodule Arbor.Agent.OrchestrationTaskRunnerTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Orchestration.TaskRunner
  alias Arbor.Contracts.Session.UserMessage

  defmodule FakeStructuredManager do
    def chat_response(input, sender, opts) do
      send(self(), {:chat_response, input, sender, opts})

      coding_result = %{
        "status" => "pr_created",
        "branch" => "agent/change",
        "commit" => "abc123",
        "diff" => "diff --git a/lib/a.ex b/lib/a.ex\n+ok\n",
        "files" => ["lib/a.ex"],
        "validation" => [%{"command" => "./bin/mix test", "passed" => true}],
        "review" => %{
          "recommendation" => "keep",
          "tier_decision" => "human_review",
          "human_required" => true
        },
        "pr_url" => "https://example.test/pr/1"
      }

      {:ok,
       %{
         text: "Opened a draft PR.",
         tool_calls: [
           %{
             name: "coding_produce_reviewable_change",
             result: Jason.encode!(coding_result)
           }
         ],
         tool_rounds: 1
       }}
    end
  end

  defmodule FakeLegacyManager do
    def chat(input, sender, opts) do
      send(self(), {:chat, input, sender, opts})
      {:ok, "plain response"}
    end
  end

  test "preserves coding-agent artifacts from structured manager tool history" do
    assert {:ok, result} =
             TaskRunner.run("agent_1", "write a patch",
               manager_module: FakeStructuredManager,
               timeout: 120_000
             )

    assert_received {:chat_response, "write a patch", "Orchestration", opts}
    assert opts[:agent_id] == "agent_1"
    assert opts[:timeout] == 120_000

    assert result.result_type == :coding_change
    assert result.payload.branch == "agent/change"
    assert result.payload.diff =~ "diff --git"
    assert result.payload.files == ["lib/a.ex"]
    assert result.payload.pr_url == "https://example.test/pr/1"
    assert result.payload.report.review["recommendation"] == "keep"
    assert result.payload.verdict.recommendation == "keep"
    assert result.source == :tool_history
  end

  test "falls back to legacy chat managers as generic chat results" do
    assert {:ok, result} =
             TaskRunner.run("agent_1", "say hi", manager_module: FakeLegacyManager)

    assert_received {:chat, "say hi", "Orchestration", opts}
    assert opts[:agent_id] == "agent_1"
    assert result.result_type == :chat
    assert result.payload.text == "plain response"
  end

  test "passes task id through typed user message metadata" do
    assert {:ok, result} =
             TaskRunner.run("agent_1", "write a patch",
               manager_module: FakeStructuredManager,
               task_id: "task_1"
             )

    assert_received {:chat_response, %UserMessage{} = message, "Orchestration", opts}
    assert message.content == "write a patch"
    assert message.sender == "Orchestration"
    assert message.transport == :cli
    assert message.transport_metadata == %{task_id: "task_1"}
    assert opts[:agent_id] == "agent_1"
    assert opts[:task_id] == "task_1"
    assert result.result_type == :coding_change
  end
end
