defmodule Arbor.Orchestrator.Registrar do
  @moduledoc """
  Populates handler DI registries with core entries at boot.

  Called during `Arbor.Orchestrator.Application.start/2` after registries
  are running. Registers all core handler backends and actions, then
  locks the core namespace to prevent overwriting.

  ## Registration Order

  1. ReadableRegistry — file and context read backends
  2. WriteableRegistry — file and accumulator write backends
  3. ComputeRegistry — LLM and routing compute backends
  4. PipelineResolver — composition mode backends
  5. ActionRegistry — all action modules from Arbor.Actions

  Each registry is checked with `Process.whereis/1` before registration.
  If a registry isn't running, its entries are skipped (graceful degradation).
  """

  require Logger

  alias Arbor.Common.{
    ActionRegistry,
    ComputeRegistry,
    PipelineResolver,
    ReadableRegistry,
    WriteableRegistry
  }

  @doc """
  Register all core entries and lock registries.

  Returns `:ok` on success or `{:error, failures}` with a list of
  registration errors (non-fatal — other registries still populated).
  """
  @spec register_core() :: :ok | {:error, [{atom(), term()}]}
  def register_core do
    failures =
      []
      |> register_readable_backends()
      |> register_writeable_backends()
      |> register_compute_backends()
      |> register_pipeline_backends()
      |> register_actions()

    if failures == [] do
      :ok
    else
      Logger.warning("Registrar: #{length(failures)} registration failures: #{inspect(failures)}")
      {:error, failures}
    end
  end

  # --- Readable Backends ---

  defp register_readable_backends(failures) do
    unless Process.whereis(ReadableRegistry) do
      failures
    else
      entries = [
        {"file", Arbor.Orchestrator.Backends.FileReadable, %{default: true}},
        {"context", Arbor.Orchestrator.Backends.ContextReadable, %{}}
      ]

      register_entries(ReadableRegistry, entries, failures)
    end
  end

  # --- Writeable Backends ---

  defp register_writeable_backends(failures) do
    unless Process.whereis(WriteableRegistry) do
      failures
    else
      entries = [
        {"file", Arbor.Orchestrator.Handlers.FileWriteHandler, %{default: true}},
        {"accumulator", Arbor.Orchestrator.Handlers.AccumulatorHandler, %{}}
      ]

      register_entries(WriteableRegistry, entries, failures)
    end
  end

  # --- Compute Backends ---

  defp register_compute_backends(failures) do
    unless Process.whereis(ComputeRegistry) do
      failures
    else
      entries = [
        {"llm", Arbor.Orchestrator.Handlers.CodergenHandler, %{default: true}},
        {"routing", Arbor.Orchestrator.Handlers.RoutingHandler, %{}}
      ]

      register_entries(ComputeRegistry, entries, failures)
    end
  end

  # --- Pipeline Backends ---

  defp register_pipeline_backends(failures) do
    unless Process.whereis(PipelineResolver) do
      failures
    else
      entries = [
        {"invoke", Arbor.Orchestrator.Handlers.SubgraphHandler, %{default: true}},
        {"compose", Arbor.Orchestrator.Handlers.SubgraphHandler, %{}},
        {"pipeline", Arbor.Orchestrator.Handlers.PipelineRunHandler, %{}},
        {"manager_loop", Arbor.Orchestrator.Handlers.ManagerLoopHandler, %{}}
      ]

      # SessionHandler is in a different app — use runtime check
      entries =
        if Code.ensure_loaded?(Arbor.Orchestrator.Handlers.SessionHandler) do
          entries ++ [{"session", Arbor.Orchestrator.Handlers.SessionHandler, %{}}]
        else
          entries
        end

      register_entries(PipelineResolver, entries, failures)
    end
  end

  # --- Action Registry ---

  defp register_actions(failures) do
    unless Process.whereis(ActionRegistry) do
      failures
    else
      if Code.ensure_loaded?(Arbor.Actions) do
        actions = apply(Arbor.Actions, :list_actions, [])

        action_failures =
          Enum.flat_map(actions, fn {category, modules} ->
            Enum.flat_map(modules, fn module ->
              case ActionRegistry.register_action(module, %{category: category}) do
                :ok -> []
                # Already registered/locked = desired state
                {:error, :core_locked} -> []
                {:error, :already_registered} -> []
                {:error, reason} -> [{:action_registry, {module, reason}}]
              end
            end)
          end)

        # Lock core after all actions registered
        ActionRegistry.lock_core()

        failures ++ action_failures
      else
        failures
      end
    end
  end

  # --- Helpers ---

  defp register_entries(registry, entries, failures) do
    entry_failures =
      Enum.flat_map(entries, fn {name, module, metadata} ->
        case registry.register(name, module, metadata) do
          :ok -> []
          # Already registered/locked = desired state, treat as success
          {:error, :core_locked} -> []
          {:error, :already_registered} -> []
          {:error, reason} -> [{registry, {name, reason}}]
        end
      end)

    # Lock core after registering core entries (idempotent if already locked)
    registry.lock_core()

    failures ++ entry_failures
  end
end
