defmodule ConversationKit.ArborTest do
  use ExUnit.Case, async: true

  alias ConversationKit.Arbor

  @engagement "eng_0123456789abcdef0123456789abcdef"
  @other_engagement "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  defmodule Facade do
    def conversation_history(caller, target, opts),
      do: respond(:history, caller, target, nil, opts)

    def conversation_events(caller, target, cursor, opts),
      do: respond(:events, caller, target, cursor, opts)

    def conversation_command(caller, target, id, opts),
      do: respond(:command, caller, target, id, opts)

    def submit_conversation_command(caller, target, command, opts),
      do: respond(:submit, caller, target, command, opts)

    defp respond(operation, caller, target, input, opts) do
      send(self(), {:request, operation, caller, target, input, opts})
      Process.get(:host).(operation, caller, target, input, opts)
    end
  end

  defp client(opts \\ []) do
    provider = fn context ->
      count = Process.get(:proof_count, 0) + 1
      Process.put(:proof_count, count)
      send(self(), {:proof, context})
      {:ok, [session_token: "private-proof-#{count}"]}
    end

    {:ok, client} =
      Arbor.new("human_private", "agent_private", provider, [facade: Facade] ++ opts)

    client
  end

  defp attached_client do
    saved_host = Process.get(:host)
    serve_history_and_events(history(), journal())
    {:ok, attached} = Arbor.sync(client())
    Process.put(:host, saved_host)
    attached
  end

  defp history(entries \\ [], extra \\ %{}) do
    head =
      case List.last(entries) do
        nil -> 0
        entry -> entry.entry_ordinal
      end

    Map.merge(
      %{engagement_id: @engagement, entries: entries, cursor: head, head: head, has_more: false},
      extra
    )
  end

  defp journal(events \\ [], extra \\ %{}) do
    head =
      case List.last(events) do
        nil -> 0
        event -> event.cursor
      end

    Map.merge(
      %{engagement_id: @engagement, events: events, cursor: head, head: head, has_more: false},
      extra
    )
  end

  defp entry(ordinal, text \\ "Text") do
    %{
      id: "message_#{ordinal}",
      role: "assistant",
      content: text,
      timestamp: "2026-09-27T00:00:00Z",
      entry_ordinal: ordinal
    }
  end

  defp command(status \\ :admitted, extra \\ %{}) do
    {cursor, outcome} =
      case status do
        :admitted -> {1, nil}
        :dispatch_started -> {2, nil}
        :completed -> {3, %{status: :completed, text: "Delivery result"}}
        :uncertain -> {3, %{status: :uncertain, reason: :delivery_unknown}}
      end

    Map.merge(
      %{
        id: "cmd_1",
        name: "chat.send",
        text: "Hello",
        principal_id: "human_private",
        agent_id: "agent_private",
        engagement_id: @engagement,
        status: status,
        outcome: outcome,
        admitted_cursor: 1,
        updated_cursor: cursor
      },
      extra
    )
  end

  defp event(status, extra \\ %{}) do
    command = command(status)

    kind =
      case status do
        :admitted -> "admitted"
        :dispatch_started -> "dispatch_started"
        _ -> "settled"
      end

    Map.merge(
      %{
        id: "event_#{command.updated_cursor}",
        cursor: command.updated_cursor,
        kind: kind,
        command: command
      },
      extra
    )
  end

  defp serve_history_and_events(history, events) do
    Process.put(:host, fn
      :history, _, _, _, _ -> {:ok, history}
      :events, _, _, _, _ -> {:ok, events}
    end)
  end

  test "separate transcript and journal projections never fabricate correlated assistant messages" do
    original = client()

    serve_history_and_events(
      history([entry(2, "Existing transcript"), entry(7)]),
      journal([event(:admitted), event(:dispatch_started), event(:completed)])
    )

    assert {:ok, next} = Arbor.sync(original)
    assert %{history: 7, commands: 3} = Arbor.position(next)
    projected = Arbor.projection(next)
    assert Enum.map(projected["messages"], & &1["text"]) == ["Existing transcript", "Text"]

    assert [%{"status" => "completed", "result_text" => "Delivery result"}] =
             projected["deliveries"]

    assert projected["speech"] == []
    assert length(projected["blocks"]) == 3
    refute inspect(projected) =~ "human_private"
    refute inspect(projected) =~ "agent_private"
    refute inspect(projected) =~ "private-proof"
    refute inspect(projected) =~ @engagement
    assert inspect(next) == "#ConversationKit.Arbor.Client<private>"
  end

  test "bounded sync preserves each pinned head across calls and makes incremental progress" do
    original = client(page_limit: 1, max_pages: 1)

    Process.put(:host, fn
      :history, _, _, _, opts ->
        case opts[:after] do
          0 ->
            assert opts[:through] == nil
            {:ok, history([entry(2)], %{head: 9, has_more: true})}

          2 ->
            assert opts[:through] == 9
            {:ok, history([entry(7)], %{cursor: 9, head: 9})}

          9 ->
            assert opts[:through] == nil
            {:ok, history([entry(12)], %{cursor: 12, head: 12})}
        end

      :events, _, _, cursor, opts ->
        case cursor do
          0 ->
            assert opts[:through] == nil
            {:ok, journal([event(:admitted)], %{head: 3, has_more: true})}

          1 ->
            assert opts[:through] == 3
            {:ok, journal([event(:dispatch_started)], %{head: 3, has_more: true})}

          2 ->
            assert opts[:through] == 3
            {:ok, journal([event(:completed)])}
        end
    end)

    assert {:ok, one} = Arbor.sync(original)
    assert %{history: 2, commands: 1} = Arbor.position(one)

    assert %{history: %{head: 9, has_more: true}, commands: %{head: 3, has_more: true}} =
             Arbor.sync_status(one)

    assert {:ok, two} = Arbor.sync(one)
    assert %{history: 9, commands: 2} = Arbor.position(two)
    assert {:ok, three} = Arbor.sync(two)
    assert %{history: 12, commands: 3} = Arbor.position(three)
    assert Process.get(:proof_count) == 6

    tokens =
      for n <- 1..6 do
        assert_receive {:request, _, "human_private", "agent_private", _, opts}
        assert opts[:session_token] == "private-proof-#{n}"
        opts[:session_token]
      end

    assert length(Enum.uniq(tokens)) == 6
  end

  test "reconstructing on reconnect gives deterministic projections and polling is idempotent" do
    original = client()
    serve_history_and_events(history([entry(3)]), journal([event(:admitted)]))
    assert {:ok, one} = Arbor.sync(original)
    assert {:ok, replayed} = Arbor.sync(client())
    assert Arbor.projection(one) == Arbor.projection(replayed)

    serve_history_and_events(
      history([], %{cursor: 3, head: 3}),
      journal([], %{cursor: 1, head: 1})
    )

    assert {:ok, two} = Arbor.sync(one)
    assert Arbor.projection(one) == Arbor.projection(two)
  end

  test "history with ordinal gaps and an empty trailing private page advances to the global head" do
    serve_history_and_events(history([entry(2), entry(11)], %{cursor: 20, head: 20}), journal())
    assert {:ok, one} = Arbor.sync(client())
    assert Arbor.position(one).history == 20
    serve_history_and_events(history([], %{cursor: 29, head: 29}), journal())
    assert {:ok, two} = Arbor.sync(one)
    assert Arbor.position(two).history == 29
    assert length(Arbor.projection(two)["messages"]) == 2
  end

  test "both streams remain unchanged on a late-page failure" do
    original = client(page_limit: 1)

    Process.put(:host, fn
      :history, _, _, _, opts ->
        if opts[:after] == 0,
          do: {:ok, history([entry(2)], %{head: 7, has_more: true})},
          else: {:ok, history([entry(7)])}

      :events, _, _, _, _ ->
        {:error, :conversation_unavailable}
    end)

    assert {:error, :conversation_unavailable} = Arbor.sync(original)
    assert Arbor.position(original) == %{history: 0, commands: 0}
    assert Arbor.projection(original)["messages"] == []
  end

  test "security regression: pinned owner, target and engagement cannot change" do
    serve_history_and_events(history(), journal([event(:admitted)]))
    assert {:ok, pinned} = Arbor.sync(client())

    for extra <- [
          %{principal_id: "another_canonical_owner"},
          %{agent_id: "other"},
          %{engagement_id: @other_engagement}
        ] do
      Process.put(:host, fn :command, _, _, _, _ -> {:ok, command(:admitted, extra)} end)
      assert {:error, _} = Arbor.command(pinned, "cmd_1")
    end
  end

  test "security regression: history engagement cannot change after an empty authenticated page" do
    serve_history_and_events(history(), journal())
    assert {:ok, one} = Arbor.sync(client())
    serve_history_and_events(history([entry(1)], %{engagement_id: @other_engagement}), journal())
    assert {:error, :conversation_scope_changed} = Arbor.sync(one)
  end

  test "unknown future events stop replay explicitly" do
    serve_history_and_events(history(), journal([event(:admitted, %{kind: "future_kind"})]))
    assert {:error, :unsupported_event_kind} = Arbor.sync(client())
  end

  test "command journal gaps and duplicate event IDs are rejected" do
    for events <- [
          [event(:dispatch_started)],
          [event(:admitted), event(:dispatch_started, %{id: "event_1"})],
          [event(:admitted), event(:admitted)]
        ] do
      serve_history_and_events(history(), journal(events))
      assert {:error, _} = Arbor.sync(client())
    end
  end

  test "completion without a dispatch event is rejected" do
    bad = event(:completed, %{cursor: 2, command: command(:completed, %{updated_cursor: 2})})
    serve_history_and_events(history(), journal([event(:admitted), bad]))
    assert {:error, :invalid_command_response} = Arbor.sync(client())
  end

  test "saved response statuses require space for their durable journal transitions" do
    for {status, cursor} <- [
          admitted: 2,
          dispatch_started: 1,
          completed: 1,
          completed: 2,
          uncertain: 2
        ] do
      Process.put(:host, fn :command, _, _, _, _ ->
        {:ok, command(status, %{updated_cursor: cursor})}
      end)

      assert {:error, :invalid_command_response} = Arbor.command(client(), "cmd_1")
    end
  end

  test "dispatch started and uncertain remain visible and never become assistant or speech output" do
    for status <- [:dispatch_started, :uncertain] do
      events =
        [event(:admitted), event(:dispatch_started)] ++
          if(status == :uncertain, do: [event(:uncertain)], else: [])

      serve_history_and_events(history(), journal(events))
      assert {:ok, one} = Arbor.sync(client())
      assert [%{"status" => actual, "result_text" => nil}] = Arbor.projection(one)["deliveries"]
      assert actual == Atom.to_string(status)
      assert Arbor.projection(one)["messages"] == []
      assert Arbor.projection(one)["speech"] == []
    end
  end

  test "submit uses stable input and command reads cannot advance replay cursor" do
    Process.put(:host, fn
      :submit, _, _, input, _ ->
        assert input == %{id: "cmd_1", text: "Hello"}
        {:ok, command()}

      :command, _, _, "cmd_1", _ ->
        {:ok, command(:completed)}
    end)

    assert {:ok, admitted, %{"status" => "admitted"}} =
             Arbor.submit(attached_client(), "cmd_1", "Hello")

    assert {:ok, completed, %{"status" => "completed"}} = Arbor.command(admitted, "cmd_1")
    assert Arbor.position(completed) == %{history: 0, commands: 0}
    assert Arbor.projection(completed)["messages"] == []

    serve_history_and_events(
      history(),
      journal([event(:admitted), event(:dispatch_started), event(:completed)])
    )

    assert {:ok, replayed} = Arbor.sync(completed)
    assert Arbor.projection(completed) == Arbor.projection(replayed)
  end

  test "older replay pages cannot regress a directly observed completion" do
    Process.put(:host, fn :command, _, _, _, _ -> {:ok, command(:completed)} end)
    assert {:ok, completed, _} = Arbor.command(client(page_limit: 1, max_pages: 1), "cmd_1")
    serve_history_and_events(history(), journal([event(:admitted)], %{head: 3, has_more: true}))
    assert {:ok, partial} = Arbor.sync(completed)
    assert [%{"status" => "completed"}] = Arbor.projection(partial)["deliveries"]
  end

  test "older command responses cannot regress a completion already seen in replay" do
    serve_history_and_events(
      history(),
      journal([event(:admitted), event(:dispatch_started), event(:completed)])
    )

    assert {:ok, completed} = Arbor.sync(client())
    Process.put(:host, fn :command, _, _, _, _ -> {:ok, command(:admitted)} end)
    assert {:ok, next, %{"status" => "completed"}} = Arbor.command(completed, "cmd_1")
    assert Arbor.projection(next) == Arbor.projection(completed)
  end

  test "a changed pinned head is rejected across bounded sync calls" do
    serve_history_and_events(history([entry(1)], %{head: 3, has_more: true}), journal())
    assert {:ok, one} = Arbor.sync(client(page_limit: 1, max_pages: 1))
    serve_history_and_events(history([entry(3)], %{head: 4, cursor: 4}), journal())
    assert {:error, :invalid_page_bounds} = Arbor.sync(one)
    assert Arbor.position(one) == %{history: 1, commands: 0}
  end

  test "conflicting command input, outcome, ID, and cursor observations are rejected" do
    Process.put(:host, fn :command, _, _, _, _ -> {:ok, command(:completed)} end)
    assert {:ok, one, _} = Arbor.command(client(), "cmd_1")

    for extra <- [
          %{id: "wrong"},
          %{text: "Different"},
          %{outcome: %{status: :completed, text: "Wrong"}},
          %{updated_cursor: 5}
        ] do
      Process.put(:host, fn :command, _, _, _, _ -> {:ok, command(:completed, extra)} end)
      assert {:error, :conflicting_response} = Arbor.command(one, "cmd_1")
    end
  end

  test "submit rejects changed returned input rather than accepting an unrelated delivery" do
    Process.put(:host, fn :submit, _, _, _, _ ->
      {:ok, command(:admitted, %{text: "Different"})}
    end)

    assert {:error, :conflicting_response} = Arbor.submit(attached_client(), "cmd_1", "Hello")
  end

  test "input and history use the actual independent host limits without truncation" do
    input = String.duplicate("x", 32_768)
    transcript = String.duplicate("y", 262_144)
    reply = String.duplicate("z", 131_072)

    Process.put(:host, fn :submit, _, _, %{text: ^input}, _ ->
      {:ok, command(:completed, %{text: input, outcome: %{status: :completed, text: reply}})}
    end)

    assert {:ok, submitted, delivery} = Arbor.submit(attached_client(), "cmd_1", input)
    assert delivery["input_text"] == input
    assert delivery["result_text"] == reply
    assert {:error, :invalid_command} = Arbor.submit(submitted, "cmd_2", input <> "x")
    serve_history_and_events(history([entry(1, transcript)]), journal())
    assert {:ok, synced} = Arbor.sync(client())
    assert hd(Arbor.projection(synced)["messages"])["text"] == transcript
  end

  test "oversized pages retry at a lower limit with fresh authentication" do
    Process.put(:host, fn
      :history, _, _, _, opts ->
        if opts[:limit] > 1, do: {:error, :page_too_large}, else: {:ok, history([entry(1)])}

      :events, _, _, _, _ ->
        {:ok, journal()}
    end)

    assert {:ok, synced} = Arbor.sync(client(page_limit: 8, max_pages: 1))
    assert Arbor.position(synced).history == 1
    assert Process.get(:proof_count) == 5
  end

  test "unknown status, hidden metadata, private claim tokens and extra page fields fail closed" do
    for bad <- [
          Map.put(command(), :claim_token, "secret"),
          Map.put(command(), :metadata, %{secret: true}),
          %{command() | status: :future}
        ] do
      Process.put(:host, fn :command, _, _, _, _ -> {:ok, bad} end)
      assert {:error, _} = Arbor.command(client(), "cmd_1")
    end

    serve_history_and_events(Map.put(history(), :metadata, "secret"), journal())
    assert {:error, :invalid_history_page} = Arbor.sync(client())
  end

  test "bad pinned heads, backwards cursors, non-progress pages, and mismatched terminal cursors reject" do
    for bad <- [
          history([], %{cursor: -1}),
          history([], %{cursor: 1, head: 0}),
          history([], %{head: 2, has_more: true}),
          history([entry(3)], %{cursor: 2, head: 2})
        ] do
      serve_history_and_events(bad, journal())
      assert {:error, _} = Arbor.sync(client())
    end
  end

  test "history rejects duplicate IDs, non-increasing ordinals, bad timestamps and invalid roles" do
    for entries <- [
          [entry(1), %{entry(2) | id: "message_1"}],
          [entry(2), entry(1)],
          [%{entry(1) | timestamp: "invalid"}],
          [%{entry(1) | role: "system"}]
        ] do
      serve_history_and_events(history(entries), journal())
      assert {:error, _} = Arbor.sync(client())
    end
  end

  test "proof errors and host exceptions are bounded and never exposed verbatim" do
    for provider <- [
          fn _ -> {:ok, [session_token: "secret", signed_request: "secret"]} end,
          fn _ -> raise "secret" end,
          fn _ -> {:error, %{secret: true}} end
        ] do
      {:ok, one} = Arbor.new("human", "agent", provider, facade: Facade)
      assert {:error, :proof_unavailable} = Arbor.sync(one)
    end

    Process.put(:host, fn _, _, _, _, _ -> raise "secret" end)
    assert {:error, :conversation_unavailable} = Arbor.sync(client())
    Process.put(:host, fn _, _, _, _, _ -> {:error, %{secret: true}} end)
    assert {:error, :conversation_unavailable} = Arbor.sync(client())
  end

  test "each signed request provider call receives the precise operation and page options" do
    provider = fn context ->
      send(self(), {:context, context})
      {:ok, [signed_request: make_ref()]}
    end

    {:ok, one} = Arbor.new("human_private", "agent_private", provider, facade: Facade)
    serve_history_and_events(history(), journal())
    assert {:ok, _} = Arbor.sync(one)
    assert_receive {:context, %{operation: :history, input: nil, options: [after: 0, limit: 50]}}

    assert_receive {:context,
                    %{
                      operation: :events,
                      input: 0,
                      options: [expected_engagement_id: @engagement, limit: 50]
                    }}

    assert_receive {:request, :history, _, _, _, [signed_request: a, after: 0, limit: 50]}

    assert_receive {:request, :events, _, _, _,
                    [signed_request: b, expected_engagement_id: @engagement, limit: 50]}

    refute a == b
  end

  test "unauthorized host/proof results remain explicit for owner cache invalidation" do
    Process.put(:host, fn _, _, _, _, _ -> {:error, :unauthorized} end)
    assert {:error, :unauthorized} = Arbor.sync(client())
    {:ok, one} = Arbor.new("human", "agent", fn _ -> {:error, :unauthorized} end)
    assert {:error, :unauthorized} = Arbor.sync(one)
  end

  test "configuration, command IDs and empty text use closed validation" do
    for opts <- [
          [page_limit: 0],
          [max_pages: 101],
          [page_limit: 1, page_limit: 2],
          [session_token: "secret"],
          [engagement_id: @engagement],
          nil
        ] do
      assert {:error, :invalid_client_options} =
               Arbor.new("human", "agent", fn _ -> nil end, opts)
    end

    for {id, text} <- [{"bad.id", "text"}, {"id", "  "}, {"", "text"}, {"id", <<255>>}] do
      assert {:error, :invalid_command} = Arbor.submit(attached_client(), id, text)
    end
  end

  test "linked caller accepts host canonical owner and pins it without rewriting proof subject" do
    canonical = command(:admitted, %{principal_id: "human_canonical"})
    serve_history_and_events(history(), journal([event(:admitted, %{command: canonical})]))
    assert {:ok, pinned} = Arbor.sync(client())
    assert pinned.caller == "human_private"
    assert pinned.owner == "human_canonical"
    refute inspect(Arbor.projection(pinned)) =~ "human_canonical"
    assert_receive {:request, :events, "human_private", "agent_private", 0, opts}
    assert opts[:expected_engagement_id] == @engagement

    Process.put(:host, fn :command, caller, _, _, opts ->
      assert caller == "human_private"
      assert opts[:expected_engagement_id] == @engagement
      {:ok, command(:completed, %{principal_id: "human_canonical"})}
    end)

    assert {:ok, _, _} = Arbor.command(pinned, "cmd_1")
  end

  test "security regression: an empty journal page must retain the history engagement" do
    serve_history_and_events(history(), journal([], %{engagement_id: @other_engagement}))
    assert {:error, :conversation_scope_changed} = Arbor.sync(client())
  end

  test "every later operation sends the pinned engagement fence in proof context and host opts" do
    serve_history_and_events(history(), journal())
    assert {:ok, pinned} = Arbor.sync(client())

    Process.put(:host, fn operation, _, _, _, opts ->
      assert opts[:expected_engagement_id] == @engagement

      case operation do
        :history -> {:ok, history()}
        :events -> {:ok, journal()}
        _ -> {:ok, command()}
      end
    end)

    assert {:ok, pinned} = Arbor.sync(pinned)
    assert {:ok, pinned, _} = Arbor.submit(pinned, "cmd_1", "Hello")
    assert {:ok, _, _} = Arbor.command(pinned, "cmd_1")
    Process.put(:host, fn _, _, _, _, _ -> {:error, :conversation_scope_changed} end)
    assert {:error, :conversation_scope_changed} = Arbor.submit(pinned, "cmd_1", "Hello")
  end

  test "unsupported capability remains a bounded deterministic admission rejection" do
    Process.put(:host, fn _, _, _, _, _ -> {:error, :unsupported_conversation_capability} end)

    assert {:error, :unsupported_conversation_capability} =
             Arbor.submit(attached_client(), "cmd_1", "Hello")
  end

  test "security regression: first submission requires a successfully pinned scope" do
    original = client()

    Process.put(:host, fn :submit, _, _, input, _ ->
      send(self(), {:unfenced_submission, input})
      {:ok, command()}
    end)

    assert {:error, :conversation_not_attached} = Arbor.submit(original, "cmd_1", "Hello")
    refute_receive {:unfenced_submission, _}
    refute_receive {:request, _, _, _, _, _}
    refute_receive {:proof, _}
  end

  test "trusted transport receives a fresh provided proof and the pinned request context" do
    transport = fn context, proof ->
      send(self(), {:transport, context, proof})

      case context.operation do
        :history -> {:ok, history()}
        :events -> {:ok, journal()}
      end
    end

    assert {:ok, next} = Arbor.sync(client(transport: transport))
    assert Arbor.position(next) == %{history: 0, commands: 0}

    assert_receive {:transport, %{operation: :history, options: history_opts},
                    [session_token: first]}

    assert history_opts[:expected_engagement_id] == nil

    assert_receive {:transport, %{operation: :events, options: event_opts},
                    [session_token: second]}

    assert event_opts[:expected_engagement_id] == @engagement
    refute first == second
    refute_receive {:request, _, _, _, _, _}
  end

  test "security regression: remote malformed responses and scope changes retain closed validation" do
    assert {:error, :invalid_transport_response} =
             Arbor.sync(client(transport: fn _, _ -> {:ok, "not a page"} end))

    transport = fn
      %{operation: :history}, _ -> {:ok, history()}
      %{operation: :events}, _ -> {:ok, journal([], %{engagement_id: @other_engagement})}
    end

    assert {:error, :conversation_scope_changed} = Arbor.sync(client(transport: transport))
  end

  test "transport is never invoked when proof acquisition fails" do
    transport = fn _, _ ->
      send(self(), :transport_effect)
      {:ok, history()}
    end

    {:ok, original} =
      Arbor.new("human_private", "agent_private", fn _ -> {:error, :unauthorized} end,
        transport: transport
      )

    assert {:error, :unauthorized} = Arbor.sync(original)
    refute_receive :transport_effect
  end
end
