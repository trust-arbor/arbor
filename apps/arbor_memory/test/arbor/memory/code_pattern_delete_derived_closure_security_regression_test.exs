defmodule Arbor.Memory.CodePatternDeleteDerivedClosureSecurityRegressionTest do
  @moduledoc """
  Security regression for AfterDeleteBench leftover retrieval after
  `code_pattern_delete` (`Arbor.Memory.delete_code` / `CodeStore.delete`).

  After a pattern is deleted, its MemoryStore embedding and any knowledge-graph
  nodes that `:derived_from` the pattern must no longer be retrievable.
  """

  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Test.DurableGraphAuthority

  @moduletag :fast
  @moduletag security_regression: true

  @namespace "code_patterns"
  @graph_ets :arbor_memory_graphs

  defmodule RecordStore do
    @moduledoc false

    alias Arbor.Memory.Embedding

    @table :code_pattern_delete_derived_closure_records

    def start, do: :ets.new(@table, [:named_table, :public, :set])

    def encode_operation(input), do: Embedding.encode_strict_operation(input)
    def encode_batch(inputs), do: Embedding.encode_strict_batch(inputs)

    def execute(_agent, %{kind: :batch, operations: ops}, _opts) do
      receipts =
        Enum.map(ops, fn op ->
          {:ok, receipt} = execute(nil, op, [])
          receipt
        end)

      {:ok, %{kind: :batch, receipts: receipts}}
    end

    def execute(_agent, %{kind: :delete, record: record} = operation, _opts) do
      :ets.delete(@table, {record.agent_id, record.source_namespace, record.source_key})
      {:ok, %{kind: operation.kind, record: record}}
    end

    def execute(_agent, operation, _opts) do
      record = persist_record(operation.record)
      :ets.insert(@table, {{record.agent_id, record.source_namespace, record.source_key}, record})
      {:ok, %{kind: operation.kind, record: record}}
    end

    def reconcile(_agent, _operation, _opts), do: {:ok, :absent}

    def fetch(agent, namespace, key, opts) do
      include_tombstone? = Keyword.get(opts, :include_tombstone, false)

      case :ets.lookup(@table, {agent, namespace, key}) do
        [{_, record}] ->
          case Embedding.decode_strict_record(record) do
            {:ok, view} ->
              if view.tombstone and not include_tombstone?,
                do: {:error, :not_found},
                else: {:ok, view}

            error ->
              error
          end

        [] ->
          {:error, :not_found}
      end
    end

    defp persist_record(record) do
      %{
        record
        | generation: max(record.generation, 1),
          revision: max(record.revision, 1)
      }
    end

    def list(agent, _opts) do
      views =
        for {{^agent, _, _}, record} <- :ets.tab2list(@table) do
          {:ok, view} = Embedding.decode_strict_record(record)
          view
        end

      {:ok, views}
    end

    def search(agent, _vector, opts) do
      {:ok, views} = list(agent, [])
      category = Keyword.get(opts, :category)
      views = Enum.filter(views, &(is_nil(category) or &1.category == category))
      {:ok, Enum.map(views, &%{match: &1, similarity: 1.0})}
    end

    def destroy(_agent, _opts), do: :ok
  end

  setup do
    DurableGraphAuthority.start!()
    RecordStore.start()

    previous = Application.fetch_env(:arbor_memory, :strict_vector_seam)
    Application.put_env(:arbor_memory, :strict_vector_seam, RecordStore)

    agent_id = "agent_code_del_y_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = Memory.cleanup_for_agent(agent_id)
      :ets.delete(@graph_ets, agent_id)

      case previous do
        {:ok, value} -> Application.put_env(:arbor_memory, :strict_vector_seam, value)
        :error -> Application.delete_env(:arbor_memory, :strict_vector_seam)
      end
    end)

    %{agent_id: agent_id}
  end

  test "security regression: code_pattern_delete removes the embedding and derived_from nodes",
       %{agent_id: agent_id} do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, entry} =
             Memory.store_code(agent_id, %{
               code: "fn leftover -> leftover end",
               language: "elixir",
               purpose: "AfterDeleteBench leftover pattern"
             })

    logical_key = "#{agent_id}:#{entry.id}"
    await_embedding!(agent_id, logical_key)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert {:ok, _view} = RecordStore.fetch(agent_id, @namespace, logical_key, [])

    assert {:ok, source_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "source code pattern #{entry.id}",
               metadata: %{"code_pattern_id" => entry.id, "name" => "code pattern source"}
             })

    assert {:ok, derived_id} =
             Memory.add_knowledge(agent_id, %{
               type: :insight,
               content: "derived leftover from #{entry.id}",
               metadata: %{"name" => "derived leftover"}
             })

    assert {:ok, survivor_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "unrelated survivor knowledge",
               metadata: %{"name" => "survivor"}
             })

    assert :ok = Memory.link_knowledge(agent_id, derived_id, source_id, :derived_from)

    assert {:ok, [_derived | _]} =
             Memory.search_knowledge(agent_id, "derived leftover from #{entry.id}")

    assert :ok = Memory.delete_code(agent_id, entry.id)
    assert {:error, :not_found} = Memory.get_code(agent_id, entry.id)

    assert {:error, :not_found} = RecordStore.fetch(agent_id, @namespace, logical_key, [])

    assert {:ok, []} = Memory.search_knowledge(agent_id, "derived leftover from #{entry.id}")

    assert {:ok, exported} = Memory.export_knowledge_graph(agent_id)
    refute Map.has_key?(exported.nodes, derived_id)
    assert Map.has_key?(exported.nodes, source_id)
    assert Map.has_key?(exported.nodes, survivor_id)
  end

  defp await_embedding!(agent_id, logical_key) do
    assert wait_until(fn ->
             match?({:ok, _}, RecordStore.fetch(agent_id, @namespace, logical_key, []))
           end)
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(fun, deadline)
  end

  defp wait_loop(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(10)
        wait_loop(fun, deadline)
      end
    end
  end
end
