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
  @default_max_input_bytes 1_048_576
  @worker_marker {__MODULE__, :timeout_worker}

  @type failure_reason :: :timeout | :input_too_large | :invalid_input | :operation_failed

  @doc """
  Runs a regex against a string with timeout protection.

  Returns `{:ok, result}` where result is the match or nil,
  or `{:error, :timeout}` if the operation takes too long.

  ## Options

  - `:timeout` - Maximum milliseconds to wait (default: #{@default_timeout})
  """
  @spec run(Regex.t(), String.t(), keyword()) ::
          {:ok, list() | nil} | {:error, failure_reason()}
  def run(regex, string, opts \\ []) do
    with :ok <- validate_operation(regex, string, opts) do
      execute(fn -> Regex.run(regex, string) end, opts)
    end
  end

  @doc """
  Scans a string for all regex matches with timeout protection.

  Returns `{:ok, matches}` where matches is a list of match lists,
  or `{:error, :timeout}` if the operation takes too long.

  ## Options

  - `:timeout` - Maximum milliseconds to wait (default: #{@default_timeout})
  """
  @spec scan(Regex.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, failure_reason()}
  def scan(regex, string, opts \\ []) do
    with :ok <- validate_operation(regex, string, opts) do
      execute(fn -> Regex.scan(regex, string) end, opts)
    end
  end

  @doc """
  Checks if a regex matches a string with timeout protection.

  Returns `{:ok, boolean}` or `{:error, :timeout}`.

  ## Options

  - `:timeout` - Maximum milliseconds to wait (default: #{@default_timeout})
  """
  @spec match?(Regex.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, failure_reason()}
  def match?(regex, string, opts \\ []) do
    with :ok <- validate_operation(regex, string, opts) do
      execute(fn -> Regex.match?(regex, string) end, opts)
    end
  end

  @doc """
  Replaces matches with timeout and input-size protection.

  The replacement may be a string or any callback accepted by `Regex.replace/4`.
  """
  @spec replace(Regex.t(), String.t(), String.t() | function(), keyword()) ::
          {:ok, String.t()} | {:error, failure_reason()}
  def replace(regex, string, replacement, opts \\ []) do
    with :ok <- validate_operation(regex, string, opts) do
      execute(fn -> Regex.replace(regex, string, replacement) end, opts)
    end
  end

  @doc """
  Executes a group of regex operations under one wall-clock timeout.

  Calls to this module from inside `fun` share the enclosing worker instead of
  creating one task per match. This is useful for scanners which perform many
  small matches over one bounded input.
  """
  @spec within_timeout((-> result), keyword()) ::
          {:ok, result} | {:error, failure_reason()}
        when result: var
  def within_timeout(fun, opts \\ []) when is_function(fun, 0) do
    execute(fun, opts)
  end

  defp validate_operation(%Regex{}, string, opts) when is_binary(string) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_input_bytes)

    cond do
      not is_integer(max_bytes) or max_bytes < 0 -> {:error, :invalid_input}
      byte_size(string) > max_bytes -> {:error, :input_too_large}
      true -> :ok
    end
  end

  defp validate_operation(_regex, _string, _opts), do: {:error, :invalid_input}

  # A scanner wrapped by within_timeout/2 already has one killable worker.
  # Running nested operations in that worker prevents an attacker-controlled
  # number of lines or patterns from creating an attacker-controlled number of
  # processes.
  defp execute(fun, opts) do
    if Process.get(@worker_marker) do
      invoke(fun)
    else
      execute_in_worker(fun, timeout(opts))
    end
  end

  defp execute_in_worker(fun, timeout) do
    caller = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        Process.put(@worker_marker, true)
        send(caller, {reply_ref, invoke(fun)})
      end)

    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        # A normal result is sent before the worker exits. Preserve that result
        # if the monitor signal and ordinary message race in this receive.
        receive do
          {^reply_ref, result} -> result
        after
          0 -> {:error, :operation_failed}
        end
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        end

        flush_reply(reply_ref)
        {:error, :timeout}
    end
  end

  defp invoke(fun) do
    {:ok, fun.()}
  rescue
    _exception -> {:error, :operation_failed}
  catch
    _kind, _reason -> {:error, :operation_failed}
  end

  defp timeout(opts) when is_list(opts) do
    case Keyword.get(opts, :timeout, @default_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> 0
    end
  end

  defp timeout(_opts), do: 0

  defp flush_reply(reply_ref) do
    receive do
      {^reply_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
