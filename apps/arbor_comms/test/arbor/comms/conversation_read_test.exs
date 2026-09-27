defmodule Arbor.Comms.ConversationReadTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Comms
  alias Arbor.Comms.EngagementStore
  alias Arbor.Persistence

  @moduletag :database
  @moduletag :fast

  defmodule FaultPersistence do
    def normalize_conversation_page_options(opts),
      do: Arbor.Persistence.normalize_conversation_page_options(opts)

    def read_conversation_page(_, _, _) do
      case Process.get(:conversation_read_fault) do
        :raise -> raise "private storage detail"
        :exit -> exit(:private_storage_detail)
        :throw -> throw(:private_storage_detail)
        :empty -> []
        :error -> {:error, {:backend_error, "private storage detail"}}
      end
    end
  end

  setup do
    suffix = System.unique_integer([:positive])
    agent = "read_agent_#{suffix}"
    principal = "human_reader_#{suffix}"
    foreign = "human_foreign_#{suffix}"
    {:ok, own} = Comms.resolve_user_engagement(agent, principal)
    {:ok, other} = Comms.resolve_user_engagement(agent, foreign)
    previous = Application.fetch_env(:arbor_comms, :conversation_persistence_module)

    on_exit(fn ->
      EngagementStore.delete(own.id)
      EngagementStore.delete(other.id)

      case previous do
        {:ok, value} -> Application.put_env(:arbor_comms, :conversation_persistence_module, value)
        :error -> Application.delete_env(:arbor_comms, :conversation_persistence_module)
      end
    end)

    %{agent: agent, principal: principal, foreign: foreign, own: own, other: other}
  end

  test "security regression returns only the verified owner's canonical engagement", ctx do
    {:ok, session} = Persistence.ensure_session("agent-session-#{ctx.agent}", ctx.agent)

    assert {:ok, 3} =
             Persistence.append_session_entries(session.id, [
               entry(ctx.other.id, "foreign before"),
               entry(ctx.own.id, "owner content"),
               entry(ctx.other.id, "foreign after")
             ])

    assert {:ok, page} = Comms.read_user_conversation_page(ctx.agent, ctx.principal, limit: 1)
    assert page.engagement_id == ctx.own.id
    assert page.head == 2
    assert page.cursor == 2
    refute page.has_more
    assert [%{content: "owner content", entry_ordinal: 2}] = page.entries

    assert {:ok, foreign_page} = Comms.read_user_conversation_page(ctx.agent, ctx.foreign)
    assert foreign_page.engagement_id == ctx.other.id
    assert Enum.map(foreign_page.entries, & &1.content) == ["foreign before", "foreign after"]
  end

  test "security regression rejects recovered engagement ownership and visibility mismatch",
       ctx do
    for change <- [
          %{owner_tenant: ctx.foreign},
          %{agent_id: "foreign-agent"},
          %{visibility: :public},
          %{scope: :channel}
        ] do
      EngagementStore.put(Map.merge(ctx.own, change))

      assert {:error, :invalid_engagement} =
               Comms.read_user_conversation_page(ctx.agent, ctx.principal)
    end
  end

  test "security regression rejects routing overrides and malformed options before resolution",
       ctx do
    # Poisoned recovered state makes resolution observable: valid options reach
    # :invalid_engagement, rejected options stop before that owner is consulted.
    EngagementStore.put(%{ctx.own | owner_tenant: ctx.foreign})

    for opts <- [
          [engagement_id: ctx.other.id],
          [principal_id: ctx.foreign],
          [user_id: ctx.foreign],
          [session_id: "foreign"],
          [persistence: FaultPersistence],
          [limit: 1, limit: 2],
          [limit: 0],
          [limit: 101],
          [after: -1],
          [through: nil],
          [after: 2, through: 1],
          nil,
          %{},
          [{:limit, 1} | :malformed]
        ] do
      assert {:error, :invalid_options} =
               Comms.read_user_conversation_page(ctx.agent, ctx.principal, opts)
    end

    assert {:error, :invalid_engagement} =
             Comms.read_user_conversation_page(ctx.agent, ctx.principal)
  end

  test "security regression invalid identifiers never become an empty authorized page", ctx do
    for invalid <- [nil, "", " ", <<255>>, String.duplicate("x", 257)] do
      assert {:error, :invalid_identifier} = Comms.read_user_conversation_page(ctx.agent, invalid)

      assert {:error, :invalid_identifier} =
               Comms.read_user_conversation_page(invalid, ctx.principal)
    end
  end

  test "storage exceptions and malformed results fail closed without leaking details", ctx do
    Application.put_env(:arbor_comms, :conversation_persistence_module, FaultPersistence)

    for fault <- [:raise, :exit, :throw, :empty, :error] do
      Process.put(:conversation_read_fault, fault)

      assert {:error, :conversation_unavailable} =
               Comms.read_user_conversation_page(ctx.agent, ctx.principal)
    end
  end

  test "an observed empty conversation keeps its canonical engagement id", ctx do
    assert {:ok, %{engagement_id: id, entries: [], head: 0, cursor: 0, has_more: false}} =
             Comms.read_user_conversation_page(ctx.agent, ctx.principal)

    assert id == ctx.own.id
  end

  test "security regression includes the engagement envelope in the one MiB page bound", ctx do
    {:ok, session} = Persistence.ensure_session("agent-session-#{ctx.agent}", ctx.agent)
    empty_entries = for _ <- 1..4, do: entry(ctx.own.id, "")
    assert {:ok, 4} = Persistence.append_session_entries(session.id, empty_entries)
    {:ok, empty_page} = Comms.read_user_conversation_page(ctx.agent, ctx.principal)

    # Both private engagement ids and all UUIDs have fixed encoded lengths;
    # ordinals 1..4 and 5..8 are each one digit. Without envelope reservation
    # this storage page fits, but the public page exceeds 1 MiB by 35 bytes.
    text_bytes = 1_048_576 - byte_size(Jason.encode!(empty_page)) + 35
    lengths = [div(text_bytes, 4) + rem(text_bytes, 4) | List.duplicate(div(text_bytes, 4), 3)]
    full_entries = for length <- lengths, do: entry(ctx.other.id, String.duplicate("x", length))
    assert {:ok, 4} = Persistence.append_session_entries(session.id, full_entries)

    assert {:error, :page_too_large} =
             Comms.read_user_conversation_page(ctx.agent, ctx.foreign)

    assert {:ok, smaller} = Comms.read_user_conversation_page(ctx.agent, ctx.foreign, limit: 3)
    assert byte_size(Jason.encode!(smaller)) <= 1_048_576
  end

  defp entry(engagement, content) do
    %{
      entry_type: "user",
      role: "user",
      content: [%{"type" => "text", "text" => content}],
      timestamp: ~U[2026-09-26 00:00:00.000000Z],
      metadata: %{"engagement_id" => engagement}
    }
  end
end
