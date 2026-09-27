defmodule Arbor.Comms.ConversationJournalCoreTest do
  use ExUnit.Case, async: true
  alias Arbor.Comms.ConversationJournalCore, as: Core

  @moduletag :fast
  @scope %{principal_id: "human_test", agent_id: "agent_test", engagement_id: "eng_test"}
  @command %{id: "cmd_1", text: "hello 👋"}
  @token String.duplicate("a", 64)

  test "closed exact input identity and principal-scoped stable IDs" do
    assert :ok = Core.validate_command(@command)
    assert {:error, :invalid_command} = Core.validate_command(Map.put(@command, :name, "other"))
    assert {:error, :invalid_command} = Core.validate_command(%{@command | text: " "})
    assert {:error, :invalid_command_id} = Core.validate_id(<<255>>)
    assert {:error, :invalid_scope} = Core.validate_scope(Map.put(@scope, :authority, true))
    changed_scope = %{@scope | engagement_id: "another"}

    assert Core.event_id(@scope, @command.id, "admitted") ==
             Core.event_id(changed_scope, @command.id, "admitted")

    refute Core.stream_id(@scope) == Core.stream_id(changed_scope)
  end

  test "security regression: a saved dispatch claim can never grant dispatch again" do
    initial = Core.new(@scope)
    {:ok, admitted, event} = append(initial, {:admit, @command})
    assert event.command.status == :admitted
    assert {:return, _} = Core.decide(admitted, {:admit, @command})

    assert {:error, :command_conflict} =
             Core.decide(admitted, {:admit, %{@command | text: "changed"}})

    {:ok, claimed, event} = append(admitted, {:claim, @command.id, @token})
    assert event.command.status == :dispatch_started
    refute Map.has_key?(event.command, :claim_token)
    assert {:error, :already_claimed} = Core.decide(claimed, {:claim, @command.id, @token})

    assert {:error, :already_claimed} =
             Core.decide(claimed, {:claim, @command.id, String.duplicate("b", 64)})
  end

  test "terminal identity is immutable and wrong claimant cannot settle" do
    {:ok, admitted, _} = append(Core.new(@scope), {:admit, @command})
    {:ok, claimed, _} = append(admitted, {:claim, @command.id, @token})
    outcome = %{status: :completed, text: "saved reply"}

    assert {:error, :invalid_claim} =
             Core.decide(claimed, {:settle, @command.id, String.duplicate("b", 64), outcome})

    {:ok, settled, _} = append(claimed, {:settle, @command.id, @token, outcome})

    assert {:return, %{status: :completed}} =
             Core.decide(settled, {:settle, @command.id, @token, outcome})

    assert {:error, :terminal_conflict} =
             Core.decide(
               settled,
               {:settle, @command.id, @token, %{status: :uncertain, reason: :delivery_unknown}}
             )
  end

  test "unknown authoritative events, gaps and duplicate positions do not reduce" do
    initial = Core.new(@scope)
    event = make_event(initial, {:admit, @command})
    assert {:error, :invalid_journal} = Core.apply_event(initial, %{event | type: "unknown"})
    assert {:error, :invalid_journal} = Core.apply_event(initial, %{event | event_number: 2})
    {:ok, admitted, _} = Core.apply_event(initial, event)
    assert {:error, :invalid_journal} = Core.apply_event(admitted, event)
    forged = %{event | data: Map.put(event.data, "engagement_id", "other")}
    assert {:error, :invalid_journal} = Core.apply_event(initial, forged)
  end

  defp append(state, operation), do: Core.apply_event(state, make_event(state, operation))

  defp make_event(state, operation) do
    {:append, type, kind, data} = Core.decide(state, operation)

    %{
      id: Core.event_id(@scope, data["command_id"], kind),
      stream_id: Core.stream_id(@scope),
      event_number: state.cursor + 1,
      type: type,
      data: data
    }
  end
end
