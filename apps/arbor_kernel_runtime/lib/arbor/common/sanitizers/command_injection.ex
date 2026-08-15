defmodule Arbor.Common.Sanitizers.CommandInjection do
  @moduledoc """
  Sanitizer for command injection attacks.

  Wraps `Arbor.Common.ShellEscape.escape_arg/1` and sets bit 2 on the
  taint sanitizations bitmask after successful sanitization.

  ## Attack Vectors Detected

  - Shell metacharacters: `| & ; $ () {} \` etc.
  - Null bytes (can truncate arguments in C-based parsers)
  - Command substitution: `$(...)` and backticks
  - Pipeline injection: `| command`
  - Background execution: `& command`
  - Semicolon chaining: `; command`
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Common.ShellEscape
  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b00000100

  # Patterns that indicate command injection attempts
  @dangerous_patterns [
    # Command chaining
    ~r/[;&|]/,
    # Command substitution
    ~r/\$\(/,
    ~r/`/,
    # Redirection
    ~r/[<>]/,
    # Subshell
    ~r/\(/,
    # Variable expansion
    ~r/\$\{/,
    ~r/\$[A-Za-z_]/,
    # Null byte
    ~r/\x00/,
    # Newline injection (can start new command)
    ~r/\n/,
    # Common dangerous commands
    ~r/\b(?:rm|chmod|chown|kill|shutdown|reboot|dd|mkfs|curl|wget|nc|ncat)\b/i
  ]

  @pattern_names [
    "command_chaining",
    "command_substitution_dollar",
    "command_substitution_backtick",
    "redirection",
    "subshell",
    "variable_expansion_brace",
    "variable_expansion",
    "null_byte",
    "newline_injection",
    "dangerous_command"
  ]

  @impl true
  @spec sanitize(term(), Taint.t(), keyword()) ::
          {:ok, String.t(), Taint.t()} | {:error, term()}
  def sanitize(value, %Taint{} = taint, _opts \\ []) when is_binary(value) do
    if String.contains?(value, <<0>>) do
      {:error, {:null_byte_in_input, "Command arguments must not contain null bytes"}}
    else
      escaped = ShellEscape.escape_arg(value)
      updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
      {:ok, escaped, updated_taint}
    end
  end

  @impl true
  @spec detect(term()) :: {:safe, float()} | {:unsafe, [String.t()]}
  def detect(value) when is_binary(value) do
    found =
      @dangerous_patterns
      |> Enum.zip(@pattern_names)
      |> Enum.flat_map(fn {pattern, name} ->
        if Regex.match?(pattern, value), do: [name], else: []
      end)

    case found do
      [] -> {:safe, 1.0}
      patterns -> {:unsafe, patterns}
    end
  end

  def detect(_), do: {:safe, 1.0}
end
