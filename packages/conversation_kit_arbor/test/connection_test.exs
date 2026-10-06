defmodule ConversationKit.Arbor.ConnectionTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor.Connection
  alias ConversationKit.Composer
  @moduletag :fast
  @engagement "eng_0123456789abcdef0123456789abcdef"

  defp window do
    %{
      engagement_id: @engagement,
      entries: [],
      head: 0,
      first: 0,
      last: 0,
      has_older: false,
      has_newer: false
    }
  end

  defp receipt(id, text) do
    %{
      id: id,
      name: "chat.send",
      text: text,
      principal_id: "human_private",
      agent_id: "agent_private",
      engagement_id: @engagement,
      status: :admitted,
      outcome: nil,
      admitted_cursor: 1,
      updated_cursor: 1
    }
  end

  defp start(host, overrides \\ []) do
    observer = self()

    opts = [
      caller: "human_private",
      target: "agent_private",
      poll_interval_ms: 100,
      proof_provider: fn _ -> {:ok, [session_token: "credential-sentinel"]} end,
      adapter_options: [transport: fn context, _ -> host.(context, observer) end]
    ]

    {:ok, pid} = Connection.start(Keyword.merge(opts, overrides))
    on_exit(fn -> Connection.close(pid) end)
    pid
  end

  defp attached(pid) do
    receive do
      {:conversation_updated, ^pid, %{connected: true} = snapshot} -> snapshot
      {:conversation_updated, ^pid, _} -> attached(pid)
    after
      2_000 -> flunk("Connection did not attach")
    end
  end

  defp await(pid, predicate) do
    await(pid, predicate, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await(pid, predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:conversation_updated, ^pid, snapshot} ->
        if predicate.(snapshot), do: snapshot, else: await(pid, predicate, deadline)
    after
      remaining -> flunk("Expected connection snapshot did not arrive")
    end
  end

  test "slow reads leave the owner responsive and a racing send is queued exactly once" do
    store = start_supervised!({Agent, fn -> 0 end})

    pid =
      start(fn context, observer ->
        case context.operation do
          :window ->
            count = Agent.get_and_update(store, &{&1, &1 + 1})

            if count == 1 do
              send(observer, {:blocked, self()})

              receive do
                :release -> :ok
              end
            end

            {:ok, window()}

          :submit ->
            send(observer, {:submitted, context.input})
            {:ok, receipt(context.input.id, context.input.text)}

          :command ->
            {:ok, receipt(context.input, "Hello")}
        end
      end)

    attached(pid)
    assert_receive {:blocked, worker}, 2_000
    assert Connection.snapshot(pid).busy
    assert :ok = Connection.act(pid, :send, %{id: "stable_id", text: "Hello"})
    assert Connection.snapshot(pid).pending_id == nil
    send(worker, :release)
    assert_receive {:submitted, %{id: "stable_id", text: "Hello"}}, 2_000
    refute_receive {:submitted, _}, 250
    refute inspect(Connection.snapshot(pid)) =~ "credential-sentinel"
  end

  test "an admission is acknowledged before a subsequent refresh error" do
    store = start_supervised!({Agent, fn -> false end})

    pid =
      start(fn context, observer ->
        case context.operation do
          :window ->
            if Agent.get(store, & &1),
              do: {:error, :conversation_unavailable},
              else: {:ok, window()}

          :submit ->
            Agent.update(store, fn _ -> true end)
            send(observer, :admitted)
            {:ok, receipt(context.input.id, context.input.text)}
        end
      end)

    attached(pid)
    Connection.act(pid, :send, %{id: "stable_id", text: "Hello"})
    assert_receive :admitted, 2_000

    assert_receive {:conversation_updated, ^pid,
                    %{ack: %{id: "stable_id", text: "Hello"}, pending_id: nil}},
                   2_000

    failed = await(pid, &(not is_nil(&1.error) and not &1.busy))
    assert failed.pending_id == nil
  end

  test "server-side revocation during idle browsing clears the next display snapshot" do
    store = start_supervised!({Agent, fn -> true end})

    pid =
      start(fn context, _ ->
        if Agent.get(store, & &1),
          do:
            if(context.operation == :window,
              do: {:ok, window()},
              else: {:error, :unsupported_conversation_capability}
            ),
          else: {:error, :unauthorized}
      end)

    attached(pid)
    Agent.update(store, fn _ -> false end)

    assert_receive {:conversation_updated, ^pid, %{private_cleared: true, connected: false}},
                   2_000

    assert Connection.snapshot(pid).projection["messages"] == []
    refute Connection.snapshot(pid).send_allowed
  end

  test "a hung read is cancelled by its watchdog and the owner can refresh again" do
    count = start_supervised!({Agent, fn -> 0 end})

    pid =
      start(
        fn %{operation: :window}, observer ->
          if Agent.get_and_update(count, &{&1, &1 + 1}) == 0 do
            send(observer, {:hung_read, self()})

            receive do
              :never_release -> :ok
            end
          end

          {:ok, window()}
        end,
        operation_timeout_ms: 100,
        poll_interval_ms: 60_000
      )

    assert_receive {:hung_read, worker}, 2_000
    monitor = Process.monitor(worker)
    assert Connection.snapshot(pid).busy
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000
    failed = await(pid, &(not &1.busy and not is_nil(&1.error)))
    refute failed.send_allowed
    Connection.act(pid, :refresh)
    assert attached(pid).send_allowed
  end

  test "restoring a different request cannot overwrite an unresolved delivery" do
    pid =
      start(
        fn context, observer ->
          case context.operation do
            :window ->
              {:ok, window()}

            :submit ->
              {:error, :transport_timeout}

            :command ->
              send(observer, {:unexpected_lookup, context.input})
              {:error, :not_found}
          end
        end,
        poll_interval_ms: 60_000
      )

    attached(pid)
    Connection.act(pid, :send, %{id: "saved_one", text: "First"})
    await(pid, &(&1.pending_id == "saved_one" and not &1.busy))
    Connection.act(pid, :restore, %{id: "saved_two", text: "Second"})
    snapshot = Connection.snapshot(pid)
    assert snapshot.pending_id == "saved_one"
    assert snapshot.error =~ "existing unresolved"
    refute_receive {:unexpected_lookup, _}
  end

  test "a refused retry preserves the earlier uncertain request until a same-ID acknowledgement" do
    attempts = start_supervised!({Agent, fn -> 0 end})

    pid =
      start(
        fn context, observer ->
          case context.operation do
            :window ->
              {:ok, window()}

            :command ->
              send(observer, {:lookup, context.input})
              {:error, :not_found}

            :submit ->
              send(observer, {:submitted, context.input})

              case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
                0 -> {:error, :transport_timeout}
                1 -> {:error, :command_conflict}
                _ -> {:ok, receipt(context.input.id, context.input.text)}
              end
          end
        end,
        poll_interval_ms: 60_000
      )

    attached(pid)
    Connection.act(pid, :send, %{id: "stable_retry", text: "Hello"})
    await(pid, &(&1.pending_id == "stable_retry" and not &1.busy))
    assert_receive {:submitted, %{id: "stable_retry", text: "Hello"}}
    Connection.act(pid, :retry)

    snapshot =
      await(pid, &(&1.pending_id == "stable_retry" and not &1.busy and &1.error =~ "refused"))

    assert snapshot.retry_allowed
    assert_receive {:lookup, "stable_retry"}
    assert_receive {:submitted, %{id: "stable_retry", text: "Hello"}}
    Connection.act(pid, :retry)

    assert %{pending_id: nil, ack: %{id: "stable_retry", text: "Hello"}} =
             await(pid, &(not is_nil(&1.ack)))

    assert_receive {:lookup, "stable_retry"}
    assert_receive {:submitted, %{id: "stable_retry", text: "Hello"}}
    refute_receive {:submitted, _}
  end

  test "a first stopped-agent rejection releases admission without acknowledging or erasing the draft" do
    pid =
      start(
        fn context, observer ->
          case context.operation do
            :window ->
              {:ok, window()}

            :submit ->
              send(observer, {:submitted, context.input})
              {:error, :agent_not_running}

            _ ->
              {:error, :unsupported_conversation_capability}
          end
        end,
        poll_interval_ms: 60_000
      )

    snapshot = attached(pid)
    draft = Composer.new() |> Composer.draft("Keep this draft 日本語")
    {:send, request, submitted} = Composer.submit(draft, snapshot.send_allowed, "stopped_first")
    Connection.act(pid, :send, request)

    rejected =
      await(
        pid,
        &(&1.error == "This agent is not running. Resume it in Console, then send again." and
            not &1.busy)
      )

    assert_receive {:submitted, ^request}
    assert rejected.connected
    assert rejected.send_allowed
    refute rejected.retry_allowed
    refute rejected.private_cleared
    assert rejected.pending_id == nil
    assert rejected.receipt == nil
    assert rejected.ack == nil
    assert rejected.projection["messages"] == []
    assert Composer.acknowledge(submitted, rejected.ack) == submitted

    assert %{draft: "Keep this draft 日本語", submitted: nil} =
             Composer.reject(submitted, request.id)

    refute_receive {:submitted, _}
  end

  test "a stopped-agent retry retains earlier uncertainty and reconciles only the saved ID" do
    attempts = start_supervised!({Agent, fn -> 0 end})

    pid =
      start(
        fn context, observer ->
          case context.operation do
            :window ->
              {:ok, window()}

            :command ->
              send(observer, {:lookup, context.input})
              {:error, :not_found}

            :submit ->
              send(observer, {:submitted, context.input})

              case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
                0 -> {:error, :transport_timeout}
                1 -> {:error, :agent_not_running}
                _ -> {:ok, receipt(context.input.id, context.input.text)}
              end

            _ ->
              {:error, :unsupported_conversation_capability}
          end
        end,
        poll_interval_ms: 60_000
      )

    attached(pid)
    request = %{id: "stopped_retry", text: "Keep the saved text"}
    Connection.act(pid, :send, request)
    await(pid, &(&1.pending_id == request.id and not &1.busy))
    assert_receive {:submitted, ^request}
    Connection.act(pid, :retry)

    uncertain =
      await(
        pid,
        &(&1.pending_id == request.id and not &1.busy and is_binary(&1.error) and
            String.contains?(
              &1.error,
              "This agent is not running. Earlier delivery remains unconfirmed."
            ))
      )

    assert uncertain.connected
    assert uncertain.retry_allowed
    refute uncertain.send_allowed
    assert uncertain.ack == nil
    assert_receive {:lookup, "stopped_retry"}
    assert_receive {:submitted, ^request}
    refute_receive {:submitted, _}
    assert Agent.get(attempts, & &1) == 2

    Connection.act(pid, :retry)
    assert %{pending_id: nil, ack: ^request} = await(pid, &(not is_nil(&1.ack)))
    assert_receive {:lookup, "stopped_retry"}
    assert_receive {:submitted, ^request}
    refute_receive {:submitted, _}
  end

  test "security regression reconnect retains the established owner scope fence" do
    changed = start_supervised!({Agent, fn -> false end})

    pid =
      start(
        fn context, observer ->
          if context.operation == :window,
            do: send(observer, {:window_scope, context.options[:expected_engagement_id]})

          response =
            if Agent.get(changed, & &1),
              do: %{window() | engagement_id: "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
              else: window()

          if context.operation == :window,
            do: {:ok, response},
            else: {:error, :unsupported_conversation_capability}
        end,
        poll_interval_ms: 60_000
      )

    attached(pid)
    assert_receive {:window_scope, nil}
    Connection.act(pid, :disconnect)
    refute Connection.snapshot(pid).connected
    Agent.update(changed, fn _ -> true end)
    Connection.act(pid, :reconnect)
    assert_receive {:window_scope, @engagement}
    snapshot = await(pid, & &1.private_cleared)
    refute snapshot.connected
    assert snapshot.projection["messages"] == []
    assert snapshot.engagement_id == nil
  end

  test "closing an already retired connection is idempotent" do
    pid =
      start(fn context, _ ->
        if context.operation == :window,
          do: {:ok, window()},
          else: {:error, :unsupported_conversation_capability}
      end)

    attached(pid)
    assert Connection.close(pid) == :ok
    assert Connection.close(pid) == :ok
  end

  test "refresh and reconnect retain a pinned browsing window until latest is explicitly selected" do
    head = start_supervised!({Agent, fn -> 60 end})

    pid =
      start(
        fn %{operation: :window, options: options}, _observer ->
          through = options[:through] || Agent.get(head, & &1)

          entries =
            for n <- 1..through,
                do: %{
                  id: "entry_#{n}",
                  role: "assistant",
                  content: "Message #{n}",
                  timestamp: "2026-10-02T00:00:00Z",
                  entry_ordinal: n
                }

          selected =
            cond do
              options[:before] ->
                entries
                |> Enum.filter(&(&1.entry_ordinal < options[:before]))
                |> Enum.take(-options[:limit])

              Keyword.has_key?(options, :after) ->
                entries
                |> Enum.filter(&(&1.entry_ordinal > options[:after]))
                |> Enum.take(options[:limit])

              true ->
                Enum.take(entries, -options[:limit])
            end

          first = hd(selected).entry_ordinal
          last = List.last(selected).entry_ordinal

          {:ok,
           %{
             engagement_id: @engagement,
             entries: selected,
             head: through,
             first: first,
             last: last,
             has_older: first > 1,
             has_newer: last < through
           }}
        end,
        poll_interval_ms: 60_000
      )

    assert attached(pid).window.first == 41
    Connection.act(pid, :older)
    assert await(pid, &(&1.window.first == 21 and not &1.busy)).window.head == 60
    Agent.update(head, fn _ -> 64 end)
    Connection.act(pid, :refresh)
    browsing = await(pid, &(&1.window.first == 21 and not &1.busy))
    assert browsing.window.head == 60
    assert browsing.window.last == 40
    Connection.act(pid, :disconnect)
    await(pid, &(not &1.connected and not &1.busy))
    Connection.act(pid, :reconnect)
    reconnected = await(pid, &(&1.connected and &1.window.first == 21 and not &1.busy))
    assert reconnected.window.head == 60
    assert reconnected.window.last == 40
    Connection.act(pid, :latest)
    assert await(pid, &(&1.window.last == 64 and not &1.busy)).window.first == 45
  end
end
