defmodule Arbor.Persistence.ConversationCommandIndexTest do
  use Arbor.Persistence.DatabaseCase, async: false
  alias Arbor.Persistence
  @moduletag :database

  test "security regression exact original scope filters before the active limit" do
    scope = scope("owner")

    for other <- [
          scope("foreign"),
          %{scope | stream_id: "target", target_agent_id: "other"},
          %{scope | stream_id: "engagement", engagement_id: "other"}
        ] do
      assert {:ok, _} = Persistence.project_conversation_command(other, row("foreign", 1), 1)
    end

    rows =
      for n <- 1..100, do: row("command_#{n}", n, if(n == 1, do: "admitted", else: "completed"))

    assert {:ok, %{watermark: 100}} =
             Persistence.project_conversation_commands(scope, rows, %{from: 0, to: 100})

    assert {:ok, %{commands: [command], watermark: 100, has_more: false}} =
             Persistence.read_conversation_commands(scope, limit: 1)

    assert command.command_id == "command_1"

    assert Map.keys(command) |> Enum.sort() ==
             Enum.sort([
               :command_id,
               :admitted_event_number,
               :source_event_number,
               :delivery_status,
               :cancellation_status,
               :cancellation_termination
             ])
  end

  test "admission keyset remains stable while older commands update" do
    scope = scope("keyset")

    assert {:ok, _} =
             Persistence.project_conversation_commands(
               scope,
               [row("old", 1), row("second", 2), row("third", 3)],
               %{from: 0, to: 3}
             )

    assert {:ok, %{commands: [first], next_cursor: cursor, has_more: true}} =
             Persistence.read_conversation_commands(scope, limit: 1)

    assert first.command_id == "third"
    assert cursor == %{admitted_event_number: 3, command_id: "third"}
    updated = row("old", 1, "dispatch_started") |> Map.put(:source_event_number, 4)
    assert {:ok, _} = Persistence.project_conversation_command(scope, updated, 4)

    assert {:ok, %{commands: [second, third], next_cursor: nil}} =
             Persistence.read_conversation_commands(scope, limit: 2, cursor: cursor)

    assert Enum.map([second, third], & &1.command_id) == ["second", "old"]
  end

  test "active observation includes an unconfirmed cancellation independently of delivery" do
    scope = scope("axes")

    rows = [
      row("active", 1),
      row("uncertain", 2, "uncertain"),
      row("requested", 3, "uncertain") |> Map.put(:cancellation_status, "requested"),
      row("confirmed", 4, "uncertain")
      |> Map.merge(%{
        cancellation_status: "confirmed",
        cancellation_termination: "engine_terminated"
      }),
      row("never_dispatched", 5)
      |> Map.merge(%{
        cancellation_status: "confirmed",
        cancellation_termination: "never_dispatched"
      }),
      row("completed_requested", 6, "completed") |> Map.put(:cancellation_status, "requested")
    ]

    assert {:ok, _} = Persistence.project_conversation_commands(scope, rows, %{from: 0, to: 6})
    assert {:ok, %{commands: active}} = Persistence.read_conversation_commands(scope)

    assert Enum.map(active, & &1.command_id) == [
             "completed_requested",
             "requested",
             "uncertain",
             "active"
           ]

    assert {:ok, %{commands: all}} =
             Persistence.read_conversation_commands(scope, active_only: false)

    assert length(all) == 6
  end

  test "committed page watermark survives retries and conflicting retries fail closed" do
    scope = scope("retry")
    initial = row("command", 1)

    assert {:ok, %{watermark: 1, projected: 1}} =
             Persistence.project_conversation_command(scope, initial, 1)

    update = %{initial | source_event_number: 2, delivery_status: "dispatch_started"}
    assert {:ok, _} = Persistence.project_conversation_command(scope, update, 2)

    assert {:ok, %{watermark: 2, projected: 0}} =
             Persistence.project_conversation_command(scope, initial, 1)

    assert {:error, :projection_source_conflict} =
             Persistence.project_conversation_command(
               scope,
               %{initial | delivery_status: "completed"},
               1
             )

    assert {:error, :projection_watermark_conflict} =
             Persistence.project_conversation_command(scope, row("gap", 4), 4)

    assert {:ok, 2} = Persistence.conversation_command_index_watermark(scope)
  end

  test "security regression a page conflict rolls every row and its watermark back" do
    scope = scope("rollback")
    assert {:ok, _} = Persistence.project_conversation_command(scope, row("known", 1), 1)
    changed_identity = row("known", 2)
    admitted = row("a_new", 2)

    assert {:error, :projection_identity_conflict} =
             Persistence.project_conversation_commands(scope, [admitted, changed_identity], %{
               from: 1,
               to: 2
             })

    assert {:ok, 1} = Persistence.conversation_command_index_watermark(scope)
    assert {:ok, %{commands: [original]}} = Persistence.read_conversation_commands(scope)
    assert original.command_id == "known"
    assert original.admitted_event_number == 1
  end

  test "security regression a stream cannot be reassigned to another original owner" do
    scope = scope("immutable")
    assert {:ok, _} = Persistence.project_conversation_command(scope, row("one", 1), 1)
    foreign = %{scope | owner_id: "different"}
    assert {:error, :projection_scope_conflict} = Persistence.read_conversation_commands(foreign)

    assert {:error, :projection_scope_conflict} =
             Persistence.conversation_command_index_watermark(foreign)

    assert {:error, :projection_scope_conflict} =
             Persistence.project_conversation_command(foreign, row("two", 2), 2)
  end

  test "read bounds and row envelopes reject invalid selectors before unavailable SQL" do
    scope = scope("bounds")
    previous = Repo.put_dynamic_repo(:unavailable_command_index)

    try do
      for opts <- [
            [limit: 51],
            [limit: 0],
            [limit: 1, limit: 2],
            [owner_id: "foreign"],
            [cursor: 1],
            [active_only: :yes],
            nil,
            %{}
          ] do
        assert {:error, :invalid_options} = Persistence.read_conversation_commands(scope, opts)
      end

      assert {:error, :invalid_scope} =
               Persistence.read_conversation_commands(Map.put(scope, :token, "bearer"))

      assert {:error, :invalid_projection} =
               Persistence.project_conversation_command(
                 scope,
                 Map.put(row("one", 1), :claim_token, "bearer"),
                 1
               )

      assert {:error, :invalid_projection} =
               Persistence.project_conversation_command(
                 scope,
                 %{row("one", 1) | cancellation_status: "confirmed"},
                 1
               )

      assert {:error, :conversation_index_unavailable} =
               Persistence.read_conversation_commands(scope)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "projection bounds do not cap retained historical command identity" do
    scope = scope("retained")

    for first <- [0, 100] do
      rows = for n <- (first + 1)..(first + 100), do: row("id_#{n}", n, "completed")

      assert {:ok, _} =
               Persistence.project_conversation_commands(scope, rows, %{
                 from: first,
                 to: first + 100
               })
    end

    assert {:ok, %{commands: commands, has_more: true, watermark: 200}} =
             Persistence.read_conversation_commands(scope, limit: 50, active_only: false)

    assert length(commands) == 50
    assert Repo.aggregate(Arbor.Persistence.Schemas.ConversationCommand, :count) == 200
  end

  test "SQL applies scope and admission keyset with a bounded materialized page" do
    scope = scope("query")
    rows = for n <- 1..100, do: row("row_#{n}", n)
    assert {:ok, _} = Persistence.project_conversation_commands(scope, rows, %{from: 0, to: 100})
    observer = self()
    handler = "command_index_query_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _, _, metadata, pid -> send(pid, {:index_query, metadata}) end,
        observer
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %{commands: commands, has_more: true}} =
             Persistence.read_conversation_commands(scope,
               limit: 50,
               cursor: %{admitted_event_number: 100, command_id: "row_100"}
             )

    assert length(commands) == 50
    queries = collect_queries([])
    query = Enum.find(queries, &String.contains?(&1.query, "FROM \"conversation_commands\""))
    assert query

    for field <- [
          "owner_id",
          "target_agent_id",
          "engagement_id",
          "stream_id",
          "admitted_event_number"
        ] do
      assert String.contains?(query.query, field)
    end

    assert String.contains?(query.query, "LIMIT")
    refute String.contains?(query.query, "OFFSET")
    assert 51 in query.params
    assert {:ok, %{num_rows: 51}} = query.result
  end

  test "security regression a malformed durable watermark is never reported as complete" do
    scope = scope("malformed")
    assert {:ok, _} = Persistence.project_conversation_command(scope, row("one", 1), 1)
    Repo.update_all(Arbor.Persistence.Schemas.ConversationCommandCheckpoint, set: [watermark: -1])

    assert {:error, :invalid_projection_record} =
             Persistence.conversation_command_index_watermark(scope)

    assert {:error, :invalid_projection_record} = Persistence.read_conversation_commands(scope)
  end

  defp collect_queries(acc) do
    receive do
      {:index_query, metadata} -> collect_queries([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp scope(id),
    do: %{
      owner_id: "human_#{id}",
      target_agent_id: "agent_target",
      engagement_id: "eng_scope",
      stream_id: "conversation_#{id}"
    }

  defp row(id, number, status \\ "admitted"),
    do: %{
      command_id: id,
      admitted_event_number: number,
      source_event_number: number,
      delivery_status: status,
      cancellation_status: "none",
      cancellation_termination: nil
    }
end
