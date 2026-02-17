defmodule Arbor.Common.LogRedactor do
  @moduledoc """
  Logger filter that redacts sensitive values from log output.

  Scans log messages and metadata for patterns that look like API keys,
  tokens, or passwords and replaces them with [REDACTED].
  """

  @sensitive_patterns [
    ~r/(?i)(api[_-]?key|token|password|secret|credential)[=:\s]+["']?[\w\-\.]{16,}/,
    ~r/(?i)bearer\s+[\w\-\.]{16,}/,
    ~r/sk-[a-zA-Z0-9]{20,}/,
    ~r/key-[a-zA-Z0-9]{20,}/
  ]

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
    Enum.reduce(@sensitive_patterns, str, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
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
