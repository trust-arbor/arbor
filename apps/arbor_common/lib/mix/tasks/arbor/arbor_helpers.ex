defmodule Mix.Tasks.Arbor.Helpers do
  @moduledoc """
  Shared configuration and helpers for Arbor lifecycle mix tasks.

  All `mix arbor.*` tasks use these shared constants and helpers to manage
  the Arbor development server as a background daemon.

  ## Node Naming

  Arbor always uses longnames for Erlang distribution. The node name format is:

      arbor_dev_<node_id>@<host>

  Where:
  - `node_id` is a persistent 4-hex-char identifier stored in `~/.arbor/node_id`
  - `host` is determined by (in priority order):
    1. `ARBOR_NODE_HOST` env var (explicit override)
    2. WireGuard VPN IP (auto-detected from wg0/utun interfaces)
    3. `127.0.0.1` (localhost fallback, no clustering)

  This means:
  - Zero-config local dev works everywhere (any OS, any network)
  - WireGuard VPN enables automatic clustering across machines
  - Node identity is stable across restarts and network changes
  """

  @node_base_name "arbor_dev"
  @pid_file Path.expand("~/.arbor/arbor-dev.pid")
  @log_file Path.expand("~/.arbor/logs/arbor-dev.log")
  @node_id_file Path.expand("~/.arbor/node_id")

  # WireGuard interface names by platform
  @wg_interfaces_linux ["wg0", "wg1", "wg-arbor"]
  # macOS: utun interfaces scanned dynamically (WireGuard utun number varies)

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
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&blank_or_comment?/1)
      |> Enum.each(&parse_and_set_env/1)
    end
  end

  defp blank_or_comment?(""), do: true
  defp blank_or_comment?("#" <> _), do: true
  defp blank_or_comment?(_), do: false

  defp parse_and_set_env(line) do
    line = String.replace_prefix(line, "export ", "")

    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
        unless System.get_env(key), do: System.put_env(key, value)

      _ ->
        :ok
    end
  end

  @doc """
  Returns the persistent node ID (4 hex chars).
  Generated once and stored at `~/.arbor/node_id`.
  """
  def node_id do
    case File.read(@node_id_file) do
      {:ok, content} ->
        String.trim(content)

      {:error, _} ->
        id = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
        File.mkdir_p!(Path.dirname(@node_id_file))
        File.write!(@node_id_file, id)
        id
    end
  end

  def node_name do
    # Safe: node_base_name is a compile-time constant, node_id is hex from crypto
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    String.to_atom("#{@node_base_name}_#{node_id()}")
  end

  @doc """
  Returns the full node name with host.

  Always uses longnames for clustering compatibility:
  - `arbor_dev_a1b2@10.42.42.101` (WireGuard detected)
  - `arbor_dev_a1b2@127.0.0.1` (localhost fallback)
  """
  def full_node_name do
    host = node_hostname()
    # Safe: node_name returns operator-controlled atom, host is detected IP or env var
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{node_name()}@#{host}"
  end

  @doc """
  Always true — Arbor uses longnames for clustering compatibility.
  """
  def longnames?, do: true

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
  Returns the hostname/IP for node names.

  Priority:
  1. `ARBOR_NODE_HOST` env var (explicit override for known-IP scenarios)
  2. WireGuard VPN IP (auto-detected, enables clustering)
  3. `127.0.0.1` (localhost fallback, no clustering)
  """
  def node_hostname do
    cond do
      host = System.get_env("ARBOR_NODE_HOST") ->
        host

      wg_ip = detect_wireguard_ip() ->
        wg_ip

      true ->
        "127.0.0.1"
    end
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
  Always uses longnames for clustering compatibility.
  """
  def ensure_distribution do
    load_dotenv()

    unless Node.alive?() do
      ensure_epmd()
      suffix = :rand.uniform(99_999)
      host = node_hostname()
      # Safe: suffix is bounded integer from :rand, host is detected IP or env var
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"arbor_mix_#{suffix}@#{host}"
      {:ok, _} = Node.start(name, :longnames)
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

  @doc """
  Ensure the Arbor server is running and distribution is started.

  Call this at the top of any mix task that needs the running server.
  Returns the server node name for RPC calls. Exits with error if
  the server isn't running.
  """
  def require_server! do
    ensure_distribution()

    unless server_running?() do
      Mix.shell().error("""
      Arbor server is not running. Start it first:

          mix arbor.start

      This task requires the running server for event persistence,
      agent management, and security enforcement.
      """)

      exit({:shutdown, 1})
    end

    full_node_name()
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

  # --- WireGuard IP Detection ---

  @doc """
  Detect the IP address of an active WireGuard interface.
  Returns nil if no WireGuard interface is found.

  Works on:
  - Linux: checks wg0, wg1, wg-arbor via `ip addr show`
  - macOS: checks utun interfaces via `ifconfig`
  - Android/Termux: same as Linux (uses `ip` command)
  """
  def detect_wireguard_ip do
    case :os.type() do
      {:unix, :darwin} -> detect_wg_macos()
      {:unix, _} -> detect_wg_linux()
      _ -> nil
    end
  end

  defp detect_wg_linux do
    # Try each known WireGuard interface name
    Enum.find_value(@wg_interfaces_linux, fn iface ->
      case System.cmd("ip", ["-4", "addr", "show", iface], stderr_to_stdout: true) do
        {output, 0} -> parse_ip_linux(output)
        _ -> nil
      end
    end)
  end

  defp detect_wg_macos do
    # Strategy 1: Use `wg show interfaces` to find WireGuard's utun
    wg_iface = detect_wg_interface_macos()

    if wg_iface do
      case System.cmd("ifconfig", [wg_iface], stderr_to_stdout: true) do
        {output, 0} -> parse_ip_macos(output)
        _ -> nil
      end
    else
      # Strategy 2: Scan all utun interfaces for point-to-point with private IPv4
      # WireGuard on macOS uses utun* interfaces (number varies)
      scan_utun_interfaces()
    end
  end

  defp detect_wg_interface_macos do
    case System.cmd("wg", ["show", "interfaces"], stderr_to_stdout: true) do
      {output, 0} ->
        iface = output |> String.trim() |> String.split() |> List.first()
        if iface && String.starts_with?(iface, "utun"), do: iface

      _ ->
        nil
    end
  end

  defp scan_utun_interfaces do
    # Parse ifconfig output for all utun interfaces with private IPv4
    case System.cmd("ifconfig", [], stderr_to_stdout: true) do
      {output, 0} ->
        # Split by interface blocks
        output
        |> String.split(~r/^(?=\S)/m)
        |> Enum.find_value(fn block ->
          if String.starts_with?(block, "utun") and
               String.contains?(block, "POINTOPOINT") and
               String.contains?(block, "inet ") do
            case Regex.run(~r/inet\s+(\d+\.\d+\.\d+\.\d+)/, block) do
              [_, ip] when ip != "127.0.0.1" ->
                # Only match private/VPN ranges (10.x, 172.16-31.x, 192.168.x)
                if private_ip?(ip), do: ip

              _ ->
                nil
            end
          end
        end)

      _ ->
        nil
    end
  end

  defp private_ip?(ip) do
    case String.split(ip, ".") |> Enum.map(&String.to_integer/1) do
      [10 | _] -> true
      [172, b | _] when b >= 16 and b <= 31 -> true
      [192, 168 | _] -> true
      _ -> false
    end
  end

  defp parse_ip_linux(output) do
    case Regex.run(~r/inet\s+(\d+\.\d+\.\d+\.\d+)/, output) do
      [_, ip] -> ip
      _ -> nil
    end
  end

  defp parse_ip_macos(output) do
    case Regex.run(~r/inet\s+(\d+\.\d+\.\d+\.\d+)/, output) do
      [_, ip] when ip != "127.0.0.1" -> ip
      _ -> nil
    end
  end
end
