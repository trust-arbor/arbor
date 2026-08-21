defmodule Arbor.Historian.QueryEngineTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Historian.QueryEngine
  alias Arbor.Historian.TestHelpers
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS

  defmodule ColdDurable do
    # Mirrors Ecto.read_stream/2: honors :limit and :from, ignores :max_scan.
    def stream_version(stream_id, opts) do
      repo = Keyword.fetch!(opts, :repo)

      Agent.get_and_update(repo, fn state ->
        version =
          state.streams
          |> Map.get(stream_id, [])
          |> Enum.map(& &1.event_number)
          |> Enum.max(fn -> 0 end)

        {{:ok, version}, %{state | probes: state.probes + 1}}
      end)
    end

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

        captured = Keyword.take(opts, [:name, :repo, :from, :to, :limit, :max_scan])
        {{:ok, events}, %{state | reads: [{stream_id, captured} | state.reads]}}
      end)
    end
  end

  defmodule FlunkDurable do
    def stream_version(_stream_id, _opts), do: {:ok, 1}

    def read_stream(_stream_id, _opts) do
      raise "sensitive payload that must not be logged"
    end
  end

  defmodule ErrorDurable do
    def stream_version(_stream_id, _opts), do: {:ok, 1}
    def read_stream(_stream_id, _opts), do: {:error, %{payload: "stale-secret"}}
  end

  defmodule MalformedDurable do
    def stream_version(_stream_id, _opts), do: {:ok, 1}
    def read_stream(_stream_id, _opts), do: {:ok, %{payload: "not-a-list"}}
  end

  defmodule ThrowDurable do
    def stream_version(_stream_id, _opts), do: {:ok, 1}
    def read_stream(_stream_id, _opts), do: throw(:sensitive_backend_term)
  end

  defmodule ExitDurable do
    def stream_version(_stream_id, _opts), do: {:ok, 1}
    def read_stream(_stream_id, _opts), do: exit(:sensitive_backend_term)
  end

  defmodule UnavailableDurable do
  end

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ctx = TestHelpers.start_test_historian(:"qe_#{System.unique_integer([:positive])}")
    original_target = Application.fetch_env(:arbor_historian, :durable_event_log_target)
    original_hot_target = Application.fetch_env(:arbor_historian, :hot_event_log_target)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: ctx.event_log,
      backend: PersistenceETS,
      opts: []
    })

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: :query_engine_test_hot_placeholder,
      backend: PersistenceETS,
      opts: []
    })

    on_exit(fn ->
      case original_target do
        {:ok, value} ->
          Application.put_env(:arbor_historian, :durable_event_log_target, value)

        :error ->
          Application.delete_env(:arbor_historian, :durable_event_log_target)
      end

      case original_hot_target do
        {:ok, value} ->
          Application.put_env(:arbor_historian, :hot_event_log_target, value)

        :error ->
          Application.delete_env(:arbor_historian, :hot_event_log_target)
      end
    end)

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

  describe "explicit authoritative EventLog compatibility" do
    test "a named authoritative test EventLog is honored through the public facade" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      authoritative = :"qe_authoritative_#{System.unique_integer([:positive])}"

      start_supervised!(
        {PersistenceETS, name: authoritative, max_age_ms: :infinity, trim_interval_ms: :disabled}
      )

      event = durable_historian_event(id: "named-authoritative")
      assert {:ok, [_positioned]} = PersistenceETS.append("global", event, name: authoritative)

      assert {:ok, [entry]} = Arbor.Historian.recent(event_log: authoritative)
      assert entry.signal_id == "named-authoritative"
    end

    test "a named projection EventLog is rejected through the public facade" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      projection = :"qe_named_projection_#{System.unique_integer([:positive])}"

      start_supervised!(
        {PersistenceETS,
         name: projection, mode: :projection, max_age_ms: :infinity, trim_interval_ms: :disabled}
      )

      assert {:error, {:authoritative_target_rejected, :projection}} =
               Arbor.Historian.recent(event_log: projection)
    end

    test "an authoritative named EventLog supports inclusive cursors", %{ctx: ctx} do
      signal_1 = TestHelpers.build_signal(category: :test, type: :evt1)
      signal_2 = TestHelpers.build_signal(category: :test, type: :evt2)
      TestHelpers.collect_signal(ctx, signal_1)
      TestHelpers.collect_signal(ctx, signal_2)

      result =
        QueryEngine.read_stream("global",
          event_log: ctx.event_log,
          from: 0
        )

      assert {:ok, entries} = result
      assert is_list(entries)
    end

    test "an empty authoritative named EventLog returns an empty history", %{ctx: ctx} do
      assert {:ok, []} =
               QueryEngine.read_stream("stream_only_in_durable",
                 event_log: ctx.event_log,
                 from: 5
               )
    end

    test "DateTime bounds are not converted into event-number cursors", %{ctx: ctx} do
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

  describe "injected authoritative complete-history target" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      ctx = TestHelpers.start_test_historian(:"qe_cold_#{System.unique_integer([:positive])}")
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      repo = :"qe_cold_repo_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Agent.start_link(fn -> %{streams: %{}, reads: [], probes: 0} end, name: repo)

      original_target = Application.fetch_env(:arbor_historian, :durable_event_log_target)

      Application.put_env(:arbor_historian, :durable_event_log_target, %{
        name: :configured_query_authority,
        backend: ColdDurable,
        opts: [repo: repo]
      })

      on_exit(fn ->
        case original_target do
          {:ok, value} ->
            Application.put_env(:arbor_historian, :durable_event_log_target, value)

          :error ->
            Application.delete_env(:arbor_historian, :durable_event_log_target)
        end

        if pid = Process.whereis(repo), do: Process.exit(pid, :kill)
      end)

      %{ctx: ctx, repo: repo}
    end

    test "empty cache default reads durable history", %{repo: repo} do
      event = durable_historian_event(id: "hist_cold_default")

      Agent.update(repo, fn state ->
        %{state | streams: %{"global" => [event]}}
      end)

      assert {:ok, entries} = QueryEngine.read_global([])

      assert length(entries) == 1
      assert hd(entries).signal_id == "hist_cold_default"

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      refute Keyword.has_key?(captured, :to)
      refute Keyword.has_key?(captured, :limit)
    end

    test "legacy durable_event_log and repo keys cannot replace Config-owned authority", %{
      repo: repo
    } do
      event = durable_historian_event(id: "configured-authority")
      Agent.update(repo, &%{&1 | streams: %{"global" => [event]}})

      assert {:ok, [entry]} =
               QueryEngine.query(
                 category: :activity,
                 durable_event_log: ErrorDurable,
                 repo: :caller_repo
               )

      assert entry.signal_id == "configured-authority"
      assert [{"global", _captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Agent.get(repo, & &1.probes) == 0
    end

    test "test seam replaces only the Config hot name while Config owns backend and opts", %{
      repo: repo
    } do
      event = durable_historian_event(id: "configured-hot-authority")
      Agent.update(repo, &%{&1 | streams: %{"global" => [event]}})

      Application.put_env(:arbor_historian, :durable_event_log_target, %{
        name: :durable_must_not_be_used,
        backend: ErrorDurable,
        opts: []
      })

      Application.put_env(:arbor_historian, :hot_event_log_target, %{
        name: :configured_hot_name,
        backend: ColdDurable,
        opts: [repo: repo]
      })

      assert {:ok, [entry]} =
               Arbor.Historian.recent(
                 event_log: :caller_named_authority,
                 durable_event_log: ErrorDurable,
                 backend: ErrorDurable,
                 opts: [repo: :caller_repo],
                 repo: :caller_repo
               )

      assert entry.signal_id == "configured-hot-authority"
      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert captured[:name] == :caller_named_authority
      assert captured[:repo] == repo
    end

    test "bounded default reads do not fetch the entire durable stream", %{repo: repo} do
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
               QueryEngine.read_global(limit: 1)

      assert length(entries) == 1
      assert hd(entries).signal_id == "hist_bound_1"

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      assert Keyword.get(captured, :limit) == 1
    end

    test "unfiltered max_scan maps to Ecto :limit and fails closed when the page is full", %{
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
               QueryEngine.read_global(max_scan: 2)

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :from) == 0
      assert Keyword.get(captured, :limit) == 3
      refute Keyword.has_key?(captured, :max_scan)

      assert {:ok, entries} =
               QueryEngine.read_global(max_scan: 10)

      assert Enum.map(entries, & &1.signal_id) == [
               "hist_scan_1",
               "hist_scan_2",
               "hist_scan_3"
             ]
    end

    test "max_scan admits a stream whose cardinality exactly equals the bound", %{
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
               QueryEngine.read_global(max_scan: 2)

      assert Enum.map(entries, & &1.signal_id) == [
               "hist_exact_scan_1",
               "hist_exact_scan_2"
             ]

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :limit) == 3
    end

    test "smaller caller :limit is preserved over a larger max_scan", %{repo: repo} do
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
                 limit: 1,
                 max_scan: 100
               )

      assert Enum.map(entries, & &1.signal_id) == ["hist_limit_1"]

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Keyword.get(captured, :limit) == 1
    end

    test "inclusive from reads the authoritative row when a projection row aged out", %{
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
                 from: 5
               )

      assert Enum.map(entries, & &1.signal_id) == ["hist_inclusive_5", "hist_inclusive_6"]
      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert captured[:from] == 5
    end

    test "DateTime filters read durable history then post-filter", %{repo: repo} do
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

    test "DateTime filters map explicit max_scan to durable :limit", %{repo: repo} do
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

    test "filtered limit finds a match on a later durable page", %{repo: repo} do
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

    test "filtered integer from remains inclusive", %{repo: repo} do
      events =
        for n <- 1..3 do
          durable_historian_event(
            id: "hist_filtered_from_#{n}",
            category: if(n == 2, do: :logs, else: :activity),
            event_number: n,
            global_position: n
          )
        end

      Agent.update(repo, &%{&1 | streams: %{"global" => events}})

      assert {:ok, [entry]} =
               QueryEngine.query(
                 category: :logs,
                 from: 2,
                 max_scan: 2
               )

      assert entry.signal_id == "hist_filtered_from_2"
      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert captured[:from] == 2
    end

    test "filtered backward query with a result limit is rejected explicitly", %{repo: repo} do
      assert {:error, {:invalid_query_options, :backward_filtered_scan_unsupported}} =
               QueryEngine.query(category: :logs, direction: :backward, limit: 1)

      assert {:error, {:invalid_query_options, :backward_filtered_scan_unsupported}} =
               QueryEngine.find_by_signal_id("missing", direction: :backward)

      assert Agent.get(repo, & &1.reads) == []
    end

    test "filtered no-match fails when durable scan completeness exceeds the bound", %{
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
                 category: :logs,
                 limit: 1,
                 max_scan: 2
               )

      assert [{"global", captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
      assert captured[:limit] == 3
      refute Keyword.has_key?(captured, :max_scan)
    end

    test "filtered scan admits exact-bound EOF and rejects one row beyond the bound", %{
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
                 category: :logs,
                 max_scan: 2
               )

      Agent.update(repo, &%{&1 | reads: []})

      assert {:error, {:scan_limit_exceeded, %{max_scan: 1}}} =
               QueryEngine.query(
                 category: :logs,
                 max_scan: 1
               )
    end

    test "combined post-filters are applied after durable pagination", %{repo: repo} do
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
                 max_scan: 10,
                 durable_page_size: 1
               )

      assert entry.signal_id == "hist_signal_page_3"
      reads = Agent.get(repo, &Enum.reverse(&1.reads))
      assert Enum.map(reads, fn {"global", opts} -> opts[:from] end) == [0, 2, 3]
    end

    test "signal-id lookup distinguishes EOF from scan exhaustion", %{repo: repo} do
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
                 max_scan: 2
               )

      Agent.update(repo, &%{&1 | reads: []})

      assert {:error, {:scan_limit_exceeded, %{max_scan: 1}}} =
               QueryEngine.find_by_signal_id("hist_signal_bound_2",
                 max_scan: 1
               )
    end

    test "durable is consulted even when projection rows look complete", %{repo: repo} do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      projection = :"qe_complete_projection_#{System.unique_integer([:positive])}"

      start_supervised!(
        {PersistenceETS,
         name: projection, mode: :projection, max_age_ms: :infinity, trim_interval_ms: :disabled}
      )

      projected = durable_historian_event(id: "projection-looks-complete")

      projected = %{
        projected
        | operation_fingerprint: Persistence.canonical_event_fingerprint("global", projected)
      }

      assert {:ok, %{projected: 1}} =
               Persistence.project_committed_events(
                 projection,
                 PersistenceETS,
                 [projected]
               )

      durable = durable_historian_event(id: "durable-wins")
      Agent.update(repo, &%{&1 | streams: %{"global" => [durable]}})

      assert {:ok, entries} = QueryEngine.query([])

      assert length(entries) == 1
      assert hd(entries).signal_id == "durable-wins"
      assert [{"global", _captured}] = Agent.get(repo, &Enum.reverse(&1.reads))
    end

    test "stale projection rows are never returned after durable failures", %{
      ctx: ctx,
      repo: repo
    } do
      TestHelpers.collect_signal(
        ctx,
        TestHelpers.build_signal(id: "stale-projection", category: :logs, type: :error)
      )

      failures = [
        {ErrorDurable, {:authoritative_read_failed, :backend_error}},
        {FlunkDurable, {:authoritative_read_failed, :backend_exception}},
        {MalformedDurable, {:authoritative_read_failed, :malformed_success_reply}},
        {ThrowDurable, {:authoritative_read_failed, :backend_throw}},
        {ExitDurable, {:authoritative_read_failed, :backend_exit}},
        {UnavailableDurable, {:authoritative_read_failed, :backend_exception}}
      ]

      Enum.each(failures, fn {backend, expected_reason} ->
        Application.put_env(:arbor_historian, :durable_event_log_target, %{
          name: :configured_query_authority,
          backend: backend,
          opts: [repo: repo]
        })

        assert {:error, ^expected_reason} =
                 QueryEngine.query([])
      end)
    end

    test "a configured projection-mode EventLog is rejected as authority" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      projection = :"qe_projection_#{System.unique_integer([:positive])}"

      start_supervised!(
        {PersistenceETS,
         name: projection, mode: :projection, max_age_ms: :infinity, trim_interval_ms: :disabled}
      )

      Application.put_env(:arbor_historian, :durable_event_log_target, %{
        name: projection,
        backend: PersistenceETS,
        opts: []
      })

      assert {:error, {:authoritative_target_rejected, :projection}} =
               QueryEngine.read_global([])
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
