defmodule Arbor.LLM.Plugs.ResponseLimit do
  @moduledoc "Closes the maximum response receipt before transport dispatch."

  use Arbor.LLM.Plug
  alias Arbor.LLM.Call

  @default_max_response_bytes 16_777_216

  def call(%Call{halted: true} = call), do: call

  def call(%Call{request: {model, input, opts}} = call) when is_list(opts) do
    case fetch_limit(opts) do
      {:ok, maximum} ->
        closed_opts =
          opts
          |> Keyword.drop([:max_response_bytes, :max_output_bytes, :arbor_max_response_bytes])
          |> Keyword.put(:arbor_max_response_bytes, maximum)

        %{call | request: {model, input, closed_opts}}

      {:error, reason} ->
        Call.halt(%{call | result: {:error, reason}})
    end
  end

  def call(%Call{} = call), do: Call.halt(%{call | result: {:error, :invalid_dispatch_request}})

  defp fetch_limit(opts), do: fetch_limit(opts, [], 0)
  defp fetch_limit([], values, _count), do: close_limits(values)

  defp fetch_limit(_opts, _values, count) when count >= 128,
    do: {:error, :invalid_dispatch_request}

  defp fetch_limit([{key, value} | rest], values, count)
       when key in [:max_response_bytes, :max_output_bytes, :arbor_max_response_bytes],
       do: fetch_limit(rest, [value | values], count + 1)

  defp fetch_limit([{key, _value} | rest], values, count) when is_atom(key),
    do: fetch_limit(rest, values, count + 1)

  defp fetch_limit(_improper, _values, _count), do: {:error, :invalid_dispatch_request}

  defp close_limits(values) do
    case Enum.find(values, &(not (is_integer(&1) and &1 > 0))) do
      nil -> {:ok, Enum.reduce(values, @default_max_response_bytes, &min/2)}
      invalid -> {:error, {:invalid_response_limit, invalid}}
    end
  end
end
