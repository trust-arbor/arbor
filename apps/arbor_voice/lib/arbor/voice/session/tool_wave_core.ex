defmodule Arbor.Voice.Session.ToolWaveCore do
  @moduledoc """
  Pure tool-wave bookkeeping for one voice turn.

  A wave is the set of tool calls admitted from one provider response. The
  provider continues only after it receives every output of that response
  and then one continuation (`request_response`), not one per output.

  * `admit/2` records an admitted call id in the open wave.
  * `close/1` runs on the tool-bearing `turn_done` (TurnCore `:cycle_reset`)
    and moves the open wave to the closed list.
  * `take_ready/2` returns how many closed waves have no outstanding call
    and drops them; the Session sends one continuation for each.

  Outstanding ids are the Session's pending tool owners. Synchronous outputs
  (refusals, capacity errors) never enter that map, so they count as sent.
  Stores no pids, clocks or functions.
  """

  @type wave :: MapSet.t(String.t())
  @type t :: %{open: wave() | nil, closed: [wave()]}

  @doc "Construct empty wave state."
  @spec new() :: t()
  def new, do: %{open: nil, closed: []}

  @doc "Record one admitted tool call of the current response."
  @spec admit(t(), String.t()) :: t()
  def admit(%{open: open} = waves, call_id) when is_binary(call_id),
    do: %{waves | open: MapSet.put(open || MapSet.new(), call_id)}

  @doc "Close the current response's wave, if it admitted any call."
  @spec close(t()) :: t()
  def close(%{open: nil} = waves), do: waves
  def close(%{open: open, closed: closed}), do: %{open: nil, closed: closed ++ [open]}

  @doc """
  Split closed waves whose calls are all settled. Returns the number of
  continuations due and the remaining state.
  """
  @spec take_ready(t(), Enumerable.t()) :: {non_neg_integer(), t()}
  def take_ready(%{closed: closed} = waves, outstanding_ids) do
    outstanding = MapSet.new(outstanding_ids)
    {ready, waiting} = Enum.split_with(closed, &MapSet.disjoint?(&1, outstanding))
    {length(ready), %{waves | closed: waiting}}
  end
end
