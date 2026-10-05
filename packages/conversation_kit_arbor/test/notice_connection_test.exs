defmodule ConversationKit.Arbor.NoticeConnectionTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor.Connection
  @moduletag :fast
  @page JSON.decode!(File.read!(Path.join(__DIR__, "support/notice_page.json")))

  defp start(host, opts \\ [], owner \\ self()) do
    observer = self()
    {host_window, opts} = Keyword.pop(opts, :host_window, false)

    options = [
      caller: "human_linked_alias",
      target: @page["target_agent_id"],
      poll_interval_ms: 60_000,
      operation_timeout_ms: 500,
      proof_provider: fn context ->
        token = make_ref()
        send(observer, {:fresh_proof, context.operation, token})
        {:ok, [session_token: token]}
      end,
      adapter_options: [
        transport: fn context, proof ->
          send(observer, {:read, context, proof})

          case context.operation do
            :window -> if(host_window, do: host.(context, observer), else: {:ok, window()})
            :activity -> {:error, :unsupported_conversation_capability}
            _ -> host.(context, observer)
          end
        end
      ]
    ]

    {:ok, pid} = Connection.start(Keyword.merge(options, opts), owner)
    on_exit(fn -> Connection.close(pid) end)
    pid
  end

  defp window do
    %{
      engagement_id: @page["engagement_id"],
      entries: [
        %{
          id: "recent",
          role: "assistant",
          content: "Fresh transcript",
          timestamp: "2026-10-03T00:00:00Z",
          entry_ordinal: 1
        }
      ],
      head: 1,
      first: 1,
      last: 1,
      has_older: false,
      has_newer: false
    }
  end

  defp await(pid, predicate),
    do: await(pid, predicate, System.monotonic_time(:millisecond) + 2_000)

  defp await(pid, predicate, deadline) do
    receive do
      {:conversation_updated, ^pid, snapshot} ->
        if predicate.(snapshot), do: snapshot, else: await(pid, predicate, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("Notice snapshot did not arrive")
    end
  end

  test "blocked notice read publishes fresh transcript first and queues one same-ID send behind fresh proof" do
    pid =
      start(fn context, observer ->
        case context.operation do
          :notices ->
            send(observer, {:blocked_notice, self()})

            receive do
              :release -> {:ok, @page}
            end

          :submit ->
            send(observer, {:submitted, context.input})
            {:error, :conversation_unavailable}
        end
      end)

    assert_receive {:blocked_notice, worker}, 2_000
    snapshot = Connection.snapshot(pid)
    assert snapshot.connected and snapshot.busy and snapshot.send_allowed
    assert snapshot.notices_status == :checking
    assert [%{"text" => "Fresh transcript"}] = snapshot.projection["messages"]
    assert :ok = Connection.act(pid, :send, %{id: "same_request", text: "Hello"})
    refute_receive {:submitted, _}, 40
    send(worker, :release)
    assert_receive {:submitted, %{id: "same_request", text: "Hello"}}, 2_000
    refute_receive {:submitted, _}, 40
    assert_receive {:fresh_proof, :notices, notice_proof}
    assert_receive {:fresh_proof, :submit, send_proof}
    assert notice_proof != send_proof
  end

  test "read timeout clears prior notices but retains separately authorized transcript and no uncertain receipt" do
    store = start_supervised!({Agent, fn -> :normal end})

    pid =
      start(
        fn %{operation: :notices}, observer ->
          case Agent.get(store, & &1) do
            :normal ->
              {:ok, @page}

            :hold ->
              send(observer, {:blocked_notice, self()})

              receive do
                :never -> {:ok, @page}
              end
          end
        end,
        operation_timeout_ms: 100
      )

    await(pid, &(&1.notices_status == :available))
    Agent.update(store, fn _ -> :hold end)
    Connection.act(pid, :refresh)
    assert_receive {:blocked_notice, worker}, 2_000
    ref = Process.monitor(worker)
    snapshot = await(pid, &(&1.notices_status == :unavailable and not &1.busy))
    assert snapshot.connected and snapshot.send_allowed
    assert snapshot.projection["notices"] == []
    assert [%{"text" => "Fresh transcript"}] = snapshot.projection["messages"]
    assert snapshot.error == nil and snapshot.pending_id == nil and snapshot.receipt == nil
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
  end

  test "malformed local transport notice page clears notices without invalidating freshly authorized transcript" do
    pid =
      start(fn %{operation: :notices}, observer ->
        send(observer, {:malformed_notice, self()})

        receive do
          :release_malformed -> {:ok, nil}
        end
      end)

    assert_receive {:malformed_notice, worker}, 2_000
    await(pid, &(&1.notices_status == :checking))
    send(worker, :release_malformed)
    snapshot = await(pid, &(&1.notices_status == :unavailable and not &1.busy))
    assert snapshot.connected and snapshot.send_allowed
    refute snapshot.private_cleared
    assert [%{"text" => "Fresh transcript"}] = snapshot.projection["messages"]
    assert snapshot.projection["notices"] == []
    assert snapshot.error == nil and snapshot.receipt == nil and snapshot.pending_id == nil
  end

  test "security regression: notice revocation clears all private state and refuses the queued send" do
    pid =
      start(fn context, observer ->
        case context.operation do
          :notices ->
            send(observer, {:blocked_notice, self()})

            receive do
              :revoke -> {:error, :unauthorized}
            end

          :submit ->
            flunk("revoked queued intent was dispatched")
        end
      end)

    assert_receive {:blocked_notice, worker}, 2_000
    Connection.act(pid, :send, %{id: "kept_id", text: "Hello"})
    send(worker, :revoke)
    snapshot = await(pid, & &1.private_cleared)
    refute snapshot.connected
    assert snapshot.projection["messages"] == [] and snapshot.projection["notices"] == []
    assert snapshot.pending_id == nil
    refute_receive {:fresh_proof, :submit, _}, 100
  end

  test "unsupported applies only to notice reads, with no caller-prefix heuristic and reconnect rechecks" do
    store = start_supervised!({Agent, fn -> 0 end})

    pid =
      start(
        fn %{operation: :notices}, _ ->
          count = Agent.get_and_update(store, &{&1, &1 + 1})
          if count == 0, do: {:error, :notice_subject_required}, else: {:ok, @page}
        end,
        caller: "agent_signed_human_without_prefix_guess"
      )

    snapshot = await(pid, &(&1.notices_status == :unsupported))
    assert snapshot.connected and snapshot.projection["messages"] != []
    Connection.act(pid, :refresh)
    await(pid, &(not &1.busy))
    assert Agent.get(store, & &1) == 1
    Connection.act(pid, :reconnect)
    snapshot = await(pid, &(&1.notices_status == :available))
    assert snapshot.projection["notices"] != []
    assert Agent.get(store, & &1) == 2
  end

  test "notice_subject_required from a history read cannot disable notices in a later authenticated phase" do
    store = start_supervised!({Agent, fn -> true end})

    pid =
      start(
        fn context, _ ->
          case context.operation do
            :window ->
              if Agent.get_and_update(store, &{&1, false}),
                do: {:error, :notice_subject_required},
                else: {:ok, window()}

            :notices ->
              {:ok, @page}
          end
        end,
        host_window: true
      )

    snapshot = await(pid, &(not &1.busy and not is_nil(&1.error)))
    assert snapshot.notices_status == :unavailable
    Connection.act(pid, :refresh)
    snapshot = await(pid, &(&1.notices_status == :available))
    assert snapshot.connected
    assert snapshot.projection["notices"] != []
  end

  test "older paging retains original cutoff on refresh and latest resets it explicitly" do
    store = start_supervised!({Agent, fn -> 4 end})

    pid =
      start(
        fn %{operation: :notices, options: opts}, _ ->
          head = Agent.get(store, & &1)
          through = opts[:through] || head

          records =
            for ordinal <- through..1//-1,
                is_nil(opts[:before]) or ordinal < opts[:before],
                do: record(ordinal)

          selected = Enum.take(records, opts[:limit])
          older = length(records) > length(selected)

          page = %{
            @page
            | "head" => head,
              "through" => through,
              "notices" => selected,
              "has_older" => older,
              "next_before" => if(older, do: List.last(selected)["ordinal"])
          }

          {:ok, page}
        end,
        notice_page_limit: 2
      )

    assert [4, 3] ==
             await(pid, &(&1.notices_status == :available)).projection["notices"]
             |> Enum.map(& &1["ordinal"])

    Connection.act(pid, :older_notices)

    snapshot =
      await(
        pid,
        &(&1.notices_status == :available and hd(&1.projection["notices"])["ordinal"] == 2)
      )

    assert Enum.map(snapshot.projection["notices"], & &1["ordinal"]) == [2, 1]
    Agent.update(store, fn _ -> 6 end)
    Connection.act(pid, :refresh)
    snapshot = await(pid, &(&1.notices_status == :available and &1.notice_window.head == 6))
    assert snapshot.notice_window.through == 4
    assert Enum.map(snapshot.projection["notices"], & &1["ordinal"]) == [2, 1]
    Connection.act(pid, :latest_notices)
    snapshot = await(pid, &(&1.notices_status == :available and &1.notice_window.through == 6))
    assert Enum.map(snapshot.projection["notices"], & &1["ordinal"]) == [6, 5]
    assert snapshot.window.head == 1
  end

  test "owner death cancels the notice worker and stale results cannot repopulate a replacement connection" do
    observer = self()

    owner =
      spawn(fn ->
        receive do
          :close_owner -> :ok
        end
      end)

    old =
      start(
        fn %{operation: :notices}, _ ->
          send(observer, {:old_worker, self()})

          receive do
            :release -> {:ok, @page}
          end
        end,
        [],
        owner
      )

    assert_receive {:old_worker, worker}, 2_000
    old_ref = Process.monitor(old)
    worker_ref = Process.monitor(worker)
    send(owner, :close_owner)
    assert_receive {:DOWN, ^old_ref, :process, ^old, _}, 2_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 2_000
    current = start(fn _context, _ -> {:ok, %{@page | "notices" => []}} end)
    snapshot = await(current, &(&1.notices_status == :available))
    send(current, {:operation_result, make_ref(), {:ok, :forged, @page}})
    assert Connection.snapshot(current).projection == snapshot.projection
    assert snapshot.projection["notices"] == []
  end

  defp record(ordinal) do
    notice =
      hd(@page["notices"])
      |> Map.put("ordinal", ordinal)
      |> Map.put(
        "notice_id",
        "notice_" <> (ordinal |> Integer.to_string(16) |> String.pad_leading(32, "0"))
      )

    payload = [
      "arbor.notice.provenance.v1",
      @page["owner_id"],
      @page["target_agent_id"],
      @page["engagement_id"],
      notice["recipient_subject_id"],
      notice["notice_id"],
      notice["kind"],
      notice["text"]
    ]

    digest = :crypto.hash(:sha256, JSON.encode!(payload)) |> Base.encode16(case: :lower)
    put_in(notice, ["provenance", "taint", "payload_sha256"], digest)
  end
end
