defmodule Arbor.AI.LLMUsageConsumerTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.BudgetTracker
  alias Arbor.AI.LLMUsageConsumer

  @event [:arbor, :llm, :usage]
  @observed_at ~U[2026-07-22 20:00:00Z]

  @moduletag :fast

  setup do
    ensure_started(LLMUsageConsumer)
    ensure_started(BudgetTracker)
    previous = Application.get_env(:arbor_ai, :enable_budget_tracking, true)
    Application.put_env(:arbor_ai, :enable_budget_tracking, true)
    BudgetTracker.reset()
    wait_for_tracker()

    on_exit(fn ->
      Application.put_env(:arbor_ai, :enable_budget_tracking, previous)
      BudgetTracker.reset()
    end)

    :ok
  end

  test "valid usage changes BudgetTracker and appears through ProviderControlPlane" do
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

    wait_for_tracker()

    assert {:ok, status} = BudgetTracker.get_status()
    assert status.backends.openai.requests == 1
    assert status.backends.openai.cost == 1.25

    assert {:ok, %{snapshot: snapshot}} =
             AI.provider_budget_snapshot(:openai, observed_at: @observed_at)

    assert snapshot["current_spend"] == 1.25
    assert snapshot["request_count"] == 1
  end

  test "malformed events, unknown providers, and invalid costs are ignored" do
    emit(%{count: 1, input: 1, output: 1, total: 2, cached: 0},
      provider: "provider-never-interned-usage",
      model: "gpt-4",
      event_id: "unknown-provider"
    )

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

    wait_for_tracker()
    assert {:ok, status} = BudgetTracker.get_status()
    assert status.backends == %{}
  end

  test "disabled BudgetTracker does not receive telemetry usage" do
    Application.put_env(:arbor_ai, :enable_budget_tracking, false)

    emit(%{count: 1, input: 10, output: 2, total: 12, cached: 0},
      provider: "openai",
      model: "gpt-4",
      event_id: "tracker-disabled"
    )

    wait_for_tracker()

    assert {:ok, status} = BudgetTracker.get_status()
    assert status.backends == %{}
  end

  test "duplicate event IDs are accounted for once" do
    measurements = %{count: 1, input: 100, output: 25, total: 125, cached: 0}
    opts = [provider: "anthropic", model: "claude-sonnet-4", event_id: "duplicate-usage-1"]
    emit(measurements, opts)
    emit(measurements, opts)
    wait_for_tracker()

    assert %{requests: 1, total_tokens: 125} = BudgetTracker.today_stats()
  end

  test "reset clears the in-memory event ID cache" do
    measurements = %{count: 1, input: 4, output: 1, total: 5, cached: 0}
    opts = [provider: "openai", model: "gpt-4", event_id: "resettable-usage-1"]
    emit(measurements, opts)
    wait_for_tracker()

    BudgetTracker.reset()
    wait_for_tracker()
    emit(measurements, opts)
    wait_for_tracker()

    assert %{requests: 1, total_tokens: 5} = BudgetTracker.today_stats()
  end

  test "existing callers without event IDs continue to count" do
    BudgetTracker.record_usage(:ollama, %{model: "llama", input_tokens: 2, output_tokens: 1})
    BudgetTracker.record_usage(:ollama, %{model: "llama", input_tokens: 3, output_tokens: 4})
    wait_for_tracker()

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

    wait_for_tracker()

    assert BudgetTracker.backend_spend(:anthropic) == 0.25
  end

  defp emit(measurements, opts) do
    metadata = %{
      event_id: Keyword.fetch!(opts, :event_id),
      source: :req_llm,
      operation: :complete,
      provider: Keyword.fetch!(opts, :provider),
      model: Keyword.fetch!(opts, :model),
      usage_status: :authoritative
    }

    :telemetry.execute(@event, measurements, metadata)
  end

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil ->
        {:ok, _pid} = module.start_link()

      _pid ->
        :ok
    end
  end

  defp wait_for_tracker, do: :timer.sleep(25)
end
