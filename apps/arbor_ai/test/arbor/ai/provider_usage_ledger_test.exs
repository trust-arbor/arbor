defmodule Arbor.AI.ProviderUsageLedgerTest.IndeterminateBackend do
  @moduledoc false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog

  def append(stream_id, events, opts) do
    agent = Keyword.fetch!(opts, :agent)
    events = List.wrap(events)
    {:ok, operation} = EventLog.build_operation(stream_id, events)

    Agent.get_and_update(agent, fn state ->
      append_calls = Map.get(state, :append_calls, 0) + 1
      state = Map.put(state, :append_calls, append_calls)

      case {state.mode, append_calls} do
        {:indeterminate_commit, 1} ->
          stored = store_events(state, stream_id, events)
          {{:error, {:append_indeterminate, operation}}, stored}

        {:indeterminate_absent, 1} ->
          {{:error, {:append_indeterminate, operation}}, state}

        {:indeterminate_absent, 2} ->
          stored = store_events(state, stream_id, events)
          committed = Map.fetch!(stored.events, stream_id)
          {{:ok, committed}, stored}

        {:still_unknown, 1} ->
          {{:error, {:append_indeterminate, operation}}, state}

        _other ->
          {{:error, :unexpected_append}, state}
      end
    end)
  end

  def reconcile_append(operation, opts) do
    agent = Keyword.fetch!(opts, :agent)

    Agent.get_and_update(agent, fn state ->
      reconcile_calls = Map.get(state, :reconcile_calls, 0) + 1
      state = Map.put(state, :reconcile_calls, reconcile_calls)

      result =
        case state.mode do
          :indeterminate_commit ->
            events = Map.get(state.events, operation.stream_id, [])
            found = Enum.filter(events, &(&1.id in operation.event_ids))
            {:ok, {:committed, found}}

          :indeterminate_absent ->
            {:ok, :absent}

          :still_unknown ->
            {:error, {:append_indeterminate, operation}}
        end

      {result, state}
    end)
  end

  def read_stream(stream_id, opts) do
    agent = Keyword.fetch!(opts, :agent)
    from = Keyword.get(opts, :from, 1)
    limit = Keyword.get(opts, :limit)

    events =
      agent
      |> Agent.get(&Map.get(&1.events, stream_id, []))
      |> Enum.filter(&(&1.event_number >= from))
      |> then(fn list -> if limit, do: Enum.take(list, limit), else: list end)

    {:ok, events}
  end

  defp store_events(state, stream_id, events) do
    existing = Map.get(state.events, stream_id, [])
    start = length(existing)

    persisted =
      events
      |> Enum.with_index(1)
      |> Enum.map(fn {%Event{} = event, index} ->
        %Event{
          event
          | stream_id: stream_id,
            event_number: start + index,
            global_position: start + index
        }
      end)

    %{state | events: Map.put(state.events, stream_id, existing ++ persisted)}
  end
end

defmodule Arbor.AI.ProviderUsageLedgerTest.ScriptedReadBackend do
  @moduledoc false

  def read_stream(_stream_id, opts) do
    Keyword.fetch!(opts, :reply)
  end
end

defmodule Arbor.AI.ProviderUsageLedgerTest.ScriptedAppendBackend do
  @moduledoc false

  def append(_stream_id, _events, opts) do
    Keyword.fetch!(opts, :reply)
  end

  def read_stream(_stream_id, _opts), do: {:ok, []}
end

