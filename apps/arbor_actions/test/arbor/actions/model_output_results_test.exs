defmodule Arbor.Actions.ModelOutputResultsTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.SessionGoals.StoreIdentity
  alias Arbor.Actions.SessionMemory.{Update, UpdateWorkingMemory}
  alias Arbor.Memory

  @moduletag :fast
  @moduletag :integration

  setup do
    agent = "agent_model_results_#{System.unique_integer([:positive])}"
    assert {:ok, nil} = Memory.init_for_agent(agent, index_enabled: false, auto_embed: false)

    assert {:ok, cap} =
             Arbor.Security.grant(principal: agent, resource: "arbor://orchestrator/execute")

    existing_writers = writer_pids()

    on_exit(fn ->
      for pid <- MapSet.difference(writer_pids(), existing_writers) do
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      end

      Arbor.Security.revoke(cap.id)
      Memory.cleanup_for_agent(agent)
    end)

    # Production ActionsExecutor supplies this only for pinned graph syscalls.
    %{agent: agent, context: %{agent_id: agent, allow_pipeline_internal: true}}
  end

  test "public note update reports an empty no-op and actual saved content", ctx do
    assert {:ok, %{memory_updated: false, memory_notes_result: %{applied_count: 0}}} =
             dispatch(ctx, Update, %{turn_data: %{}})

    assert {:ok,
            %{
              memory_updated: true,
              memory_notes_result: %{applied_count: 1, skipped_count: 2, error_count: 0}
            }} =
             dispatch(ctx, Update, %{
               turn_data: %{"memory_notes" => [false, %{"text" => ""}, "precise note"]}
             })

    assert [%{content: "precise note"}] = Memory.get_working_memory(ctx.agent).recent_thoughts
  end

  test "heartbeat combined update applies each note once and includes concerns and curiosity",
       ctx do
    assert {:ok,
            %{wm_updated: true, working_memory_result: %{applied_count: 3, skipped_count: 1}}} =
             dispatch(ctx, UpdateWorkingMemory, %{
               memory_notes: ["one note", false],
               concerns: ["one concern"],
               curiosity: ["one question"]
             })

    wm = Memory.get_working_memory(ctx.agent)
    assert [%{content: "one note"}] = wm.recent_thoughts
    assert wm.concerns == ["one concern"]
    assert wm.curiosity == ["one question"]

    assert {:ok, %{wm_updated: false, working_memory_result: %{applied_count: 0}}} =
             dispatch(ctx, UpdateWorkingMemory, %{})
  end

  test "identity regression: invalid first insight cannot discard later valid content", ctx do
    insights = [
      %{"category" => "unrecognized-model-category", "content" => "invalid category"},
      %{"category" => "value", "content" => false},
      %{"category" => "trait", "content" => "bad confidence", "confidence" => "high"},
      %{
        "category" => "capability",
        "content" => "I can verify complete value flows",
        "confidence" => 0.9
      }
    ]

    assert {:ok,
            %{
              identity_admitted_count: 1,
              identity_skipped_count: 3,
              identity_error_count: 0,
              identity_persistence: "unconfirmed"
            } = result} = dispatch(ctx, StoreIdentity, %{insights: insights})

    refute Map.has_key?(result, :identity_stored)

    assert Enum.any?(
             Memory.get_self_knowledge(ctx.agent).capabilities,
             &(&1.name == "can_verify_complete_value" and
                 &1.evidence == "Original: I can verify complete value flows")
           )
  end

  test "empty and invalid identity batches report no admitted persistence", ctx do
    for {insights, skipped} <- [{[], 0}, {[%{category: "unknown", content: "unused"}], 1}] do
      assert {:ok,
              %{
                identity_admitted_count: 0,
                identity_skipped_count: ^skipped,
                identity_error_count: 0,
                identity_persistence: "not_requested"
              }} = dispatch(ctx, StoreIdentity, %{insights: insights})
    end

    assert Memory.get_self_knowledge(ctx.agent) == nil
  end

  test "security regression: truthful write results do not relax private-turn denial", ctx do
    before_wm = Memory.get_working_memory(ctx.agent)
    before_identity = Memory.get_self_knowledge(ctx.agent)
    restricted = %{ctx | context: Map.put(ctx.context, :memory_write_policy, :deny)}

    for {action, params} <- [
          {Update, %{turn_data: %{memory_notes: ["private note"]}}},
          {UpdateWorkingMemory, %{memory_notes: ["private note"]}},
          {StoreIdentity, %{insights: [%{category: "capability", content: "private insight"}]}}
        ] do
      assert {:error, :private_turn_memory_write_denied} = dispatch(restricted, action, params)
    end

    assert Memory.get_working_memory(ctx.agent) == before_wm
    assert Memory.get_self_knowledge(ctx.agent) == before_identity
  end

  defp writer_pids do
    Memory.AsyncWriter.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} -> if is_pid(pid), do: [pid], else: [] end)
    |> MapSet.new()
  end

  defp dispatch(ctx, action, params) do
    Actions.authorize_and_execute(
      ctx.agent,
      action,
      Map.put(params, :agent_id, ctx.agent),
      ctx.context
    )
  end
end
