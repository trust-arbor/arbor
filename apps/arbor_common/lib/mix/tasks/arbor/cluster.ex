defmodule Mix.Tasks.Arbor.Cluster do
  @shortdoc "View and manage the Arbor cluster"
  @moduledoc """
  View cluster status, node capabilities, and manage connections.

      $ mix arbor.cluster status
      $ mix arbor.cluster connect node@host
      $ mix arbor.cluster capabilities
      $ mix arbor.cluster sync

  ## Commands

    - `status` — Show all connected nodes with capabilities
    - `connect` — Connect to a remote node
    - `capabilities` — Show detailed capability tags for all nodes
    - `sync` — Force capability sync across all nodes
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(args) do
    Config.ensure_distribution()

    case args do
      ["status" | _] -> status()
      ["connect", node_str | _] -> connect(parse_node(node_str))
      ["capabilities" | _] -> capabilities()
      ["sync" | _] -> sync()
      _ -> status()
    end
  end

  defp status do
    server = Config.full_node_name()

    # Get connected nodes, filtering out ephemeral mix task nodes
    nodes =
      case :rpc.call(server, Node, :list, []) do
        list when is_list(list) ->
          real_nodes = Enum.reject(list, &ephemeral_node?/1)
          [server | real_nodes]

        _ ->
          [server]
      end

    Mix.shell().info("\n  Arbor Cluster Status")
    Mix.shell().info("  ════════════════════════════════════════════════")

    for node <- Enum.sort(nodes) do
      reachable = :net_adm.ping(node) == :pong

      if reachable do
        info = gather_node_info(node)

        status_icon = if node == server, do: "*", else: " "

        Mix.shell().info(
          "  #{status_icon} #{node}" <>
            "  #{info.arch} | #{info.cpus} CPUs | #{info.memory_gb} GB" <>
            if(info.gpu, do: " | GPU: #{info.gpu}", else: "") <>
            if(info.android, do: " | Android", else: "") <>
            if(info.load, do: " | load: #{info.load}", else: "")
        )
      else
        Mix.shell().info("    #{node}  (unreachable)")
      end
    end

    Mix.shell().info("  ════════════════════════════════════════════════")
    Mix.shell().info("  #{length(nodes)} node(s), * = server\n")
  end

  defp connect(node) do
    case :net_adm.ping(node) do
      :pong ->
        Mix.shell().info("Connected to #{node}")

        # Trigger capability sync on the server
        server = Config.full_node_name()
        Config.rpc(server, Arbor.Cartographer.CapabilityRegistry, :sync_cluster, [])

      :pang ->
        Mix.shell().error("Cannot reach #{node}")
    end
  end

  defp capabilities do
    server = Config.full_node_name()

    case Config.rpc(server, Arbor.Cartographer, :list_all_capabilities, []) do
      {:ok, caps_list} when is_list(caps_list) ->
        Mix.shell().info("\n  Node Capabilities")
        Mix.shell().info("  ════════════════════════════════════════════════")

        for caps <- Enum.sort_by(caps_list, & &1.node) do
          Mix.shell().info("  #{caps.node}")
          Mix.shell().info("    Tags: #{Enum.join(Enum.map(caps.tags, &inspect/1), ", ")}")

          if caps.hardware do
            Mix.shell().info("    Arch: #{caps.hardware[:arch]}")
            Mix.shell().info("    CPUs: #{caps.hardware[:cpus]}")
            Mix.shell().info("    Memory: #{Float.round(caps.hardware[:memory_gb] || 0.0, 1)} GB")

            if caps.hardware[:gpu] do
              for gpu <- List.wrap(caps.hardware[:gpu]) do
                Mix.shell().info(
                  "    GPU: #{gpu[:name]} (#{Float.round(gpu[:vram_gb] || 0.0, 1)} GB)"
                )
              end
            end

            if caps.hardware[:android] do
              android = caps.hardware[:android]

              if android[:battery] do
                Mix.shell().info(
                  "    Battery: #{android.battery.level}%#{if android.battery[:charging], do: " (charging)", else: ""}"
                )
              end

              if android[:sensors] && android.sensors != [] do
                Mix.shell().info("    Sensors: #{Enum.join(android.sensors, ", ")}")
              end
            end
          end

          Mix.shell().info("    Load: #{caps.load}")
          Mix.shell().info("")
        end

      _ ->
        Mix.shell().error("Cannot read capabilities — is the Arbor server running?")
    end
  end

  defp sync do
    server = Config.full_node_name()

    case Config.rpc(server, Arbor.Cartographer.CapabilityRegistry, :sync_cluster, []) do
      :ok ->
        Mix.shell().info("Capability sync triggered across cluster")

      _ ->
        Mix.shell().error("Failed to trigger sync — is the Arbor server running?")
    end
  end

  defp gather_node_info(node) do
    arch =
      case :rpc.call(node, :erlang, :system_info, [:system_architecture], 5_000) do
        arch when is_list(arch) -> arch |> to_string() |> String.split("-") |> hd()
        _ -> "?"
      end

    cpus =
      case :rpc.call(node, System, :schedulers_online, [], 5_000) do
        n when is_integer(n) -> n
        _ -> "?"
      end

    # Try cartographer for rich hardware info (system RAM, GPU, Android)
    {memory_gb, gpu, android} =
      case :rpc.call(node, Arbor.Cartographer, :detect_hardware, [], 10_000) do
        {:ok, hw} ->
          mem = hw[:memory_gb] || beam_memory_gb(node)

          gpu_name =
            case hw[:gpu] do
              [g | _] when is_map(g) -> Map.get(g, :name, "yes")
              _ -> nil
            end

          is_android = hw[:android] != nil

          {mem, gpu_name, is_android}

        _ ->
          # Fallback to BEAM memory if cartographer not available
          {beam_memory_gb(node), nil, false}
      end

    load =
      case :rpc.call(node, Arbor.Cartographer, :get_node_load, [node], 5_000) do
        {:ok, l} when is_number(l) -> Float.round(l, 1)
        _ -> nil
      end

    %{arch: arch, cpus: cpus, memory_gb: memory_gb, gpu: gpu, android: android, load: load}
  end

  defp parse_node(node_str) do
    # Safe: operator-provided node name from CLI argument
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    String.to_atom(node_str)
  end

  defp ephemeral_node?(node) do
    name = Atom.to_string(node)
    String.starts_with?(name, "arbor_mix_")
  end

  defp beam_memory_gb(node) do
    case :rpc.call(node, :erlang, :memory, [:total], 5_000) do
      bytes when is_integer(bytes) -> Float.round(bytes / 1_073_741_824, 1)
      _ -> "?"
    end
  end
end
