defmodule Arbor.Orchestrator.RegistrarTest do
  use ExUnit.Case, async: false
  @moduletag :fast

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

      assert {:ok, Arbor.Orchestrator.Handlers.LlmHandler} =
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

  describe "CapabilityIndex action re-sync (boot-order regression)" do
    # Regression for the boot-order bug: CapabilityIndex (arbor_common, L1) syncs its
    # providers at ITS boot, including ActionProvider — but ActionRegistry is populated by
    # this Registrar (arbor_orchestrator, L7), which boots later. Without a re-sync after
    # register_actions/1, the index stays EMPTY of actions and
    # CapabilityResolver.search(kind: :action) returns [] (which broke spawn_worker's
    # capability resolution and drove a retry runaway). Guards
    # Registrar.sync_action_capability_index/0.
    #
    # The capability infra isn't auto-started in this app's test env
    # (:start_children=false), so this test OWNS the boot order to reproduce the bug: start
    # the index against an EMPTY ActionRegistry (boot-sync gets nothing), then register_core
    # must re-sync it. Without the fix, register_core doesn't re-sync → index stays empty →
    # the final assert fails.
    test "register_core re-syncs actions registered AFTER the index booted" do
      alias Arbor.Common.CapabilityIndex
      alias Arbor.Common.CapabilityProviders.ActionProvider
      alias Arbor.Common.CapabilityResolver

      if Code.ensure_loaded?(Arbor.Actions) do
        # Own the index lifecycle (not started in test env).
        case GenServer.whereis(CapabilityIndex) do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end

        # Reproduce the buggy order: EMPTY ActionRegistry, THEN the index boots + syncs.
        :ok = ActionRegistry.reset()
        {:ok, idx} = CapabilityIndex.start_link(providers: [ActionProvider])
        on_exit(fn -> if Process.alive?(idx), do: GenServer.stop(idx) end)

        # Bug state: no actions indexed yet (tier: 1 = the ETS index only, no skill noise).
        assert CapabilityResolver.search("file read", limit: 5, kind: :action, tier: 1) == []

        # The fix: register_core populates ActionRegistry AND re-syncs the index.
        :ok = Arbor.Orchestrator.Registrar.register_core()

        uris =
          CapabilityResolver.search("file read", limit: 5, kind: :action, tier: 1)
          |> Enum.map(fn m ->
            get_in(m, [Access.key(:descriptor), Access.key(:metadata)])[:capability_uri]
          end)

        assert "arbor://fs/read" in uris,
               "expected 'file read' to resolve to arbor://fs/read after register_core; got " <>
                 "#{inspect(uris)} (empty = the CapabilityIndex action re-sync regressed)"
      end
    end
  end
end
