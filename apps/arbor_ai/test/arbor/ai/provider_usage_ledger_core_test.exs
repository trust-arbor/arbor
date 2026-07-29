defmodule Arbor.AI.ProviderUsageLedgerCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.ProviderUsageLedgerCore
  alias Arbor.Contracts.LLM.ProviderUsageEvent

  @moduletag :fast

  @base_attrs %{
    event_id: "usage-core-1",
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
    subscription_usage_units: 1.5
  }

  test "constructs empty daily state with closed bounds and stream id" do
    assert {:ok, state} =
             ProviderUsageLedgerCore.new(
               ~D[2026-07-22],
               page_size: 10,
               max_events: 20,
               max_providers: 5
             )

    assert state.date == "2026-07-22"
    assert state.stream_id == "provider_usage:v1:2026-07-22"
    assert state.next_event_number == 1
    assert state.bounds.page_size == 10
    assert state.bounds.max_events == 20
    assert state.bounds.max_providers == 5
    assert state.totals["event_count"] == 0

    assert ProviderUsageLedgerCore.show(state) == %{
             "version" => 1,
             "date" => "2026-07-22",
             "stream_id" => "provider_usage:v1:2026-07-22",
             "event_count" => 0,
             "input_tokens" => 0,
             "output_tokens" => 0,
             "total_tokens" => 0,
             "cached_tokens" => 0,
             "marginal_api_cost_usd" => 0,
             "marginal_api_cost_unknown_events" => 0,
             "subscription_usage_units" => 0,
             "subscription_usage_unknown_events" => 0,
             "providers" => %{}
           }
  end

  test "rejects invalid dates and non-positive bounds" do
    assert {:error, :invalid_provider_usage_date} = ProviderUsageLedgerCore.new("not-a-date")

    assert {:error, {:invalid_provider_usage_bound, :page_size}} =
             ProviderUsageLedgerCore.new(~D[2026-07-22], page_size: 0)

    assert {:error, {:invalid_provider_usage_bound, :max_events}} =
             ProviderUsageLedgerCore.new(~D[2026-07-22], max_events: -1)
  end

  test "prepare_append builds canonical stream payload from usage event" do
    assert {:ok, event} = ProviderUsageEvent.new(@base_attrs)
    assert {:ok, prepared} = ProviderUsageLedgerCore.prepare_append(event)
    assert {:ok, digest} = ProviderUsageEvent.digest(event)

    assert prepared["stream_id"] == "provider_usage:v1:2026-07-22"
    assert prepared["type"] == "arbor.provider_usage.v1"
    assert prepared["id"] == "usage-core-1"
    assert prepared["timestamp"] == "2026-07-22T22:00:00Z"
    assert prepared["agent_id"] == "agent_abc"
    assert prepared["correlation_id"] == "corr-1"
    assert prepared["data"]["provider"] == "openai"

    assert prepared["metadata"] == %{
             "schema_version" => 1,
             "provider_usage_digest" => digest
           }
  end

  test "reduce accumulates known costs and unknown nil cost dimensions" do
    assert {:ok, state} = ProviderUsageLedgerCore.new(~D[2026-07-22])
    assert {:ok, known} = ProviderUsageEvent.new(@base_attrs)
    assert {:ok, prepared} = ProviderUsageLedgerCore.prepare_append(known)

    known_entry = entry(prepared, 1)

    assert {:ok, state} = ProviderUsageLedgerCore.reduce(state, known_entry)

    unknown_attrs =
      @base_attrs
      |> Map.put(:event_id, "usage-core-2")
      |> Map.put(:occurred_at, "2026-07-22T23:00:00Z")
      |> Map.delete(:marginal_api_cost_usd)
      |> Map.delete(:subscription_usage_units)

    assert {:ok, unknown} = ProviderUsageEvent.new(unknown_attrs)
    assert {:ok, prepared_unknown} = ProviderUsageLedgerCore.prepare_append(unknown)
    assert {:ok, state} = ProviderUsageLedgerCore.reduce(state, entry(prepared_unknown, 2))

    aggregate = ProviderUsageLedgerCore.show(state)
    assert aggregate["event_count"] == 2
    assert aggregate["input_tokens"] == 200
    assert aggregate["output_tokens"] == 100
    assert aggregate["total_tokens"] == 300
    assert aggregate["cached_tokens"] == 20
    assert aggregate["marginal_api_cost_usd"] == 0.01
    assert aggregate["marginal_api_cost_unknown_events"] == 1
    assert aggregate["subscription_usage_units"] == 1.5
    assert aggregate["subscription_usage_unknown_events"] == 1
    assert aggregate["providers"]["openai"]["event_count"] == 2
    assert aggregate["providers"]["openai"]["marginal_api_cost_unknown_events"] == 1
  end

  test "reduce rejects malformed entries and identity mismatches" do
    assert {:ok, state} = ProviderUsageLedgerCore.new(~D[2026-07-22])
    assert {:ok, prepared} = ProviderUsageLedgerCore.prepare_append(@base_attrs)
    valid = entry(prepared, 1)

    assert map_size(valid["metadata"]) == 2

    assert Map.keys(valid["metadata"]) |> Enum.sort() ==
             ~w(provider_usage_digest schema_version)

    assert {:error, :malformed_provider_usage_entry} =
             ProviderUsageLedgerCore.reduce(state, Map.delete(valid, "data"))

    assert {:error, {:provider_usage_stream_mismatch, _, _}} =
             ProviderUsageLedgerCore.reduce(state, Map.put(valid, "stream_id", "other"))

    assert {:error, {:provider_usage_type_mismatch, "wrong"}} =
             ProviderUsageLedgerCore.reduce(state, Map.put(valid, "type", "wrong"))

    assert {:error, {:provider_usage_position_gap, 1, 2}} =
             ProviderUsageLedgerCore.reduce(state, Map.put(valid, "event_number", 2))

    assert {:error, {:provider_usage_day_mismatch, "2026-07-22", "2026-07-23"}} =
             ProviderUsageLedgerCore.reduce(
               state,
               Map.put(valid, "timestamp", "2026-07-23T00:00:00Z")
             )

    assert {:error, {:provider_usage_identity_mismatch, :principal_id, "other", "agent_abc"}} =
             ProviderUsageLedgerCore.reduce(state, Map.put(valid, "agent_id", "other"))

    assert {:error, {:provider_usage_identity_mismatch, :correlation_id, "other", "corr-1"}} =
             ProviderUsageLedgerCore.reduce(state, Map.put(valid, "correlation_id", "other"))

    assert {:error, {:provider_usage_identity_mismatch, :event_id, "other", "usage-core-1"}} =
             ProviderUsageLedgerCore.reduce(state, Map.put(valid, "id", "other"))

    assert {:error, {:provider_usage_digest_mismatch, _, _}} =
             ProviderUsageLedgerCore.reduce(
               state,
               put_in(valid, ["metadata", "provider_usage_digest"], "sha256:deadbeef")
             )

    assert {:error, {:provider_usage_schema_mismatch, 2}} =
             ProviderUsageLedgerCore.reduce(
               state,
               put_in(valid, ["metadata", "schema_version"], 2)
             )

    assert {:error, :malformed_provider_usage_metadata} =
             ProviderUsageLedgerCore.reduce(
               state,
               put_in(valid, ["metadata", "extra"], true)
             )

    # Passes ProviderUsageEvent.new/1 (version defaults) but is not exact to_map shape.
    assert {:error, {:malformed_provider_usage_data, :non_canonical_data}} =
             ProviderUsageLedgerCore.reduce(
               state,
               update_in(valid, ["data"], &Map.delete(&1, "version"))
             )

    # ProviderUsageEvent.new/1 gates numeric values before accumulation.
    assert {:error, {:malformed_provider_usage_data, {:invalid_field, "input_tokens"}}} =
             ProviderUsageLedgerCore.reduce(
               state,
               put_in(valid, ["data", "input_tokens"], -1)
             )
  end

  test "reduce enforces contiguous positions and configured bounds" do
    assert {:ok, state} =
             ProviderUsageLedgerCore.new(~D[2026-07-22], max_events: 1, max_providers: 1)

    assert {:ok, first} = ProviderUsageLedgerCore.prepare_append(@base_attrs)
    assert {:ok, state} = ProviderUsageLedgerCore.reduce(state, entry(first, 1))

    second_attrs =
      @base_attrs
      |> Map.put(:event_id, "usage-core-2")
      |> Map.put(:provider, "anthropic")

    assert {:ok, second} = ProviderUsageLedgerCore.prepare_append(second_attrs)

    assert {:error, {:provider_usage_event_bound_exceeded, 1}} =
             ProviderUsageLedgerCore.reduce(state, entry(second, 2))

    assert {:ok, multi} =
             ProviderUsageLedgerCore.new(~D[2026-07-22], max_events: 2, max_providers: 1)

    assert {:ok, multi} = ProviderUsageLedgerCore.reduce(multi, entry(first, 1))

    assert {:error, {:provider_usage_provider_bound_exceeded, 1}} =
             ProviderUsageLedgerCore.reduce(multi, entry(second, 2))
  end

  defp entry(prepared, event_number) do
    %{
      "id" => prepared["id"],
      "stream_id" => prepared["stream_id"],
      "event_number" => event_number,
      "type" => prepared["type"],
      "data" => prepared["data"],
      "metadata" => prepared["metadata"],
      "agent_id" => prepared["agent_id"],
      "correlation_id" => prepared["correlation_id"],
      "timestamp" => prepared["timestamp"]
    }
  end
end
