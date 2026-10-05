defmodule ConversationKit.Arbor.WindowTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  @moduletag :fast
  @engagement "eng_0123456789abcdef0123456789abcdef"

  defp entry(n, text \\ "Message") do
    %{
      id: "entry_#{n}",
      role: "assistant",
      content: text,
      timestamp: "2026-10-02T00:00:00Z",
      entry_ordinal: n
    }
  end

  defp page(entries, extra \\ %{}) do
    Map.merge(
      %{
        engagement_id: @engagement,
        entries: entries,
        head: 100_000,
        first: if(entries == [], do: 0, else: hd(entries).entry_ordinal),
        last: if(entries == [], do: 0, else: List.last(entries).entry_ordinal),
        has_older: true,
        has_newer: false
      },
      extra
    )
  end

  defp client(host, options \\ []) do
    observer = self()

    proof = fn context ->
      send(observer, {:proof, context})
      {:ok, [session_token: "credential-sentinel"]}
    end

    transport = fn context, proof ->
      send(observer, {:request, context, proof})
      host.(context)
    end

    {:ok, client} =
      Arbor.new(
        "human_private",
        "agent_private",
        proof,
        Keyword.merge([transport: transport, page_limit: 20], options)
      )

    client
  end

  test "latest startup is one bounded request and private fields never enter projection" do
    initial =
      client(fn %{operation: :window, options: [limit: 20]} ->
        {:ok, page(Enum.map(99_981..100_000, &entry/1))}
      end)

    assert {:ok, next, %{last: 100_000}} = Arbor.window(initial)
    assert length(Arbor.projection(next)["messages"]) == 20
    refute inspect(Arbor.projection(next)) =~ "credential-sentinel"
    assert_receive {:proof, %{operation: :window}}
    assert_receive {:request, %{operation: :window}, _}
    refute_receive {:request, _, _}
  end

  test "window preserves explicit assistant status as semantic strings in public projection" do
    for status <- ~w(complete interrupted cancelled failed streaming) do
      initial =
        client(fn _ -> {:ok, page([Map.put(entry(100_000, "Partial"), :status, status)])} end)

      assert {:ok, next, _} = Arbor.window(initial)

      assert [%{"status" => ^status, "role" => "assistant", "text" => "Partial"}] =
               next.messages

      assert [%{"status" => ^status, "role" => "assistant", "text" => "Partial"}] =
               Arbor.projection(next)["messages"]
    end

    assert {:ok, legacy, _} = Arbor.window(client(fn _ -> {:ok, page([entry(100_000)])} end))
    refute Map.has_key?(hd(legacy.messages), "status")
    refute Map.has_key?(hd(Arbor.projection(legacy)["messages"]), "status")
  end

  test "security regression window rejects invalid assistant status, user status, and extra fields" do
    for bad <- [
          Map.put(entry(100_000), :status, "unknown"),
          Map.put(entry(100_000), :status, nil),
          Map.put(entry(100_000), :status, :cancelled),
          Map.put(entry(100_000), :status, 123),
          Map.put(entry(100_000), :status, %{"status" => "cancelled"}),
          Map.merge(entry(100_000), %{role: "user", status: "cancelled"}),
          Map.merge(entry(100_000), %{
            status: "cancelled",
            metadata: %{principal_id: "private"}
          }),
          Map.merge(entry(100_000), %{status: "cancelled", reason: "private"}),
          Map.put(entry(100_000), :metadata, %{status: "cancelled"})
        ] do
      initial = client(fn _ -> {:ok, page([bad])} end)
      assert {:error, :invalid_history_entry} = Arbor.window(initial)
      assert initial.messages == []
      assert Arbor.projection(initial)["messages"] == []
      assert Arbor.position(initial) == %{history: 0, commands: 0}
    end
  end

  test "a changed status at an overlapping identity and ordinal rejects without replacing state" do
    original = Map.put(entry(100_000, "Partial"), :status, "cancelled")
    initial = client(fn _ -> {:ok, page([original])} end)
    assert {:ok, current, _} = Arbor.window(initial)
    changed = Map.put(original, :status, "interrupted")
    candidate = %{current | transport: fn _, _ -> {:ok, page([changed])} end}
    assert {:error, :invalid_history_entry} = Arbor.window(candidate)
    assert [%{"status" => "cancelled", "text" => "Partial"}] = current.messages
  end

  test "legacy replay rejects window-only status instead of changing its entry contract" do
    initial =
      client(fn %{operation: :history} ->
        {:ok,
         %{
           engagement_id: @engagement,
           entries: [Map.put(entry(1), :status, "cancelled")],
           cursor: 1,
           head: 1,
           has_more: false
         }}
      end)

    assert {:error, :invalid_history_entry} = Arbor.sync(initial)
    assert initial.messages == []
    assert Arbor.position(initial) == %{history: 0, commands: 0}
  end

  test "older and newer windows replace retained records without replaying prior history" do
    initial =
      client(fn %{options: opts} ->
        finish = Keyword.get(opts, :before, 100_001) - 1
        {:ok, page(Enum.map((finish - 19)..finish, &entry/1), %{has_newer: finish < 100_000})}
      end)

    assert {:ok, current, _} = Arbor.window(initial)

    oldest =
      Enum.reduce(1..100, current, fn n, acc ->
        assert {:ok, next, _} = Arbor.window(acc, before: 100_001 - 20 * n, through: 100_000)
        assert length(next.messages) == 20
        assert MapSet.size(next.message_ids) == 20
        assert next.event_ids == MapSet.new()
        next
      end)

    assert hd(oldest.messages)["ordinal"] == 97_981
    assert_receive {:proof, %{options: opts}}
    assert opts[:limit] == 20
    assert {:ok, latest, _} = Arbor.window(oldest)
    assert List.last(latest.messages)["ordinal"] == 100_000
  end

  test "scope changes, malformed bounds, and changed overlapping content reject atomically" do
    initial = client(fn _ -> {:ok, page([entry(100_000)])} end)
    assert {:ok, current, _} = Arbor.window(initial)

    for bad <- [
          page([entry(100_000)], %{engagement_id: "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}),
          page([entry(100_000)], %{last: 99_999}),
          page([entry(100_000, "Changed")]),
          page([entry(100_000)], %{hidden: "private"})
        ] do
      candidate = %{current | transport: fn _, _ -> {:ok, bad} end}
      assert {:error, _} = Arbor.window(candidate)
      assert List.last(current.messages)["text"] == "Message"
    end
  end

  test "direction, snapshot head, and UTF-8 entry bounds are validated" do
    for opts <- [[before: 2, after: 1], [limit: 101], [before: -1], [unknown: true]] do
      assert {:error, :invalid_opts} =
               Arbor.window(client(fn _ -> flunk("Host must not be called") end), opts)
    end

    initial = client(fn _ -> {:ok, page([entry(10)])} end)
    assert {:error, :invalid_history_entry} = Arbor.window(initial, after: 10)
    assert {:error, :invalid_history_page} = Arbor.window(initial, through: 9)
    invalid = client(fn _ -> {:ok, page([entry(10, <<255>>)])} end)
    assert {:error, :invalid_history_entry} = Arbor.window(invalid)
  end

  test "oversized windows shrink with fresh proofs and retain the effective bound" do
    initial =
      client(
        fn %{options: options} ->
          if options[:limit] > 3,
            do: {:error, :page_too_large},
            else: {:ok, page(Enum.map(99_998..100_000, &entry/1))}
        end,
        page_limit: 100
      )

    assert {:ok, next, _} = Arbor.window(initial)
    assert next.history.limit == 3
    assert length(next.messages) == 3

    for limit <- [100, 50, 25, 12, 6, 3] do
      assert_receive {:proof, %{options: [limit: ^limit]}}
      assert_receive {:request, %{options: [limit: ^limit]}, _}
    end

    refute_receive {:request, _, _}
    assert {:ok, _, _} = Arbor.window(next)
    assert_receive {:proof, %{options: options}}
    assert options[:limit] == 3
    assert options[:expected_engagement_id] == @engagement
  end

  test "security regression startup scope fence rejects another engagement before rendering" do
    initial =
      client(
        fn context ->
          assert context.options[:expected_engagement_id] ==
                   "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

          {:ok, page([entry(100_000)])}
        end,
        expected_engagement_id: "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )

    assert {:error, :conversation_scope_changed} = Arbor.window(initial)
    assert Arbor.projection(initial)["messages"] == []
  end

  test "a replaced entry at an overlapping ordinal is rejected even with a new ID" do
    initial = client(fn _ -> {:ok, page([entry(100_000)])} end)
    assert {:ok, current, _} = Arbor.window(initial)
    renamed = %{entry(100_000) | id: "different_identity"}
    candidate = %{current | transport: fn _, _ -> {:ok, page([renamed])} end}
    assert {:error, :invalid_history_entry} = Arbor.window(candidate)
    assert List.last(current.messages)["id"] == "entry_100000"
  end

  test "switching from replay releases its history and journal cache without pretending a tail is a prefix" do
    command = %{
      id: "saved_command",
      name: "chat.send",
      text: "Hello",
      principal_id: "human_private",
      agent_id: "agent_private",
      engagement_id: @engagement,
      status: :admitted,
      outcome: nil,
      admitted_cursor: 1,
      updated_cursor: 1
    }

    initial =
      client(fn context ->
        case context.operation do
          :history ->
            {:ok,
             %{
               engagement_id: @engagement,
               entries: [entry(1)],
               cursor: 1,
               head: 1,
               has_more: false
             }}

          :events ->
            {:ok,
             %{
               engagement_id: @engagement,
               events: [%{id: "event_1", cursor: 1, kind: "admitted", command: command}],
               cursor: 1,
               head: 1,
               has_more: false
             }}

          :window ->
            {:ok, page(Enum.map(99_981..100_000, &entry/1))}
        end
      end)

    assert {:ok, replayed} = Arbor.sync(initial)
    assert MapSet.size(replayed.event_ids) == 1
    assert map_size(replayed.commands) == 1
    assert {:ok, next, _} = Arbor.window(replayed)
    assert next.commands == %{}
    assert next.event_ids == MapSet.new()
    assert length(next.messages) == 20
    assert [%{"id" => "saved_command"}] = Arbor.projection(next)["deliveries"]
    assert {:error, :incompatible_replay_mode} = Arbor.sync(next)
  end
end
