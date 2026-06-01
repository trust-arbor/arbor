defmodule Arbor.Orchestrator.Handlers.RegistryDispatchTest do
  @moduledoc """
  Tests that core handlers dispatch via registries when available,
  and fall back to inline implementation when registries are unavailable.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Common.{
    ComputeRegistry,
    PipelineResolver,
    ReadableRegistry,
    WriteableRegistry
  }

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph.Node

  @registries [ReadableRegistry, WriteableRegistry, ComputeRegistry, PipelineResolver]

  defp make_node(id, attrs) do
    %Node{id: id, attrs: Map.merge(%{"type" => "test"}, attrs)}
  end

  defp ensure_registry(registry) do
    case GenServer.whereis(registry) do
      nil ->
        {:ok, _} = registry.start_link()

      _pid ->
        try do
          registry.reset()
        catch
          :exit, _ ->
            # Process dying — wait and restart
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

    # Idempotent — safe to call even if Application already registered
    :ok = Arbor.Orchestrator.Registrar.register_core()

    on_exit(fn ->
      for registry <- @registries, do: safe_reset(registry)
    end)

    :ok
  end

  describe "ReadHandler with registry" do
    test "dispatches file reads via FileReadable from registry" do
      tmp = System.tmp_dir!()
      filename = "registry_read_#{:rand.uniform(100_000)}.txt"
      File.write!(Path.join(tmp, filename), "registry dispatched")

      node = make_node("r1", %{"source" => "file", "path" => filename})
      context = Context.new()

      result =
        Arbor.Orchestrator.Handlers.ReadHandler.execute(node, context, nil, workdir: tmp)

      assert %Outcome{status: :success} = result
      assert result.context_updates["last_response"] == "registry dispatched"
    after
      File.rm(Path.join(System.tmp_dir!(), "registry_read_*.txt"))
    end

    test "dispatches context reads via ContextReadable from registry" do
      node = make_node("r2", %{"source" => "context", "source_key" => "my_data"})
      context = Context.new(%{"my_data" => "from context"})

      result =
        Arbor.Orchestrator.Handlers.ReadHandler.execute(node, context, nil, [])

      assert %Outcome{status: :success} = result
      assert result.context_updates["last_response"] == "from context"
    end

    test "default source is file" do
      tmp = System.tmp_dir!()
      filename = "registry_default_#{:rand.uniform(100_000)}.txt"
      File.write!(Path.join(tmp, filename), "default file")

      node = make_node("r3", %{"path" => filename})
      context = Context.new()

      result =
        Arbor.Orchestrator.Handlers.ReadHandler.execute(node, context, nil, workdir: tmp)

      assert %Outcome{status: :success} = result
      assert result.context_updates["last_response"] == "default file"
    after
      File.rm(Path.join(System.tmp_dir!(), "registry_default_*.txt"))
    end

    test "custom output_key is respected" do
      tmp = System.tmp_dir!()
      filename = "registry_okey_#{:rand.uniform(100_000)}.txt"
      File.write!(Path.join(tmp, filename), "custom key")

      node = make_node("r4", %{"path" => filename, "output_key" => "custom.output"})
      context = Context.new()

      result =
        Arbor.Orchestrator.Handlers.ReadHandler.execute(node, context, nil, workdir: tmp)

      assert %Outcome{status: :success} = result
      assert result.context_updates["custom.output"] == "custom key"
    after
      File.rm(Path.join(System.tmp_dir!(), "registry_okey_*.txt"))
    end

    test "plugin-registered source is dispatched" do
      defmodule TestPluginReadable do
        @behaviour Arbor.Contracts.Handler.Readable
        alias Arbor.Contracts.Handler.ScopedContext
        @impl true
        def read(%ScopedContext{}, _opts), do: {:ok, "from plugin"}
        @impl true
        def list(%ScopedContext{}, _opts), do: {:ok, []}
        @impl true
        def capability_required(_op, _ctx), do: "arbor://handler/read/test_plugin"
      end

      :ok = ReadableRegistry.register("test.plugin", TestPluginReadable)

      node = make_node("r5", %{"source" => "test.plugin"})
      context = Context.new()

      result =
        Arbor.Orchestrator.Handlers.ReadHandler.execute(node, context, nil, [])

      assert %Outcome{status: :success} = result
      assert result.context_updates["last_response"] == "from plugin"
    end
  end

  describe "WriteHandler with registry" do
    test "dispatches via registry to FileWriteHandler" do
      # Use workdir so FileWriteHandler's path traversal check passes
      dir = System.tmp_dir!()
      filename = "registry_write_#{:rand.uniform(100_000)}.txt"

      node =
        make_node("w1", %{
          "target" => "file",
          "content_key" => "last_response",
          "output" => filename
        })

      context = Context.new(%{"last_response" => "write this"})

      result =
        Arbor.Orchestrator.Handlers.WriteHandler.execute(node, context, nil, workdir: dir)

      assert %Outcome{status: :success} = result
      assert File.read!(Path.join(dir, filename)) == "write this"
    after
      for f <- Path.wildcard(Path.join(System.tmp_dir!(), "registry_write_*.txt")),
          do: File.rm(f)
    end

    test "dispatches via registry to AccumulatorHandler" do
      node =
        make_node("w2", %{
          "target" => "accumulator",
          "operation" => "append",
          "input_key" => "last_response"
        })

      context = Context.new(%{"last_response" => "item1"})

      result =
        Arbor.Orchestrator.Handlers.WriteHandler.execute(node, context, nil, [])

      assert %Outcome{status: :success} = result
    end
  end

  describe "ComputeHandler with registry" do
    test "dispatches llm via registry to LlmHandler" do
      assert {:ok, Arbor.Orchestrator.Handlers.LlmHandler} =
               ComputeRegistry.resolve("llm")
    end

    test "dispatches routing via registry" do
      assert {:ok, Arbor.Orchestrator.Handlers.RoutingHandler} =
               ComputeRegistry.resolve("routing")
    end
  end

  describe "ComposeHandler with registry" do
    test "dispatches invoke via registry to SubgraphHandler" do
      assert {:ok, Arbor.Orchestrator.Handlers.SubgraphHandler} =
               PipelineResolver.resolve("invoke")
    end

    test "dispatches pipeline via registry to PipelineRunHandler" do
      assert {:ok, Arbor.Orchestrator.Handlers.PipelineRunHandler} =
               PipelineResolver.resolve("pipeline")
    end

    test "all core modes are registered" do
      for mode <- ["invoke", "compose", "pipeline", "manager_loop"] do
        assert {:ok, _module} = PipelineResolver.resolve(mode),
               "Mode '#{mode}' not found in PipelineResolver"
      end
    end
  end

  describe "fallback when registries unavailable" do
    test "ReadHandler falls back to inline when registry not running" do
      # Stop the ReadableRegistry
      GenServer.stop(ReadableRegistry)
      Process.sleep(10)

      # Delete the ETS table held by heir
      try do
        :ets.delete(:readable_registry)
      rescue
        ArgumentError -> :ok
      end

      tmp = System.tmp_dir!()
      filename = "fallback_read_#{:rand.uniform(100_000)}.txt"
      path = Path.join(tmp, filename)
      File.write!(path, "fallback content")

      node = make_node("fb1", %{"source" => "file", "path" => filename})
      context = Context.new()

      result =
        Arbor.Orchestrator.Handlers.ReadHandler.execute(node, context, nil, workdir: tmp)

      assert %Outcome{status: :success} = result
      assert result.context_updates["last_response"] == "fallback content"

      # Restart for subsequent tests
      {:ok, _} = ReadableRegistry.start_link()
    after
      File.rm(Path.join(System.tmp_dir!(), "fallback_read_*.txt"))
    end
  end

  describe "strict unknown handler mode (M3 regression)" do
    alias Arbor.Orchestrator.Handlers.Registry, as: HandlerRegistry
    alias Arbor.Orchestrator.Graph.Node, as: GraphNode

    setup do
      original = Application.get_env(:arbor_orchestrator, :strict_unknown_handlers)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:arbor_orchestrator, :strict_unknown_handlers)
        else
          Application.put_env(:arbor_orchestrator, :strict_unknown_handlers, original)
        end
      end)

      :ok
    end

    test "security regression (M3): unknown handler type raises in strict mode" do
      # M3: pre-fix, Registry.resolve fell through to LlmHandler for any node
      # whose type wasn't in the core map or HandlerRegistry. That turned every
      # misspelled type, every typo in a custom handler name, and every
      # unrecognized type in an untrusted graph into an LLM call with whatever
      # context the graph was carrying. Strict mode now raises so a malformed
      # or malicious graph fails fast.
      Application.put_env(:arbor_orchestrator, :strict_unknown_handlers, true)

      node = %GraphNode{
        id: "n1",
        attrs: %{"type" => "definitely_not_a_real_handler_m3_regression"}
      }

      assert_raise ArgumentError, ~r/Unknown handler type.*strict mode \(M3\)/, fn ->
        HandlerRegistry.resolve(node)
      end
    end

    test "permissive mode falls back to LlmHandler (existing behavior preserved)" do
      Application.put_env(:arbor_orchestrator, :strict_unknown_handlers, false)

      node = %GraphNode{
        id: "n2",
        attrs: %{"type" => "another_unknown_type_m3"}
      }

      assert Arbor.Orchestrator.Handlers.LlmHandler = HandlerRegistry.resolve(node)
    end
  end
end
