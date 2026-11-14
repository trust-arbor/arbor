defmodule Mix.Tasks.Arbor.Attach do
  use Boundary, classify_to: Arbor.KernelRuntime.DevTools
  @shortdoc "Attach an IEx session to the running Arbor server"
  @moduledoc """
  Prints the command to attach an IEx remote shell to the running Arbor server.

      $ mix arbor.attach

  Since interactive sessions require a TTY, this task prints the `iex --remsh`
  command for you to run directly in your terminal.

  ## Why the attach client keeps a private HOME

  The daemon no longer redirects HOME (see `mix help arbor.start`), but this
  client still boots with `HOME=~/.arbor/distribution`. A remote shell must be
  distributed from the first instant, and OTP gives a boot-time node its cookie
  only from argv (visible in `ps`) or from `$HOME/.erlang.cookie`. The private
  HOME is the second channel. It is safe here because the client runs no
  Arbor code and loads no Arbor configuration: every expression is evaluated
  on the daemon, which resolves `~` to the real HOME. Locally, only IEx's
  `~/.iex.exs` lookup and shell history see the private HOME.

  The client starts with `-dist_listen false -hidden`: it dials the daemon and
  accepts no connections of its own.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    hostname = Config.node_hostname()

    suffix = :rand.uniform(99_999)
    attach_name = "arbor_attach_#{suffix}@#{hostname}"
    remote_node = "#{Config.node_name()}@#{hostname}"

    cookie_home =
      case Config.prepare_distribution_cookie(Config.cookie()) do
        {:ok, path} -> path
        {:error, reason} -> Mix.raise("Could not prepare distribution cookie: #{inspect(reason)}")
      end

    cmd =
      attach_command(%{
        attach_name: attach_name,
        remote_node: remote_node,
        cookie_home: cookie_home,
        iex_path: Config.elixir_executable("iex"),
        erlang_bin_dir: Config.erlang_bin_dir()
      })

    Mix.shell().info("""

    Run this command to attach to the Arbor server:

        #{cmd}

    Detach with Ctrl+C, Ctrl+C (this won't stop the server).
    """)
  end

  @doc false
  @spec attach_command(map()) :: String.t()
  def attach_command(%{
        attach_name: attach_name,
        remote_node: remote_node,
        cookie_home: cookie_home,
        iex_path: iex_path,
        erlang_bin_dir: erlang_bin_dir
      }) do
    [
      "PATH=#{shell_quote(erlang_bin_dir)}:\"$PATH\"",
      "HOME=#{shell_quote(cookie_home)}",
      "ERL_AFLAGS=''",
      "ERL_FLAGS=''",
      "ERL_ZFLAGS=''",
      "ELIXIR_ERL_OPTIONS=''",
      shell_quote(iex_path),
      "--erl",
      shell_quote("-dist_listen false -hidden"),
      "--name",
      shell_quote(attach_name),
      "--remsh",
      shell_quote(remote_node)
    ]
    |> Enum.join(" ")
  end

  def attach_command(_), do: raise(ArgumentError, "invalid attach command specification")

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
