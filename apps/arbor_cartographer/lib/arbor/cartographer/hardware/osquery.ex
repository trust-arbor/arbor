defmodule Arbor.Cartographer.Hardware.Osquery do
  @moduledoc """
  Optional osquery integration for cross-platform hardware detection.

  osquery provides a unified SQL interface to system information across
  macOS, Linux, and Windows. When available, it gives more accurate and
  comprehensive hardware data than platform-specific commands.

  osquery is optional — if `osqueryi` is not found in PATH, all functions
  return `{:error, :not_available}` and the cartographer falls back to
  its built-in detection methods.

  ## Installation

  See https://osquery.io/downloads for platform packages.

  ## Cached Results

  Hardware info is cached for `@cache_ttl_ms` (5 minutes) since it rarely
  changes. Call `clear_cache/0` to force a refresh.
  """

  require Logger

  @cache_ttl_ms :timer.minutes(5)

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Returns true if osqueryi is available on this system.
  """
  @spec available?() :: boolean()
  def available? do
    case cached(:available) do
      {:ok, val} ->
        val

      :miss ->
        val = System.find_executable("osqueryi") != nil
        put_cache(:available, val)
        val
    end
  end

  @doc """
  Detect hardware using osquery. Returns enriched hardware map
  or `{:error, :not_available}` if osquery isn't installed.
  """
  @spec detect() :: {:ok, map()} | {:error, :not_available}
  def detect do
    if available?() do
      case cached(:hardware) do
        {:ok, hw} ->
          {:ok, hw}

        :miss ->
          hw = do_detect()
          put_cache(:hardware, hw)
          {:ok, hw}
      end
    else
      {:error, :not_available}
    end
  end

  @doc "Clear the osquery result cache."
  @spec clear_cache() :: :ok
  def clear_cache do
    for key <- [:available, :hardware] do
      :persistent_term.erase({__MODULE__, :value, key})
      :persistent_term.erase({__MODULE__, :cached_at, key})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Run a raw osquery SQL query. Returns parsed JSON results.
  """
  @spec query(String.t()) :: {:ok, [map()]} | {:error, term()}
  def query(sql) do
    case System.cmd("osqueryi", ["--json", sql], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, rows} when is_list(rows) -> {:ok, rows}
          {:ok, _} -> {:error, :unexpected_format}
          {:error, reason} -> {:error, {:json_parse, reason}}
        end

      {output, code} ->
        {:error, {:exit_code, code, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:command_failed, Exception.message(e)}}
  end

  # ── Detection ───────────────────────────────────────────────────────

  defp do_detect do
    %{}
    |> detect_system_info()
    |> detect_cpu_info()
    |> detect_memory()
    |> detect_os_version()
    |> detect_gpu()
    |> detect_disks()
    |> detect_network_interfaces()
  end

  defp detect_system_info(acc) do
    case query(
           "SELECT hostname, computer_name, cpu_brand, cpu_type, hardware_vendor, hardware_model FROM system_info LIMIT 1"
         ) do
      {:ok, [row | _]} ->
        Map.merge(acc, %{
          hostname: row["hostname"],
          computer_name: row["computer_name"],
          cpu_brand: row["cpu_brand"],
          cpu_type: row["cpu_type"],
          hardware_vendor: row["hardware_vendor"],
          hardware_model: row["hardware_model"]
        })

      _ ->
        acc
    end
  end

  defp detect_cpu_info(acc) do
    case query("SELECT cpu_logical_cores, cpu_physical_cores, cpu_brand FROM cpu_info LIMIT 1") do
      {:ok, [row | _]} ->
        Map.merge(acc, %{
          cpu_logical_cores: parse_int(row["cpu_logical_cores"]),
          cpu_physical_cores: parse_int(row["cpu_physical_cores"]),
          cpu_brand: row["cpu_brand"] || acc[:cpu_brand]
        })

      _ ->
        acc
    end
  end

  defp detect_memory(acc) do
    case query("SELECT physical_memory FROM system_info LIMIT 1") do
      {:ok, [row | _]} ->
        bytes = parse_int(row["physical_memory"])
        Map.put(acc, :memory_gb, bytes / (1024 * 1024 * 1024))

      _ ->
        acc
    end
  end

  defp detect_os_version(acc) do
    case query("SELECT name, version, major, minor, patch, platform FROM os_version LIMIT 1") do
      {:ok, [row | _]} ->
        Map.merge(acc, %{
          os_name: row["name"],
          os_version: row["version"],
          os_platform: row["platform"]
        })

      _ ->
        acc
    end
  end

  defp detect_gpu(acc) do
    # pci_devices with class "Display controller" or "VGA compatible controller"
    sql = """
    SELECT vendor_name, model_name, pci_class
    FROM pci_devices
    WHERE pci_class_id = '0300' OR pci_class_id = '0302'
    """

    case query(sql) do
      {:ok, rows} when rows != [] ->
        gpus =
          Enum.map(rows, fn row ->
            %{
              vendor: row["vendor_name"],
              name: row["model_name"] || row["vendor_name"],
              pci_class: row["pci_class"]
            }
          end)

        Map.put(acc, :gpus, gpus)

      _ ->
        acc
    end
  end

  defp detect_disks(acc) do
    case query(
           "SELECT path, device, blocks_size, blocks, blocks_available, type FROM mounts WHERE type NOT IN ('devfs','autofs','tmpfs','devtmpfs','proc','sysfs','cgroup','cgroup2') AND path NOT LIKE '/System/Volumes/%'"
         ) do
      {:ok, rows} when rows != [] ->
        disks =
          Enum.map(rows, fn row ->
            block_size = parse_int(row["blocks_size"])
            blocks = parse_int(row["blocks"])
            available = parse_int(row["blocks_available"])

            %{
              mount: row["path"],
              device: row["device"],
              type: row["type"],
              size_gb: Float.round(block_size * blocks / (1024 * 1024 * 1024), 1),
              available_gb: Float.round(block_size * available / (1024 * 1024 * 1024), 1)
            }
          end)
          |> Enum.reject(fn d -> d.size_gb == 0.0 end)

        Map.put(acc, :disks, disks)

      _ ->
        acc
    end
  end

  defp detect_network_interfaces(acc) do
    sql = """
    SELECT ia.interface, ia.address, id.mac, id.type
    FROM interface_addresses ia
    JOIN interface_details id ON ia.interface = id.interface
    WHERE ia.address NOT LIKE '127.%'
      AND ia.address NOT LIKE 'fe80:%'
      AND ia.address NOT LIKE '::1'
      AND id.type != 'loopback'
    """

    case query(sql) do
      {:ok, rows} when rows != [] ->
        interfaces =
          Enum.map(rows, fn row ->
            %{
              interface: row["interface"],
              address: row["address"],
              mac: row["mac"],
              type: row["type"]
            }
          end)

        Map.put(acc, :network_interfaces, interfaces)

      _ ->
        acc
    end
  end

  # ── Cache ───────────────────────────────────────────────────────────

  defp cached(key) do
    try do
      value = :persistent_term.get({__MODULE__, :value, key})
      cached_at = :persistent_term.get({__MODULE__, :cached_at, key})

      if System.monotonic_time(:millisecond) - cached_at < @cache_ttl_ms do
        {:ok, value}
      else
        :miss
      end
    rescue
      ArgumentError -> :miss
    end
  end

  defp put_cache(key, value) do
    :persistent_term.put({__MODULE__, :value, key}, value)
    :persistent_term.put({__MODULE__, :cached_at, key}, System.monotonic_time(:millisecond))
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp parse_int(nil), do: 0
  defp parse_int(""), do: 0

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(n) when is_integer(n), do: n
end
