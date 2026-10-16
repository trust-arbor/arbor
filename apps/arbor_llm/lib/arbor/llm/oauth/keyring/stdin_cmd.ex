defmodule Arbor.LLM.OAuth.Keyring.StdinCmd do
  @moduledoc false

  # Runs an OS keyring helper without placing secret bytes on argv.
  # When `stdin` is a binary, it is written to an exclusive 0600 temp file and
  # redirected into the child; the temp path is not a secret. Lookup commands
  # pass `stdin = nil` and use stdout only for the caller to decode.

  @default_timeout_ms 15_000
  @max_stdout_bytes 1_048_576

  @spec run(String.t(), [String.t()], String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(executable, args, stdin, opts \\ [])

  def run(executable, args, stdin, opts)
      when is_binary(executable) and is_list(args) and (is_binary(stdin) or is_nil(stdin)) and
             is_list(opts) do
    if valid_args?(args) do
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

      case Application.get_env(:arbor_llm, :oauth_keyring_cmd_fun) do
        fun when is_function(fun, 4) ->
          normalize_result(fun.(executable, args, stdin, opts))

        _ ->
          do_run(executable, args, stdin, timeout)
      end
    else
      {:error, :invalid_keyring_command}
    end
  end

  def run(_executable, _args, _stdin, _opts), do: {:error, :invalid_keyring_command}

  defp valid_args?(args) do
    Enum.all?(args, fn
      arg when is_binary(arg) and byte_size(arg) <= 4_096 -> String.valid?(arg)
      _other -> false
    end)
  end

  defp do_run(executable, args, nil, timeout) do
    with {:ok, exe} <- find_executable(executable) do
      cmd(exe, args, timeout)
    end
  end

  defp do_run(executable, args, stdin, timeout) when is_binary(stdin) do
    with {:ok, exe} <- find_executable(executable),
         {:ok, sh} <- find_executable("sh"),
         {:ok, tmp} <- create_stdin_temp() do
      try do
        with :ok <- write_stdin_temp(tmp, stdin) do
          # POSIX sh (dash on Debian/Ubuntu): no bash `${@:3}`. $1 is the
          # helper, $2 is the 0600 stdin temp, remaining argv are forwarded.
          cmd(
            sh,
            [
              "-c",
              ~S[exe="$1"; infile="$2"; shift 2; exec "$exe" "$@" < "$infile"],
              "arbor-oauth-keyring",
              exe,
              tmp | args
            ],
            timeout
          )
        end
      after
        _ = scrub_and_rm(tmp)
      end
    end
  end

  defp find_executable(name) when is_binary(name) do
    case System.find_executable(name) do
      exe when is_binary(exe) -> {:ok, exe}
      _ -> {:error, :keyring_unavailable}
    end
  end

  defp cmd(exe, args, timeout) do
    task =
      Task.async(fn ->
        System.cmd(exe, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, 0}} when is_binary(stdout) and byte_size(stdout) <= @max_stdout_bytes ->
        {:ok, stdout}

      {:ok, {stdout, 0}} when is_binary(stdout) ->
        {:error, :keyring_output_too_large}

      {:ok, {_stdout, status}} when is_integer(status) ->
        {:error, {:keyring_command_failed, status}}

      nil ->
        {:error, :keyring_timeout}

      _other ->
        {:error, :keyring_unavailable}
    end
  end

  defp normalize_result({:ok, stdout}) when is_binary(stdout), do: {:ok, stdout}

  defp normalize_result({stdout, 0})
       when is_binary(stdout) and byte_size(stdout) <= @max_stdout_bytes,
       do: {:ok, stdout}

  defp normalize_result({stdout, 0}) when is_binary(stdout),
    do: {:error, :keyring_output_too_large}

  defp normalize_result({_stdout, status}) when is_integer(status),
    do: {:error, {:keyring_command_failed, status}}

  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_other), do: {:error, :keyring_unavailable}

  defp create_stdin_temp do
    dir =
      case Application.get_env(:arbor_llm, :oauth_store_dir) do
        store when is_binary(store) and byte_size(store) > 0 -> Path.expand(store)
        _ -> System.tmp_dir!()
      end

    case File.mkdir_p(dir) do
      :ok ->
        suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        tmp = Path.join(dir, ".keyring.#{System.unique_integer([:positive])}.#{suffix}.tmp")
        {:ok, tmp}

      {:error, reason} ->
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp write_stdin_temp(tmp, stdin) do
    case :file.open(tmp, [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- :file.change_mode(tmp, 0o600),
               :ok <- :file.write(io, stdin),
               :ok <- :file.sync(io),
               :ok <- :file.close(io) do
            :ok
          else
            {:error, reason} ->
              _ = :file.close(io)
              _ = File.rm(tmp)
              {:error, {:token_store_write_failed, reason}}
          end
        rescue
          exception ->
            _ = :file.close(io)
            _ = File.rm(tmp)
            {:error, {:token_store_write_failed, Exception.message(exception)}}
        end

      {:error, reason} ->
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp scrub_and_rm(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 and size <= @max_stdout_bytes ->
        zeros = :binary.copy(<<0>>, size)

        case :file.open(path, [:raw, :binary, :write]) do
          {:ok, io} ->
            _ = :file.write(io, zeros)
            _ = :file.sync(io)
            _ = :file.close(io)

          _ ->
            :ok
        end

        File.rm(path)

      {:ok, _} ->
        File.rm(path)

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        File.rm(path)
    end
  end
end
