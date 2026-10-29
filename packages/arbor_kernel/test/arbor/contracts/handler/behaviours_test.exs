defmodule Arbor.Contracts.Handler.BehavioursTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Handler.ScopedContext

  describe "ScopedContext" do
    test "from_node_and_context builds scoped context" do
      node = %{id: "n1", type: "read", attrs: %{"source" => "file"}}

      context = %{
        "path" => "/tmp/test.txt",
        "internal_key" => "should_not_leak",
        :agent_id => "agent_1"
      }

      ctx = ScopedContext.from_node_and_context(node, context, input_keys: ["path"])

      assert ctx.node_id == "n1"
      assert ctx.node_type == "read"
      assert ctx.agent_id == "agent_1"
      assert ctx.values == %{"path" => "/tmp/test.txt"}
      refute Map.has_key?(ctx.values, "internal_key")
    end

    test "from_node_and_context without input_keys passes all values" do
      node = %{id: "n1", type: "read", attrs: %{}}
      context = %{"a" => 1, "b" => 2}

      ctx = ScopedContext.from_node_and_context(node, context)
      assert ctx.values == %{"a" => 1, "b" => 2}
    end

    test "from_node_and_context handles string-keyed nodes" do
      node = %{"id" => "n1", "type" => "read"}
      context = %{}

      ctx = ScopedContext.from_node_and_context(node, context)
      assert ctx.node_id == "n1"
      assert ctx.node_type == "read"
    end

    test "get and put values" do
      ctx = %ScopedContext{values: %{"key" => "value"}}

      assert ScopedContext.get(ctx, "key") == "value"
      assert ScopedContext.get(ctx, "missing") == nil
      assert ScopedContext.get(ctx, "missing", "default") == "default"

      ctx2 = ScopedContext.put(ctx, "new_key", "new_value")
      assert ScopedContext.get(ctx2, "new_key") == "new_value"
    end

    test "metadata passthrough" do
      node = %{id: "n1", type: "read", attrs: %{}}
      context = %{}
      meta = %{request_id: "req_123"}

      ctx = ScopedContext.from_node_and_context(node, context, metadata: meta)
      assert ctx.metadata == meta
    end
  end

  describe "Readable behaviour" do
    defmodule TestReadable do
      @behaviour Arbor.Contracts.Handler.Readable

      @impl true
      def read(%ScopedContext{} = ctx, _opts) do
        {:ok, ScopedContext.get(ctx, "data", "default")}
      end

      @impl true
      def list(%ScopedContext{}, _opts) do
        {:ok, ["item1", "item2"]}
      end

      @impl true
      def capability_required(operation, _ctx) do
        "arbor://handler/read/test/#{operation}"
      end
    end

    test "implements read callback" do
      ctx = %ScopedContext{values: %{"data" => "hello"}}
      assert {:ok, "hello"} = TestReadable.read(ctx, [])
    end

    test "implements list callback" do
      ctx = %ScopedContext{values: %{}}
      assert {:ok, ["item1", "item2"]} = TestReadable.list(ctx, [])
    end

    test "implements capability_required callback" do
      ctx = %ScopedContext{}
      assert "arbor://handler/read/test/read" = TestReadable.capability_required(:read, ctx)
      assert "arbor://handler/read/test/list" = TestReadable.capability_required(:list, ctx)
    end
  end

  describe "Writeable behaviour" do
    defmodule TestWriteable do
      @behaviour Arbor.Contracts.Handler.Writeable

      @impl true
      def write(%ScopedContext{}, data, _opts) do
        {:ok, "wrote: #{data}"}
      end

      @impl true
      def delete(%ScopedContext{}, _opts) do
        :ok
      end

      @impl true
      def capability_required(operation, _ctx) do
        "arbor://handler/write/test/#{operation}"
      end
    end

    test "implements write callback" do
      ctx = %ScopedContext{}
      assert {:ok, "wrote: hello"} = TestWriteable.write(ctx, "hello", [])
    end

    test "implements delete callback" do
      ctx = %ScopedContext{}
      assert :ok = TestWriteable.delete(ctx, [])
    end

    test "implements capability_required callback" do
      ctx = %ScopedContext{}
      assert "arbor://handler/write/test/write" = TestWriteable.capability_required(:write, ctx)
    end
  end

  describe "Computable behaviour" do
    defmodule TestComputable do
      @behaviour Arbor.Contracts.Handler.Computable

      @impl true
      def compute(%ScopedContext{} = ctx, _opts) do
        input = ScopedContext.get(ctx, "input", 0)
        {:ok, input * 2}
      end

      @impl true
      def capabilities, do: [:math, :transform]

      @impl true
      def capability_required(_ctx), do: "arbor://handler/compute/test"

      @impl true
      def available?, do: true
    end

    test "implements compute callback" do
      ctx = %ScopedContext{values: %{"input" => 21}}
      assert {:ok, 42} = TestComputable.compute(ctx, [])
    end

    test "implements capabilities callback" do
      assert [:math, :transform] = TestComputable.capabilities()
    end

    test "implements available? callback" do
      assert TestComputable.available?()
    end
  end

  describe "Composable behaviour" do
    defmodule TestComposable do
      @behaviour Arbor.Contracts.Handler.Composable

      @impl true
      def resolve(%ScopedContext{} = ctx, _opts) do
        name = ScopedContext.get(ctx, "pipeline")
        {:ok, "digraph #{name} { a -> b }"}
      end

      @impl true
      def list(_opts) do
        {:ok, ["pipeline_a", "pipeline_b"]}
      end

      @impl true
      def capability_required(_ctx), do: "arbor://handler/compose/test"
    end

    test "implements resolve callback" do
      ctx = %ScopedContext{values: %{"pipeline" => "test"}}
      assert {:ok, "digraph test { a -> b }"} = TestComposable.resolve(ctx, [])
    end

    test "implements list callback" do
      assert {:ok, ["pipeline_a", "pipeline_b"]} = TestComposable.list([])
    end
  end

  describe "ComputePolicy behaviour" do
    defmodule CostFirstPolicy do
      @behaviour Arbor.Contracts.Handler.ComputePolicy

      @impl true
      def select(candidates, _context) do
        sorted =
          Enum.sort_by(candidates, fn {_name, _mod, meta} ->
            Map.get(meta, :cost, 999)
          end)

        case sorted do
          [{name, _mod, _meta} | _] -> {:ok, name}
          [] -> {:error, :no_candidates}
        end
      end
    end

    test "selects cheapest candidate" do
      candidates = [
        {"expensive", SomeModule, %{cost: 10.0}},
        {"cheap", SomeModule, %{cost: 0.01}},
        {"mid", SomeModule, %{cost: 1.0}}
      ]

      assert {:ok, "cheap"} = CostFirstPolicy.select(candidates, %{})
    end

    test "returns error for empty candidates" do
      assert {:error, :no_candidates} = CostFirstPolicy.select([], %{})
    end
  end

  describe "Registry behaviour contract" do
    test "contract module compiles and defines callbacks" do
      assert Code.ensure_loaded?(Arbor.Contracts.Handler.Registry)

      callbacks = Arbor.Contracts.Handler.Registry.behaviour_info(:callbacks)
      callback_names = Enum.map(callbacks, fn {name, _arity} -> name end)

      assert :register in callback_names
      assert :deregister in callback_names
      assert :resolve in callback_names
      assert :resolve_entry in callback_names
      assert :list_all in callback_names
      assert :list_available in callback_names
      assert :lock_core in callback_names
      assert :core_locked? in callback_names
      assert :snapshot in callback_names
      assert :restore in callback_names
    end
  end
end
