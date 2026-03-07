defmodule Mix.Tasks.Arbor.Phone do
  @shortdoc "Provision and manage phone nodes in the Arbor cluster"
  @moduledoc """
  Provisions an Android phone node with Elixir + Arbor modules
  and optionally starts a voice session.

      $ mix arbor.phone provision beamapp@10.42.42.205
      $ mix arbor.phone voice beamapp@10.42.42.205
      $ mix arbor.phone status beamapp@10.42.42.205

  ## Commands

    - `provision` — Load Elixir stdlib + Arbor modules onto the phone
    - `voice` — Provision (if needed) and start a voice session
    - `status` — Show phone node status (memory, loaded modules)

  ## Options

    - `--agent-id` — Agent ID for voice sessions (default: first running agent)
    - `--listen-mode` — STT mode: listen, stream_listen, buddie_listen (default: listen)
    - `--listen-seconds` — Recording duration (default: 5)
    - `--voice` — TTS voice index 0-7
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(args) do
    Config.ensure_distribution()

    case args do
      ["provision", node_str | _rest] ->
        provision(parse_node(node_str))

      ["voice", node_str | rest] ->
        voice(parse_node(node_str), parse_opts(rest))

      ["status", node_str | _rest] ->
        status(parse_node(node_str))

      _ ->
        Mix.shell().info("""
        Usage:
          mix arbor.phone provision <node>
          mix arbor.phone voice <node> [options]
          mix arbor.phone status <node>

        Examples:
          mix arbor.phone provision beamapp@10.42.42.205
          mix arbor.phone voice beamapp@10.42.42.205 --listen-seconds 8
        """)
    end
  end

  # ── Provision ──────────────────────────────────────────────────────

  defp provision(phone_node) do
    unless ping(phone_node) do
      Mix.shell().error("Cannot reach #{phone_node}")
      exit({:shutdown, 1})
    end

    Mix.shell().info("Provisioning #{phone_node}...")

    {elixir_count, elixir_time} = timed(fn -> load_elixir_runtime(phone_node) end)
    Mix.shell().info("  Elixir runtime: #{elixir_count} modules loaded")

    {arbor_count, arbor_time} = timed(fn -> load_arbor_modules(phone_node) end)
    Mix.shell().info("  Arbor modules:  #{arbor_count} modules loaded")

    mem = Config.rpc(phone_node, :erlang, :memory, [:total])
    mem_mb = if is_integer(mem), do: Float.round(mem / 1_048_576, 1), else: "?"

    total_time = Float.round((elixir_time + arbor_time) / 1000, 1)

    Mix.shell().info("""

      Provisioning complete
      ════════════════════════════
        Phone:    #{phone_node}
        Modules:  #{elixir_count + arbor_count}
        Memory:   #{mem_mb} MB
        Time:     #{total_time}s
      ════════════════════════════
    """)
  end

  # ── Voice ──────────────────────────────────────────────────────────

  defp voice(phone_node, opts) do
    unless ping(phone_node) do
      Mix.shell().error("Cannot reach #{phone_node}")
      exit({:shutdown, 1})
    end

    # Provision if Elixir isn't loaded yet
    unless elixir_loaded?(phone_node) do
      provision(phone_node)
    end

    homelab = Config.full_node_name()

    session_opts = [
      phone_node: phone_node,
      homelab_node: homelab,
      thinking_sound: true,
      listen_mode: Keyword.get(opts, :listen_mode, :listen),
      listen_seconds: Keyword.get(opts, :listen_seconds, 5)
    ]

    session_opts =
      case Keyword.get(opts, :agent_id) do
        nil -> session_opts
        id -> Keyword.put(session_opts, :agent_id, id)
      end

    session_opts =
      case Keyword.get(opts, :voice) do
        nil -> session_opts
        v -> Keyword.put(session_opts, :voice, v)
      end

    Mix.shell().info("Starting voice session on #{phone_node}...")
    Mix.shell().info("  Homelab: #{homelab}")
    Mix.shell().info("  Mode:    #{session_opts[:listen_mode]}")
    Mix.shell().info("")

    # Start session on the phone
    case start_phone_session(phone_node, session_opts) do
      {:ok, pid} ->
        Mix.shell().info("Voice session started (#{inspect(pid)} on #{phone_node})")
        Mix.shell().info("Use `mix arbor.phone status #{phone_node}` to check status")

      {:error, reason} ->
        Mix.shell().error("Failed to start voice session: #{inspect(reason)}")
    end
  end

  # ── Status ─────────────────────────────────────────────────────────

  defp status(phone_node) do
    unless ping(phone_node) do
      Mix.shell().error("Cannot reach #{phone_node}")
      exit({:shutdown, 1})
    end

    mem = Config.rpc(phone_node, :erlang, :memory, [])
    total_mb = Float.round(mem[:total] / 1_048_576, 1)
    code_mb = Float.round(mem[:code] / 1_048_576, 1)
    procs = Config.rpc(phone_node, :erlang, :system_info, [:process_count])

    elixir = elixir_loaded?(phone_node)

    loaded_count =
      case Config.rpc(phone_node, :code, :all_loaded, []) do
        mods when is_list(mods) -> length(mods)
        _ -> "?"
      end

    # Check battery
    battery =
      case Config.rpc(phone_node, :android, :battery, []) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, %{"level" => level, "charging" => charging}} ->
              "#{level}%#{if charging, do: " (charging)", else: ""}"

            _ ->
              "unknown"
          end

        _ ->
          "unknown"
      end

    Mix.shell().info("""

      Phone Node Status
      ════════════════════════════
        Node:       #{phone_node}
        Memory:     #{total_mb} MB (#{code_mb} MB code)
        Processes:  #{procs}
        Modules:    #{loaded_count}
        Elixir:     #{if elixir, do: "loaded", else: "not loaded"}
        Battery:    #{battery}
      ════════════════════════════
    """)
  end

  # ── Module Loading ─────────────────────────────────────────────────

  defp load_elixir_runtime(phone_node) do
    # Load all Elixir-prefixed and elixir_ internal modules
    modules =
      :code.all_loaded()
      |> Enum.map(fn {mod, _} -> mod end)
      |> Enum.filter(fn mod ->
        name = Atom.to_string(mod)

        String.starts_with?(name, "Elixir.") or
          String.starts_with?(name, "elixir_") or
          name == "elixir"
      end)
      # Exclude heavy modules not needed on phone
      |> Enum.reject(fn mod ->
        name = Atom.to_string(mod)

        String.contains?(name, "Phoenix") or
          String.contains?(name, "Plug.") or
          String.contains?(name, "Ecto.") or
          String.contains?(name, "Postgrex") or
          String.contains?(name, "Dashboard") or
          String.contains?(name, "LiveView") or
          String.contains?(name, "Swoosh") or
          String.contains?(name, "Bandit") or
          String.contains?(name, "Mint.") or
          String.contains?(name, "Req.") or
          String.contains?(name, "Finch.")
      end)

    load_modules_to_phone(phone_node, modules)
  end

  defp load_arbor_modules(phone_node) do
    # Get loaded modules from the running Arbor server
    server_node = Config.full_node_name()

    all_loaded =
      case :rpc.call(server_node, :code, :all_loaded, []) do
        mods when is_list(mods) -> mods
        _ -> :code.all_loaded()
      end

    modules =
      all_loaded
      |> Enum.map(fn {mod, _} -> mod end)
      |> Enum.filter(fn mod ->
        name = Atom.to_string(mod)

        String.starts_with?(name, "Elixir.Arbor.") or
          String.starts_with?(name, "Elixir.Jason")
      end)
      # Exclude web/dashboard/persistence modules not needed on phone
      |> Enum.reject(fn mod ->
        name = Atom.to_string(mod)

        String.contains?(name, "Dashboard") or
          String.contains?(name, "Phoenix") or
          String.contains?(name, "Ecto") or
          String.contains?(name, "Persistence.Ecto") or
          String.contains?(name, "Web.")
      end)

    load_modules_to_phone(phone_node, modules)
  end

  defp load_modules_to_phone(phone_node, modules) do
    # Try local code first, fall back to RPC to Arbor server for module binaries
    server_node = Config.full_node_name()

    Enum.reduce(modules, 0, fn mod, count ->
      binary = get_module_binary(mod, server_node)

      case binary do
        nil ->
          count

        bin ->
          case :rpc.call(phone_node, :code, :load_binary, [mod, ~c"#{mod}.beam", bin]) do
            {:module, ^mod} -> count + 1
            _ -> count
          end
      end
    end)
  end

  # Get module binary — try local first, then RPC to the running Arbor server
  defp get_module_binary(mod, server_node) do
    case :code.get_object_code(mod) do
      {^mod, binary, _file} ->
        binary

      :error ->
        # Module not loaded locally — fetch from the running server
        case :rpc.call(server_node, :code, :get_object_code, [mod]) do
          {^mod, binary, _file} -> binary
          _ -> nil
        end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp start_phone_session(phone_node, opts) do
    :rpc.call(phone_node, :erlang, :apply, [
      fn ->
        GenServer.start_link(
          Arbor.Comms.Channels.Voice.Session,
          opts,
          name: :voice_session
        )
      end,
      []
    ])
  end

  defp ping(phone_node) do
    :net_adm.ping(phone_node) == :pong
  end

  defp elixir_loaded?(phone_node) do
    case :rpc.call(phone_node, :code, :is_loaded, [Enum]) do
      {:file, _} -> true
      _ -> false
    end
  end

  defp parse_node(node_str) do
    # Safe: operator-provided node name from CLI argument
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    String.to_atom(node_str)
  end

  defp parse_opts(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          agent_id: :string,
          listen_mode: :string,
          listen_seconds: :integer,
          voice: :integer
        ],
        aliases: [a: :agent_id, m: :listen_mode, s: :listen_seconds, v: :voice]
      )

    case Keyword.get(opts, :listen_mode) do
      nil -> opts
      mode -> Keyword.put(opts, :listen_mode, String.to_existing_atom(mode))
    end
  end

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - start
    {result, elapsed}
  end
end
