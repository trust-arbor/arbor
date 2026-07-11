defmodule Arbor.LLM.Plugs.ResponseLimit do
  @moduledoc "Closes the maximum response receipt before transport dispatch."

  use Arbor.LLM.Plug
  alias Arbor.LLM.Call

  @default_max_response_bytes 16_777_216

  def call(%Call{halted: true} = call), do: call

  def call(%Call{request: {model, input, opts}} = call) when is_list(opts) do
    case fetch_limit(opts) do
      {:ok, maximum} when is_integer(maximum) and maximum > 0 ->
        closed_opts =
          opts
          |> Keyword.delete(:max_response_bytes)
          |> Keyword.put(:arbor_max_response_bytes, min(maximum, @default_max_response_bytes))

        %{call | request: {model, input, closed_opts}}

      {:ok, maximum} ->
        Call.halt(%{call | result: {:error, {:invalid_response_limit, maximum}}})

      {:error, reason} ->
        Call.halt(%{call | result: {:error, reason}})
    end
  end

  def call(%Call{} = call), do: Call.halt(%{call | result: {:error, :invalid_dispatch_request}})

  defp fetch_limit(opts), do: fetch_limit(opts, @default_max_response_bytes)
  defp fetch_limit([], default), do: {:ok, default}
  defp fetch_limit([{:max_response_bytes, value} | _rest], _default), do: {:ok, value}

  defp fetch_limit([{key, _value} | rest], default) when is_atom(key),
    do: fetch_limit(rest, default)

  defp fetch_limit(_improper, _default), do: {:error, :invalid_dispatch_request}
end
