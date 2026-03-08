defmodule Arbor.Cartographer.Hardware do
  @moduledoc """
  Hardware detection for the current node.

  Provides comprehensive hardware introspection including:
  - CPU architecture and count
  - Memory capacity
  - GPU detection (NVIDIA, AMD, Intel)
  - Accelerator detection (Coral TPU, Intel NCS)

  ## Detection Methods

  When osquery is installed, it provides unified cross-platform detection
  (macOS, Linux, Windows). Otherwise falls back to platform-specific methods:

  | Hardware | osquery | macOS | Linux | Windows |
  |----------|---------|-------|-------|---------|
  | Architecture | - | `:system_info` | `:system_info` | `:system_info` |
  | CPU Info | `cpu_info` | `sysctl` | `/proc` | `system_info` |
  | Memory | `system_info` | `sysctl` | `/proc/meminfo` | BEAM fallback |
  | GPU | `pci_devices` | `system_profiler` | `nvidia-smi`/`rocm-smi` | - |
  | Disks | `mounts` | - | - | - |
  | Network | `interface_addresses` | - | - | - |
  | OS Version | `os_version` | - | - | - |
  | Coral TPU | - | `/dev/apex_*` | `/dev/apex_*` | - |

  ## Examples

      {:ok, info} = Arbor.Cartographer.Hardware.detect()
      #=> {:ok, %{
      #     arch: :arm64,
      #     cpus: 10,
      #     memory_gb: 32.0,
      #     gpu: [%{type: :apple, name: "Apple M1 Pro", vram_gb: 16.0}],
      #     accelerators: []
      #   }}

      tags = Arbor.Cartographer.Hardware.to_capability_tags(info)
      #=> [:arm64, :high_memory, :gpu, :apple_gpu]
  """

  alias Arbor.Contracts.Libraries.Cartographer, as: Contract

  @type hardware_info :: Contract.hardware_info()
  @type gpu_info :: Contract.gpu_info()
  @type accelerator_info :: Contract.accelerator_info()

  @high_memory_threshold_gb 32
  @high_vram_threshold_gb 24

  @doc """
  Detect all hardware capabilities of the current node.

  Returns a comprehensive hardware information map.
  """
  @spec detect() :: {:ok, hardware_info()}
  def detect do
    alias Arbor.Cartographer.Hardware.Osquery

    base = %{
      arch: detect_arch(),
      cpus: detect_cpus(),
      memory_gb: detect_memory_gb(),
      gpu: detect_gpus(),
      accelerators: detect_accelerators()
    }

    # Enrich with osquery data when available
    info =
      case Osquery.detect() do
        {:ok, osq} -> enrich_with_osquery(base, osq)
        _ -> base
      end

    # Add Android-specific info when on Android
    info =
      if android?() do
        Map.put(info, :android, detect_android())
      else
        info
      end

    {:ok, info}
  end

  defp enrich_with_osquery(base, osq) do
    base
    # Prefer osquery system memory over BEAM memory fallback
    |> maybe_update(:memory_gb, osq[:memory_gb])
    # Add CPU brand info
    |> maybe_put(:cpu_brand, osq[:cpu_brand])
    |> maybe_put(:cpu_physical_cores, osq[:cpu_physical_cores])
    # Add system identity
    |> maybe_put(:hostname, osq[:hostname])
    |> maybe_put(:hardware_vendor, osq[:hardware_vendor])
    |> maybe_put(:hardware_model, osq[:hardware_model])
    # Add OS info
    |> maybe_put(:os_name, osq[:os_name])
    |> maybe_put(:os_version, osq[:os_version])
    |> maybe_put(:os_platform, osq[:os_platform])
    # Add disk and network info
    |> maybe_put(:disks, osq[:disks])
    |> maybe_put(:network_interfaces, osq[:network_interfaces])
    # Enrich GPU list with osquery PCI data if we had no GPUs detected
    |> enrich_gpu(osq[:gpus])
  end

  defp maybe_update(map, key, value) when is_number(value) and value > 0,
    do: Map.put(map, key, value)

  defp maybe_update(map, _key, _value), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp enrich_gpu(base, nil), do: base
  defp enrich_gpu(base, []), do: base

  defp enrich_gpu(base, osq_gpus) do
    # Only add osquery GPU data if we didn't already detect GPUs
    case base.gpu do
      nil ->
        gpus =
          Enum.map(osq_gpus, fn g ->
            %{type: gpu_type_from_vendor(g[:vendor]), name: g[:name], vram_gb: 0.0}
          end)

        Map.put(base, :gpu, gpus)

      _ ->
        base
    end
  end

  defp gpu_type_from_vendor(nil), do: :unknown

  defp gpu_type_from_vendor(vendor) do
    vendor_lower = String.downcase(vendor)

    cond do
      String.contains?(vendor_lower, "nvidia") -> :nvidia
      String.contains?(vendor_lower, "amd") or String.contains?(vendor_lower, "ati") -> :amd
      String.contains?(vendor_lower, "intel") -> :intel
      String.contains?(vendor_lower, "apple") -> :apple
      true -> :unknown
    end
  end

  @doc """
  Convert hardware info to capability tags.

  ## Tags Generated

  - Architecture: `:x86_64`, `:arm64`, `:arm32`
  - Memory: `:high_memory` if >= 32GB
  - GPU: `:gpu`, `:nvidia_gpu`, `:amd_gpu`, `:intel_gpu`, `:apple_gpu`
  - VRAM: `:gpu_vram_24gb` if any GPU has >= 24GB
  - Accelerators: `:coral_tpu`, `:intel_ncs`
  """
  @spec to_capability_tags(hardware_info()) :: [atom()]
  def to_capability_tags(hardware_info) do
    tags =
      []
      |> add_arch_tag(hardware_info.arch)
      |> add_memory_tags(hardware_info.memory_gb)
      |> add_gpu_tags(hardware_info.gpu)
      |> add_accelerator_tags(hardware_info.accelerators)

    # Add Android-specific tags
    tags =
      case Map.get(hardware_info, :android) do
        nil -> tags
        android_info -> tags ++ android_capability_tags(android_info)
      end

    Enum.uniq(tags)
  end

  # ==========================================================================
  # Architecture Detection
  # ==========================================================================

  @doc """
  Detect the CPU architecture.
  """
  @spec detect_arch() :: :x86_64 | :arm64 | :arm32 | :unknown
  def detect_arch do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "x86_64" <> _ -> :x86_64
      "amd64" <> _ -> :x86_64
      "aarch64" <> _ -> :arm64
      "arm64" <> _ -> :arm64
      "arm" <> _ -> :arm32
      _ -> :unknown
    end
  end

  # ==========================================================================
  # CPU Detection
  # ==========================================================================

  @doc """
  Detect the number of online schedulers (logical CPUs).
  """
  @spec detect_cpus() :: non_neg_integer()
  def detect_cpus do
    System.schedulers_online()
  end

  # ==========================================================================
  # Memory Detection
  # ==========================================================================

  @doc """
  Detect total system memory in gigabytes.

  Uses `/proc/meminfo` on Linux for accurate system total.
  Falls back to BEAM memory on other platforms.
  """
  @spec detect_memory_gb() :: float()
  def detect_memory_gb do
    if android?() do
      detect_android_memory_gb()
    else
      case :os.type() do
        {:unix, :linux} -> detect_linux_memory_gb()
        {:unix, :darwin} -> detect_macos_memory_gb()
        {:win32, _} -> detect_windows_memory_gb()
        _ -> beam_memory_gb()
      end
    end
  end

  defp detect_linux_memory_gb do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, content) do
          [_, kb_str] ->
            kb = String.to_integer(kb_str)
            kb / 1024 / 1024

          _ ->
            beam_memory_gb()
        end

      {:error, _} ->
        beam_memory_gb()
    end
  end

  defp detect_macos_memory_gb do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {bytes, _} -> bytes / (1024 * 1024 * 1024)
          :error -> beam_memory_gb()
        end

      _ ->
        beam_memory_gb()
    end
  rescue
    _ -> beam_memory_gb()
  end

  defp detect_windows_memory_gb do
    # Use PowerShell to get total physical memory
    case System.cmd(
           "powershell",
           ["-Command", "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {bytes, _} -> bytes / (1024 * 1024 * 1024)
          :error -> beam_memory_gb()
        end

      _ ->
        beam_memory_gb()
    end
  rescue
    _ -> beam_memory_gb()
  end

  defp beam_memory_gb do
    :erlang.memory(:total) / (1024 * 1024 * 1024)
  end

  # ==========================================================================
  # GPU Detection
  # ==========================================================================

  @doc """
  Detect all GPUs on the system.

  Returns a list of GPU info maps or nil if no GPUs detected.
  """
  @spec detect_gpus() :: [gpu_info()] | nil
  def detect_gpus do
    gpus =
      []
      |> detect_nvidia_gpus()
      |> detect_amd_gpus()
      |> detect_apple_gpus()
      |> detect_intel_gpus()

    case gpus do
      [] -> nil
      list -> list
    end
  end

  defp detect_nvidia_gpus(acc) do
    case run_command("nvidia-smi", [
           "--query-gpu=name,memory.total",
           "--format=csv,noheader,nounits"
         ]) do
      {:ok, output} ->
        gpus =
          output
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&parse_nvidia_gpu/1)
          |> Enum.reject(&is_nil/1)

        acc ++ gpus

      {:error, _} ->
        acc
    end
  end

  defp parse_nvidia_gpu(line) do
    case String.split(line, ", ") do
      [name, vram_mb] ->
        case Float.parse(vram_mb) do
          {vram, _} ->
            %{
              type: :nvidia,
              name: String.trim(name),
              vram_gb: vram / 1024
            }

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  defp detect_amd_gpus(acc) do
    case run_command("rocm-smi", ["--showproductname", "--showmeminfo", "vram"]) do
      {:ok, output} ->
        # Parse rocm-smi output (format varies by version)
        gpus = parse_rocm_output(output)
        acc ++ gpus

      {:error, _} ->
        acc
    end
  end

  defp parse_rocm_output(output) do
    # Simple parsing - rocm-smi format can vary
    lines = String.split(output, "\n")

    # Look for GPU name and VRAM info
    name =
      Enum.find_value(lines, "AMD GPU", fn line ->
        if String.contains?(line, "Card series"), do: extract_card_name(line)
      end)

    vram_gb =
      Enum.find_value(lines, 0.0, fn line ->
        if String.contains?(line, "VRAM Total"), do: extract_vram_mb(line)
      end)

    if vram_gb > 0 do
      [%{type: :amd, name: name, vram_gb: vram_gb}]
    else
      []
    end
  end

  defp extract_card_name(line) do
    case String.split(line, ":") do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp extract_vram_mb(line) do
    case Regex.run(~r/(\d+)\s*MB/, line) do
      [_, mb] -> String.to_integer(mb) / 1024
      _ -> 0.0
    end
  end

  defp detect_apple_gpus(acc) do
    with {:unix, :darwin} <- :os.type(),
         {:ok, output} <- run_command("system_profiler", ["SPDisplaysDataType", "-json"]) do
      acc ++ parse_apple_gpu_json(output)
    else
      _ -> acc
    end
  end

  defp parse_apple_gpu_json(json_output) do
    case Jason.decode(json_output) do
      {:ok, %{"SPDisplaysDataType" => displays}} ->
        Enum.flat_map(displays, &parse_apple_display/1)

      _ ->
        []
    end
  end

  defp parse_apple_display(display) do
    name = Map.get(display, "sppci_model", "Apple GPU")
    vram = resolve_apple_vram(Map.get(display, "spdisplays_vram"))
    [%{type: :apple, name: name, vram_gb: vram}]
  end

  defp resolve_apple_vram(vram_str) when is_binary(vram_str), do: parse_vram_string(vram_str)
  defp resolve_apple_vram(_), do: estimate_apple_silicon_vram()

  defp parse_vram_string(vram_str) do
    cond do
      String.contains?(vram_str, "GB") ->
        case Regex.run(~r/(\d+(?:\.\d+)?)\s*GB/, vram_str) do
          [_, gb] -> parse_float(gb)
          _ -> 0.0
        end

      String.contains?(vram_str, "MB") ->
        case Regex.run(~r/(\d+)\s*MB/, vram_str) do
          [_, mb] -> String.to_integer(mb) / 1024
          _ -> 0.0
        end

      true ->
        0.0
    end
  end

  defp estimate_apple_silicon_vram do
    # Apple Silicon uses unified memory, GPU can use ~70% for graphics workloads
    total_memory = detect_memory_gb()
    Float.round(total_memory * 0.7, 1)
  end

  defp detect_intel_gpus(acc) do
    # Intel integrated GPU detection via /sys on Linux
    with {:unix, :linux} <- :os.type(),
         {:ok, entries} <- File.ls("/sys/class/drm"),
         true <- has_intel_cards?(entries) do
      acc ++ [%{type: :intel, name: "Intel Integrated Graphics", vram_gb: 0.0}]
    else
      _ -> acc
    end
  end

  defp has_intel_cards?(entries) do
    Enum.any?(entries, fn card ->
      String.starts_with?(card, "card") &&
        intel_vendor?("/sys/class/drm/#{card}/device/vendor")
    end)
  end

  # ==========================================================================
  # Accelerator Detection
  # ==========================================================================

  @doc """
  Detect hardware accelerators (TPUs, neural compute sticks).
  """
  @spec detect_accelerators() :: [accelerator_info()]
  def detect_accelerators do
    []
    |> detect_coral_tpu()
    |> detect_intel_ncs()
  end

  defp detect_coral_tpu(acc) do
    # Check for Coral TPU devices
    coral_devices = find_devices("/dev", ~r/^apex_\d+$/)

    if coral_devices != [] do
      tpus =
        Enum.map(coral_devices, fn device ->
          %{type: :coral_tpu, device: device}
        end)

      acc ++ tpus
    else
      acc
    end
  end

  defp detect_intel_ncs(acc) do
    # Intel Neural Compute Stick detection
    # Typically appears as a Movidius USB device
    case run_command("lsusb", []) do
      {:ok, output} ->
        if String.contains?(output, "Movidius") or
             String.contains?(output, "Intel Neural Compute Stick") do
          acc ++ [%{type: :intel_ncs, device: nil}]
        else
          acc
        end

      {:error, _} ->
        acc
    end
  end

  defp find_devices(dir, pattern) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(pattern, &1))
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp intel_vendor?(vendor_path) do
    case File.read(vendor_path) do
      {:ok, content} -> String.contains?(content, "0x8086")
      _ -> false
    end
  end

  # ==========================================================================
  # Tag Generation
  # ==========================================================================

  defp add_arch_tag(tags, :x86_64), do: [:x86_64 | tags]
  defp add_arch_tag(tags, :arm64), do: [:arm64 | tags]
  defp add_arch_tag(tags, :arm32), do: [:arm32 | tags]
  defp add_arch_tag(tags, _), do: tags

  defp add_memory_tags(tags, memory_gb) when memory_gb >= @high_memory_threshold_gb do
    [:high_memory | tags]
  end

  defp add_memory_tags(tags, _), do: tags

  defp add_gpu_tags(tags, nil), do: tags

  defp add_gpu_tags(tags, gpus) when is_list(gpus) do
    gpu_tags =
      Enum.flat_map(gpus, fn gpu ->
        base_tags = [:gpu, gpu_type_tag(gpu.type)]

        vram_tags =
          if gpu.vram_gb >= @high_vram_threshold_gb do
            [:gpu_vram_24gb]
          else
            []
          end

        base_tags ++ vram_tags
      end)

    gpu_tags ++ tags
  end

  defp gpu_type_tag(:nvidia), do: :nvidia_gpu
  defp gpu_type_tag(:amd), do: :amd_gpu
  defp gpu_type_tag(:intel), do: :intel_gpu
  defp gpu_type_tag(:apple), do: :apple_gpu
  defp gpu_type_tag(_), do: :gpu

  defp add_accelerator_tags(tags, []), do: tags

  defp add_accelerator_tags(tags, accelerators) do
    accel_tags = Enum.map(accelerators, & &1.type)
    accel_tags ++ tags
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp run_command(cmd, args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, :not_found}

      path ->
        try do
          # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
          case System.cmd(path, args, stderr_to_stdout: true) do
            {output, 0} -> {:ok, output}
            {output, _} -> {:error, {:exit_code, output}}
          end
        rescue
          e -> {:error, e}
        end
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  # ==========================================================================
  # Android Detection
  # ==========================================================================

  @doc """
  Check if running on Android (Termux/BEAM app).

  Detects via the `:android` module (present on phone BEAM nodes)
  or the `ANDROID_ROOT` environment variable.
  """
  @spec android?() :: boolean()
  def android? do
    Code.ensure_loaded?(:android) or System.get_env("ANDROID_ROOT") != nil
  end

  defp detect_android_memory_gb do
    # Try /proc/meminfo first (works on Android)
    case detect_linux_memory_gb() do
      gb when gb > 0.1 -> gb
      _ -> beam_memory_gb()
    end
  end

  @doc """
  Detect Android-specific hardware capabilities.

  Uses the `:android` module's battery, sensor, and device info functions
  when available. Falls back to standard Linux detection.
  """
  @spec detect_android() :: map()
  def detect_android do
    base = %{
      platform: :android,
      battery: detect_android_battery(),
      sensors: detect_android_sensors()
    }

    # Add device info if available
    case safe_android_call(:device_info, []) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, info} -> Map.put(base, :device, info)
          _ -> base
        end

      _ ->
        base
    end
  rescue
    _ -> %{platform: :android, battery: nil, sensors: []}
  catch
    :exit, _ -> %{platform: :android, battery: nil, sensors: []}
  end

  defp detect_android_battery do
    case safe_android_call(:battery, []) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"level" => level} = info} ->
            %{level: level, charging: Map.get(info, "charging", false)}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp detect_android_sensors do
    # Query available sensors via the android module
    with {:ok, json} <- safe_android_call(:sensor_list, []),
         {:ok, sensors} when is_list(sensors) <- Jason.decode(json) do
      Enum.map(sensors, fn s ->
        name = if is_map(s), do: Map.get(s, "name", "unknown"), else: to_string(s)
        String.downcase(name)
      end)
    else
      _ -> []
    end
  end

  defp safe_android_call(function, args) do
    if Code.ensure_loaded?(:android) and function_exported?(:android, function, length(args)) do
      apply(:android, function, args)
    else
      {:error, :not_available}
    end
  end

  @doc """
  Generate Android-specific capability tags.
  """
  @spec android_capability_tags(map()) :: [atom()]
  def android_capability_tags(android_info) do
    tags = [:android, :mobile]

    tags =
      if android_info[:battery] do
        tags ++ [:has_battery]
      else
        tags
      end

    tags =
      case android_info[:sensors] do
        sensors when is_list(sensors) and sensors != [] ->
          # Sensor names are strings from device hardware — map to known atoms
          sensor_atom_map = %{
            "accelerometer" => :has_accelerometer,
            "gyroscope" => :has_gyroscope,
            "magnetometer" => :has_magnetometer,
            "proximity" => :has_proximity,
            "light" => :has_light,
            "gravity" => :has_gravity,
            "barometer" => :has_barometer,
            "step_counter" => :has_step_counter,
            "orientation" => :has_orientation
          }

          sensor_tags = Enum.flat_map(sensors, fn s -> List.wrap(sensor_atom_map[s]) end)
          tags ++ [:has_sensors | sensor_tags]

        _ ->
          tags
      end

    # Camera capability (most Android devices)
    tags ++ [:has_camera, :has_microphone, :has_speaker, :has_gps]
  end
end