defmodule Arbor.AI.ProviderUsageLedgerTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.Config
  alias Arbor.AI.ProviderUsageLedgerTest.IndeterminateBackend
  alias Arbor.AI.ProviderUsageLedgerTest.ScriptedAppendBackend
  alias Arbor.AI.ProviderUsageLedgerTest.ScriptedReadBackend
  alias Arbor.Contracts.Persistence.AppendOperation
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @moduletag :fast

  @day ~D[2026-07-22]
  @stream_id "provider_usage:v1:2026-07-22"

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"provider_usage_ledger_#{:erlang.unique_integer([:positive])}"

    start_supervised!(
      {ETS, name: name, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: name
    )

    target = %{name: name, backend: ETS, opts: []}
    {:ok, name: name, target: target}
  end

  test "records a canonical daily event through the AI facade", %{target: target} do
    attrs = usage_attrs("usage-facade-1")

    assert {:ok, receipt} = AI.record_provider_usage(attrs, target: target)
    assert receipt["event_id"] == "usage-facade-1"
    assert receipt["stream_id"] == @stream_id
    assert receipt["event_number"] == 1
    assert receipt["type"] == "arbor.provider_usage.v1"

    assert {:ok, [event]} =
             Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)

    assert event.id == "usage-facade-1"
    assert event.type == "arbor.provider_usage.v1"
    assert event.agent_id == "agent_abc"
    assert event.correlation_id == "corr-1"

    assert event.metadata == %{
             "schema_version" => 1,
             "provider_usage_digest" => event.metadata["provider_usage_digest"]
           }

    assert map_size(event.metadata) == 2
    assert is_binary(event.metadata["provider_usage_digest"])
    assert event.data["provider"] == "openai"
    assert event.data["input_tokens"] == 100
    assert event.data["total_tokens"] == 150
  end

  test "exact duplicate submission is idempotent and changed content conflicts", %{
    target: target
  } do
    attrs = usage_attrs("usage-dup-1")

    assert {:ok, first} = AI.record_provider_usage(attrs, target: target)
    assert {:ok, second} = AI.record_provider_usage(attrs, target: target)
    assert second == first

    assert {:ok, [only]} =
             Persistence.read_stream(target.name, target.backend, @stream_id, from: 1, limit: 10)

    assert only.event_number == 1

    # Contract-valid changed payload: raise tokens while keeping total consistent.
    changed =
      attrs
      |> Map.put(:input_tokens, 999)
      |> Map.put(:total_tokens, 1049)

    assert {:error, :event_identity_conflict} =
             AI.record_provider_usage(changed, target: target)

    assert {:ok, 1} = Persistence.stream_version(target.name, target.backend, @stream_id)
  end

  test "concurrent exact submissions collapse to one stream event", %{target: target} do
    attrs = usage_attrs("usage-concurrent-1")

    results =
      1..8
      |> Task.async_stream(
        fn _ -> AI.record_provider_usage(attrs, target: target) end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{"event_id" => "usage-concurrent-1"}}, &1))
    assert {:ok, 1} = Persistence.stream_version(target.name, target.backend, @stream_id)
  end

  test "daily projection aggregates tokens, known costs, and unknown counters", %{
    target: target
  } do
    known = usage_attrs("usage-daily-1", marginal_api_cost_usd: 0.02, subscription_usage_units: 3)

    unknown =
      usage_attrs("usage-daily-2",
        provider: "anthropic",
        occurred_at: "2026-07-22T23:30:00Z"
      )
      |> Map.delete(:marginal_api_cost_usd)
      |> Map.delete(:subscription_usage_units)

    assert {:ok, _} = AI.record_provider_usage(known, target: target)
    assert {:ok, _} = AI.record_provider_usage(unknown, target: target)

    assert {:ok, aggregate} =
             AI.provider_usage_daily(@day, target: target, page_size: 1, max_events: 10)

    assert aggregate["version"] == 1
    assert aggregate["date"] == "2026-07-22"
    assert aggregate["stream_id"] == @stream_id
    assert aggregate["event_count"] == 2
    assert aggregate["input_tokens"] == 200
    assert aggregate["output_tokens"] == 100
    assert aggregate["total_tokens"] == 300
    assert aggregate["cached_tokens"] == 20
    assert aggregate["marginal_api_cost_usd"] == 0.02
    assert aggregate["marginal_api_cost_unknown_events"] == 1
    assert aggregate["subscription_usage_units"] == 3
    assert aggregate["subscription_usage_unknown_events"] == 1
    assert aggregate["providers"]["openai"]["event_count"] == 1
    assert aggregate["providers"]["anthropic"]["event_count"] == 1
    assert aggregate["providers"]["anthropic"]["marginal_api_cost_unknown_events"] == 1
    assert {:ok, _} = Jason.encode(aggregate)
  end

  test "restart-style re-projection matches the first daily aggregate", %{target: target} do
    assert {:ok, _} = AI.record_provider_usage(usage_attrs("usage-restart-1"), target: target)
    assert {:ok, _} = AI.record_provider_usage(usage_attrs("usage-restart-2"), target: target)

    assert {:ok, first} = AI.provider_usage_daily(@day, target: target)
    assert {:ok, second} = AI.provider_usage_daily(@day, target: target)
    assert second == first
  end

  test "projection rejects malformed stream entries with typed errors", %{target: target} do
    bad =
      Event.new(@stream_id, "arbor.provider_usage.v1", %{"not" => "valid"},
        id: "usage-bad-1",
        timestamp: ~U[2026-07-22 12:00:00Z],
        metadata: %{"schema_version" => 1, "provider_usage_digest" => "sha256:nope"}
      )

    assert {:ok, [_]} = Persistence.append(target.name, target.backend, @stream_id, bad)

    assert {:error, {:malformed_provider_usage_data, _}} =
             AI.provider_usage_daily(@day, target: target)
  end

  test "projection enforces configured event and provider bounds", %{target: target} do
    assert {:ok, _} = AI.record_provider_usage(usage_attrs("usage-bound-1"), target: target)

    assert {:ok, _} =
             AI.record_provider_usage(
               usage_attrs("usage-bound-2", provider: "anthropic"),
               target: target
             )

    assert {:error, {:provider_usage_event_bound_exceeded, 1}} =
             AI.provider_usage_daily(@day, target: target, max_events: 1)

    assert {:error, {:provider_usage_provider_bound_exceeded, 1}} =
             AI.provider_usage_daily(@day, target: target, max_providers: 1)
  end

  test "absent production target fails closed via config seam; per-call injection uses isolated store" do
    assert {:error, :provider_usage_ledger_target_unset} =
             Config.provider_usage_ledger_target_from(nil)

    assert {:error, :invalid_provider_usage_ledger_target} =
             Config.provider_usage_ledger_target_from(%{name: "not-an-atom", backend: ETS})

    assert {:error, :invalid_provider_usage_ledger_target} =
             Config.normalize_provider_usage_ledger_target(%{
               name: :ok,
               backend: ETS,
               extra: true
             })

    assert {:error, :invalid_provider_usage_ledger_target} =
             Config.normalize_provider_usage_ledger_target(%{
               :name => :ok,
               "name" => :other,
               :backend => ETS
             })

    assert {:error, :invalid_provider_usage_ledger_target} =
             AI.record_provider_usage(
               usage_attrs("usage-bad-target"),
               target: %{name: "bad", backend: ETS}
             )

    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    inject_name = :"provider_usage_inject_#{:erlang.unique_integer([:positive])}"

    start_supervised!(
      {ETS, name: inject_name, max_age_ms: :infinity, trim_interval_ms: :disabled},
      id: inject_name
    )

    target = %{name: inject_name, backend: ETS, opts: []}
    assert {:ok, _} = AI.record_provider_usage(usage_attrs("usage-inject-1"), target: target)
    assert {:ok, aggregate} = AI.provider_usage_daily(@day, target: target)
    assert aggregate["event_count"] == 1
  end

  test "unavailable backend fails closed without UndefinedFunctionError" do
    target = %{name: :missing_store, backend: Nonexistent.ProviderUsage.Backend, opts: []}

    assert {:error, :backend_unavailable} =
             AI.record_provider_usage(usage_attrs("usage-missing-backend"), target: target)

    assert {:error, :backend_unavailable} =
             AI.provider_usage_daily(@day, target: target)
  end

  test "projection returns typed errors for oversized and unexpected read replies" do
    oversized =
      for i <- 1..3 do
        Event.new(@stream_id, "arbor.provider_usage.v1", %{"n" => i},
          id: "usage-over-#{i}",
          event_number: i,
          timestamp: ~U[2026-07-22 12:00:00Z],
          metadata: %{"schema_version" => 1, "provider_usage_digest" => "sha256:x"}
        )
      end

    oversized_target = %{
      name: :scripted_oversize,
      backend: ScriptedReadBackend,
      opts: [reply: {:ok, oversized}]
    }

    assert {:error, {:provider_usage_page_too_large, 1}} =
             AI.provider_usage_daily(@day, target: oversized_target, page_size: 1)

    unexpected_target = %{
      name: :scripted_unexpected,
      backend: ScriptedReadBackend,
      opts: [reply: :not_a_result_tuple]
    }

    assert {:error, {:unexpected_read_result, :not_a_result_tuple}} =
             AI.provider_usage_daily(@day, target: unexpected_target)

    non_event_target = %{
      name: :scripted_non_event,
      backend: ScriptedReadBackend,
      opts: [reply: {:ok, [%{not: :an_event}]}]
    }

    assert {:error, :malformed_provider_usage_entry} =
             AI.provider_usage_daily(@day, target: non_event_target)
  end

  test "malformed option lists return typed errors without Keyword escape" do
    attrs = usage_attrs("usage-bad-opts")

    assert {:error, :invalid_options} =
             AI.record_provider_usage(attrs, [{"target", :not_keyword}])

    assert {:error, :invalid_options} =
             AI.record_provider_usage(attrs, :not_a_list)

    assert {:error, :invalid_provider_usage_bounds} =
             AI.provider_usage_daily(@day, [{"page_size", 1}])

    assert {:error, :invalid_options} =
             AI.provider_usage_daily(@day, :not_a_list)
  end

  test "append success with a non-Event value returns typed unexpected-persisted-event" do
    non_event = %{not: :an_event}

    target = %{
      name: :scripted_append_non_event,
      backend: ScriptedAppendBackend,
      opts: [reply: {:ok, [non_event]}]
    }

    assert {:error, {:unexpected_persisted_event, ^non_event}} =
             AI.record_provider_usage(usage_attrs("usage-non-event-append"), target: target)
  end

  test "indeterminate append reconciles a proven committed operation once" do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"provider_usage_committed_#{:erlang.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start:
        {Agent, :start_link,
         [fn -> %{events: %{}, mode: :indeterminate_commit} end, [name: name]]}
    })

    target = %{name: name, backend: IndeterminateBackend, opts: [agent: name]}
    attrs = usage_attrs("usage-indet-committed")

    assert {:ok, receipt} = AI.record_provider_usage(attrs, target: target)
    assert receipt["event_id"] == "usage-indet-committed"
    assert receipt["event_number"] == 1

    assert Agent.get(name, & &1.reconcile_calls) == 1
    assert Agent.get(name, & &1.append_calls) == 1
  end

  test "indeterminate append retries exactly once after proven absence" do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"provider_usage_absent_#{:erlang.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start:
        {Agent, :start_link,
         [fn -> %{events: %{}, mode: :indeterminate_absent} end, [name: name]]}
    })

    target = %{name: name, backend: IndeterminateBackend, opts: [agent: name]}
    attrs = usage_attrs("usage-indet-absent")

    assert {:ok, receipt} = AI.record_provider_usage(attrs, target: target)
    assert receipt["event_id"] == "usage-indet-absent"
    assert receipt["event_number"] == 1
    assert Agent.get(name, & &1.reconcile_calls) == 1
    assert Agent.get(name, & &1.append_calls) == 2
  end

  test "still-unknown reconciliation returns a typed indeterminate error" do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"provider_usage_unknown_#{:erlang.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {Agent, :start_link, [fn -> %{events: %{}, mode: :still_unknown} end, [name: name]]}
    })

    target = %{name: name, backend: IndeterminateBackend, opts: [agent: name]}
    attrs = usage_attrs("usage-indet-unknown")

    assert {:error, {:append_indeterminate, %AppendOperation{} = operation}} =
             AI.record_provider_usage(attrs, target: target)

    assert operation.stream_id == @stream_id
    assert operation.event_ids == ["usage-indet-unknown"]
    assert Agent.get(name, & &1.reconcile_calls) == 1
    assert Agent.get(name, & &1.append_calls) == 1
  end

  defp usage_attrs(event_id, overrides \\ []) do
    base = %{
      event_id: event_id,
      provider: "openai",
      source: "req_llm",
      runtime: "arbor",
      model_id: "gpt-5",
      operation: "complete",
      occurred_at: "2026-07-22T22:00:00Z",
      principal_id: "agent_abc",
      correlation_id: "corr-1",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      cached_tokens: 10,
      marginal_api_cost_usd: 0.01,
      subscription_usage_units: 1.0
    }

    Enum.reduce(overrides, base, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end
end
