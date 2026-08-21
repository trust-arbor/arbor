defmodule Arbor.Historian.QueryEngineTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Historian.QueryEngine
  alias Arbor.Historian.TestHelpers
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS

  defmodule ColdDurable do
    # Mirrors Ecto.read_stream/2: honors :limit and :from, ignores :max_scan.
    def read_stream(stream_id, opts) do
      repo = Keyword.fetch!(opts, :repo)
      from = Keyword.get(opts, :from, 0)
      limit = Keyword.get(opts, :limit)

      Agent.get_and_update(repo, fn state ->
        events =
          state.streams
          |> Map.get(stream_id, [])
          |> Enum.filter(fn event ->
            not is_integer(from) or event.event_number >= from
          end)

        events =
          if is_integer(limit) and limit > 0, do: Enum.take(events, limit), else: events

        captured = Keyword.take(opts, [:from, :to, :limit, :max_scan])
        {{:ok, events}, %{state | reads: [{stream_id, captured} | state.reads]}}
      end)
    end
  end

  defmodule FlunkDurable do
    def read_stream(_stream_id, _opts) do
      raise "durable must not be consulted for a complete payload cache"
    end
  end

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ctx = TestHelpers.start_test_historian(:"qe_#{System.unique_integer([:positive])}")

    # Seed some signals
    signals = [
      TestHelpers.build_agent_signal("a1",
        category: :activity,
        type: :agent_started,
        correlation_id: "corr_1"
      ),
      TestHelpers.build_agent_signal("a1",
        category: :activity,
        type: :task_completed
      ),
      TestHelpers.build_signal(
        category: :security,
        type: :authorization,
        data: %{session_id: "sess_1"}
      ),
      TestHelpers.build_signal(
        category: :logs,
        type: :error,
        data: %{message: "something failed"}
      )
    ]

    for signal <- signals do
      TestHelpers.collect_signal(ctx, signal)
    end

    %{ctx: ctx}
  end

  describe "read_global/1" do
    test "returns all entries", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_global(event_log: ctx.event_log)
      assert length(entries) == 4
    end

    test "forwards an inclusive integer cursor and limit to the cache", %{ctx: ctx} do
      assert {:ok, [entry]} =
               QueryEngine.read_global(event_log: ctx.event_log, from: 3, limit: 1)

      assert entry.category == :security
    end
  end

  describe "read_agent/2" do
    test "returns entries for a specific agent", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_agent("a1", event_log: ctx.event_log)
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.data[:agent_id] == "a1" || &1.data["agent_id"] == "a1"))
    end

    test "returns empty for unknown agent", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_agent("nonexistent", event_log: ctx.event_log)
      assert entries == []
    end
  end

  describe "read_category/2" do
    test "returns entries for a specific category", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_category(:security, event_log: ctx.event_log)
      assert length(entries) == 1
      assert hd(entries).category == :security
    end

    test "returns entries for activity category", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_category(:activity, event_log: ctx.event_log)
      assert length(entries) == 2
    end
  end

  describe "read_session/2" do
    test "returns entries for a specific session", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_session("sess_1", event_log: ctx.event_log)
      assert length(entries) == 1
    end
  end

  describe "read_correlation/2" do
    test "returns entries for a correlation chain", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_correlation("corr_1", event_log: ctx.event_log)
      assert length(entries) == 1
    end
  end

  describe "query/1" do
    test "filters by category", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, category: :logs)
      assert length(entries) == 1
      assert hd(entries).category == :logs
    end

    test "filters by type", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, type: :agent_started)
      assert length(entries) == 1
      assert hd(entries).type == :agent_started
    end

    test "applies limit", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, limit: 2)
      assert length(entries) == 2
    end

    test "combines filters", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(event_log: ctx.event_log, category: :activity, type: :task_completed)

      assert length(entries) == 1
    end

    test "returns empty when no matches", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, category: :nonexistent)
      assert entries == []
    end
  end

  describe "query edge cases" do
    test "query with no filters returns all entries", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log)
      assert length(entries) == 4
    end

    test "query with limit larger than result set returns all entries", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, limit: 100)
      assert length(entries) == 4
    end

    test "query with limit of 1 returns exactly one entry", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, limit: 1)
      assert length(entries) == 1
    end

    test "query with multiple filter types combined", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(
          event_log: ctx.event_log,
          category: :activity,
          type: :agent_started,
          correlation_id: "corr_1"
        )

      assert length(entries) == 1
      entry = hd(entries)
      assert entry.category == :activity
      assert entry.type == :agent_started
      assert entry.correlation_id == "corr_1"
    end

    test "query with time range filters", %{ctx: ctx} do
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)
      future = DateTime.add(now, 3600, :second)

      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, from: past, to: future)
      assert length(entries) == 4

      # With a very narrow window in the past, should get nothing
      very_old = DateTime.add(now, -7200, :second)
      old = DateTime.add(now, -3600, :second)
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, from: very_old, to: old)
      assert entries == []
    end

    test "query with source filter", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(event_log: ctx.event_log, source: "arbor://test/historian")

      assert length(entries) == 4
      assert Enum.all?(entries, &(&1.source == "arbor://test/historian"))
    end

    test "query with source filter no match", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(event_log: ctx.event_log, source: "arbor://nonexistent")

      assert entries == []
    end
  end

  describe "read_stream/2" do
    test "returns empty list for non-existent stream", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_stream("nonexistent_stream", event_log: ctx.event_log)
      assert entries == []
    end
  end

  describe "cache-miss fallthrough (graceful degradation)" do
    # When ETS has events from oldest_event_number onward and a read
    # requests events from BEFORE that, the fallthrough check fires.
    # In tests there's no Repo running, so `durable_backend_available?`
    # returns false — the cache result is returned unchanged. This guards
    # the degradation path from accidental breakage by a future refactor.
    # The durable backend is adapter-agnostic (Postgres or SQLite3) — the
    # check is on Repo presence, not on a specific adapter.
    test "with :from earlier than cache coverage, returns cache result when durable backend unavailable",
         %{
           ctx: ctx
         } do
      # Populate the stream with a few events.
      signal_1 = TestHelpers.build_signal(category: :test, type: :evt1)
      signal_2 = TestHelpers.build_signal(category: :test, type: :evt2)
      TestHelpers.collect_signal(ctx, signal_1)
      TestHelpers.collect_signal(ctx, signal_2)

      # Read with :from set to an integer — exercises the fallthrough
      # check. Postgres isn't running in unit tests, so we must get the
      # cache result back without crashing.
      result =
        QueryEngine.read_stream("global",
          event_log: ctx.event_log,
          from: 0
        )

      assert {:ok, entries} = result
      assert is_list(entries)
    end

    test "empty cache + integer :from triggers fallthrough check (PR 2 fix)", %{ctx: ctx} do
      # After PR 2, ETS starts empty at boot for streams that exist
      # only in the durable backend. The fallthrough must fire when
      # `oldest_event_number` returns nil. Without the durable backend
      # running in tests, the path falls back to cache (empty list) —
      # the important thing is that this does NOT raise.
      assert {:ok, []} =
               QueryEngine.read_stream("stream_only_in_durable",
                 event_log: ctx.event_log,
                 from: 5
               )
    end

    test "non-integer :from skips fallthrough (post-filter case)", %{ctx: ctx} do
      # query/1 passes DateTime values via :from / :to as post-filter
      # bounds, not event_number cursors. The fallthrough path must
      # NOT try to do `oldest > from + 1` on a DateTime.
      TestHelpers.collect_signal(ctx, TestHelpers.build_signal(category: :test, type: :evt))

      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)

      result = QueryEngine.read_stream("global", event_log: ctx.event_log, from: past)
      assert {:ok, _} = result
    end
  end

  describe "find_by_signal_id/2" do
    test "finds entry by original signal ID", %{ctx: ctx} do
      signal = TestHelpers.build_signal(id: "sig_findme", category: :metrics, type: :cpu)
      TestHelpers.collect_signal(ctx, signal)

      {:ok, entry} = QueryEngine.find_by_signal_id("sig_findme", event_log: ctx.event_log)
      assert entry.signal_id == "sig_findme"
    end

    test "returns not_found for unknown signal", %{ctx: ctx} do
      assert {:error, :not_found} =
               QueryEngine.find_by_signal_id("sig_unknown", event_log: ctx.event_log)
    end
  end

  describe "injected durable complete-history fallthrough" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      ctx = TestHelpers.start_test_historian(:"qe_cold_#{System.unique_integer([:positive])}")
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      repo = :"qe_cold_repo_#{System.unique_integer([:positive])}"

      {:ok, _pid} = Agent.start_link(fn -> %{streams: %{}, reads: []} end, name: repo)

      on_exit(fn ->
        if pid = Process.whereis(repo), do: Process.exit(pid, :kill)
      end)

      %{ctx: ctx, repo: repo}
    end

    test "empty cache default reads durable history", %{ctx: ctx, repo: repo} do
      event = durable_historian_event(id: "hist_cold_default")

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => [event]}}
      end)

      assert {:ok, entries} =
               QueryEngine.read_global(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo
               )

      assert length(entries) == 1
      assert hd(entries).signal_id == "hist_cold_default"

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      refute Keyword.has_key?(captured, :to)
      refute Keyword.has_key?(captured, :limit)
    end

    test "bounded default reads do not fetch the entire durable stream", %{ctx: ctx, repo: repo} do
      events =
        for n <- 1..3 do
          durable_historian_event(
            id: "hist_bound_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => events}}
      end)

      assert {:ok, entries} =
               QueryEngine.read_global(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 limit: 1
               )

      assert length(entries) == 1
      assert hd(entries).signal_id == "hist_bound_1"

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      assert Keyword.get(captured, :limit) == 1
    end

    test "unfiltered max_scan maps to Ecto :limit and fails closed when the page is full", %{
      ctx: ctx,
      repo: repo
    } do
      events =
        for n <- 1..3 do
          durable_historian_event(
            id: "hist_scan_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => events}}
      end)

      assert {:error, {:scan_limit_exceeded, %{max_scan: 2}}} =
               QueryEngine.read_global(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 max_scan: 2
               )

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      assert Keyword.get(captured, :limit) == 3
      refute Keyword.has_key?(captured, :max_scan)

      assert {:ok, entries} =
               QueryEngine.read_global(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 max_scan: 10
               )

      assert Enum.map(entries, & &1.signal_id) == [
               "hist_scan_1",
               "hist_scan_2",
               "hist_scan_3"
             ]
    end

    test "max_scan admits a stream whose cardinality exactly equals the bound", %{
      ctx: ctx,
      repo: repo
    } do
      events =
        for n <- 1..2 do
          durable_historian_event(
            id: "hist_exact_scan_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => events}}
      end)

      assert {:ok, entries} =
               QueryEngine.read_global(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 max_scan: 2
               )

      assert Enum.map(entries, & &1.signal_id) == [
               "hist_exact_scan_1",
               "hist_exact_scan_2"
             ]

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :limit) == 3
    end

    test "smaller caller :limit is preserved over a larger max_scan", %{ctx: ctx, repo: repo} do
      events =
        for n <- 1..3 do
          durable_historian_event(
            id: "hist_limit_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => events}}
      end)

      assert {:ok, entries} =
               QueryEngine.read_global(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 limit: 1,
                 max_scan: 100
               )

      assert Enum.map(entries, & &1.signal_id) == ["hist_limit_1"]

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :limit) == 1
    end

    test "inclusive from falls through when the immediately preceding row aged out", %{
      repo: repo
    } do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"qe_inclusive_#{System.unique_integer([:positive])}"

      start_supervised!(
        {PersistenceETS, name: name, max_age_ms: 1_000, trim_interval_ms: :disabled}
      )

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      old = DateTime.add(now, -3_600, :second)

      persisted =
        for n <- 1..6 do
          timestamp = if n < 6, do: old, else: now

          event =
            durable_historian_event(
              id: "hist_inclusive_#{n}",
              event_number: 0,
              global_position: nil,
              timestamp: timestamp
            )

          assert {:ok, [positioned]} =
                   PersistenceETS.append("global", event, name: name)

          positioned
        end

      send(name, :trim_old_events)
      assert {:ok, 6} = PersistenceETS.oldest_event_number("global", name: name)

      Agent.update(repo, &%{&1 | streams: %{"global" => Enum.drop(persisted, 4)}})

      assert {:ok, entries} =
               QueryEngine.read_stream("global",
                 event_log: name,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 from: 5
               )

      assert Enum.map(entries, & &1.signal_id) == ["hist_inclusive_5", "hist_inclusive_6"]
      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert captured[:from] == 5
    end

    test "DateTime filters read durable history then post-filter", %{ctx: ctx, repo: repo} do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      past = DateTime.add(now, -3_600, :second)
      old = DateTime.add(now, -7_200, :second)
      future = DateTime.add(now, 3_600, :second)

      in_window =
        durable_historian_event(
          id: "hist_in_window",
          timestamp: now,
          event_number: 2,
          global_position: 2
        )

      out_window =
        durable_historian_event(
          id: "hist_out_window",
          timestamp: old,
          event_number: 1,
          global_position: 1
        )

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => [out_window, in_window]}}
      end)

      assert {:ok, entries} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 from: past,
                 to: future,
                 limit: 1
               )

      assert Enum.map(entries, & &1.signal_id) == ["hist_in_window"]

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      refute Keyword.has_key?(captured, :to)
      refute match?(%DateTime{}, Keyword.get(captured, :from))
      # Result :limit is a post-filter; the durable limit is a scan page.
      assert Keyword.get(captured, :limit) == 1_001
      refute Keyword.has_key?(captured, :max_scan)
    end

    test "DateTime filters map explicit max_scan to durable :limit", %{ctx: ctx, repo: repo} do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      past = DateTime.add(now, -3_600, :second)
      future = DateTime.add(now, 3_600, :second)

      event =
        durable_historian_event(
          id: "hist_dt_scan",
          timestamp: now,
          event_number: 1,
          global_position: 1
        )

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => [event]}}
      end)

      assert {:ok, entries} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 from: past,
                 to: future,
                 limit: 1,
                 max_scan: 50
               )

      assert Enum.map(entries, & &1.signal_id) == ["hist_dt_scan"]

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      assert Keyword.get(captured, :limit) == 51
    end

    test "DateTime max_scan fails closed instead of returning a clipped page as complete", %{
      ctx: ctx,
      repo: repo
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      past = DateTime.add(now, -3_600, :second)
      future = DateTime.add(now, 3_600, :second)

      events =
        for n <- 1..2 do
          durable_historian_event(
            id: "hist_dt_clip_#{n}",
            timestamp: now,
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => events}}
      end)

      assert {:error, {:scan_limit_exceeded, %{max_scan: 1}}} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 from: past,
                 to: future,
                 limit: 10,
                 max_scan: 1
               )

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      assert Keyword.get(captured, :limit) == 2
      refute Keyword.has_key?(captured, :to)
    end

    test "filtered limit finds a match on a later durable page", %{ctx: ctx, repo: repo} do
      events = [
        durable_historian_event(
          id: "hist_later_1",
          category: :activity,
          event_number: 1,
          global_position: 1
        ),
        durable_historian_event(
          id: "hist_later_2",
          category: :activity,
          event_number: 2,
          global_position: 2
        ),
        durable_historian_event(
          id: "hist_later_3",
          category: :logs,
          type: :error,
          event_number: 3,
          global_position: 3
        )
      ]

      Agent.update(repo, &%{&1 | streams: %{"global" => events}})

      assert {:ok, [entry]} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 category: :logs,
                 limit: 1,
                 max_scan: 10,
                 durable_page_size: 1
               )

      assert entry.signal_id == "hist_later_3"

      reads = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Enum.map(reads, fn {"global", opts} -> opts[:from] end) == [0, 2, 3]
      assert Enum.all?(reads, fn {"global", opts} -> opts[:limit] == 2 end)
      assert Enum.all?(reads, fn {"global", opts} -> not Keyword.has_key?(opts, :max_scan) end)
    end

    test "filtered no-match fails when durable scan completeness exceeds the bound", %{
      ctx: ctx,
      repo: repo
    } do
      events =
        for n <- 1..3 do
          durable_historian_event(
            id: "hist_no_match_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, &%{&1 | streams: %{"global" => events}})

      assert {:error, {:scan_limit_exceeded, %{max_scan: 2}}} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 category: :logs,
                 limit: 1,
                 max_scan: 2
               )

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert captured[:limit] == 3
      refute Keyword.has_key?(captured, :max_scan)
    end

    test "filtered scan admits exact-bound EOF and rejects one row beyond the bound", %{
      ctx: ctx,
      repo: repo
    } do
      events =
        for n <- 1..2 do
          durable_historian_event(
            id: "hist_filtered_bound_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, &%{&1 | streams: %{"global" => events}})

      assert {:ok, []} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 category: :logs,
                 max_scan: 2
               )

      Agent.update(repo, &%{&1 | reads: []})

      assert {:error, {:scan_limit_exceeded, %{max_scan: 1}}} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 category: :logs,
                 max_scan: 1
               )
    end

    test "combined post-filters are applied after durable pagination", %{ctx: ctx, repo: repo} do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      past = DateTime.add(now, -3_600, :second)
      old = DateTime.add(now, -7_200, :second)

      events = [
        durable_historian_event(
          id: "hist_combined_old",
          category: :logs,
          type: :error,
          source: "arbor://target",
          correlation_id: "corr-target",
          timestamp: old,
          event_number: 1,
          global_position: 1
        ),
        durable_historian_event(
          id: "hist_combined_wrong",
          category: :activity,
          timestamp: now,
          event_number: 2,
          global_position: 2
        ),
        durable_historian_event(
          id: "hist_combined_match",
          category: :logs,
          type: :error,
          source: "arbor://target",
          correlation_id: "corr-target",
          timestamp: now,
          event_number: 3,
          global_position: 3
        )
      ]

      Agent.update(repo, &%{&1 | streams: %{"global" => events}})

      assert {:ok, [entry]} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 category: :logs,
                 type: :error,
                 source: "arbor://target",
                 correlation_id: "corr-target",
                 from: past,
                 limit: 1,
                 max_scan: 10,
                 durable_page_size: 1
               )

      assert entry.signal_id == "hist_combined_match"

      reads = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Enum.map(reads, fn {"global", opts} -> opts[:from] end) == [0, 2, 3]
      assert Enum.all?(reads, fn {"global", opts} -> not match?(%DateTime{}, opts[:from]) end)
    end

    test "signal-id lookup paginates and stops when a later match is proved", %{
      ctx: ctx,
      repo: repo
    } do
      events =
        for n <- 1..3 do
          durable_historian_event(
            id: "hist_signal_page_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, &%{&1 | streams: %{"global" => events}})

      assert {:ok, entry} =
               QueryEngine.find_by_signal_id("hist_signal_page_3",
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 max_scan: 10,
                 durable_page_size: 1
               )

      assert entry.signal_id == "hist_signal_page_3"
      reads = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Enum.map(reads, fn {"global", opts} -> opts[:from] end) == [0, 2, 3]
    end

    test "signal-id lookup distinguishes EOF from scan exhaustion", %{ctx: ctx, repo: repo} do
      events =
        for n <- 1..2 do
          durable_historian_event(
            id: "hist_signal_bound_#{n}",
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, &%{&1 | streams: %{"global" => events}})

      assert {:error, :not_found} =
               QueryEngine.find_by_signal_id("missing",
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 max_scan: 2
               )

      Agent.update(repo, &%{&1 | reads: []})

      assert {:error, {:scan_limit_exceeded, %{max_scan: 1}}} =
               QueryEngine.find_by_signal_id("hist_signal_bound_2",
                 event_log: ctx.event_log,
                 durable_event_log: ColdDurable,
                 repo: repo,
                 max_scan: 1
               )
    end

    test "complete payload cache does not consult durable", %{ctx: ctx, repo: repo} do
      TestHelpers.collect_signal(
        ctx,
        TestHelpers.build_signal(category: :activity, type: :agent_started)
      )

      assert {:ok, entries} =
               QueryEngine.query(
                 event_log: ctx.event_log,
                 durable_event_log: FlunkDurable,
                 repo: repo
               )

      assert length(entries) == 1
    end
  end

  defp durable_historian_event(opts) do
    stream_id = Keyword.get(opts, :stream_id, "global")
    id = Keyword.get(opts, :id, "hist_cold_#{System.unique_integer([:positive])}")
    category = Keyword.get(opts, :category, :activity)
    type = Keyword.get(opts, :type, :agent_started)

    Event.new(
      stream_id,
      "arbor.historian.#{category}:#{type}",
      %{"agent_id" => "a-cold"},
      id: id,
      event_number: Keyword.get(opts, :event_number, 1),
      global_position: Keyword.get(opts, :global_position, 1),
      metadata: %{
        signal_id: id,
        source: Keyword.get(opts, :source, "arbor://test/historian"),
        subject_id: stream_id,
        subject_type: :historian,
        version: "1.0.0"
      },
      correlation_id: Keyword.get(opts, :correlation_id),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    )
  end
end
