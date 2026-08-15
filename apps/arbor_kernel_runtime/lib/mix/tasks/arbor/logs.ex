defmodule Mix.Tasks.Arbor.Logs do
  @shortdoc "Tail Arbor server log output"
  @moduledoc """
  Tails the Arbor server log file.

      $ mix arbor.logs
      $ mix arbor.logs -n 50

  Prints the `tail` command to run for live log streaming.
  This avoids the Erlang BREAK handler intercepting Ctrl+C.

  ## Options

    * `-n` / `--lines` - Number of initial lines to show (default: 100)
    * `--no-follow` - Print recent lines without following
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        aliases: [n: :lines],
        strict: [lines: :integer, follow: :boolean]
      )

    lines = opts[:lines] || 100
    follow? = Keyword.get(opts, :follow, true)
    log_file = Config.log_file()

    unless File.exists?(log_file) do
      Mix.shell().error("Log file not found: #{log_file}")
      Mix.shell().info("Start the server with: mix arbor.start")
      exit({:shutdown, 1})
    end

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().info("Note: Arbor server is not currently running. Showing existing log.\n")
    end

    if follow? do
      Mix.shell().info("""
      Run this command to tail the Arbor server log:

          tail -f -n #{lines} #{log_file}

      Press Ctrl+C to stop.
      """)
    else
      # Non-follow mode: just print the last N lines directly
      case System.cmd("tail", ["-n", to_string(lines), log_file]) do
        {output, 0} -> IO.write(output)
        {_, _} -> Mix.shell().error("Failed to read log file.")
      end
    end
  end
end
