defmodule Arbor.Orchestrator.Session.CompactionSummaryRoleSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Session.Persistence.Core

  test "security regression: compaction summary role is projected and is not rewritten as user" do
    messages = [
      %{role: :system, content: "You are a helpful agent."},
      %{
        role: :summary,
        content: "Context summary of earlier conversation.",
        compactor_kind: :summary
      },
      %{role: :user, content: "follow-up"}
    ]

    projected = Core.prompt_messages(messages)

    assert Enum.any?(projected, fn
             %{"role" => "summary", "content" => "Context summary of earlier conversation."} ->
               true

             _other ->
               false
           end)

    refute Enum.any?(projected, fn
             %{"role" => "user", "content" => content} ->
               String.contains?(content, "Context summary of earlier conversation.")

             _other ->
               false
           end)
  end
end
