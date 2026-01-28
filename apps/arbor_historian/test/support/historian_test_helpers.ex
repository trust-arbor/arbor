defmodule Arbor.Historian.TestHelpers do
  @moduledoc """
  Test helpers and signal factory for historian tests.
  """

  alias Arbor.Signals.Signal

  @doc "Build a fake signal struct for testing."
  def build_signal(opts \\ []) do
    category = Keyword.get(opts, :category, :activity)
    type = Keyword.get(opts, :type, :agent_started)

    %Signal{
      id: Keyword.get(opts, :id, "sig_#{random_hex(16)}"),
      source: Keyword.get(opts, :source, "arbor://test/historian"),
      category: category,
      type: type,
      timestamp: Keyword.get(opts, :time, DateTime.utc_now()),
      data: Keyword.get(opts, :data, %{}),
      cause_id: Keyword.get(opts, :cause_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Build a signal with agent_id in data."
  def build_agent_signal(agent_id, opts \\ []) do
    build_signal(Keyword.merge([data: %{agent_id: agent_id}], opts))
  end

  @doc "Build a signal with session_id in data."
  def build_session_signal(session_id, opts \\ []) do
    build_signal(Keyword.merge([data: %{session_id: session_id}], opts))
  end

  @doc "Start an isolated historian stack for testing."
  def start_test_historian(test_name) do
    event_log_name = :"event_log_#{test_name}"
    registry_name = :"registry_#{test_name}"
    collector_name = :"collector_#{test_name}"

    {:ok, event_log} =
      Arbor.Historian.EventLog.ETS.start_link(name: event_log_name)

    {:ok, registry} =
      Arbor.Historian.StreamRegistry.start_link(name: registry_name)

    {:ok, collector} =
      Arbor.Historian.Collector.start_link(
        name: collector_name,
        event_log: event_log_name,
        registry: registry_name,
        subscribe: false
      )

    %{
      event_log: event_log_name,
      registry: registry_name,
      collector: collector_name,
      pids: [event_log, registry, collector]
    }
  end

  @doc "Collect a signal through the test stack."
  def collect_signal(ctx, signal) do
    Arbor.Historian.Collector.collect(ctx.collector, signal)
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end
end
