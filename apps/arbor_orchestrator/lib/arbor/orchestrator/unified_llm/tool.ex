defmodule Arbor.Orchestrator.UnifiedLLM.Tool do
  @moduledoc false

  @type execute_fun :: (map() -> map() | {:ok, map()} | {:error, term()})

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map() | nil,
          execute: execute_fun() | nil
        }

  defstruct name: "", description: nil, input_schema: nil, execute: nil

  @spec noop(map()) :: map()
  def noop(_args), do: %{}

  @spec as_definition(t()) :: map()
  def as_definition(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema || %{}
    }
  end
end
