defmodule Arbor.Commands.CodingBenchmark.ApprovalObservationsTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingBenchmark.ApprovalObservations

  @moduletag :fast

  test "counts each approval once across requested and queued events" do
    events = [
      signal(:requested, "irq_one", :approval, nil, 1),
      signal(:queued, "irq_one", :approval, nil, 2),
      signal(:resolved, "irq_one", :approval, :rejected, 3, true),
      signal(:requested, "irq_two", :approval, nil, 4),
      signal(:resolved, "irq_two", :approval, :approved, 5)
    ]

    assert ApprovalObservations.from_signals(events) == %{
             "count" => 2,
             "requested" => true,
             "required" => true,
             "resumed" => true,
             "status" => "approved"
           }
  end

  test "ignores non-approval interactions" do
    assert ApprovalObservations.from_signals([
             signal(:requested, "irq_other", :clarification, nil, 1)
           ]) == :empty
  end

  test "projects unresolved and rejected approvals without inventing resume" do
    pending = [signal(:requested, "irq_pending", :approval, nil, 1)]

    assert %{"count" => 1, "resumed" => false, "status" => "pending"} =
             ApprovalObservations.from_signals(pending)

    denied = [
      signal(:requested, "irq_denied", :approval, nil, 1),
      signal(:resolved, "irq_denied", :approval, :rejected, 2)
    ]

    assert %{"count" => 1, "resumed" => false, "status" => "denied"} =
             ApprovalObservations.from_signals(denied)
  end

  test "preserves event order within one millisecond" do
    base = DateTime.from_unix!(1_000_000, :microsecond)

    events = [
      signal_at(:requested, "irq_first", :approval, nil, base),
      signal_at(:resolved, "irq_first", :approval, :rejected, add_us(base, 100), true),
      signal_at(:requested, "irq_second", :approval, nil, add_us(base, 200)),
      signal_at(:resolved, "irq_second", :approval, :approved, add_us(base, 300))
    ]

    assert %{"count" => 2, "resumed" => true, "status" => "approved"} =
             ApprovalObservations.from_signals(Enum.reverse(events))
  end

  test "uses the emitter sequence when timestamps are identical" do
    timestamp = DateTime.from_unix!(1_000_000, :microsecond)

    events = [
      signal_at(:requested, "irq_first", :approval, nil, timestamp, false, 1),
      signal_at(:resolved, "irq_first", :approval, :rejected, timestamp, true, 2),
      signal_at(:requested, "irq_second", :approval, nil, timestamp, false, 3),
      signal_at(:resolved, "irq_second", :approval, :approved, timestamp, false, 4)
    ]

    assert %{"count" => 2, "resumed" => true, "status" => "approved"} =
             ApprovalObservations.from_signals(Enum.reverse(events))
  end

  defp signal(type, request_id, kind, response, second, rework \\ false) do
    signal_at(type, request_id, kind, response, DateTime.from_unix!(second), rework)
  end

  defp signal_at(type, request_id, kind, response, timestamp, rework \\ false, sequence \\ nil) do
    data = %{kind: kind, request_id: request_id}
    data = if response == nil, do: data, else: Map.put(data, :response, response)
    data = if rework, do: Map.put(data, :rework, true), else: data
    data = if sequence == nil, do: data, else: Map.put(data, :event_sequence, sequence)

    %{
      data: data,
      timestamp: timestamp,
      type: type
    }
  end

  defp add_us(timestamp, microseconds), do: DateTime.add(timestamp, microseconds, :microsecond)
end
