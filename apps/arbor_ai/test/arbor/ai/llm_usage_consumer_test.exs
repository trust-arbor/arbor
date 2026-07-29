defmodule Arbor.AI.LLMUsageConsumerTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.BudgetTracker
  alias Arbor.AI.LLMUsageConsumer
  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog.ETS

  @event [:arbor, :llm, :usage]
  @observed_at ~U[2026-07-22 20:00:00Z]
  @stream_id "provider_usage:v1:2026-07-22"

  @moduletag :fast

  defmodule GatedETS do
    @moduledoc false
    @behaviour Arbor.Persistence.EventLog

    @gate_key {__MODULE__, :gate}

    def set_gate(pid), do: :persistent_term.put(@gate_key, pid)
    def clear_gate, do: :persistent_term.erase(@gate_key)

    @impl true
    def append(stream_id, events, opts) do
      case :persistent_term.get(@gate_key, nil) do
        pid when is_pid(pid) ->
          send(pid, {:append_blocked, self()})

          receive do
            :release_append -> :ok
          after
            5_000 -> :ok
          end

        _ ->
          :ok
      end

      ETS.append(stream_id, events, opts)
    end

    @impl true
    def reconcile_append(operation, opts), do: ETS.reconcile_append(operation, opts)

    @impl true
    def read_stream(stream_id, opts), do: ETS.read_stream(stream_id, opts)

    @impl true
    def read_stream_head(stream_id, opts), do: ETS.read_stream_head(stream_id, opts)

    @impl true
    def read_all(opts), do: ETS.read_all(opts)

    @impl true
    def stream_exists?(stream_id, opts), do: ETS.stream_exists?(stream_id, opts)

    @impl true
    def stream_version(stream_id, opts), do: ETS.stream_version(stream_id, opts)

    @impl true
    def subscribe(stream_id, pid, opts), do: ETS.subscribe(stream_id, pid, opts)

    @impl true
    def list_streams(opts), do: ETS.list_streams(opts)

    @impl true
    def stream_count(opts), do: ETS.stream_count(opts)

    @impl true
    def event_count(opts), do: ETS.event_count(opts)

    @impl true
    def read_agent_events(agent_id, opts), do: ETS.read_agent_events(agent_id, opts)
  end

  setup context do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    store_name = :"provider_usage_store_#{:erlang.unique_integer([:positive])}"
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    consumer_name = :"provider_usage_consumer_#{:erlang.unique_integer([:positive])}"

    # Leave the application-supervised LLMUsageConsumer singleton running.
    # Named test consumers attach under distinct handler ids; assert only the
    # named handler's exact presence/count — never stop/kill/detach the app child.

    start_supervised!(
      {ETS, name: store_name, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: store_name
    )

    valid_target = %{name: store_name, backend: ETS, opts: []}
    failing_target = %{name: :missing_provider_usage_backend, backend: ETS, opts: []}

    # ledger_mode:
    #   :valid  — setup starts one consumer with a working ETS target (default)
    #   :failing — setup starts one consumer with a missing-backend target
    #   :none   — no setup consumer; test starts exactly one itself (gated path)
    ledger_mode = Map.get(context, :ledger_mode, :valid)

    target =
      case ledger_mode do
        :failing -> failing_target
        _ -> valid_target
      end

    previous_budget = Application.get_env(:arbor_ai, :enable_budget_tracking, true)
    Application.put_env(:arbor_ai, :enable_budget_tracking, true)

    ensure_started(BudgetTracker)
    BudgetTracker.reset()

    start_setup_consumer? = ledger_mode in [:valid, :failing]

    if start_setup_consumer? do
      start_supervised!(
        {LLMUsageConsumer, name: consumer_name, ledger_target: target},
        id: consumer_name,
        restart: :permanent
      )

      assert_eventually(fn -> handler_count(consumer_name) == 1 end)
      assert_eventually(fn -> handler_id_for(consumer_name) in usage_handler_ids() end)
    else
      assert_eventually(fn -> handler_count(consumer_name) == 0 end)
    end

    on_exit(fn ->
      Application.put_env(:arbor_ai, :enable_budget_tracking, previous_budget)
      BudgetTracker.reset()
      GatedETS.clear_gate()
    end)

    {:ok,
     target: target,
     valid_target: valid_target,
     consumer_name: consumer_name,
     setup_consumer?: start_setup_consumer?,
     ledger_mode: ledger_mode}
  end

  test "valid usage is durably admitted once then projected to BudgetTracker", %{target: target} do
    emit(
      %{
        count: 1,
        input: 1_000_000,
        output: 0,
        total: 1_000_000,
        cached: 0,
        marginal_cost_usd: 1.25
      },
      provider: "openai",
      model: "gpt-4",
      event_id: "usage-integration-1"
    )

    assert_eventually(fn ->
      match?(
        {:ok, %{backends: %{openai: %{requests: 1, cost: 1.25}}}},
        BudgetTracker.get_status()
      )
    end)

    assert_eventually(fn ->
      match?(
        {:ok, [%{id: "usage-integration-1"}]},
        Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)
      )
    end)

    assert {:ok, [event]} =
             Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)

    assert event.data["provider"] == "openai"
    assert event.data["runtime"] == "arbor"
    assert event.data["input_tokens"] == 1_000_000

    assert {:ok, %{snapshot: snapshot}} =
             AI.provider_budget_snapshot(:openai, observed_at: @observed_at)

    assert snapshot["current_spend"] == 1.25
    assert snapshot["request_count"] == 1
  end

  test "unknown provider is durably stored and not projected or atomized", %{target: target} do
    emit(
      %{count: 1, input: 10, output: 2, total: 12, cached: 0},
      provider: "provider-never-interned-usage",
      model: "custom-model",
      event_id: "unknown-provider-ledger-1"
    )

    assert_eventually(fn ->
      match?(
        {:ok, [%{id: "unknown-provider-ledger-1"}]},
        Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)
      )
    end)

    assert {:ok, [event]} =
             Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)

    assert event.data["provider"] == "provider-never-interned-usage"
    assert event.data["model_id"] == "custom-model"

    assert {:ok, status} = BudgetTracker.get_status()
    assert status.backends == %{}
  end

  test "malformed events and invalid costs are ignored", %{target: target} do
    emit(%{count: 1, input: 1, output: 1, total: 2, cached: 0, unexpected: "secret"},
      provider: "openai",
      model: "gpt-4",
      event_id: "malformed-extra-key"
    )

    emit(%{count: 1, input: 1, output: 1, total: 2, cached: 0, marginal_cost_usd: -1.0},
      provider: "openai",
      model: "gpt-4",
      event_id: "malformed-cost"
    )

    emit_non_authoritative(
      %{count: 1, input: 0, output: 0, total: 0, cached: 0},
      provider: "openai",
      model: "gpt-4",
      event_id: "missing-usage",
      usage_status: :missing
    )

    # Rejects are async; require the empty outcome to remain stable across polls.
    assert_stable(fn ->
      {:ok, status} = BudgetTracker.get_status()

      {:ok, events} =
        Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)

      status.backends == %{} and events == []
    end)
  end

  test "disabled BudgetTracker still admits durable events without projection", %{target: target} do
    Application.put_env(:arbor_ai, :enable_budget_tracking, false)

    emit(%{count: 1, input: 10, output: 2, total: 12, cached: 0},
      provider: "openai",
      model: "gpt-4",
      event_id: "tracker-disabled"
    )

    assert_eventually(fn ->
      match?(
        {:ok, [%{id: "tracker-disabled"}]},
        Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)
      )
    end)

    assert {:ok, status} = BudgetTracker.get_status()
    assert status.backends == %{}
  end

  test "duplicate event IDs remain one durable event and one projection", %{target: target} do
    measurements = %{count: 1, input: 100, output: 25, total: 125, cached: 0}
    opts = [provider: "anthropic", model: "claude-sonnet-4", event_id: "duplicate-usage-1"]
    emit(measurements, opts)
    emit(measurements, opts)

    assert_eventually(fn -> BudgetTracker.today_stats().requests == 1 end)

    assert_eventually(fn ->
      match?({:ok, 1}, Persistence.stream_version(target.name, target.backend, @stream_id))
    end)

    assert %{requests: 1, total_tokens: 125} = BudgetTracker.today_stats()
  end

  test "same-event-id restart replay remains one durable entry and one projection", %{
    target: target,
    consumer_name: consumer_name
  } do
    measurements = %{count: 1, input: 4, output: 1, total: 5, cached: 0}
    opts = [provider: "openai", model: "gpt-4", event_id: "restart-dedup-1"]
    emit(measurements, opts)

    assert_eventually(fn -> BudgetTracker.today_stats().requests == 1 end)
    assert_eventually(fn -> handler_count(consumer_name) == 1 end)

    # Permanent supervised child auto-restarts; await new PID (no second start).
    restart_consumer(consumer_name)
    assert_eventually(fn -> handler_count(consumer_name) == 1 end)

    emit(measurements, opts)

    assert_eventually(fn -> BudgetTracker.today_stats().requests == 1 end)

    assert_eventually(fn ->
      match?({:ok, 1}, Persistence.stream_version(target.name, target.backend, @stream_id))
    end)

    assert %{requests: 1, total_tokens: 5} = BudgetTracker.today_stats()
  end

  test "abnormal restart leaves exactly one telemetry handler", %{
    target: target,
    consumer_name: consumer_name
  } do
    assert_eventually(fn -> handler_count(consumer_name) == 1 end)
    restart_consumer(consumer_name)
    assert_eventually(fn -> handler_count(consumer_name) == 1 end)

    # Fresh event id proves a single handler — not masked by BudgetTracker dedupe.
    emit(%{count: 1, input: 2, output: 1, total: 3, cached: 0},
      provider: "openai",
      model: "gpt-4",
      event_id: "one-handler-after-restart"
    )

    assert_eventually(fn -> BudgetTracker.today_stats().requests == 1 end)

    assert_eventually(fn ->
      match?(
        {:ok, [%{id: "one-handler-after-restart"}]},
        Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)
      )
    end)

    assert %{requests: 1, total_tokens: 3} = BudgetTracker.today_stats()
  end

  @tag ledger_mode: :none
  test "gated backend: telemetry returns while admit blocks; projection waits" do
    # ledger_mode: :none — setup started no consumer. Start exactly one gated.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    store_name = :"gated_usage_store_#{:erlang.unique_integer([:positive])}"
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    consumer_name = :"gated_usage_consumer_#{:erlang.unique_integer([:positive])}"

    start_supervised!(
      {ETS, name: store_name, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: store_name
    )

    GatedETS.set_gate(self())
    gated_target = %{name: store_name, backend: GatedETS, opts: []}

    start_supervised!(
      {LLMUsageConsumer, name: consumer_name, ledger_target: gated_target},
      id: consumer_name,
      restart: :permanent
    )

    assert_eventually(fn -> handler_count(consumer_name) == 1 end)
    assert handler_id_for(consumer_name) in usage_handler_ids()

    BudgetTracker.reset()

    task =
      Task.async(fn ->
        emit(%{count: 1, input: 8, output: 1, total: 9, cached: 0},
          provider: "openai",
          model: "gpt-4",
          event_id: "gated-ordering-1"
        )

        :telemetry_returned
      end)

    assert :telemetry_returned = Task.await(task, 500)
    assert_receive {:append_blocked, blocked_pid}, 1_000

    # Admit is in-flight on the sole consumer; BudgetTracker must still be empty.
    assert {:ok, status} = BudgetTracker.get_status()
    assert status.backends == %{}

    send(blocked_pid, :release_append)

    assert_eventually(fn -> BudgetTracker.today_stats().requests == 1 end)

    assert_eventually(fn ->
      match?(
        {:ok, [%{id: "gated-ordering-1"}]},
        Persistence.read_stream(store_name, ETS, @stream_id, from: 1, limit: 10)
      )
    end)

    assert %{requests: 1, total_tokens: 9} = BudgetTracker.today_stats()
  end

  # Single consumer with a failing target selected in setup — never a valid
  # setup consumer plus a second failing one (both would receive telemetry).
  @tag ledger_mode: :failing
  test "ledger failure yields zero BudgetTracker projection", %{
    consumer_name: consumer_name
  } do
    assert handler_count(consumer_name) == 1
    assert handler_id_for(consumer_name) in usage_handler_ids()
    BudgetTracker.reset()

    emit(%{count: 1, input: 9, output: 1, total: 10, cached: 0},
      provider: "openai",
      model: "gpt-4",
      event_id: "ledger-fail-1"
    )

    # Drain the named consumer mailbox so the failed admit has run before
    # sampling BudgetTracker for the zero-projection stability window.
    _ = :sys.get_state(consumer_name)

    # Failed admit is async; require zero projection to remain stable.
    assert_stable(fn ->
      match?({:ok, %{backends: %{}}}, BudgetTracker.get_status())
    end)
  end

  @tag ledger_mode: :none
  test "invalid explicit ledger_target fails start" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, :invalid_provider_usage_ledger_target} =
               LLMUsageConsumer.start_link(
                 name: :"bad_target_#{:erlang.unique_integer([:positive])}",
                 ledger_target: %{name: "not-an-atom", backend: ETS}
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  test "existing callers without event IDs continue to count" do
    BudgetTracker.record_usage(:ollama, %{model: "llama", input_tokens: 2, output_tokens: 1})
    BudgetTracker.record_usage(:ollama, %{model: "llama", input_tokens: 3, output_tokens: 4})

    assert_eventually(fn -> BudgetTracker.today_stats().requests == 2 end)
    assert %{requests: 2, total_tokens: 10} = BudgetTracker.today_stats()
  end

  test "authoritative cost wins over the configured token estimate" do
    emit(
      %{
        count: 1,
        input: 1_000_000,
        output: 0,
        total: 1_000_000,
        cached: 0,
        marginal_cost_usd: 0.25
      },
      provider: "anthropic",
      model: "claude-opus-4",
      event_id: "authoritative-cost"
    )

    assert_eventually(fn -> BudgetTracker.backend_spend(:anthropic) == 0.25 end)
  end

  defp emit(measurements, opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)
    operation = Keyword.get(opts, :operation, :complete)

    event = %{
      "version" => 1,
      "event_id" => event_id,
      "provider" => provider,
      "source" => "req_llm",
      "runtime" => "arbor",
      "model_id" => model,
      "operation" => Atom.to_string(operation),
      "occurred_at" => DateTime.to_iso8601(@observed_at),
      "input_tokens" => measurements.input,
      "output_tokens" => measurements.output,
      "total_tokens" => measurements.total,
      "cached_tokens" => measurements.cached
    }

    event =
      case Map.fetch(measurements, :marginal_cost_usd) do
        {:ok, cost} -> Map.put(event, "marginal_api_cost_usd", cost)
        :error -> event
      end

    metadata = %{
      event_id: event_id,
      source: :req_llm,
      operation: operation,
      provider: provider,
      model: model,
      usage_status: :authoritative,
      event: event
    }

    :telemetry.execute(@event, measurements, metadata)
  end

  defp emit_non_authoritative(measurements, opts) do
    metadata = %{
      event_id: Keyword.fetch!(opts, :event_id),
      source: :req_llm,
      operation: :complete,
      provider: Keyword.fetch!(opts, :provider),
      model: Keyword.fetch!(opts, :model),
      usage_status: Keyword.fetch!(opts, :usage_status)
    }

    :telemetry.execute(@event, measurements, metadata)
  end

  # Permanent start_supervised child auto-restarts with the original child
  # spec after kill. Await the new PID; never start_link/start_supervised again
  # (races with already_started).
  defp restart_consumer(consumer_name) do
    old_pid = Process.whereis(consumer_name)
    assert is_pid(old_pid), "expected setup consumer #{inspect(consumer_name)} to be running"

    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, _} -> :ok
    after
      2_000 -> flunk("consumer #{inspect(consumer_name)} did not exit after kill")
    end

    new_pid =
      assert_eventually(fn ->
        case Process.whereis(consumer_name) do
          pid when is_pid(pid) and pid != old_pid -> pid
          _ -> false
        end
      end)

    assert is_pid(new_pid)
    assert_eventually(fn -> handler_count(consumer_name) == 1 end)
    new_pid
  end

  # Mirrors production: singleton name == module uses bare-module handler id;
  # explicitly named instances use {module, name}.
  defp handler_id_for(name) when name == LLMUsageConsumer, do: LLMUsageConsumer
  defp handler_id_for(name), do: {LLMUsageConsumer, name}

  defp handler_count(consumer_name) do
    handler_id = handler_id_for(consumer_name)

    usage_handler_ids()
    |> Enum.count(&(&1 == handler_id))
  end

  defp usage_handler_ids do
    @event
    |> :telemetry.list_handlers()
    |> Enum.map(& &1.id)
    |> Enum.filter(fn
      {LLMUsageConsumer, _name} -> true
      LLMUsageConsumer -> true
      _ -> false
    end)
    |> Enum.sort()
  end

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil ->
        {:ok, _pid} = module.start_link([])

      _pid ->
        :ok
    end
  end

  # Poll until fun returns a truthy value (true, pid, etc.). false/nil/raise retry.
  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, 0) do
    last =
      try do
        fun.()
      rescue
        e -> {:raised, e}
      catch
        k, r -> {:thrown, {k, r}}
      end

    flunk("condition not met eventually; last=#{inspect(last)}")
  end

  defp assert_eventually(fun, attempts) when attempts > 0 do
    result =
      try do
        fun.()
      rescue
        _ -> :retry
      catch
        _, _ -> :retry
      end

    case result do
      :retry ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)

      false ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)

      nil ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)

      other ->
        other
    end
  end

  # Require fun to return truthy on several consecutive polls (stable empty/failure).
  defp assert_stable(fun, needed \\ 3, attempts \\ 100)

  defp assert_stable(_fun, _needed, 0), do: flunk("condition did not remain stable")

  defp assert_stable(fun, needed, attempts) do
    do_stable(fun, needed, needed, attempts)
  end

  defp do_stable(_fun, _needed, _left, 0), do: flunk("condition did not remain stable")

  defp do_stable(fun, needed, left, attempts) do
    ok? =
      try do
        !!fun.()
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    cond do
      ok? and left <= 1 ->
        true

      ok? ->
        Process.sleep(10)
        do_stable(fun, needed, left - 1, attempts - 1)

      true ->
        Process.sleep(10)
        do_stable(fun, needed, needed, attempts - 1)
    end
  end
end
