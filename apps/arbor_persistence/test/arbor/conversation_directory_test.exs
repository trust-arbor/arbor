defmodule Arbor.Persistence.ConversationDirectoryTest do
  use Arbor.Persistence.DatabaseCase, async: false
  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Persistence
  alias Arbor.Persistence.EngagementStore
  @moduletag :database
  @owner "human_directory_owner"
  @other "human_directory_other"

  test "security regression directory filters owner scope and visibility before the limit" do
    own = put("agent_directory_own", @owner)
    put("agent_directory_foreign", @other)
    put("agent_directory_group", @owner, visibility: :group)
    put("agent_directory_channel", @owner, scope: :channel)

    assert {:ok, %{records: [record], has_more: false, next_cursor: nil}} =
             Persistence.list_user_conversation_records(@owner, limit: 1)

    assert record.engagement_id == own.id
    assert record.owner_tenant == @owner

    assert Enum.sort(Map.keys(record)) ==
             Enum.sort([
               :engagement_id,
               :agent_id,
               :owner_tenant,
               :scope,
               :visibility,
               :status,
               :updated_at
             ])
  end

  test "live activity order uses scoped conversation rows and cursor bounds returned records" do
    first = put("agent_directory_first", @owner)
    second = put("agent_directory_second", @owner)
    append(first, ~U[2090-01-01 00:00:00Z])
    append(second, ~U[2091-01-01 00:00:00Z])
    append(%{first | id: "eng_99999999999999999999999999999999"}, ~U[2092-01-01 00:00:00Z])
    append(first, ~U[2093-01-01 00:00:00Z], "tool_result")

    assert {:ok, %{records: [recent], has_more: true, next_cursor: 1}} =
             Persistence.list_user_conversation_records(@owner, limit: 1)

    assert recent.engagement_id == second.id
    assert recent.updated_at == ~U[2091-01-01 00:00:00.000000Z]

    assert {:ok, %{records: [older], has_more: false, next_cursor: nil}} =
             Persistence.list_user_conversation_records(@owner, limit: 1, cursor: 1)

    assert older.engagement_id == first.id
    assert older.updated_at == ~U[2090-01-01 00:00:00.000000Z]
  end

  test "security regression deep reference is an owner-filtered durable lookup" do
    own = put("agent_directory_reference", @owner)
    foreign = put("agent_directory_reference_other", @other)

    assert {:ok, %{engagement_id: id, agent_id: "agent_directory_reference"}} =
             Persistence.read_user_conversation_record(@owner, own.id)

    assert id == own.id
    assert {:error, :not_found} = Persistence.read_user_conversation_record(@owner, foreign.id)

    assert {:error, :not_found} =
             Persistence.read_user_conversation_record(
               @owner,
               "eng_00000000000000000000000000000000"
             )
  end

  test "security regression invalid selectors stop before SQL and unavailable DB never falls back to cache" do
    put("agent_directory_cache", @owner)
    previous = Repo.put_dynamic_repo(:unavailable_conversation_directory)

    try do
      for opts <- [
            [limit: 0],
            [limit: 101],
            [cursor: -1],
            [cursor: nil],
            [limit: 1, limit: 2],
            [owner_tenant: @other],
            [persistence: EngagementStore],
            nil,
            %{}
          ] do
        assert {:error, :invalid_options} =
                 Persistence.list_user_conversation_records(@owner, opts)
      end

      assert {:error, :conversation_unavailable} =
               Persistence.list_user_conversation_records(@owner)

      assert {:error, :conversation_unavailable} =
               Persistence.read_user_conversation_record(
                 @owner,
                 "eng_00000000000000000000000000000000"
               )
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "an observed empty owner directory and a position past its end remain successful empty pages" do
    assert {:ok, %{records: [], has_more: false, next_cursor: nil}} =
             Persistence.list_user_conversation_records("human_directory_empty")

    put("agent_directory_end", @owner)

    assert {:ok, %{records: [], has_more: false, next_cursor: nil}} =
             Persistence.list_user_conversation_records(@owner, cursor: 5)
  end

  defp put(agent, owner, opts \\ []) do
    engagement =
      Engagement.new(
        [agent_id: agent, owner_tenant: owner, scope: :user, visibility: :private] ++ opts
      )

    # Overrides need explicit construction because Keyword duplicate handling
    # should not determine the security fixture's scope.
    engagement = Enum.reduce(opts, engagement, fn {key, value}, e -> Map.put(e, key, value) end)
    {:ok, saved} = EngagementStore.upsert(engagement)
    saved
  end

  defp append(engagement, timestamp, type \\ "user") do
    {:ok, session} =
      Persistence.ensure_session("agent-session-#{engagement.agent_id}", engagement.agent_id)

    assert {:ok, _} =
             Persistence.append_session_entries(session.id, [
               %{
                 entry_type: type,
                 role: if(type in ["user", "assistant"], do: type, else: nil),
                 content: [%{"type" => "text", "text" => "private body"}],
                 timestamp: timestamp,
                 metadata: %{"engagement_id" => engagement.id}
               }
             ])
  end
end
