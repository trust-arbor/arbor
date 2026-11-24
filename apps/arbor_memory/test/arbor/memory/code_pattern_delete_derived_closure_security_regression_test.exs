defmodule Arbor.Memory.CodePatternDeleteDerivedClosureSecurityRegressionTest do
  @moduledoc """
  Security regression for AfterDeleteBench leftover retrieval after
  `code_pattern_delete` (`Arbor.Memory.delete_code` / `CodeStore.delete`).

  After a pattern is deleted, its MemoryStore embedding and any knowledge-graph
  nodes that `:derived_from` the pattern must no longer be retrievable.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.TaintedValue
  alias Arbor.Memory
  alias Arbor.Memory.KnowledgeGraphStore
  alias Arbor.Memory.MemoryStore
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
    @control :code_pattern_delete_derived_closure_control

    def start do
      ensure_table(@table)
      ensure_table(@control)
      :ets.delete_all_objects(@table)
      :ets.insert(@control, {:fail_delete, false})
      :ets.insert(@control, {:unsupported_fetch, false})
      :ets.insert(@control, {:hang, :off})
    end

    defp ensure_table(table) do
      case :ets.whereis(table) do
        :undefined -> :ets.new(table, [:named_table, :public, :set])
        _tid -> table
      end
    end

    def fail_next_delete do
      :ets.insert(@control, {:fail_delete, true})
    end

    def unsupported_fetch do
      :ets.insert(@control, {:unsupported_fetch, true})
    end

    def clear_unsupported_fetch do
      :ets.insert(@control, {:unsupported_fetch, false})
    end

    def arm_write_fetch_hang(tester \\ self()) when is_pid(tester) do
      :ets.insert(@control, {:hang, {:armed, tester}})
    end

    def await_write_fetch_hang(timeout \\ 2_000) do
      receive do
        {:code_pattern_embed_hang, ref, blocked_pid}
        when is_reference(ref) and is_pid(blocked_pid) ->
          {:ok, ref, blocked_pid}
      after
        timeout -> {:error, :hang_timeout}
      end
    end

    def release_write_fetch_hang do
      case :ets.lookup(@control, :hang) do
        [{:hang, {:holding, waiters}}] ->
          :ets.insert(@control, {:hang, :off})

          Enum.each(waiters, fn {pid, ref} ->
            if is_pid(pid) and Process.alive?(pid), do: send(pid, {:code_pattern_embed_go, ref})
          end)

          :ok

        _ ->
          :ets.insert(@control, {:hang, :off})
          :ok
      end
    end

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
      case :ets.lookup(@control, :fail_delete) do
        [{:fail_delete, true}] ->
          :ets.insert(@control, {:fail_delete, false})
          {:error, :conflict}

        _ ->
          :ets.delete(@table, {record.agent_id, record.source_namespace, record.source_key})
          {:ok, %{kind: operation.kind, record: record}}
      end
    end

    def execute(_agent, operation, _opts) do
      record = persist_record(operation.record)
      :ets.insert(@table, {{record.agent_id, record.source_namespace, record.source_key}, record})
      {:ok, %{kind: operation.kind, record: record}}
    end

    def reconcile(_agent, _operation, _opts), do: {:ok, :absent}

    def fetch(agent, namespace, key, opts) do
      include_tombstone? = Keyword.get(opts, :include_tombstone, false)
      if include_tombstone?, do: maybe_hang_write_fetch()

      case :ets.lookup(@control, :unsupported_fetch) do
        [{:unsupported_fetch, true}] ->
          {:error, :unsupported}

        _ ->
          fetch_record(agent, namespace, key, include_tombstone?)
      end
    end

    defp fetch_record(agent, namespace, key, include_tombstone?) do
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

    defp maybe_hang_write_fetch do
      blocked_pid = self()

      park =
        case :ets.lookup(@control, :hang) do
          [{:hang, {:armed, tester}}] ->
            ref = make_ref()
            send(tester, {:code_pattern_embed_hang, ref, blocked_pid})
            :ets.insert(@control, {:hang, {:holding, [{blocked_pid, ref}]}})
            {:park, ref}

          [{:hang, {:holding, waiters}}] ->
            ref = make_ref()
            :ets.insert(@control, {:hang, {:holding, [{blocked_pid, ref} | waiters]}})
            {:park, ref}

          _ ->
            :cont
        end

      case park do
        {:park, ref} ->
          receive do
            {:code_pattern_embed_go, ^ref} -> :ok
          after
            30_000 -> :ok
          end

        :cont ->
          :ok
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

  test "security regression: delete_code surfaces embedding cleanup failure", %{
    agent_id: agent_id
  } do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, entry} =
             Memory.store_code(agent_id, %{
               code: "fn cleanup -> :fail end",
               language: "elixir",
               purpose: "embedding cleanup failure"
             })

    await_embedding!(agent_id, "#{agent_id}:#{entry.id}")
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    RecordStore.fail_next_delete()

    assert {:error, _reason} = Memory.delete_code(agent_id, entry.id)
  end

  test "security regression: delete_code surfaces graph cleanup failure", %{agent_id: agent_id} do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, entry} =
             Memory.store_code(agent_id, %{
               code: "fn graph -> :fail end",
               language: "elixir",
               purpose: "graph cleanup failure"
             })

    await_embedding!(agent_id, "#{agent_id}:#{entry.id}")
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert {:ok, source_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "source #{entry.id}",
               metadata: %{"code_pattern_id" => entry.id}
             })

    assert {:ok, derived_id} =
             Memory.add_knowledge(agent_id, %{
               type: :insight,
               content: "derived #{entry.id}",
               metadata: %{"name" => "derived"}
             })

    assert :ok = Memory.link_knowledge(agent_id, derived_id, source_id, :derived_from)

    stop_knowledge_graph_store!()

    assert {:error, _reason} = Memory.delete_code(agent_id, entry.id)
  after
    restart_knowledge_graph_store!()
  end

  test "security regression: a racing embedding write does not survive delete_code",
       %{agent_id: agent_id} do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    RecordStore.arm_write_fetch_hang()

    store_task =
      Task.async(fn ->
        Memory.store_code(agent_id, %{
          code: "fn race -> race end",
          language: "elixir",
          purpose: "racing embedding write"
        })
      end)

    assert {:ok, _ref, _pid} = RecordStore.await_write_fetch_hang()
    assert {:ok, entry} = Task.await(store_task)
    logical_key = "#{agent_id}:#{entry.id}"

    delete_result = Memory.delete_code(agent_id, entry.id)
    RecordStore.release_write_fetch_hang()
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert delete_result == :ok or match?({:error, _}, delete_result)
    assert {:error, :not_found} = Memory.get_code(agent_id, entry.id)
    assert {:error, :not_found} = RecordStore.fetch(agent_id, @namespace, logical_key, [])
  end

  test "security regression: delete_code surfaces a live-store graph read failure", %{
    agent_id: agent_id
  } do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, entry} =
             Memory.store_code(agent_id, %{
               code: "fn live_read -> :fail end",
               language: "elixir",
               purpose: "live store authoritative read failure"
             })

    await_embedding!(agent_id, "#{agent_id}:#{entry.id}")
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert {:ok, source_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "source #{entry.id}",
               metadata: %{"code_pattern_id" => entry.id}
             })

    assert {:ok, derived_id} =
             Memory.add_knowledge(agent_id, %{
               type: :insight,
               content: "derived leftover #{entry.id}",
               metadata: %{"name" => "derived leftover"}
             })

    assert :ok = Memory.link_knowledge(agent_id, derived_id, source_id, :derived_from)

    assert {:ok, %TaintedValue{value: wrapper, taint: outer}, _status, observed, _location} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    malformed = Map.delete(wrapper, "provenance")

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               "knowledge_graph",
               agent_id,
               observed,
               malformed,
               taint: outer
             )

    assert is_pid(Process.whereis(KnowledgeGraphStore))
    assert {:error, :invalid_provenance} = KnowledgeGraphStore.get_graph(agent_id)

    assert {:error, :store_unavailable} = Memory.delete_code(agent_id, entry.id)

    assert {:ok, %TaintedValue{}, _status, restored_observed, _location} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               "knowledge_graph",
               agent_id,
               restored_observed,
               wrapper,
               taint: outer
             )

    assert :ok = KnowledgeGraphStore.converge_projection(agent_id)
    assert {:ok, exported} = Memory.export_knowledge_graph(agent_id)
    assert Map.has_key?(exported.nodes, derived_id)
  end

  test "security regression: delete_code does not treat unsupported vector fetch as success",
       %{agent_id: agent_id} do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, entry} =
             Memory.store_code(agent_id, %{
               code: "fn unsupported -> :fail_open end",
               language: "elixir",
               purpose: "unsupported vector fetch"
             })

    logical_key = "#{agent_id}:#{entry.id}"
    await_embedding!(agent_id, logical_key)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    RecordStore.unsupported_fetch()

    assert {:error, :store_unavailable} = Memory.delete_code(agent_id, entry.id)

    RecordStore.clear_unsupported_fetch()
    assert {:ok, _view} = RecordStore.fetch(agent_id, @namespace, logical_key, [])
  end

  defp stop_knowledge_graph_store! do
    case Process.whereis(Arbor.Memory.KnowledgeGraphStore) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)

        :ok =
          Supervisor.terminate_child(Arbor.Memory.Supervisor, Arbor.Memory.KnowledgeGraphStore)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

      nil ->
        :ok
    end
  end

  defp restart_knowledge_graph_store! do
    case Supervisor.restart_child(Arbor.Memory.Supervisor, Arbor.Memory.KnowledgeGraphStore) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :not_found} -> start_knowledge_graph_store!()
      {:error, _reason} -> start_knowledge_graph_store!()
    end
  end

  defp start_knowledge_graph_store! do
    case Supervisor.start_child(Arbor.Memory.Supervisor, {Arbor.Memory.KnowledgeGraphStore, []}) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart_knowledge_graph_store!()
    end
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
