defmodule Arbor.Shell.Executor do
  @moduledoc """
  Bounded direct-argv execution behind a native process-group supervisor.

  The native supervisor creates a new session/process group before target exec,
  verifies the startup-pinned executable identity, forwards bounded output, and
  kills every remaining group member before sending a terminal frame. Timeout,
  cancellation, output-limit, port-owner loss, and direct-child exit all pass
  through that same containment boundary on macOS and Linux.
  """

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.{ProcessGroup, Sandbox}

  @default_timeout 30_000
  @default_max_output_bytes 8_388_608
  @max_max_output_bytes 16_777_216

  @type result :: %{
          optional(:cancelled) => boolean(),
          optional(:containment_failure) => boolean(),
          exit_code: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          timed_out: boolean(),
          killed: boolean(),
          output_truncated: boolean(),
          output_limit_exceeded: boolean()
        }

  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(command, opts \\ []) do
    {cmd, args} = Sandbox.parse_command(command)
    run_direct(cmd, args, opts)
  end

  @spec run_direct(String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run_direct(cmd, args, opts \\ []) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))
    max_output_bytes = normalize_max_output_bytes(Keyword.get(opts, :max_output_bytes))
    start_time = System.monotonic_time(:millisecond)

    case ProcessGroup.run(cmd, args, opts, start_time, timeout, max_output_bytes) do
      {:ok, terminal} ->
        result_from_terminal(terminal, start_time)

      {:error, :executable_policy_unavailable} ->
        {:error, :executable_policy_unavailable}

      {:error, :timeout_during_setup} ->
        {:ok, terminal_result(:timeout, 137, "", start_time)}

      {:error, :cancelled_during_setup} ->
        {:ok, terminal_result(:cancelled, 137, "", start_time)}

      {:error, {:port_exited, _reason}} ->
        # Abnormal native-port close (e.g. :epipe) after ownership isolation:
        # return a bounded fail-closed terminal rather than crashing the caller.
        {:ok, terminal_result(:containment_failure, 137, "", start_time)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec run_bound(Executable.t(), [String.t()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def run_bound(%Executable{} = executable, args, opts \\ []) do
    run_bound_with(&ProcessGroup.run_executable/6, executable, args, opts)
  end

  @doc false
  @spec run_apple_container_probe(Executable.t(), [String.t()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def run_apple_container_probe(%Executable{} = executable, args, opts) do
    run_bound_with(
      &ProcessGroup.run_apple_container_probe_executable/6,
      executable,
      args,
      opts
    )
  end

  defp run_bound_with(process_group_runner, executable, args, opts) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))
    max_output_bytes = normalize_max_output_bytes(Keyword.get(opts, :max_output_bytes))
    start_time = System.monotonic_time(:millisecond)

    case process_group_runner.(executable, args, opts, start_time, timeout, max_output_bytes) do
      {:ok, terminal} ->
        result_from_terminal(terminal, start_time)

      {:error, :timeout_during_setup} ->
        {:ok, terminal_result(:timeout, 137, "", start_time)}

      {:error, :cancelled_during_setup} ->
        {:ok, terminal_result(:cancelled, 137, "", start_time)}

      {:error, {:port_exited, _reason}} ->
        {:ok, terminal_result(:containment_failure, 137, "", start_time)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec normalize_timeout(term()) :: pos_integer()
  def normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  def normalize_timeout(_timeout), do: @default_timeout

  @doc false
  @spec normalize_max_output_bytes(term()) :: pos_integer()
  def normalize_max_output_bytes(n) when is_integer(n) and n > 0,
    do: min(n, @max_max_output_bytes)

  def normalize_max_output_bytes(_n), do: @default_max_output_bytes

  @doc false
  @spec max_output_bytes_limit() :: pos_integer()
  def max_output_bytes_limit, do: @max_max_output_bytes

  @doc false
  @spec default_max_output_bytes() :: pos_integer()
  def default_max_output_bytes, do: @default_max_output_bytes

  defp result_from_terminal(%{reason: reason, exit_code: exit_code, output: output}, start_time) do
    output = if reason == :output_limit, do: utf8_safe_prefix(output), else: output
    {:ok, terminal_result(reason, exit_code, output, start_time)}
  end

  defp terminal_result(reason, exit_code, output, start_time) do
    base = %{
      exit_code: exit_code,
      stdout: output,
      stderr: "",
      duration_ms: max(System.monotonic_time(:millisecond) - start_time, 0),
      timed_out: reason == :timeout,
      killed: reason in [:timeout, :output_limit, :cancelled, :containment_failure],
      output_truncated: reason == :output_limit,
      output_limit_exceeded: reason == :output_limit
    }

    base
    |> maybe_put(:cancelled, reason == :cancelled, reason == :cancelled)
    |> maybe_put(
      :containment_failure,
      reason == :containment_failure,
      reason == :containment_failure
    )
  end

  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map

  defp utf8_safe_prefix(data) when is_binary(data) do
    if String.valid?(data) do
      data
    else
      size = byte_size(data)

      Enum.find_value(1..min(3, size), fn n ->
        candidate = binary_part(data, 0, size - n)
        if String.valid?(candidate), do: candidate
      end) || <<>>
    end
  end
end
