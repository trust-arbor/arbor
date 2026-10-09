defmodule Arbor.Persistence.ConversationCommandActivityOrderingRegressionTest do
  use Arbor.Persistence.DatabaseCase, async: false
  alias Arbor.Persistence
  @moduletag :database

  test "security regression latest active page and older cutoff survive newer admissions and live updates" do
    scope = scope("latest")
    rows = for n <- 1..60, do: row("command_#{n}", n)
    assert {:ok, _} = Persistence.project_conversation_commands(scope, rows, %{from: 0, to: 60})
    assert {:ok, first} = Persistence.read_conversation_commands(scope)
    assert numbers(first) == Enum.to_list(60..41//-1)
    assert first.watermark == 60 and first.has_more
    assert first.next_cursor == %{admitted_event_number: 41, command_id: "command_41"}

    update = %{row("command_30", 30) | source_event_number: 61, delivery_status: "completed"}

    assert {:ok, _} =
             Persistence.project_conversation_commands(scope, [update, row("new", 62)], %{
               from: 60,
               to: 62
             })

    assert {:ok, middle} =
             Persistence.read_conversation_commands(scope, cursor: first.next_cursor)

    assert numbers(middle) == Enum.to_list(40..31//-1) ++ Enum.to_list(29..20//-1)
    assert middle.watermark == 62 and middle.has_more
    assert middle.next_cursor == %{admitted_event_number: 20, command_id: "command_20"}
    assert {:ok, last} = Persistence.read_conversation_commands(scope, cursor: middle.next_cursor)
    assert numbers(last) == Enum.to_list(19..1//-1)
    refute last.has_more
    assert last.next_cursor == nil
    refute "new" in Enum.map(middle.commands ++ last.commands, & &1.command_id)
    assert {:ok, latest} = Persistence.read_conversation_commands(scope, limit: 1)
    assert numbers(latest) == [62]
    assert {:ok, maximum} = Persistence.read_conversation_commands(scope, limit: 50)
    assert length(maximum.commands) == 50 and maximum.has_more

    assert Enum.all?(
             middle.commands ++ last.commands,
             &(&1.source_event_number <= middle.watermark)
           )
  end

  test "security regression descending command tie-break retains original scope and immutable keyset" do
    scope = scope("ties")
    foreign = %{scope | stream_id: "foreign-stream", owner_id: "foreign-owner"}

    assert {:ok, _} =
             Persistence.project_conversation_commands(foreign, [row("private-foreign", 100)], %{
               from: 0,
               to: 100
             })

    assert {:ok, _} =
             Persistence.project_conversation_commands(
               scope,
               [row("old", 1), row("a", 5), row("m", 5), row("z", 5), row("latest", 6)],
               %{from: 0, to: 6}
             )

    assert {:ok, first} = Persistence.read_conversation_commands(scope, limit: 2)
    assert ids(first) == ["latest", "z"]
    assert first.next_cursor == %{admitted_event_number: 5, command_id: "z"}
    updated = %{row("a", 5) | source_event_number: 7, delivery_status: "dispatch_started"}

    assert {:ok, _} =
             Persistence.project_conversation_commands(scope, [updated, row("newest", 8)], %{
               from: 6,
               to: 8
             })

    assert {:ok, middle} =
             Persistence.read_conversation_commands(scope, limit: 2, cursor: first.next_cursor)

    assert ids(middle) == ["m", "a"]
    assert middle.next_cursor == %{admitted_event_number: 5, command_id: "a"}
    assert middle.watermark == 8

    assert {:ok, last} =
             Persistence.read_conversation_commands(scope, limit: 2, cursor: middle.next_cursor)

    assert ids(last) == ["old"]
    refute last.has_more
    assert last.next_cursor == nil
    refute inspect(first.commands ++ middle.commands ++ last.commands) =~ "private-foreign"

    assert Enum.all?(first.commands ++ middle.commands ++ last.commands, fn command ->
             Enum.sort(Map.keys(command)) ==
               Enum.sort([
                 :command_id,
                 :admitted_event_number,
                 :source_event_number,
                 :delivery_status,
                 :cancellation_status,
                 :cancellation_termination
               ])
           end)
  end

  defp ids(page), do: Enum.map(page.commands, & &1.command_id)
  defp numbers(page), do: Enum.map(page.commands, & &1.admitted_event_number)

  defp scope(id),
    do: %{
      owner_id: "human_#{id}",
      target_agent_id: "agent_target",
      engagement_id: "eng_scope",
      stream_id: "ordering_#{id}"
    }

  defp row(id, number),
    do: %{
      command_id: id,
      admitted_event_number: number,
      source_event_number: number,
      delivery_status: "admitted",
      cancellation_status: "none",
      cancellation_termination: nil
    }
end
