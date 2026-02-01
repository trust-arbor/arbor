defmodule Mix.Tasks.Arbor.Sdlc do
  @shortdoc "Manage SDLC pipeline stages on the running Arbor server"
  @moduledoc """
  Manage SDLC pipeline stage processing on the running Arbor server.

      $ mix arbor.sdlc status
      $ mix arbor.sdlc enable inbox
      $ mix arbor.sdlc enable all
      $ mix arbor.sdlc disable brainstorming
      $ mix arbor.sdlc disable all
      $ mix arbor.sdlc root /tmp/roadmap
      $ mix arbor.sdlc root --reset
      $ mix arbor.sdlc rescan
      $ mix arbor.sdlc backend api
      $ mix arbor.sdlc backend cli

  ## Commands

    * `status`              - Show current SDLC config and enabled stages
    * `enable <stage|all>`  - Enable a stage (or all) for automatic processing
    * `disable <stage|all>` - Disable a stage (or all) for automatic processing
    * `root <path|--reset>` - Set roadmap directory (creates stage dirs, triggers rescan)
    * `rescan`              - Force an immediate rescan of watched directories
    * `backend <cli|api>`   - Set the AI backend for processors
  """
  use Mix.Task

  alias Arbor.SDLC.Pipeline
  alias Mix.Tasks.Arbor.Helpers

  @valid_backends ~w(cli api)

  @impl Mix.Task
  def run(args) do
    case args do
      ["status" | _] -> cmd_status()
      ["enable", stage] -> cmd_enable(stage)
      ["disable", stage] -> cmd_disable(stage)
      ["root", path] -> cmd_root(path)
      ["rescan" | _] -> cmd_rescan()
      ["backend", backend] -> cmd_backend(backend)
      _ -> print_usage()
    end
  end

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  defp cmd_status do
    ensure_running!()
    node = Helpers.full_node_name()

    case :rpc.call(node, Arbor.SDLC, :status, []) do
      {:badrpc, reason} ->
        Mix.shell().error("Failed to get status: #{inspect(reason)}")

      status ->
        enabled = Map.get(status, :enabled_stages, [])
        watcher = Map.get(status, :watcher_enabled, false)
        root = Map.get(status, :roadmap_root, "?")
        healthy = Map.get(status, :healthy, false)

        # Get backend from config
        backend =
          case :rpc.call(node, Application, :get_env, [:arbor_sdlc, :ai_backend, :cli]) do
            {:badrpc, _} -> "?"
            val -> val
          end

        Mix.shell().info("")
        Mix.shell().info("SDLC Pipeline Status")
        Mix.shell().info("====================")
        Mix.shell().info("  Healthy:    #{healthy}")
        Mix.shell().info("  Watcher:    #{watcher}")
        Mix.shell().info("  Root:       #{root}")
        Mix.shell().info("  Backend:    #{backend}")
        all_stages = Pipeline.stages()
        processing = Pipeline.config().processing_stages

        Mix.shell().info("")
        Mix.shell().info("  Stage            Enabled  Processor")
        Mix.shell().info("  ───────────────  ───────  ─────────")

        for stage <- all_stages do
          enabled_marker = if stage in enabled, do: "  ✓", else: "  ✗"
          proc_marker = if stage in processing, do: "  ✓", else: "  ─"
          name = stage |> Atom.to_string() |> String.pad_trailing(15)
          Mix.shell().info("  #{name}#{String.pad_trailing(enabled_marker, 9)}#{proc_marker}")
        end

        Mix.shell().info("")
    end
  end

  defp cmd_enable("all") do
    ensure_running!()
    node = Helpers.full_node_name()

    case :rpc.call(node, Arbor.SDLC.Config, :enable_all_stages, []) do
      :ok ->
        Mix.shell().info("All stages enabled.")

      {:badrpc, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp cmd_enable(stage) do
    case validate_stage(stage) do
      {:ok, atom} ->
        ensure_running!()
        node = Helpers.full_node_name()

        case :rpc.call(node, Arbor.SDLC.Config, :enable_stage, [atom]) do
          :ok ->
            Mix.shell().info("Stage :#{stage} enabled.")

          {:badrpc, reason} ->
            Mix.shell().error("Failed: #{inspect(reason)}")
        end

      :error ->
        valid = Pipeline.stages() |> Enum.map_join(", ", &Atom.to_string/1)
        Mix.shell().error("Unknown stage: #{stage}. Valid stages: #{valid}, all")
    end
  end

  defp cmd_disable("all") do
    ensure_running!()
    node = Helpers.full_node_name()

    case :rpc.call(node, Arbor.SDLC.Config, :disable_all_stages, []) do
      :ok ->
        Mix.shell().info("All stages disabled.")

      {:badrpc, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp cmd_disable(stage) do
    case validate_stage(stage) do
      {:ok, atom} ->
        ensure_running!()
        node = Helpers.full_node_name()

        case :rpc.call(node, Arbor.SDLC.Config, :disable_stage, [atom]) do
          :ok ->
            Mix.shell().info("Stage :#{stage} disabled.")

          {:badrpc, reason} ->
            Mix.shell().error("Failed: #{inspect(reason)}")
        end

      :error ->
        valid = Pipeline.stages() |> Enum.map_join(", ", &Atom.to_string/1)
        Mix.shell().error("Unknown stage: #{stage}. Valid stages: #{valid}, all")
    end
  end

  defp cmd_root("--reset") do
    ensure_running!()
    node = Helpers.full_node_name()

    case :rpc.call(node, Application, :put_env, [:arbor_sdlc, :roadmap_root, ".arbor/roadmap"]) do
      :ok ->
        abs = :rpc.call(node, Arbor.SDLC.Config, :absolute_roadmap_root, [])
        :rpc.call(node, Arbor.SDLC.Pipeline, :ensure_directories!, [abs])
        :rpc.call(node, Arbor.SDLC, :restart_watcher, [])
        Mix.shell().info("Roadmap root reset to .arbor/roadmap")

      {:badrpc, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp cmd_root(path) do
    ensure_running!()
    node = Helpers.full_node_name()

    abs_path =
      if Path.type(path) == :absolute do
        path
      else
        Path.expand(path)
      end

    case :rpc.call(node, Application, :put_env, [:arbor_sdlc, :roadmap_root, abs_path]) do
      :ok ->
        :rpc.call(node, Arbor.SDLC.Pipeline, :ensure_directories!, [abs_path])

        case :rpc.call(node, Arbor.SDLC, :restart_watcher, []) do
          :ok ->
            Mix.shell().info("Roadmap root set to #{abs_path}")
            Mix.shell().info("Stage directories created. Watcher restarted.")

          {:error, reason} ->
            Mix.shell().info("Roadmap root set to #{abs_path}")
            Mix.shell().error("Watcher restart failed: #{inspect(reason)}")
        end

      {:badrpc, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp cmd_rescan do
    ensure_running!()
    node = Helpers.full_node_name()

    case :rpc.call(node, Arbor.SDLC, :rescan, []) do
      :ok ->
        Mix.shell().info("Rescan triggered.")

      {:error, :watcher_not_running} ->
        Mix.shell().error("Watcher is not running.")

      {:badrpc, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp cmd_backend(backend) when backend in @valid_backends do
    ensure_running!()
    node = Helpers.full_node_name()
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    atom = String.to_atom(backend)

    case :rpc.call(node, Application, :put_env, [:arbor_sdlc, :ai_backend, atom]) do
      :ok ->
        Mix.shell().info("AI backend set to :#{backend}.")

      {:badrpc, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp cmd_backend(backend) do
    Mix.shell().error("Unknown backend: #{backend}. Valid: #{Enum.join(@valid_backends, ", ")}")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_running! do
    Helpers.ensure_distribution()

    unless Helpers.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end
  end

  defp print_usage do
    valid = Pipeline.stages() |> Enum.map_join(", ", &Atom.to_string/1)

    Mix.shell().info("""
    Usage: mix arbor.sdlc <command> [args]

    Commands:
      status              Show pipeline config and enabled stages
      enable <stage|all>  Enable stage for automatic processing
      disable <stage|all> Disable stage for automatic processing
      root <path>         Set roadmap directory (creates stage dirs, rescans)
      root --reset        Reset roadmap directory to .arbor/roadmap
      rescan              Force immediate rescan of watched directories
      backend <cli|api>   Set AI backend for processors

    Stages: #{valid}

    Examples:
      mix arbor.sdlc status
      mix arbor.sdlc enable inbox
      mix arbor.sdlc enable all
      mix arbor.sdlc disable brainstorming
      mix arbor.sdlc root /tmp/roadmap
      mix arbor.sdlc root --reset
      mix arbor.sdlc backend api
      mix arbor.sdlc rescan
    """)
  end

  defp validate_stage(name) when is_binary(name) do
    stage_atoms = Pipeline.stages()

    case Enum.find(stage_atoms, &(Atom.to_string(&1) == name)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end
end
