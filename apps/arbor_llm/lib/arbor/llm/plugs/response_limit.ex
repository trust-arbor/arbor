defmodule Arbor.LLM.Plugs.ResponseLimit do
  @moduledoc "Closes the maximum response receipt before transport dispatch."

  use Arbor.LLM.Plug
  alias Arbor.LLM.Call

  @default_max_response_bytes 16_777_216

  def call(%Call{halted: true} = call), do: call

  def call(%Call{request: {model, input, opts}} = call) when is_list(opts) do
    maximum = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    if is_integer(maximum) and maximum > 0 and maximum <= @default_max_response_bytes do
      closed_opts =
        opts
        |> Keyword.delete(:max_response_bytes)
        |> Keyword.put(:arbor_max_response_bytes, maximum)

      %{call | request: {model, input, closed_opts}}
    else
      Call.halt(%{call | result: {:error, {:invalid_response_limit, maximum}}})
    end
  end

  def call(%Call{} = call), do: Call.halt(%{call | result: {:error, :invalid_dispatch_request}})
end
