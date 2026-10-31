defmodule Arbor.LLM.Plugs.Sensitivity do
  @moduledoc "Mandatory fail-closed sensitivity admission, repeated at each outbound effect."
  use Arbor.LLM.Plug
  alias Arbor.LLM.{Call, Sensitivity}

  def call(%Call{halted: true} = call), do: call

  def call(%Call{metadata: %{sensitivity_input: input}} = call) do
    case Sensitivity.decide(input) do
      :ok -> call
      {:error, _} = error -> %{call | result: error, halted: true}
    end
  end

  def call(%Call{} = call),
    do: %{call | result: {:error, {:sensitivity_blocked, :missing_destination}}, halted: true}
end
