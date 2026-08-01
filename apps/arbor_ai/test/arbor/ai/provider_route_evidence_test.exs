defmodule Arbor.AI.ProviderRouteEvidenceTest.FailBackend do
  @moduledoc false
  def durability_class(_opts), do: :node_restart
  def append(_stream, _events, _opts), do: {:error, :backend_down}
  def reconcile_append(_operation, _opts), do: {:error, :backend_down}
  def stream_version(_stream, _opts), do: {:ok, 0}
  def read_stream(_stream, _opts), do: {:ok, []}
end

defmodule Arbor.AI.ProviderRouteEvidenceTest.ReplayFailureBackend do
  @moduledoc false
  alias Arbor.Persistence.EventLog.ETS

  def durability_class(_opts), do: :node_restart

  def append(stream, events, opts) do
    Agent.update(Keyword.fetch!(opts, :replay_agent), fn _ -> :appended end)
    ETS.append(stream, events, opts)
  end

  def reconcile_append(operation, opts), do: ETS.reconcile_append(operation, opts)
  def stream_version(stream, opts), do: ETS.stream_version(stream, opts)

  def read_stream(stream, opts) do
    if Agent.get(Keyword.fetch!(opts, :replay_agent), &(&1 == :appended)),
      do: {:error, :replay_failed},
      else: ETS.read_stream(stream, opts)
  end
end

defmodule Arbor.AI.ProviderRouteEvidenceTest.SlowReplayBackend do
  @moduledoc false
  alias Arbor.Persistence.EventLog.ETS

  def durability_class(_opts), do: :node_restart
  def append(stream, events, opts), do: ETS.append(stream, events, opts)
  def reconcile_append(operation, opts), do: ETS.reconcile_append(operation, opts)

  def stream_version(stream, opts) do
    gate = Keyword.fetch!(opts, :replay_gate)

    if Agent.get_and_update(gate, fn
         :blocked -> {true, :released}
         state -> {false, state}
       end) do
      send(
        Keyword.fetch!(opts, :replay_parent),
        {:provider_route_evidence_replay_started, self()}
      )

      receive do
        :release_provider_route_evidence_replay -> :ok
      end
    end

    ETS.stream_version(stream, opts)
  end

  def read_stream(stream, opts), do: ETS.read_stream(stream, opts)
end

defmodule Arbor.AI.ProviderRouteEvidenceTest.WeakBackend do
  @moduledoc false
  def durability_class(_opts), do: :process_lifetime
  def append(_stream, _events, _opts), do: {:ok, []}
  def reconcile_append(_operation, _opts), do: {:ok, :absent}
  def stream_version(_stream, _opts), do: {:ok, 0}
  def read_stream(_stream, _opts), do: {:ok, []}
end

defmodule Arbor.AI.ProviderRouteEvidenceTest.OverflowBackend do
  @moduledoc false
  def durability_class(_opts), do: :node_restart
  def append(_stream, _events, _opts), do: {:ok, []}
  def reconcile_append(_operation, _opts), do: {:ok, :absent}
  def stream_version(_stream, _opts), do: {:ok, 513}
  def read_stream(_stream, _opts), do: {:ok, []}
end

defmodule Arbor.AI.ProviderRouteEvidenceTest.DurableETS do
  @moduledoc false
  alias Arbor.Persistence.EventLog.ETS
  def durability_class(_opts), do: :node_restart
  def append(stream, events, opts), do: ETS.append(stream, events, opts)
  def reconcile_append(operation, opts), do: ETS.reconcile_append(operation, opts)
  def stream_version(stream, opts), do: ETS.stream_version(stream, opts)
  def read_stream(stream, opts), do: ETS.read_stream(stream, opts)
end

