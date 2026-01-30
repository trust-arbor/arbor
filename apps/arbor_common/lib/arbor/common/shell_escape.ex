defmodule Arbor.Common.ShellEscape do
  @moduledoc """
  Safe shell argument escaping to prevent command injection.

  Uses POSIX single-quote wrapping: the argument is wrapped in single
  quotes, and any embedded single quotes are replaced with `'\\''`
  (end quote, escaped quote, start quote). This is the safest portable
  approach because single-quoted strings in POSIX shells have no
  special characters except the closing quote itself.

  ## Usage

      iex> ShellEscape.escape_arg("hello world")
      "'hello world'"

      iex> ShellEscape.escape_arg("it's")
      "'it'\\''s'"

      iex> ShellEscape.escape_arg("safe")
      "safe"
  """

  # Characters that require escaping in shell contexts.
  # Union of all metacharacters from POSIX sh, bash, and zsh.
  @shell_metacharacters [
    " ",
    "'",
    "\"",
    "\\",
    "$",
    "`",
    "!",
    "\n",
    "\t",
    ";",
    "&",
    "|",
    "<",
    ">",
    "(",
    ")",
    "{",
    "}",
    "[",
    "]",
    "?",
    "*",
    "#",
    "~"
  ]

  @doc """
  Escape a string for safe use as a shell argument.

  Only wraps in quotes if the argument contains shell metacharacters.
  Returns the argument unchanged if no escaping is needed.

  ## Examples

      iex> Arbor.Common.ShellEscape.escape_arg("simple")
      "simple"

      iex> Arbor.Common.ShellEscape.escape_arg("has spaces")
      "'has spaces'"

      iex> Arbor.Common.ShellEscape.escape_arg("it's quoted")
      "'it'\\\\''s quoted'"
  """
  @spec escape_arg(String.t() | nil) :: String.t()
  def escape_arg(nil), do: "''"

  def escape_arg(arg) when is_binary(arg) do
    if needs_escaping?(arg) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end

  def escape_arg(arg), do: escape_arg(to_string(arg))

  @doc """
  Escape a string, always wrapping in quotes regardless of content.

  Use this when the argument may be empty or when you want consistent
  quoting for all arguments (e.g., in programmatic command construction).

  ## Examples

      iex> Arbor.Common.ShellEscape.escape_arg!("safe")
      "'safe'"

      iex> Arbor.Common.ShellEscape.escape_arg!("")
      "''"
  """
  @spec escape_arg!(String.t() | nil) :: String.t()
  def escape_arg!(nil), do: "''"

  def escape_arg!(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  def escape_arg!(arg), do: escape_arg!(to_string(arg))

  @doc """
  Escape multiple arguments and join with spaces.

  ## Examples

      iex> Arbor.Common.ShellEscape.escape_args(["echo", "hello world"])
      "echo 'hello world'"
  """
  @spec escape_args([String.t()]) :: String.t()
  def escape_args(args) when is_list(args) do
    Enum.map_join(args, " ", &escape_arg/1)
  end

  @doc """
  Check if a string contains shell metacharacters that require escaping.
  """
  @spec needs_escaping?(String.t()) :: boolean()
  def needs_escaping?(arg) when is_binary(arg) do
    String.contains?(arg, @shell_metacharacters)
  end
end
