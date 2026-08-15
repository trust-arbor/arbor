defmodule Arbor.Common.SafeRegex do
  @moduledoc """
  Safe regex operations with timeout protection against ReDoS attacks.

  Complex regex patterns with nested quantifiers can cause exponential
  backtracking on adversarial input. This module wraps regex operations
  with timeouts to prevent denial of service.

  ## Examples

      iex> Arbor.Common.SafeRegex.run(~r/foo/, "foobar")
      {:ok, ["foo"]}

      iex> Arbor.Common.SafeRegex.run(~r/foo/, "bar")
      {:ok, nil}

      # With timeout (for testing)
      iex> Arbor.Common.SafeRegex.run(~r/foo/, "bar", timeout: 100)
      {:ok, nil}

  ## Security Note

  The default timeout of 1000ms is generous for most patterns. If you're
  dealing with user-provided input and complex patterns, consider:

  1. Using simpler, non-backtracking patterns
  2. Limiting input size before regex matching
  3. Using possessive quantifiers where available
  """

  @default_timeout 1000

  @doc """
  Runs a regex against a string with timeout protection.

  Returns `{:ok, result}` where result is the match or nil,
  or `{:error, :timeout}` if the operation takes too long.

  ## Options

  - `:timeout` - Maximum milliseconds to wait (default: #{@default_timeout})
  """
  @spec run(Regex.t(), String.t(), keyword()) :: {:ok, list() | nil} | {:error, :timeout}
  def run(regex, string, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.async(fn -> Regex.run(regex, string) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end

  @doc """
  Scans a string for all regex matches with timeout protection.

  Returns `{:ok, matches}` where matches is a list of match lists,
  or `{:error, :timeout}` if the operation takes too long.

  ## Options

  - `:timeout` - Maximum milliseconds to wait (default: #{@default_timeout})
  """
  @spec scan(Regex.t(), String.t(), keyword()) :: {:ok, list()} | {:error, :timeout}
  def scan(regex, string, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.async(fn -> Regex.scan(regex, string) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end

  @doc """
  Checks if a regex matches a string with timeout protection.

  Returns `{:ok, boolean}` or `{:error, :timeout}`.

  ## Options

  - `:timeout` - Maximum milliseconds to wait (default: #{@default_timeout})
  """
  @spec match?(Regex.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, :timeout}
  def match?(regex, string, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.async(fn -> Regex.match?(regex, string) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end
end