defmodule Arbor.AI.ProviderRouteEvidenceTest.ConcurrentETS do
  @moduledoc false
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  def durability_class(_opts), do: :node_restart
  def append(stream, events, opts), do: ETS.append(stream, events, opts)
  def reconcile_append(operation, opts), do: ETS.reconcile_append(operation, opts)
  def stream_version(stream, opts), do: ETS.stream_version(stream, opts)

  def read_stream(stream, opts) do
    race_agent = Keyword.get(opts, :race_agent)

    if is_pid(race_agent) and
         Agent.get_and_update(race_agent, fn
           :armed -> {true, :done}
           value -> {false, value}
         end) do
      now = DateTime.add(DateTime.utc_now(), -1, :second)

      data = %{
        "route" => "openai_oauth",
        "observed_at" => DateTime.to_iso8601(now),
        "available_at" => DateTime.to_iso8601(DateTime.add(now, 60, :second))
      }

      external =
        Event.new(
          stream,
          "arbor.provider_route_quota.v1",
          data,
          id:
            elem(
              Arbor.AI.ProviderRouteEvidenceCore.event_id(
                stream,
                "arbor.provider_route_quota.v1",
                data
              ),
              1
            ),
          timestamp: now,
          metadata: %{"schema_version" => 1}
        )

      _ = ETS.append(stream, external, opts)
    end

    {:ok, events} = ETS.read_stream(stream, opts)
    {:ok, events}
  end
end

