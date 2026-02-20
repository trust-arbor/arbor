defmodule Arbor.Common.Sanitizers.LogInjection do
  @moduledoc """
  Sanitizer for log injection attacks.

  Strips CRLF sequences, control characters, and ANSI escape codes
  that could forge log entries or manipulate terminal output. Enforces
  length limits to prevent log flooding. Delegates to
  `Arbor.Common.SensitiveData.redact/1` for PII/secret redaction.

  Sets bit 6 on the taint sanitizations bitmask.

  ## Options

  - `:max_length` — maximum output length (default: 10_000)
  - `:redact` — whether to apply PII/secret redaction (default: true)
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b01000000
  @default_max_length 10_000

  # ANSI escape sequences (colors, cursor movement, etc.)
  @ansi_pattern ~r/\e\[[0-9;]*[A-Za-z]/
  # Control characters except \t (0x09) and \n (0x0A)
  @control_chars_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

  @impl true
  @spec sanitize(term(), Taint.t(), keyword()) ::
          {:ok, String.t(), Taint.t()} | {:error, term()}
  def sanitize(value, %Taint{} = taint, opts \\ []) when is_binary(value) do
    max_length = Keyword.get(opts, :max_length, @default_max_length)
    redact? = Keyword.get(opts, :redact, true)

    sanitized =
      value
      # Strip CRLF sequences (log forging)
      |> String.replace(~r/\r\n|\r/, " ")
      # Strip ANSI escape codes
      |> String.replace(@ansi_pattern, "")
      # Strip control characters (except tab and newline)
      |> String.replace(@control_chars_pattern, "")
      # Enforce length limit
      |> truncate(max_length)
      # Optionally redact sensitive data
      |> maybe_redact(redact?)

    updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
    {:ok, sanitized, updated_taint}
  end

  @impl true
  @spec detect(term()) :: {:safe, float()} | {:unsafe, [String.t()]}
  def detect(value) when is_binary(value) do
    found =
      [
        {String.contains?(value, "\r\n"), "crlf_injection"},
        {String.contains?(value, "\r"), "cr_injection"},
        {Regex.match?(@ansi_pattern, value), "ansi_escape"},
        {Regex.match?(@control_chars_pattern, value), "control_characters"},
        {String.contains?(value, <<0>>), "null_byte"},
        {byte_size(value) > @default_max_length, "excessive_length"}
      ]

    patterns = for {true, name} <- found, do: name

    case patterns do
      [] -> {:safe, 1.0}
      _ -> {:unsafe, patterns}
    end
  end

  def detect(_), do: {:safe, 1.0}

  defp truncate(value, max_length) do
    if byte_size(value) > max_length do
      String.slice(value, 0, max_length) <> "...[truncated]"
    else
      value
    end
  end

  defp maybe_redact(value, true) do
    if Code.ensure_loaded?(Arbor.Common.SensitiveData) do
      Arbor.Common.SensitiveData.redact(value)
    else
      value
    end
  end

  defp maybe_redact(value, false), do: value
end
