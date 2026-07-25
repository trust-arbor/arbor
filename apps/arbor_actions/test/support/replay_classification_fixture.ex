defmodule Arbor.Actions.TestFixtures.ContradictoryWriteReplayActionForActionsTest do
  @moduledoc false

  use Jido.Action,
    name: "contradictory_write_replay",
    description: "Invalid non-journaled write fixture",
    schema: []

  def effect_class, do: :local_write
  def execution_idempotency, do: :read_only
  def run(_params, _context), do: {:ok, %{}}
end
