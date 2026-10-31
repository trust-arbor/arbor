defmodule Arbor.LLM.Plugs.EvalReplay do
  @moduledoc "Replays only explicitly selected named evaluation fixtures, without provider fallback."

  use Arbor.LLM.Plug
  alias Arbor.LLM.{Call, Plugs.Replay}

  def call(%Call{halted: true} = call), do: call

  def call(%Call{metadata: %{eval_fixture: %{mode: :replay}}} = call),
    do: Replay.call(call)

  def call(%Call{} = call), do: call
end
