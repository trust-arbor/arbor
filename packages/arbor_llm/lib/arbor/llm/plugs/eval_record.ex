defmodule Arbor.LLM.Plugs.EvalRecord do
  @moduledoc "Records only explicitly selected named evaluation completions."

  use Arbor.LLM.Plug
  alias Arbor.LLM.{Call, Plugs.Record}

  def call(%Call{halted: true} = call), do: call

  def call(%Call{metadata: %{eval_fixture: %{mode: :record}}} = call),
    do: Record.call(call)

  def call(%Call{} = call), do: call
end
