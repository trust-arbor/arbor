defmodule Arbor.Orchestrator.RegistrarTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.{
    ActionRegistry,
    ComputeRegistry,
    PipelineResolver,
    ReadableRegistry,
    WriteableRegistry
  }

  @registries [
    ReadableRegistry,
    WriteableRegistry,
    ComputeRegistry,
    PipelineResolver,
    ActionRegistry
  ]

  defp ensure_registry(registry) do
    case GenServer.whereis(registry) do
      nil ->
        {:ok, _} = registry.start_link()

      _pid ->
        try do
          registry.reset()
        catch
          :exit, _ ->
            Process.sleep(10)
            {:ok, _} = registry.start_link()
        end
    end
  end

  defp safe_reset(registry) do
    case GenServer.whereis(registry) do
      nil ->
        :ok

      _pid ->
        try do
          registry.reset()
        catch
          :exit, _ -> :ok
        end
    end
  end

  setup do
    for registry <- @registries, do: ensure_registry(registry)

    # Idempotent — safe even if Application already registered
    :ok = Arbor.Orchestrator.Registrar.register_core()

    on_exit(fn ->
      for registry <- @registries, do: safe_reset(registry)
    end)

    :ok
  end

  describe "register_core/0" do
    test "populates all registries with core entries" do
      assert {:ok, Arbor.Orchestrator.Backends.FileReadable} = ReadableRegistry.resolve("file")

      assert {:ok, Arbor.Orchestrator.Backends.ContextReadable} =
               ReadableRegistry.resolve("context")

      assert {:ok, Arbor.Orchestrator.Handlers.FileWriteHandler} =
               WriteableRegistry.resolve("file")

      assert {:ok, Arbor.Orchestrator.Handlers.AccumulatorHandler} =
               WriteableRegistry.resolve("accumulator")

      assert {:ok, Arbor.Orchestrator.Handlers.CodergenHandler} =
               ComputeRegistry.resolve("llm")

      assert {:ok, Arbor.Orchestrator.Handlers.RoutingHandler} =
               ComputeRegistry.resolve("routing")

      assert {:ok, Arbor.Orchestrator.Handlers.SubgraphHandler} =
               PipelineResolver.resolve("invoke")

      assert {:ok, Arbor.Orchestrator.Handlers.PipelineRunHandler} =
               PipelineResolver.resolve("pipeline")
    end

    test "idempotent — second call returns :ok" do
      assert :ok = Arbor.Orchestrator.Registrar.register_core()
    end

    test "locks core after registration" do
      assert ReadableRegistry.core_locked?()
      assert WriteableRegistry.core_locked?()
      assert ComputeRegistry.core_locked?()
      assert PipelineResolver.core_locked?()
    end

    test "core entries cannot be overwritten after locking" do
      assert {:error, :core_locked} =
               ReadableRegistry.register("file", SomeOtherModule)
    end

    test "plugin entries can be registered after core lock" do
      defmodule TestPluginReadable do
        @behaviour Arbor.Contracts.Handler.Readable
        alias Arbor.Contracts.Handler.ScopedContext
        @impl true
        def read(%ScopedContext{}, _opts), do: {:ok, "plugin data"}
        @impl true
        def list(%ScopedContext{}, _opts), do: {:ok, []}
        @impl true
        def capability_required(_op, _ctx), do: "arbor://handler/read/test_plugin"
      end

      assert :ok =
               ReadableRegistry.register("test_plugin.custom", TestPluginReadable)

      assert {:ok, TestPluginReadable} = ReadableRegistry.resolve("test_plugin.custom")
    end
  end

  describe "ActionRegistry population" do
    test "registers actions from Arbor.Actions when available" do
      if Code.ensure_loaded?(Arbor.Actions) do
        assert {:ok, _module} = ActionRegistry.resolve("file.read")
        assert {:ok, _module} = ActionRegistry.resolve("shell.execute")

        # Jido names should also resolve
        assert {:ok, _module} = ActionRegistry.resolve_by_name("file_read")

        # Should have many entries
        all = ActionRegistry.list_all()
        assert length(all) > 20
      end
    end

    test "ActionRegistry is locked after registration" do
      if Code.ensure_loaded?(Arbor.Actions) do
        assert ActionRegistry.core_locked?()
      end
    end
  end
end
