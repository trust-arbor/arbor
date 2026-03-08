defmodule Mix.Tasks.Arbor.Helpers do
  @moduledoc """
  Shared configuration and helpers for Arbor lifecycle mix tasks.

  All `mix arbor.*` tasks use these shared constants and helpers to manage
  the Arbor development server as a background daemon.
  """

  @node_name :arbor_dev
  @pid_file Path.expand("~/.arbor/arbor-dev.pid")
  @log_file Path.expand("~/.arbor/logs/arbor-dev.log")

  @doc """
  Loads .env file from the project root if it exists.
  Only sets variables that aren't already in the environment
  (env vars take precedence over .env).
  """
  def load_dotenv do
    env_file = Path.join(File.cwd!(), ".env")

    if File.exists?(env_file) do
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        unless line == "" or String.starts_with?(line, "#") do
          # Strip leading "export " if present
          line = String.replace_prefix(line, "export ", "")

          case String.split(line, "=", parts: 2) do
            [key, value] ->
              key = String.trim(key)
              value = value |> String.trim() |> String.trim("\"") |> String.trim("'")

              unless System.get_env(key) do
                System.put_env(key, value)
              end

            _ ->
              :skip
          end
        end
      end)
    end
  end

  def node_name, do: @node_name

  @doc """
  Returns the full node name.

  If ARBOR_NODE_HOST is set, uses longnames (e.g. arbor_dev@10.0.0.1).
  Otherwise uses shortnames (arbor_dev@localhost).
  """
  def full_node_name do
    host = node_hostname()
    # Safe: node_name is a compile-time constant, host is operator-controlled env var
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{@node_name}@#{host}"
  end

  @doc """
  Returns true if using longnames (IP/FQDN), false for shortnames (localhost).
  """
  def longnames? do
    System.get_env("ARBOR_NODE_HOST") != nil
  end

  def cookie do
    case System.get_env("ARBOR_COOKIE") do
      nil ->
        Mix.raise("""
        ARBOR_COOKIE environment variable is required but not set.

        Set it to a random secret value:

            export ARBOR_COOKIE="$(openssl rand -hex 32)"

        Or add it to your shell profile for persistence.
        """)

      value ->
        # Safe: ARBOR_COOKIE is operator-controlled, not user input.
        # Erlang distribution cookies must be atoms, and each unique cookie
        # value is set once per node lifetime.
        # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
        String.to_atom(value)
    end
  end

  def pid_file, do: @pid_file
  def log_file, do: @log_file

  @doc """
  Returns the hostname used for node names.

  Set ARBOR_NODE_HOST to an IP or FQDN for cross-machine clustering.
  Defaults to "localhost" for local development.
  """
  def node_hostname do
    System.get_env("ARBOR_NODE_HOST", "localhost")
  end

  @doc "Checks if the server node is responding to pings."
  def server_running? do
    :net_adm.ping(full_node_name()) == :pong
  end

  @doc "Reads the OS PID from the PID file, or returns nil."
  def read_pid do
    case File.read(@pid_file) do
      {:ok, content} ->
        content |> String.trim() |> String.to_integer()

      _ ->
        nil
    end
  end

  @doc """
  Ensures the current Mix process has distribution started so it can
  communicate with the server node via `:net_adm` and `:rpc`.

  Uses a unique name to avoid conflicts with the server node.
  """
  def ensure_distribution do
    load_dotenv()

    unless Node.alive?() do
      ensure_epmd()
      suffix = :rand.uniform(99_999)
      host = node_hostname()
      name_type = if longnames?(), do: :longnames, else: :shortnames
      # Safe: suffix is bounded integer from :rand, host is operator-controlled env var
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"arbor_mix_#{suffix}@#{host}"
      {:ok, _} = Node.start(name, name_type)
      Node.set_cookie(cookie())
    end

    :ok
  end

  defp ensure_epmd do
    case System.cmd("epmd", ["-names"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      _ ->
        System.cmd("epmd", ["-daemon"])
        Process.sleep(500)
        :ok
    end
  end

  @doc "Makes an RPC call, returning nil on badrpc."
  def rpc(node, mod, fun, args) do
    case :rpc.call(node, mod, fun, args) do
      {:badrpc, _reason} -> nil
      result -> result
    end
  end

  @doc "Makes an RPC call, raising on failure."
  def rpc!(node, mod, fun, args) do
    case :rpc.call(node, mod, fun, args) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")
        exit({:shutdown, 1})

      result ->
        result
    end
  end
end
