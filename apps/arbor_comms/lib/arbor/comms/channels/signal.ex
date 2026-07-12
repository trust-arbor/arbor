defmodule Arbor.Comms.Channels.Signal do
  @moduledoc """
  Signal messaging channel implementation via signal-cli.

  Provides bidirectional messaging capabilities using the signal-cli
  command-line tool. Supports sending and receiving text messages.

  ## Configuration

      config :arbor_comms, :signal,
        enabled: true,
        account: "+1XXXXXXXXXX",
        signal_cli_path: "/usr/local/bin/signal-cli",
        command_runner: Arbor.Shell,
        poll_interval_ms: 60_000,
        log_dir: "~/.arbor/logs/signal_chat",
        log_retention_days: 30

  `:command_runner` is trusted application configuration and must name a module
  exporting `execute/2`. It defaults to the public `Arbor.Shell` facade and is
  never selected from message or request data.
  """

  @behaviour Arbor.Contracts.Comms.ChannelSender
  @behaviour Arbor.Contracts.Comms.ChannelReceiver

  alias Arbor.Common.ShellEscape
  alias Arbor.Contracts.Comms.Message

  # Signal has a ~2000 character limit
  @max_message_length 2000
  @default_command_runner Arbor.Shell

  @doc "Returns channel capabilities and metadata."
  def channel_info do
    %{
      name: :signal,
      max_message_length: @max_message_length,
      supports_media: true,
      supports_threads: false,
      supports_outbound: true,
      latency: :polling
    }
  end

  @impl Arbor.Contracts.Comms.ChannelReceiver
  def poll do
    account = config(:account)

    args = [
      "-u",
      account,
      "-o",
      "json",
      "receive",
      "--timeout",
      "1",
      "--max-messages",
      "10"
    ]

    case run_signal_cli(args) do
      {:ok, output} -> parse_messages(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Arbor.Contracts.Comms.ChannelSender
  def send_message(recipient, message, opts \\ []) do
    case config(:account) do
      nil ->
        {:error, :no_account_configured}

      account ->
        formatted = do_format(message)
        attachments = Keyword.get(opts, :attachments, [])

        args = ["-u", account, "send", "-m", formatted, recipient]

        args =
          Enum.reduce(attachments, args, fn path, acc ->
            acc ++ ["--attachment", path]
          end)

        case run_signal_cli(args) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl Arbor.Contracts.Comms.ChannelSender
  def format_for_channel(message), do: do_format(message)

  defp do_format(response) do
    response = String.trim(response)

    if String.length(response) > @max_message_length do
      String.slice(response, 0, @max_message_length - 3) <> "..."
    else
      response
    end
  end

  defp run_signal_cli(args) do
    signal_cli = config(:signal_cli_path) || find_signal_cli()
    command = Enum.map_join([signal_cli | args], " ", &ShellEscape.escape_arg/1)

    with_isolated_tmpdir(fn tmpdir ->
      # signal-cli is a JVM tool; on every invocation libsignal-client extracts
      # its ~24 MB native library (libsignal_jni_*.dylib) to java.io.tmpdir and
      # never cleans it up, leaking tens of GB of stale `libsignal*` dirs into the
      # shared $TMPDIR. Point each run at a dedicated temp dir (TMPDIR drives the
      # JVM's java.io.tmpdir, with an explicit -D as a belt) so we can delete the
      # extraction when the command returns and it can never accumulate.
      env = %{
        "TMPDIR" => tmpdir,
        "JAVA_OPTS" => "-Djava.io.tmpdir=#{tmpdir}"
      }

      case execute_command(command, timeout: 30_000, sandbox: :none, env: env) do
        {:ok, %{exit_code: 0, stdout: output}} ->
          {:ok, output}

        {:ok, %{exit_code: code, stdout: output}} ->
          {:error, {:signal_cli_error, code, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  catch
    :exit, {:noproc, _} ->
      {:error, {:shell_unavailable, "Shell.ExecutionRegistry not running"}}
  end

  defp execute_command(command, opts) do
    runner = config(:command_runner, @default_command_runner)

    if is_atom(runner) and Code.ensure_loaded?(runner) and
         function_exported?(runner, :execute, 2) do
      apply(runner, :execute, [command, opts])
    else
      {:error, {:invalid_command_runner, runner}}
    end
  end

  # Runs `fun` with a private temp directory that is always removed afterward,
  # even if the command fails. This keeps signal-cli's per-invocation native
  # library extraction from leaking into the shared $TMPDIR.
  defp with_isolated_tmpdir(fun) do
    tmpdir =
      Path.join(
        System.tmp_dir!(),
        "arbor-signal-cli-#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmpdir)

    try do
      fun.(tmpdir)
    after
      File.rm_rf(tmpdir)
    end
  end

  defp find_signal_cli do
    cond do
      File.exists?("/usr/local/bin/signal-cli") -> "/usr/local/bin/signal-cli"
      File.exists?("/opt/homebrew/bin/signal-cli") -> "/opt/homebrew/bin/signal-cli"
      File.exists?("/usr/bin/signal-cli") -> "/usr/bin/signal-cli"
      true -> "signal-cli"
    end
  end

  defp parse_messages(output) do
    messages =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&parse_message_line/1)

    {:ok, messages}
  rescue
    _ -> {:ok, []}
  end

  defp parse_message_line(line) do
    case Jason.decode(line) do
      {:ok, %{"envelope" => %{"dataMessage" => %{"message" => text}} = envelope}}
      when is_binary(text) and text != "" ->
        [
          Message.new(
            channel: :signal,
            from: envelope["source"],
            content: text,
            received_at: parse_timestamp(envelope["timestamp"]),
            metadata: %{
              source_device: envelope["sourceDevice"],
              has_attachments: Map.has_key?(envelope["dataMessage"], "attachments")
            }
          )
        ]

      _ ->
        []
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(ts) when is_integer(ts) do
    case DateTime.from_unix(div(ts, 1000)) do
      {:ok, dt} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp config(key, default \\ nil) do
    Application.get_env(:arbor_comms, :signal, [])
    |> Keyword.get(key, default)
  end
end
