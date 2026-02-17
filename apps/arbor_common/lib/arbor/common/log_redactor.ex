defmodule Arbor.Common.LogRedactor do
  @moduledoc """
  Logger filter that redacts sensitive values from log output.

  Delegates to `Arbor.Common.SensitiveData.redact/1` for pattern matching,
  which covers both PII and secret patterns.
  """

  alias Arbor.Common.SensitiveData

  @doc false
  def filter(%{msg: msg} = log_event, _extra) do
    case msg do
      {:string, str} ->
        %{log_event | msg: {:string, redact(str)}}

      {:report, report} when is_map(report) ->
        %{log_event | msg: {:report, redact_map(report)}}

      _ ->
        log_event
    end
  end

  def filter(log_event, _extra), do: log_event

  defp redact(str) when is_binary(str) do
    SensitiveData.redact(str)
  end

  defp redact(other), do: other

  defp redact_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(v) -> {k, redact(v)}
      {k, v} when is_map(v) -> {k, redact_map(v)}
      pair -> pair
    end)
  end
end
