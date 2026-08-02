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
    2. First local IPv4 matching `ARBOR_CLUSTER_SUBNETS` (comma-separated CIDRs)
    3. WireGuard VPN IP (auto-detected from wg0/utun interfaces)
    4. `127.0.0.1` (localhost fallback, no clustering)

  This means:
  - Zero-config local dev works everywhere (any OS, any network)
  - `ARBOR_CLUSTER_SUBNETS=10.42.42.0/24,10.42.43.0/24` lets the operator pin
    the cluster's address ranges; mix tasks pick the right local IP on any
    interface (en0, wifi, utun) without further input. List order is priority:
    put LAN before VPN so the direct path wins when both are present.
  - WireGuard VPN auto-detect remains as a zero-config fallback for the legacy
    case where the cluster is *only* on wg/utun interfaces.
  - Node identity is stable across restarts and network changes.
  """

  alias Mix.Tasks.Arbor.LifecycleIdentity

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

  def log_file, do: @log_file

  # ─── Persisted managed-node identity ───────────────────────────────────
  #
  # `~/.arbor/arbor-dev.meta.json` records the exact node/host/pid of the
  # daemon this machine's `mix arbor.start` actually launched, so status/
  # stop/restart resolve the real running identity instead of a freshly
  # re-detected host (the 2026-08-02 host-drift EPMD-collision incident).
  # The legacy `arbor-dev.pid` file is preserved unchanged for back-compat.
  #
  # Every read here distinguishes "file genuinely does not exist" (ENOENT —
  # `:absent`) from any other read failure or unparseable content
  # (permission denied, I/O error, a directory in the file's place,
  # non-numeric PID contents, …), which is `{:error, :malformed}` —
  # ambiguous, fail-closed, and never silently treated as "nothing here."

  @metadata_file_name "arbor-dev.meta.json"
  @pid_file_name "arbor-dev.pid"
  @lock_dir_name "arbor-dev.lock"
  @max_argv_bytes 8192

  def arbor_home, do: Path.expand("~/.arbor")

  def pid_file(home \\ arbor_home()), do: Path.join(home, @pid_file_name)
  def metadata_file(home \\ arbor_home()), do: Path.join(home, @metadata_file_name)
  def lock_dir(home \\ arbor_home()), do: Path.join(home, @lock_dir_name)

  @doc """
  Reads and validates the persisted metadata record. Returns `:absent` only
  when the file genuinely does not exist, or `{:error, :malformed}` when it
  exists but fails to read cleanly, fails syntactic parsing, or fails local
  node-identity cross-validation — that state is distinct from `:absent`
  and must never be silently overwritten.
  """
  def read_metadata(home \\ arbor_home()) do
    case File.read(metadata_file(home)) do
      {:ok, raw} ->
        with {:ok, meta} <- LifecycleIdentity.parse_metadata(raw),
             :ok <- LifecycleIdentity.validate_metadata_identity(meta, node_id()) do
          {:ok, meta}
        else
          {:error, :malformed} -> {:error, :malformed}
        end

      {:error, :enoent} ->
        :absent

      {:error, _reason} ->
        {:error, :malformed}
    end
  end

  @doc """
  Reads the legacy OS PID file. Returns `:absent` only when the file
  genuinely does not exist, `{:error, :malformed}` when it exists but
  can't be read cleanly or its content isn't a bare positive integer
  (never raises — a corrupted PID file must not crash the caller), or
  `{:ok, pid}` on a well-formed value.
  """
  def read_pid(home \\ arbor_home()) do
    case File.read(pid_file(home)) do
      {:ok, content} ->
        case content |> String.trim() |> Integer.parse() do
          {pid, ""} when pid > 0 -> {:ok, pid}
          _ -> {:error, :malformed}
        end

      {:error, :enoent} ->
        :absent

      {:error, _reason} ->
        {:error, :malformed}
    end
  end

  @doc "Atomically publishes the managed-node metadata record (tmp write + rename)."
  def write_metadata!(meta, home \\ arbor_home()) do
    atomic_write!(metadata_file(home), LifecycleIdentity.encode_metadata(meta))
  end

  defp atomic_write!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  @doc "Existence probe only (`kill -0`) — delivers no signal, safe against any PID."
  def pid_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end

  @doc """
  Verifies whether `pid` is a live Arbor node managed by this machine, via a
  bounded, exact argv check (never a substring match) — see
  `LifecycleIdentity.parse_arbor_node_from_argv/2`. Returns `:unverified` on
  any read/parse ambiguity so callers fail closed rather than guess.
  """
  def verify_pid_as_arbor_node(pid) do
    if pid_alive?(pid) do
      case System.cmd("ps", ["-ww", "-o", "args=", "-p", to_string(pid)], stderr_to_stdout: true) do
        {argv, 0} when byte_size(argv) <= @max_argv_bytes ->
          LifecycleIdentity.parse_arbor_node_from_argv(argv, node_id())

        _ ->
          :unverified
      end
    else
      :no_such_process
    end
  end

  @doc """
  Revalidates `pid`'s exact argv identity as `expected_node` immediately
  before delivering `signal`, and only signals when that fresh recheck
  matches — binding PID and expected node identity together at the actual
  effect boundary rather than at an earlier decision point. This is the
  only call site in this codebase that ever delivers `kill <pid>` (not
  `kill -0`); Start and Stop both route every signal through it.
  """
  @spec signal_if_verified(pos_integer(), String.t(), :sigterm) ::
          {:signaled, LifecycleIdentity.pid_check()} | {:refused, LifecycleIdentity.pid_check()}
  def signal_if_verified(pid, expected_node, :sigterm) do
    check = verify_pid_as_arbor_node(pid)

    case LifecycleIdentity.decide_signal_authorization(check, expected_node) do
      :safe_to_signal ->
        System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)
        {:signaled, check}

      :preserve_evidence ->
        {:refused, check}
    end
  end

  @doc """
  Polls until `pid` is no longer alive, or `timeout_ms` elapses. Never
  signals anything — existence probing only (`pid_alive?/1`, `kill -0`).
  """
  @spec await_exit?(pos_integer(), non_neg_integer(), pos_integer()) :: boolean()
  def await_exit?(pid, timeout_ms, poll_interval_ms \\ 250)

  def await_exit?(pid, timeout_ms, _poll_interval_ms) when timeout_ms <= 0 do
    not pid_alive?(pid)
  end

  def await_exit?(pid, timeout_ms, poll_interval_ms) do
    if pid_alive?(pid) do
      Process.sleep(poll_interval_ms)
      await_exit?(pid, timeout_ms - poll_interval_ms, poll_interval_ms)
    else
      true
    end
  end

  @doc "Pings a node given as a validated `arbor_dev_<id>@<host>` string."
  def node_alive?(node_string) do
    :net_adm.ping(node_atom(node_string)) == :pong
  end

  @doc "Converts a validated node-identity string to its distribution atom."
  # Safe: only ever called with a value already matched against the
  # arbor_dev_<hex>@<host> shape by LifecycleIdentity parse/validate
  # functions — never raw operator or file input.
  # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
  def node_atom(node_string), do: String.to_atom(node_string)

  # --- Exclusive lifecycle lock -------------------------------------------
  #
  # `File.mkdir/1` is the OS-atomic exclusivity primitive: exactly one
  # concurrent caller succeeds. The winner records its OS pid + a random
  # token; release only deletes when the on-disk token still matches ours,
  # so external/manual recovery cannot make an old owner tear down a newly
  # acquired lock generation.
  #
  # Stale locks are deliberately not reclaimed automatically. A contender
  # can prove that the recorded owner is dead, but no portable File API can
  # atomically prove that the directory at this reusable path is still the
  # same generation it observed before deleting or renaming it. A delayed
  # contender could otherwise remove a new owner's lock. The safe recovery
  # is an explicit operator inspection/removal followed by a fresh command.

  @doc "Acquires the exclusive lifecycle lock, refusing stale or ambiguous owners."
  def acquire_lock(home \\ arbor_home()) do
    dir = lock_dir(home)
    owner_path = Path.join(dir, "owner.json")

    case File.mkdir(dir) do
      :ok ->
        token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

        case File.write(
               owner_path,
               LifecycleIdentity.encode_lock_owner(self_os_pid(), token)
             ) do
          :ok ->
            {:ok, token}

          {:error, reason} ->
            File.rm_rf(dir)
            {:refuse, :lock_io_error, %{reason: reason}}
        end

      {:error, :eexist} ->
        owner = read_lock_owner(owner_path)
        alive? = lock_owner_alive?(owner)
        LifecycleIdentity.decide_lock_step(%{owner: owner, owner_pid_alive?: alive?})

      {:error, reason} ->
        {:refuse, :lock_io_error, %{reason: reason}}
    end
  end

  defp lock_owner_alive?({:ok, %{pid: pid}}), do: pid_alive?(pid)
  defp lock_owner_alive?(_), do: :unverified

  defp read_lock_owner(owner_path) do
    case File.read(owner_path) do
      {:ok, raw} -> LifecycleIdentity.parse_lock_owner(raw)
      {:error, _} -> :absent
    end
  end

  @doc "Releases the lock only if `token` still matches the recorded owner."
  def release_lock(home \\ arbor_home(), token) do
    dir = lock_dir(home)
    owner_path = Path.join(dir, "owner.json")

    case read_lock_owner(owner_path) do
      {:ok, %{pid: pid, token: ^token}} ->
        if pid == self_os_pid() do
          File.rm(owner_path)
          File.rmdir(dir)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp self_os_pid, do: System.pid() |> String.to_integer()

  @doc "Runs `fun` while holding the exclusive lifecycle lock; always releases it."
  def with_lock(fun, home \\ arbor_home()) do
    case acquire_lock(home) do
      {:ok, token} ->
        try do
          fun.()
        after
          release_lock(home, token)
        end

      {:refuse, _reason, _detail} = refusal ->
        refusal
    end
  end

  @doc "Human-readable message for a lock-acquisition refusal."
  def describe_lock_refusal(:held_by, pid) do
    "Another arbor lifecycle command (pid #{pid}) is already in progress. " <>
      "Wait for it to finish, or investigate if it appears stuck."
  end

  def describe_lock_refusal(:ambiguous_lock, _detail) do
    "Cannot verify the lifecycle lock owner; refusing to proceed. " <>
      "Inspect #{lock_dir()} manually if this persists."
  end

  def describe_lock_refusal(:stale_lock, %{pid: pid}) do
    "The lifecycle lock records dead owner pid #{pid}. Refusing automatic " <>
      "reclamation because the lock path may have been replaced; inspect and " <>
      "remove #{lock_dir()} manually, then retry."
  end

  def describe_lock_refusal(:lock_io_error, %{reason: reason}) do
    "Could not acquire the lifecycle lock (#{inspect(reason)})."
  end

  @doc """
  Ensure the runtime directories for the pid + log files exist.

  On a fresh node (e.g. a brand-new Proxmox host) `~/.arbor/logs` doesn't exist
  yet, so the background launch's `> #{@log_file}` shell redirect fails with
  "cannot create … : Directory nonexistent". Create both parents up front;
  `mkdir -p` semantics make this idempotent. (`Path.dirname(@log_file)` also
  creates `~/.arbor`, covering the pid file, but we ensure both explicitly.)
  """
  @spec ensure_runtime_dirs() :: :ok
  def ensure_runtime_dirs do
    File.mkdir_p!(Path.dirname(@log_file))
    File.mkdir_p!(Path.dirname(@pid_file))
    :ok
  end

  @doc """
  Returns the hostname/IP for node names.

  Priority:
  1. `ARBOR_NODE_HOST` env var (explicit override for known-IP scenarios)
  2. First local IPv4 matching one of `ARBOR_CLUSTER_SUBNETS` (in list order)
  3. WireGuard VPN IP (auto-detected utun/wg* interface; legacy fallback)
  4. `127.0.0.1` (localhost fallback, no clustering)
  """
  def node_hostname do
    cond do
      host = System.get_env("ARBOR_NODE_HOST") ->
        host

      ip = detect_ip_in_cluster_subnets() ->
        ip

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

  # ─── Cluster-subnet IP detection ───────────────────────────────────────────
  #
  # Reads ARBOR_CLUSTER_SUBNETS (comma-separated CIDRs), scans local IPv4
  # addresses via :inet.getifaddrs/0, returns the first IP matching a subnet
  # in declaration order. Cross-platform — no shelling out to ifconfig.

  @doc """
  Returns a local IPv4 string in one of the configured cluster subnets, or nil.

  Reads `ARBOR_CLUSTER_SUBNETS` (e.g. `"10.42.42.0/24,10.42.43.0/24"`). Returns
  nil if the env var is unset or empty, or if no local interface matches.
  """
  def detect_ip_in_cluster_subnets do
    case parse_cluster_subnets() do
      [] ->
        nil

      subnets ->
        ips = local_ipv4_addresses()

        Enum.find_value(subnets, fn subnet ->
          Enum.find_value(ips, fn ip ->
            if ip_in_subnet?(ip, subnet), do: format_ipv4(ip)
          end)
        end)
    end
  end

  defp parse_cluster_subnets do
    case System.get_env("ARBOR_CLUSTER_SUBNETS") do
      nil ->
        []

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_cidr/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp parse_cidr(cidr) do
    with [base, prefix] <- String.split(cidr, "/", parts: 2),
         {:ok, addr} <- :inet.parse_ipv4_address(String.to_charlist(base)),
         {prefix_int, ""} <- Integer.parse(prefix),
         true <- prefix_int in 0..32 do
      {addr, prefix_int}
    else
      _ -> nil
    end
  end

  defp local_ipv4_addresses do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        for {_iface, props} <- ifaces,
            {:addr, addr} <- props,
            tuple_size(addr) == 4,
            addr != {127, 0, 0, 1},
            do: addr

      _ ->
        []
    end
  end

  defp ip_in_subnet?({a, b, c, d}, {{ba, bb, bc, bd}, prefix}) do
    import Bitwise, only: [band: 2, bnot: 1, bsl: 2]
    ip_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
    base_int = bsl(ba, 24) + bsl(bb, 16) + bsl(bc, 8) + bd

    mask =
      if prefix == 0 do
        0
      else
        band(bnot(bsl(1, 32 - prefix) - 1), 0xFFFFFFFF)
      end

    band(ip_int, mask) == band(base_int, mask)
  end

  defp format_ipv4({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
