defmodule Arbor.Comms.InteractionRegistry.DurableStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.Config
  alias Arbor.Comms.InteractionRegistry.DurableStore
  alias Arbor.Contracts.Persistence.Record
  alias __MODULE__.DurableBackend
  alias __MODULE__.NoCasBackend
  alias __MODULE__.ProcessLifetimeBackend
  alias __MODULE__.AlternateBackend
  alias __MODULE__.SwitchingBackend

  @store_config [
    backend: __MODULE__.DurableBackend,
    namespace: :test_durable_interactions,
    opts: [],
    max_data_bytes: 256,
    max_items: 2
  ]

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-durable-interactions-#{System.unique_integer([:positive])}"
      )

    DurableBackend.start_link(path)
    original = Application.get_env(:arbor_comms, :durable_interaction_store)

    Application.put_env(
      :arbor_comms,
      :durable_interaction_store,
      Keyword.put(@store_config, :opts, path: path)
    )

    on_exit(fn ->
      if original,
        do: Application.put_env(:arbor_comms, :durable_interaction_store, original),
        else: Application.delete_env(:arbor_comms, :durable_interaction_store)

      DurableBackend.stop()
      File.rm(path)
    end)

    :ok
  end

  test "default config disables the adapter and uses a fixed atom namespace" do
    original = Application.get_env(:arbor_comms, :durable_interaction_store)
    Application.delete_env(:arbor_comms, :durable_interaction_store)

    assert Config.durable_interaction_store_backend() == nil
    assert is_atom(Config.durable_interaction_store_namespace())
    assert DurableStore.readiness() == {:error, :disabled}

    restore_config(original)
  end

  test "readiness requires CAS and node-restart durability" do
    assert {:ok, %{durability: :node_restart}} = DurableStore.readiness()

    for backend <- [NoCasBackend, ProcessLifetimeBackend] do
      Application.put_env(
        :arbor_comms,
        :durable_interaction_store,
        Keyword.put(@store_config, :backend, backend)
      )

      assert DurableStore.readiness() == {:error, :unsupported}
    end
  end

  test "concurrent insert-once admission has one winner" do
    results =
      1..20
      |> Task.async_stream(fn _ -> DurableStore.insert_once("request-1", %{"v" => 1}) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Record{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 19
  end

  test "get and exact-record CAS preserve backend fencing" do
    assert {:ok, first} = DurableStore.insert_once("request-2", %{"state" => "new"})
    replacement = Record.update(first, %{"state" => "approved"})

    assert {:ok, second} = DurableStore.compare_and_swap("request-2", first, replacement)
    assert second.id == first.id
    assert second.generation == first.generation
    assert second.revision == first.revision + 1
    assert {:ok, ^second} = DurableStore.get("request-2")
  end

  test "node-restart durable backend reloads state after its process restarts" do
    assert {:ok, first} = DurableStore.insert_once("request-reload", %{"state" => "saved"})
    assert :ok = DurableBackend.stop()
    assert {:ok, _pid} = DurableBackend.start_link(backend_path())

    assert {:ok, reloaded} = DurableStore.get("request-reload")
    assert reloaded.id == first.id
    assert reloaded.generation == first.generation
    assert reloaded.revision == first.revision
    assert reloaded.data == first.data
  end

  test "stale CAS conflicts and key mismatches are rejected" do
    assert {:ok, first} = DurableStore.insert_once("request-3", %{})
    replacement = Record.update(first, %{"state" => "one"})
    assert {:ok, current} = DurableStore.compare_and_swap("request-3", first, replacement)

    assert {:error, :conflict} =
             DurableStore.compare_and_swap("request-3", first, Record.update(first, %{}))

    wrong_key = Record.new("other-key", %{})

    assert {:error, :malformed_record} =
             DurableStore.compare_and_swap("request-3", current, wrong_key)
  end

  test "rejects non-JSON, oversized data, malformed keys, and options" do
    assert {:error, :invalid_data} = DurableStore.insert_once("request-5", %{state: "bad"})

    assert {:error, :data_too_large} =
             DurableStore.insert_once("request-6", %{"x" => String.duplicate("x", 300)})

    assert {:error, :invalid_key} = DurableStore.insert_once("", %{})
    assert {:error, :invalid_key} = DurableStore.get(123)
    assert {:error, :invalid_options} = DurableStore.get("request-5", unknown: true)
  end

  test "inventory is bounded and rejects malformed backend results" do
    assert {:ok, _} = DurableStore.insert_once("request-a", %{})
    assert {:ok, _} = DurableStore.insert_once("request-b", %{})
    assert {:ok, _} = DurableStore.insert_once("request-c", %{})
    assert {:error, :inventory_too_large} = DurableStore.inventory()
  end

  test "malformed backend records fail closed" do
    DurableBackend.put_raw("bad-record", %Record{Record.new("bad-record", %{}) | data: %{bad: 1}})
    assert {:error, :malformed_record} = DurableStore.get("bad-record")

    DurableBackend.put_raw(
      "bad-metadata",
      %Record{Record.new("bad-metadata", %{}) | metadata: %{bad: 1}}
    )

    assert {:error, :malformed_record} = DurableStore.get("bad-metadata")

    DurableBackend.put_raw(
      "bad-id",
      %Record{Record.new("bad-id", %{}) | id: String.duplicate("i", 257)}
    )

    assert {:error, :malformed_record} = DurableStore.get("bad-id")

    DurableBackend.put_raw("bad-utf8-id", %Record{Record.new("bad-utf8-id", %{}) | id: <<255>>})
    assert {:error, :malformed_record} = DurableStore.get("bad-utf8-id")
  end

  test "uses one config snapshot across readiness attestation and the write" do
    Application.put_env(
      :arbor_comms,
      :durable_interaction_store,
      backend: SwitchingBackend,
      namespace: :snapshot_interactions,
      opts: [observer: self(), switch_to: AlternateBackend],
      max_data_bytes: 256,
      max_items: 2
    )

    assert {:ok, %Record{key: "snapshot-request"}} =
             DurableStore.insert_once("snapshot-request", %{})

    assert_received :switching_durability_attested
    assert_received :switching_cas_used
    refute_received :alternate_cas_used
  end

  defp backend_path do
    Application.get_env(:arbor_comms, :durable_interaction_store)[:opts][:path]
  end

  defp restore_config(nil), do: Application.delete_env(:arbor_comms, :durable_interaction_store)

  defp restore_config(value),
    do: Application.put_env(:arbor_comms, :durable_interaction_store, value)

  defmodule DurableBackend do
    alias Arbor.Contracts.Persistence.Record

    def start_link(path) do
      case Process.whereis(__MODULE__) do
        nil -> Agent.start_link(fn -> load(path) end, name: __MODULE__)
        _pid -> {:ok, __MODULE__}
      end
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        _pid -> Agent.stop(__MODULE__)
      end
    catch
      :exit, _reason -> :ok
    end

    def durability_class(_opts), do: :node_restart

    def get(key, _opts) do
      Agent.get(__MODULE__, fn state ->
        case Map.get(state, key, :absent) do
          :absent -> {:error, :not_found}
          value -> {:ok, value}
        end
      end)
    end

    def list(_opts) do
      Agent.get(__MODULE__, fn state ->
        {:ok, for({key, %Record{}} <- state, do: key)}
      end)
    end

    def compare_and_swap(key, :not_found, %Record{} = replacement, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state, key) do
          nil ->
            stored = %{replacement | generation: 1, revision: 1}
            persist(opts, Map.put(state, key, stored))
            {{:ok, stored}, Map.put(state, key, stored)}

          _live ->
            {{:error, :conflict}, state}
        end
      end)
    end

    def compare_and_swap(key, {:value, %Record{} = expected}, %Record{} = replacement, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state, key) do
          %Record{generation: generation, revision: revision} = current
          when generation == expected.generation and revision == expected.revision ->
            stored = %{
              replacement
              | id: current.id,
                key: current.key,
                generation: current.generation,
                revision: current.revision + 1,
                inserted_at: current.inserted_at
            }

            persist(opts, Map.put(state, key, stored))
            {{:ok, stored}, Map.put(state, key, stored)}

          _ ->
            {{:error, :conflict}, state}
        end
      end)
    end

    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}

    def put_raw(key, value) do
      path = Application.get_env(:arbor_comms, :durable_interaction_store)[:opts][:path]
      state = Agent.get(__MODULE__, & &1) |> Map.put(key, value)
      persist(path, state)
      Agent.update(__MODULE__, fn _ -> state end)
    end

    defp persist(opts, state) when is_list(opts), do: persist(Keyword.fetch!(opts, :path), state)

    defp persist(path, state) when is_binary(path),
      do: File.write!(path, :erlang.term_to_binary(state))

    defp load(path) do
      case File.read(path) do
        {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
        {:error, :enoent} -> %{}
      end
    end
  end

  defmodule ProcessLifetimeBackend do
    def durability_class(_opts), do: :process_lifetime
    def get(_key, _opts), do: {:error, :not_found}
    def list(_opts), do: {:ok, []}
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}
  end

  defmodule NoCasBackend do
    def durability_class(_opts), do: :node_restart
    def get(_key, _opts), do: {:error, :not_found}
    def list(_opts), do: {:ok, []}
  end

  defmodule SwitchingBackend do
    def durability_class(opts) do
      send(opts[:observer], :switching_durability_attested)

      Application.put_env(
        :arbor_comms,
        :durable_interaction_store,
        backend: opts[:switch_to],
        namespace: :changed_after_attestation,
        opts: [],
        max_data_bytes: 256,
        max_items: 2
      )

      :node_restart
    end

    def get(_key, _opts), do: {:error, :not_found}
    def list(_opts), do: {:ok, []}

    def compare_and_swap(_key, :not_found, replacement, opts) do
      send(opts[:observer], :switching_cas_used)
      {:ok, %{replacement | generation: 1, revision: 1}}
    end
  end

  defmodule AlternateBackend do
    def durability_class(_opts), do: :node_restart
    def get(_key, _opts), do: {:error, :not_found}
    def list(_opts), do: {:ok, []}

    def compare_and_swap(_key, _expected, _replacement, _opts) do
      send(self(), :alternate_cas_used)
      {:error, :unexpected_backend}
    end
  end
end
