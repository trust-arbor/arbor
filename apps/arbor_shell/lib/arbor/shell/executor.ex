defmodule Arbor.Shell.Executor do
  @moduledoc """
  Low-level command execution using Erlang ports.

  Handles the actual execution of shell commands with timeout handling,
  output capture, and process management.
  """

  @default_timeout 30_000

  @type result :: %{
          exit_code: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          timed_out: boolean(),
          killed: boolean()
        }

  @doc """
  Execute a command synchronously.

  ## Options

  - `:timeout` - Timeout in milliseconds (default: 30_000)
  - `:cwd` - Working directory
  - `:env` - Environment variables map
  - `:stdin` - Input to send to the process
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})
    stdin = Keyword.get(opts, :stdin)

    start_time = System.monotonic_time(:millisecond)

    with :ok <- validate_cwd(cwd) do
      port_opts = build_port_opts(cwd, env)

      try do
        port = Port.open({:spawn, command}, port_opts)

        if stdin do
          Port.command(port, stdin)
        end

        collect_output(port, timeout, start_time)
      catch
        :error, reason ->
          {:error, reason}
      end
    end
  end

  @doc """
  Kill a port/process by port reference.
  """
  @spec kill_port(port()) :: :ok | {:error, term()}
  def kill_port(port) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, reason -> {:error, reason}
  end

  # Private functions

  defp build_port_opts(cwd, env) do
    opts = [:binary, :exit_status, :use_stdio, :stderr_to_stdout]

    opts =
      if cwd do
        [{:cd, to_charlist(cwd)} | opts]
      else
        opts
      end

    if map_size(env) > 0 do
      env_list =
        Enum.map(env, fn
          # Port.open convention: {var, false} removes the variable
          {k, false} -> {to_charlist(k), false}
          {k, v} -> {to_charlist(k), to_charlist(v)}
        end)

      [{:env, env_list} | opts]
    else
      opts
    end
  end

  defp validate_cwd(nil), do: :ok

  defp validate_cwd(cwd) when is_binary(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, {:invalid_cwd, cwd}}
    end
  end

  defp collect_output(port, timeout, start_time) do
    collect_output(port, timeout, start_time, [])
  end

  defp collect_output(port, timeout, start_time, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, timeout, start_time, [data | acc])

      {^port, {:exit_status, exit_code}} ->
        duration = System.monotonic_time(:millisecond) - start_time
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()

        {:ok,
         %{
           exit_code: exit_code,
           stdout: output,
           stderr: "",
           duration_ms: duration,
           timed_out: false,
           killed: false
         }}
    after
      timeout ->
        # Timeout - kill the port
        catch_port_close(port)
        duration = System.monotonic_time(:millisecond) - start_time
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()

        {:ok,
         %{
           exit_code: 137,
           stdout: output,
           stderr: "",
           duration_ms: duration,
           timed_out: true,
           killed: true
         }}
    end
  end

  defp catch_port_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end
end