defmodule Arbor.AI.ProviderRouteEvidenceTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.ProviderRouteEvidence
  alias Arbor.AI.ProviderRouteEvidenceCore
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @now ~U[2026-07-31 12:00:00Z]

  setup do
    stop_authority()

    on_exit(fn ->
      stop_authority()
    end)

    :ok
  end

  defp stop_authority do
    case Process.whereis(ProviderRouteEvidence) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp start_ets(name) do
    {:ok, pid} = ETS.start_link(name: name, max_age_ms: :infinity, trim_interval_ms: :disabled)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    name
  end

  defp await_ready!(attempts \\ 100)

  defp await_ready!(attempts) when attempts <= 0, do: flunk("authority did not become ready")

  defp await_ready!(attempts) do
    case ProviderRouteEvidence.status() do
      %{status: :ready} ->
        :ok

      %{status: :replaying} ->
        Process.sleep(1)
        await_ready!(attempts - 1)

      status ->
        flunk("authority unavailable: #{inspect(status)}")
    end
  end

  defp await_status!(predicate, attempts \\ 100)

  defp await_status!(_predicate, attempts) when attempts <= 0,
    do: flunk("authority did not reach the expected status")

  defp await_status!(predicate, attempts) do
    status = ProviderRouteEvidence.status()

    if predicate.(status) do
      status
    else
      Process.sleep(1)
      await_status!(predicate, attempts - 1)
    end
  end

  defp failure(route, class, observed_at, expires_at) do
    code =
      %{
        "auth" => "unauthorized",
        "tier_denied" => "xai_oauth_tier_denied",
        "outage" => "server_error",
        "protocol" => "invalid_stream",
        "transport" => "connection_failed"
      }[class]

    %{
      "route" => route,
      "class" => class,
      "code" => code,
      "retryable" => true,
      "observed_at" => DateTime.to_iso8601(observed_at),
      "expires_at" => DateTime.to_iso8601(expires_at)
    }
  end

  defp event(number, type, data, stream \\ "provider_route_evidence:v1:2026-07-31") do
    %{
      "id" => "evt-#{number}-#{type}",
      "stream_id" => stream,
      "event_number" => number,
      "type" => type,
      "data" => data,
      "metadata" => %{"schema_version" => 1}
    }
  end

  test "core merge is arrival-order independent and expires evidence" do
    old = failure("openai_oauth", "transport", @now, DateTime.add(@now, 100, :second))

    severe = failure("openai_oauth", "auth", @now, DateTime.add(@now, 90, :second))

    reduce = fn events ->
      Enum.reduce(events, {:ok, ProviderRouteEvidenceCore.new()}, fn item, {:ok, state} ->
        ProviderRouteEvidenceCore.reduce(state, item, @now)
      end)
    end

    assert {:ok, first} =
             reduce.([
               event(1, "arbor.provider_route_failure.v1", old),
               event(2, "arbor.provider_route_failure.v1", severe)
             ])

    assert {:ok, second} =
             reduce.([
               event(1, "arbor.provider_route_failure.v1", severe),
               event(2, "arbor.provider_route_failure.v1", old)
             ])

    assert first == second

    assert {:ok, %{failures: %{}}} =
             ProviderRouteEvidenceCore.snapshot(first, DateTime.add(@now, 200, :second))
  end

  test "core rejects malformed replay data" do
    state = ProviderRouteEvidenceCore.new()

    assert {:error, :malformed} =
             ProviderRouteEvidenceCore.reduce(state, event(1, "unknown", %{}), @now)

    assert {:error, :malformed} =
             ProviderRouteEvidenceCore.reduce(
               state,
               event(1, "arbor.provider_route_failure.v1", %{"route" => "openai_oauth"}),
               @now
             )

    assert {:error, :malformed} =
             ProviderRouteEvidenceCore.reduce(
               state,
               event(1, "arbor.provider_route_quota.v1", %{
                 "route" => "openai_oauth",
                 "observed_at" => DateTime.to_iso8601(@now),
                 "available_at" => DateTime.to_iso8601(DateTime.add(@now, 60, :second)),
                 "unexpected" => "not persisted"
               }),
               @now
             )

    assert {:error, :malformed} =
             ProviderRouteEvidenceCore.reduce(
               state,
               event(
                 1,
                 "arbor.provider_route_failure.v1",
                 failure(
                   "openai_oauth",
                   "transport",
                   DateTime.add(@now, 60, :second),
                   DateTime.add(@now, 120, :second)
                 )
               ),
               @now
             )

    assert {:error, :malformed} =
             ProviderRouteEvidenceCore.prepare_quota(
               %{route: :openai_oauth, available_at: DateTime.add(@now, 2, :day)},
               @now
             )
  end

  test "security regression: malformed options cannot crash the authority" do
    name = :provider_route_evidence_invalid_options_log
    start_ets(name)
    target = %{name: name, backend: __MODULE__.DurableETS, opts: []}
    {:ok, pid} = ProviderRouteEvidence.start_link(target: target)
    await_ready!()

    attrs = %{
      route: :openai_oauth,
      available_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    for opts <- [
          [append_timeout_ms: 0],
          [{"append_timeout_ms", 1_000}],
          [append_timeout_ms: 1_000, append_timeout_ms: 2_000],
          [{:append_timeout_ms, 1_000} | :improper]
        ] do
      assert {:error, :invalid_options} = ProviderRouteEvidence.record_quota(attrs, opts)
    end

    for opts <- [
          [{"now", @now}],
          [now: @now, now: DateTime.add(@now, 1, :second)],
          [now: struct(DateTime)],
          [{:now, @now} | :improper]
        ] do
      assert {:error, :invalid_options} = ProviderRouteEvidence.snapshot_status(opts)
    end

    assert Process.alive?(pid)
    assert %{available: true, status: :ready} = ProviderRouteEvidence.status()
    assert {:ok, _} = ProviderRouteEvidence.record_quota(attrs)
    GenServer.stop(pid)
  end

  test "replay rejects a persisted event with a mismatched deterministic ID" do
    name = :provider_route_evidence_bad_identity_log
    start_ets(name)
    now = DateTime.add(DateTime.utc_now(), -1, :second)
    stream = "provider_route_evidence:v1:" <> Date.to_iso8601(DateTime.to_date(now))
    type = "arbor.provider_route_quota.v1"

    data = %{
      "route" => "openai_oauth",
      "observed_at" => DateTime.to_iso8601(now),
      "available_at" => DateTime.to_iso8601(DateTime.add(now, 60, :second))
    }

    event =
      Event.new(stream, type, data,
        id: "evt_provider_route_corrupt",
        timestamp: now,
        metadata: %{"schema_version" => 1}
      )

    assert {:ok, [_persisted]} = ETS.append(stream, event, name: name)

    {:ok, pid} =
      ProviderRouteEvidence.start_link(
        target: %{name: name, backend: __MODULE__.DurableETS, opts: []}
      )

    assert %{available: false, status: :malformed, reason: :malformed} =
             await_status!(&(&1.status == :malformed))

    assert {:error, :unavailable} = ProviderRouteEvidence.snapshot_status()
    GenServer.stop(pid)
  end

  test "weak backend cannot be elevated by caller durability hints" do
    target = %{
      name: :weak_route_evidence,
      backend: __MODULE__.WeakBackend,
      opts: [durability_class: :node_restart]
    }

    {:ok, pid} = ProviderRouteEvidence.start_link(target: target)

    assert %{available: false, status: :unavailable, reason: :target_not_node_restart} =
             ProviderRouteEvidence.status()

    assert {:error, :provider_route_evidence_unavailable} =
             ProviderRouteEvidence.record_quota(%{
               route: :openai_oauth,
               available_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    GenServer.stop(pid)
  end

  test "append failure is durable-first and does not expose state" do
    target = %{name: :failed_route_evidence, backend: __MODULE__.FailBackend, opts: []}
    {:ok, pid} = ProviderRouteEvidence.start_link(target: target)
    await_ready!()
    assert %{available: true, status: :ready} = ProviderRouteEvidence.status()

    assert {:error, {:provider_route_evidence_write_failed, :backend_down}} =
             ProviderRouteEvidence.record_quota(%{
               route: :openai_oauth,
               available_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert {:ok, %{"route_failures" => failures, "quota_status" => quotas}} =
             ProviderRouteEvidence.snapshot_status(now: @now)

    assert failures == %{}
    assert quotas == %{}
    GenServer.stop(pid)
  end

  test "post-commit replay failure blocks authority and hides the stale projection" do
    name = :provider_route_evidence_replay_failure_log
    start_ets(name)
    {:ok, replay_agent} = Agent.start_link(fn -> :ready end)

    target = %{
      name: name,
      backend: __MODULE__.ReplayFailureBackend,
      opts: [replay_agent: replay_agent]
    }

    {:ok, pid} = ProviderRouteEvidence.start_link(target: target)
    await_ready!()

    assert {:error, {:provider_route_evidence_replay_failed, :replay_failed}} =
             ProviderRouteEvidence.record_quota(%{
               route: :openai_oauth,
               available_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert %{
             available: false,
             status: :unavailable,
             reason: {:provider_route_evidence_replay_failed, :replay_failed}
           } =
             ProviderRouteEvidence.status()

    assert {:error, :unavailable} = ProviderRouteEvidence.snapshot_status(now: @now)
    GenServer.stop(pid)
    Agent.stop(replay_agent)
  end

  test "startup returns while replay is blocked and admits the late result" do
    name = :provider_route_evidence_slow_replay_log
    start_ets(name)
    {:ok, replay_gate} = Agent.start_link(fn -> :blocked end)

    target = %{
      name: name,
      backend: __MODULE__.SlowReplayBackend,
      opts: [replay_gate: replay_gate, replay_parent: self()]
    }

    started_at = System.monotonic_time()
    {:ok, _pid} = ProviderRouteEvidence.start_link(target: target)
    elapsed = System.monotonic_time() - started_at

    assert elapsed < System.convert_time_unit(100, :millisecond, :native)
    assert_receive {:provider_route_evidence_replay_started, replay_pid}, 1_000
    on_exit(fn -> send(replay_pid, :release_provider_route_evidence_replay) end)
    assert %{available: false, status: :replaying} = ProviderRouteEvidence.status()

    assert {:error, :provider_route_evidence_unavailable} =
             ProviderRouteEvidence.record_quota(%{})

    assert {:error, :unavailable} = ProviderRouteEvidence.snapshot_status(now: @now)

    send(replay_pid, :release_provider_route_evidence_replay)
    await_ready!()
    assert %{available: true, status: :ready} = ProviderRouteEvidence.status()

    assert {:ok, %{"route_failures" => %{}, "quota_status" => %{}}} =
             ProviderRouteEvidence.snapshot_status(now: @now)

    Agent.stop(replay_gate)
  end

  test "daily stream overflow blocks replay rather than reading past the bound" do
    {:ok, pid} =
      ProviderRouteEvidence.start_link(
        target: %{
          name: :provider_route_evidence_overflow,
          backend: __MODULE__.OverflowBackend,
          opts: []
        }
      )

    assert %{available: false, status: :incomplete, reason: :replay_incomplete} =
             await_status!(&(&1.status == :incomplete))

    assert {:error, :unavailable} = ProviderRouteEvidence.snapshot_status(now: @now)
    GenServer.stop(pid)
  end

  test "node-restart EventLog replay restores accepted evidence" do
    name = :provider_route_evidence_restart_log
    start_ets(name)
    target = %{name: name, backend: __MODULE__.DurableETS, opts: []}
    {:ok, pid} = ProviderRouteEvidence.start_link(target: target)
    await_ready!()

    assert {:ok, _} =
             ProviderRouteEvidence.record_quota(%{
               route: :xai_oauth,
               available_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    GenServer.stop(pid)
    {:ok, _pid2} = ProviderRouteEvidence.start_link(target: target)
    await_ready!()

    assert {:ok, %{"quota_status" => %{"xai_oauth" => %{"available" => false}}}} =
             ProviderRouteEvidence.snapshot_status(now: @now)
  end

  test "captured-head replay reconciles a concurrent external append" do
    name = :provider_route_evidence_race_log
    start_ets(name)
    {:ok, race_agent} = Agent.start_link(fn -> :disabled end)
    target = %{name: name, backend: __MODULE__.ConcurrentETS, opts: [race_agent: race_agent]}
    {:ok, pid} = ProviderRouteEvidence.start_link(target: target)
    await_ready!()
    Agent.update(race_agent, fn _ -> :armed end)

    assert {:ok, _} =
             ProviderRouteEvidence.record_quota(%{
               route: :xai_oauth,
               available_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert {:ok, %{"quota_status" => quotas}} = ProviderRouteEvidence.snapshot_status()
    assert Map.has_key?(quotas, "openai_oauth")
    assert Map.has_key?(quotas, "xai_oauth")
    GenServer.stop(pid)
    Agent.stop(race_agent)
  end

  test "failure projection retains a long lower-severity candidate after severe expiry" do
    severe = failure("openai_oauth", "auth", @now, DateTime.add(@now, 5, :second))
    lower = failure("openai_oauth", "transport", @now, DateTime.add(@now, 60, :second))

    reduce = fn events ->
      Enum.reduce(events, {:ok, ProviderRouteEvidenceCore.new()}, fn item, {:ok, state} ->
        ProviderRouteEvidenceCore.reduce(state, item, @now)
      end)
    end

    assert {:ok, first} =
             reduce.([
               event(1, "arbor.provider_route_failure.v1", severe),
               event(2, "arbor.provider_route_failure.v1", lower)
             ])

    assert {:ok, second} =
             reduce.([
               event(1, "arbor.provider_route_failure.v1", lower),
               event(2, "arbor.provider_route_failure.v1", severe)
             ])

    assert first == second

    assert {:ok, %{failures: %{"openai_oauth" => active}}} =
             ProviderRouteEvidenceCore.snapshot(first, DateTime.add(@now, 10, :second))

    assert active["class"] == "transport"
  end

  test "prepared failures reject future observations and invalid class-code pairs" do
    assert {:error, :malformed} =
             ProviderRouteEvidenceCore.prepare_failure(
               %{
                 route: :openai_oauth,
                 class: :auth,
                 code: :unauthorized,
                 retryable: true,
                 observed_at: DateTime.add(@now, 60, :second),
                 retry_after_ms: 120_000
               },
               @now
             )

    assert {:error, :malformed} =
             ProviderRouteEvidenceCore.prepare_failure(
               %{route: :openai_oauth, class: :auth, code: :server_error, retryable: true},
               @now
             )

    assert {:ok, prepared} =
             ProviderRouteEvidenceCore.prepare_failure(
               %{
                 route: :openai_oauth,
                 class: :transport,
                 code: :connection_failed,
                 retryable: true,
                 retry_after_ms: 0
               },
               @now
             )

    assert String.ends_with?(prepared["observed_at"], "Z")
    assert DateTime.compare(DateTime.from_iso8601(prepared["expires_at"]) |> elem(1), @now) == :gt
  end
end
