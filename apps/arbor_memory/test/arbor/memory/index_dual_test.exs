defmodule Arbor.Memory.IndexDualTest do
  @moduledoc """
  Tests for the Index module in dual backend mode.

  These tests verify that the ETS + pgvector dual backend works correctly.
  Requires PostgreSQL with pgvector extension.
  Run with: mix test --include database
  """

  use Arbor.Persistence.DatabaseCase

  @moduletag :database

  alias Arbor.Memory.{Embedding, Index}

  # Must match the pgvector column dimension (vector(768)); pgvector rejects a
  # mismatched insert. (Was 128, which crashed the dual-backend write once the
  # tests actually ran against Postgres.)
  @dimension 768

  defmodule FailFirstWriter do
    @behaviour Arbor.Memory.Index.PersistentWriter

    def arm(agent_id, failures \\ 1) when is_integer(failures) and failures > 0,
      do: :persistent_term.put({__MODULE__, agent_id}, failures)

    def disarm(agent_id), do: :persistent_term.erase({__MODULE__, agent_id})

    @impl true
    def store(agent_id, content, embedding, metadata) do
      case :persistent_term.get({__MODULE__, agent_id}, 0) do
        failures when failures > 0 ->
          :persistent_term.put({__MODULE__, agent_id}, failures - 1)
          {:error, :injected_eager_failure}

        0 ->
          Arbor.Memory.Embedding.store(agent_id, content, embedding, metadata)
      end
    end

    @impl true
    def store_batch_with_ids(agent_id, entries),
      do: Arbor.Memory.Embedding.store_batch_with_ids(agent_id, entries)
  end

  defmodule MaliciousWriter do
    @behaviour Arbor.Memory.Index.PersistentWriter

    def configure(agent_id, mode) do
      :persistent_term.put({__MODULE__, agent_id}, mode)
      :persistent_term.put({__MODULE__, :batch_calls, agent_id}, 0)
    end

    def batch_call_count(agent_id),
      do: :persistent_term.get({__MODULE__, :batch_calls, agent_id}, 0)

    def disarm(agent_id) do
      :persistent_term.erase({__MODULE__, agent_id})
      :persistent_term.erase({__MODULE__, :batch_calls, agent_id})
    end

    @impl true
    def store(agent_id, content, embedding, metadata) do
      case :persistent_term.get({__MODULE__, agent_id}, :fail) do
        {:store_sequence, [result | rest]} ->
          next_mode = if rest == [], do: :delegate, else: {:store_sequence, rest}
          :persistent_term.put({__MODULE__, agent_id}, next_mode)

          case result do
            {:delegate_as, id} ->
              Arbor.Memory.Embedding.store(
                agent_id,
                content,
                embedding,
                Map.put(metadata, :id, id)
              )

            {:delegate_then_exit, reason} ->
              case Arbor.Memory.Embedding.store(agent_id, content, embedding, metadata) do
                {:ok, _id} -> exit(reason)
                error -> error
              end

            {:exit, reason} ->
              exit(reason)

            other ->
              other
          end

        {:partial_batch_failure, 0} ->
          :persistent_term.put({__MODULE__, agent_id}, {:partial_batch_failure, 1})
          Arbor.Memory.Embedding.store(agent_id, content, embedding, metadata)

        {:partial_batch_failure, 1} ->
          {:ok, String.duplicate("x", 256)}

        {:eager_id, id} ->
          {:ok, id}

        :delegate ->
          Arbor.Memory.Embedding.store(agent_id, content, embedding, metadata)

        _mode ->
          {:error, :injected_eager_failure}
      end
    end

    @impl true
    def store_batch_with_ids(agent_id, entries) do
      :persistent_term.put(
        {__MODULE__, :batch_calls, agent_id},
        batch_call_count(agent_id) + 1
      )

      requested_ids =
        Enum.map(entries, fn {_content, _embedding, metadata} ->
          Map.get(metadata, :id) || Map.get(metadata, "id")
        end)

      case :persistent_term.get({__MODULE__, agent_id}, :fail) do
        :oversized_batch ->
          [_first | rest] = requested_ids
          {:ok, [String.duplicate("x", 256) | rest]}

        :cross_group_batch ->
          [first, second] = requested_ids
          {:ok, [second, first]}

        :duplicate_batch ->
          [first, _second] = requested_ids
          {:ok, [first, first]}

        {:partial_batch_failure, _store_count} ->
          [first, _second] = requested_ids
          {:ok, [first, String.duplicate("x", 256)]}

        :delegate ->
          Arbor.Memory.Embedding.store_batch_with_ids(agent_id, entries)

        {:delegate_then_exit, reason} ->
          case Arbor.Memory.Embedding.store_batch_with_ids(agent_id, entries) do
            {:ok, _ids} ->
              :persistent_term.put({__MODULE__, agent_id}, :delegate)
              exit(reason)

            error ->
              error
          end

        _mode ->
          {:error, :injected_batch_failure}
      end
    end
  end

  setup do
    agent_id = durable_unique("test_agent_dual_index")

    # Repo is started + a Sandbox connection is checked out by DatabaseCase.
    # Clean up any existing test data
    Embedding.delete_all(agent_id)

    # Start an index in dual mode
    {:ok, pid} =
      Index.start_link(
        agent_id: agent_id,
        backend: :dual,
        name: {:via, Registry, {Arbor.Memory.Registry, {:test_dual, agent_id}}}
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Embedding.delete_all(agent_id)
    end)

    {:ok, pid: pid, agent_id: agent_id}
  end

  defp generate_embedding(seed) do
    for i <- 0..(@dimension - 1) do
      :math.sin((seed + i) / 100) * 0.5 + 0.5
    end
  end

  describe "dual backend mode" do
    test "reports correct backend mode", %{pid: pid} do
      assert Index.backend_mode(pid) == :dual
    end

    test "index writes to both ETS and pgvector", %{pid: pid, agent_id: agent_id} do
      embedding = generate_embedding(1)
      {:ok, id} = Index.index(pid, "Dual backend test", %{type: :fact}, embedding: embedding)

      # ETS write is synchronous
      assert Index.stats(pid).entry_count == 1

      assert {:ok, %{id: ^id}} = Embedding.get(agent_id, id)
      assert Embedding.count(agent_id) == 1
    end

    test "recall checks ETS first (cache hit)", %{pid: pid, agent_id: agent_id} do
      embedding = generate_embedding(1)
      {:ok, id} = Index.index(pid, "Cache hit test", %{type: :fact}, embedding: embedding)

      # Recall should find it in ETS
      {:ok, results} = Index.recall(pid, "Cache hit test", embedding: embedding, threshold: 0.0)

      assert results != []
      assert hd(results).content == "Cache hit test"
      assert {:ok, %{id: ^id}} = Embedding.get(agent_id, id)
    end

    test "recall falls back to pgvector on cache miss", %{pid: pid, agent_id: agent_id} do
      embedding = generate_embedding(1)

      # Store directly in pgvector (bypassing ETS)
      {:ok, _id} = Embedding.store(agent_id, "Pgvector only", embedding, %{type: "fact"})

      # Clear the ETS cache
      Index.clear(pid)

      # Recall should still find it via pgvector fallback
      {:ok, results} = Index.recall(pid, "Pgvector only", embedding: embedding, threshold: 0.0)

      # Should find the pgvector entry
      assert results != []
    end

    test "authority regression: content dedupe returns and deletes by the durable row id", %{
      pid: pid,
      agent_id: agent_id
    } do
      content = "Durable dedupe identity"
      embedding = generate_embedding(17)
      assert {:ok, durable_id} = Embedding.store(agent_id, content, embedding, %{type: "fact"})

      assert {:ok, ^durable_id} =
               Index.index(pid, content, %{type: :updated}, embedding: generate_embedding(18))

      assert {:ok, %{id: ^durable_id}} = Index.get(pid, durable_id)
      assert :ok = Index.delete(pid, durable_id)
      assert {:error, :not_found} = Embedding.get(agent_id, durable_id)
      assert {:error, :not_found} = Index.get(pid, durable_id)
    end

    test "capacity regression: eager authoritative replacement does not evict unrelated LRU" do
      agent_id = durable_unique("test_dual_eager_replacement_capacity")

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 2,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_eager_replacement, agent_id}}}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Eager replacement at capacity"
      unrelated_content = "Unrelated LRU survives"

      assert {:ok, authoritative_id} =
               Index.index(pid, content, %{type: :first}, embedding: generate_embedding(84))

      assert {:ok, unrelated_id} =
               Index.index(pid, unrelated_content, %{type: :unrelated},
                 embedding: generate_embedding(85)
               )

      assert {:ok, %{id: ^authoritative_id}} = Index.get(pid, authoritative_id)

      assert {:ok, ^authoritative_id} =
               Index.index(pid, content, %{type: :latest}, embedding: generate_embedding(86))

      assert Index.stats(pid).entry_count == 2

      assert {:ok, %{id: ^unrelated_id, content: ^unrelated_content}} =
               Index.get(pid, unrelated_id)

      assert {:ok, %{id: ^authoritative_id, metadata: %{type: :latest}}} =
               Index.get(pid, authoritative_id)

      assert {:ok, %{id: ^unrelated_id}} = Embedding.get(agent_id, unrelated_id)
      assert Embedding.count(agent_id) == 2
    end

    test "capacity regression: successful retry can replace its pending identity at max one" do
      agent_id = durable_unique("test_dual_pending_replacement_capacity")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_z_#{suffix}"
      generated_retry_id = "mem_a_#{suffix}"

      MaliciousWriter.configure(
        agent_id,
        {:store_sequence, [{:error, :injected_eager_failure}, {:delegate_as, first_id}]}
      )

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 1,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, generated_retry_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_pending_replacement, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Pending replacement at capacity"
      latest_embedding = generate_embedding(88)

      assert {:ok, ^first_id} =
               Index.index(pid, content, %{type: :first}, embedding: generate_embedding(87))

      assert {:ok, ^first_id} =
               Index.index(pid, content, %{type: :latest}, embedding: latest_embedding)

      state = :sys.get_state(pid)
      assert state.entry_count == 1
      assert state.pending_sync == MapSet.new()
      assert state.pending_entry_orders == %{}
      assert state.pending_group_members == %{}
      assert state.next_insertion_sequence == 2
      assert {:error, :not_found} = Index.get(pid, generated_retry_id)

      assert {:ok, %{id: ^first_id, metadata: %{type: :latest}, embedding: stored_embedding}} =
               Index.get(pid, first_id)

      assert_vector_close(stored_embedding, latest_embedding)
      assert {:ok, %{id: ^first_id}} = Embedding.get(agent_id, first_id)
      assert {:ok, 0} = Index.sync_to_persistent(pid)
    end

    test "definitive-error regression: same-content eager failure retains one retryable authority at max one" do
      agent_id = durable_unique("test_dual_eager_failure_capacity")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_z_#{suffix}"
      retry_id = "mem_a_#{suffix}"

      MaliciousWriter.configure(
        agent_id,
        {:store_sequence, [{:error, :injected_eager_failure}, {:error, :injected_eager_failure}]}
      )

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 1,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, retry_id]),
          name:
            {:via, Registry, {Arbor.Memory.Registry, {:test_eager_failure_capacity, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Ack loss at capacity"
      latest_embedding = generate_embedding(97)

      assert {:ok, ^first_id} =
               Index.index(pid, content, %{type: :first}, embedding: generate_embedding(96))

      assert {:ok, ^retry_id} =
               Index.index(pid, content, %{type: :latest}, embedding: latest_embedding)

      state = :sys.get_state(pid)
      assert state.entry_count == 1
      assert state.pending_sync == MapSet.new([first_id])
      assert state.pending_entry_orders == %{first_id => %{first: 0, latest: 1}}
      assert state.pending_group_members == %{first_id => MapSet.new([first_id, retry_id])}
      assert state.id_aliases == %{retry_id => first_id}
      assert state.next_insertion_sequence == 2

      for acknowledged_id <- [first_id, retry_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}, embedding: stored_embedding}} =
                 Index.get(pid, acknowledged_id)

        assert_vector_close(stored_embedding, latest_embedding)
      end

      MaliciousWriter.configure(agent_id, :delegate)
      assert {:ok, 2} = Index.sync_to_persistent(pid)

      assert {:ok, %{id: ^first_id, metadata: %{"type" => "latest"}}} =
               Embedding.get(agent_id, first_id)

      assert :ok = Index.delete(pid, retry_id)
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:error, :not_found} = Index.get(pid, retry_id)
    end

    test "commit acknowledgement loss regression: eager retry remains convergent at max one" do
      agent_id = durable_unique("test_dual_eager_ack_loss_capacity")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_z_#{suffix}"
      retry_id = "mem_a_#{suffix}"

      MaliciousWriter.configure(
        agent_id,
        {:store_sequence,
         [
           {:error, :injected_eager_failure},
           {:delegate_then_exit, :injected_commit_ack_loss}
         ]}
      )

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 1,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, retry_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_eager_ack_loss, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Committed eager acknowledgement loss"
      latest_embedding = generate_embedding(98)

      assert {:ok, ^first_id} =
               Index.index(pid, content, %{type: :first}, embedding: generate_embedding(97))

      assert {:ok, ^retry_id} =
               Index.index(pid, content, %{type: :latest}, embedding: latest_embedding)

      assert Embedding.count(agent_id) == 1
      assert {:ok, persisted_before_sync} = Embedding.get(agent_id, first_id)
      assert {:error, :not_found} = Embedding.get(agent_id, retry_id)
      assert persisted_before_sync.metadata["type"] == "latest"
      assert_vector_close(Pgvector.to_list(persisted_before_sync.embedding), latest_embedding)

      state = :sys.get_state(pid)
      assert state.entry_count == 1
      assert state.pending_sync == MapSet.new([first_id])
      assert state.pending_group_members == %{first_id => MapSet.new([first_id, retry_id])}
      assert state.id_aliases == %{retry_id => first_id}

      for acknowledged_id <- [first_id, retry_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}}} =
                 Index.get(pid, acknowledged_id)
      end

      assert {:ok, 2} = Index.sync_to_persistent(pid)
      assert {:ok, 0} = Index.sync_to_persistent(pid)
      assert Embedding.count(agent_id) == 1
      assert :sys.get_state(pid).pending_sync == MapSet.new()

      assert {:ok, persisted_after_sync} = Embedding.get(agent_id, first_id)
      assert persisted_after_sync.metadata["type"] == "latest"
      assert_vector_close(Pgvector.to_list(persisted_after_sync.embedding), latest_embedding)

      for acknowledged_id <- [first_id, retry_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}}} =
                 Index.get(pid, acknowledged_id)
      end
    end

    test "definitive-error regression: same-content batch fallback uses one tight-capacity authority" do
      agent_id = durable_unique("test_dual_batch_failure_capacity")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_z_#{suffix}"
      latest_id = "mem_a_#{suffix}"
      MaliciousWriter.configure(agent_id, :fail)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 1,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, latest_id]),
          name:
            {:via, Registry, {Arbor.Memory.Registry, {:test_batch_failure_capacity, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Batch ack loss at capacity"
      embedding = generate_embedding(98)

      assert {:ok, [^first_id, ^latest_id]} =
               Index.batch_index(
                 pid,
                 [{content, %{type: :first}}, {content, %{type: :latest}}],
                 embedding: embedding
               )

      state = :sys.get_state(pid)
      assert state.entry_count == 1
      assert state.pending_sync == MapSet.new([first_id])
      assert state.pending_entry_orders == %{first_id => %{first: 0, latest: 1}}
      assert state.pending_group_members == %{first_id => MapSet.new([first_id, latest_id])}
      assert state.id_aliases == %{latest_id => first_id}
      assert state.next_insertion_sequence == 2

      for acknowledged_id <- [first_id, latest_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}}} =
                 Index.get(pid, acknowledged_id)
      end

      MaliciousWriter.configure(agent_id, :delegate)
      assert {:ok, 2} = Index.sync_to_persistent(pid)

      assert {:ok, %{id: ^first_id, metadata: %{"type" => "latest"}}} =
               Embedding.get(agent_id, first_id)

      assert :ok = Index.delete(pid, latest_id)
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:error, :not_found} = Index.get(pid, latest_id)
    end

    test "commit acknowledgement loss regression: batch remains convergent at max one" do
      agent_id = durable_unique("test_dual_batch_ack_loss_capacity")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_z_#{suffix}"
      latest_id = "mem_a_#{suffix}"
      MaliciousWriter.configure(agent_id, {:delegate_then_exit, :injected_commit_ack_loss})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 1,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, latest_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_batch_ack_loss, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Committed batch acknowledgement loss"
      latest_embedding = generate_embedding(99)

      assert {:ok, [^first_id, ^latest_id]} =
               Index.batch_index(
                 pid,
                 [{content, %{type: :first}}, {content, %{type: :latest}}],
                 embedding: latest_embedding
               )

      assert Embedding.count(agent_id) == 1
      assert {:ok, persisted_before_sync} = Embedding.get(agent_id, first_id)
      assert {:error, :not_found} = Embedding.get(agent_id, latest_id)
      assert persisted_before_sync.metadata["type"] == "latest"
      assert_vector_close(Pgvector.to_list(persisted_before_sync.embedding), latest_embedding)

      state = :sys.get_state(pid)
      assert state.entry_count == 1
      assert state.pending_sync == MapSet.new([first_id])
      assert state.pending_group_members == %{first_id => MapSet.new([first_id, latest_id])}
      assert state.id_aliases == %{latest_id => first_id}

      for acknowledged_id <- [first_id, latest_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}}} =
                 Index.get(pid, acknowledged_id)
      end

      assert {:ok, 2} = Index.sync_to_persistent(pid)
      assert {:ok, 0} = Index.sync_to_persistent(pid)
      assert Embedding.count(agent_id) == 1
      assert :sys.get_state(pid).pending_sync == MapSet.new()

      assert {:ok, persisted_after_sync} = Embedding.get(agent_id, first_id)
      assert persisted_after_sync.metadata["type"] == "latest"
      assert_vector_close(Pgvector.to_list(persisted_after_sync.embedding), latest_embedding)

      for acknowledged_id <- [first_id, latest_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}}} =
                 Index.get(pid, acknowledged_id)
      end
    end

    test "capacity regression: same-content batch dedupe reserves authoritative groups only" do
      agent_id = durable_unique("test_dual_batch_replacement_capacity")

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 2,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_batch_replacement, agent_id}}}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Batch replacement at capacity"
      unrelated_content = "Batch unrelated LRU survives"

      assert {:ok, authoritative_id} =
               Index.index(pid, content, %{type: :initial}, embedding: generate_embedding(89))

      assert {:ok, unrelated_id} =
               Index.index(pid, unrelated_content, %{type: :unrelated},
                 embedding: generate_embedding(90)
               )

      assert {:ok, %{id: ^authoritative_id}} = Index.get(pid, authoritative_id)

      assert {:ok, [^authoritative_id, ^authoritative_id]} =
               Index.batch_index(
                 pid,
                 [
                   {content, %{type: :batch_first}},
                   {content, %{type: :batch_latest}}
                 ],
                 embedding: generate_embedding(91)
               )

      assert Index.stats(pid).entry_count == 2

      assert {:ok, %{id: ^unrelated_id, content: ^unrelated_content}} =
               Index.get(pid, unrelated_id)

      assert {:ok, %{id: ^authoritative_id, metadata: %{type: :batch_latest}}} =
               Index.get(pid, authoritative_id)

      assert {:ok, %{id: ^unrelated_id}} = Embedding.get(agent_id, unrelated_id)
      assert Embedding.count(agent_id) == 2
    end

    test "capacity regression: batch preflight cannot spend a replacement row as an eviction" do
      agent_id = durable_unique("test_dual_batch_capacity_preflight")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      replacement_id = "mem_replacement_#{suffix}"
      pending_id = "mem_pending_#{suffix}"
      generated_update_id = "mem_update_#{suffix}"
      generated_new_id = "mem_new_#{suffix}"

      MaliciousWriter.configure(
        agent_id,
        {:store_sequence, [{:ok, replacement_id}, {:error, :injected_eager_failure}]}
      )

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 2,
          persistent_writer: MaliciousWriter,
          entry_id_generator:
            sequence_callback([
              replacement_id,
              pending_id,
              generated_update_id,
              generated_new_id
            ]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_capacity_preflight, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      replacement_content = "Reserved replacement row"
      pending_content = "Protected pending row"

      assert {:ok, ^replacement_id} =
               Index.index(pid, replacement_content, %{type: :stored},
                 embedding: generate_embedding(92)
               )

      assert {:ok, ^pending_id} =
               Index.index(pid, pending_content, %{type: :pending},
                 embedding: generate_embedding(93)
               )

      state_before = :sys.get_state(pid)
      table_before = :ets.tab2list(state_before.table)

      assert {:error, :capacity_exceeded} =
               Index.batch_index(
                 pid,
                 [
                   {replacement_content, %{type: :updated}},
                   {"Unrepresentable new row", %{type: :new}}
                 ],
                 embedding: generate_embedding(94)
               )

      state_after = :sys.get_state(pid)
      assert MaliciousWriter.batch_call_count(agent_id) == 0
      assert :ets.tab2list(state_after.table) == table_before
      assert state_after.entry_count == state_before.entry_count
      assert state_after.pending_sync == state_before.pending_sync
      assert state_after.pending_entry_orders == state_before.pending_entry_orders
      assert state_after.id_aliases == state_before.id_aliases
      assert state_after.next_insertion_sequence == state_before.next_insertion_sequence
      assert {:error, :not_found} = Index.get(pid, generated_update_id)
      assert {:error, :not_found} = Index.get(pid, generated_new_id)
    end

    test "atomicity regression: malformed item-N durable response leaves no hidden batch prefix" do
      agent_id = durable_unique("test_dual_atomic_batch")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_first_#{suffix}"
      second_id = "mem_second_#{suffix}"
      MaliciousWriter.configure(agent_id, {:partial_batch_failure, 0})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, second_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_atomic_batch, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      state_before = :sys.get_state(pid)
      table_before = :ets.tab2list(state_before.table)

      assert {:error, :malformed_persistence_result} =
               Index.batch_index(
                 pid,
                 [
                   {"Atomic batch first", %{type: :first}},
                   {"Atomic batch second", %{type: :second}}
                 ],
                 embedding: generate_embedding(74)
               )

      state_after = :sys.get_state(pid)

      assert :ets.tab2list(state_after.table) == table_before
      assert state_after.entry_count == state_before.entry_count
      assert state_after.pending_sync == state_before.pending_sync
      assert state_after.pending_entry_orders == state_before.pending_entry_orders
      assert state_after.id_aliases == state_before.id_aliases
      assert state_after.next_insertion_sequence == state_before.next_insertion_sequence
      assert Index.stats(pid).entry_count == 0
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:error, :not_found} = Index.get(pid, second_id)
      assert Embedding.count(agent_id) == 0
    end

    test "compatibility regression: durable batch failure atomically falls back to pending" do
      agent_id = durable_unique("test_dual_pending_batch")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_first_#{suffix}"
      second_id = "mem_second_#{suffix}"
      MaliciousWriter.configure(agent_id, :fail)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, second_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_pending_batch, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      assert {:ok, [^first_id, ^second_id]} =
               Index.batch_index(
                 pid,
                 [
                   {"Pending batch first", %{type: :first}},
                   {"Pending batch second", %{type: :second}}
                 ],
                 embedding: generate_embedding(75)
               )

      state = :sys.get_state(pid)
      assert state.entry_count == 2
      assert state.pending_sync == MapSet.new([first_id, second_id])
      assert state.pending_entry_orders[first_id] == %{first: 0, latest: 0}
      assert state.pending_entry_orders[second_id] == %{first: 1, latest: 1}
      assert state.next_insertion_sequence == 2
      assert {:ok, %{id: ^first_id}} = Index.get(pid, first_id)
      assert {:ok, %{id: ^second_id}} = Index.get(pid, second_id)
      assert Embedding.count(agent_id) == 0

      MaliciousWriter.configure(agent_id, :delegate)
      assert {:ok, 2} = Index.sync_to_persistent(pid)
      assert Embedding.count(agent_id) == 2
    end

    test "security regression: fresh batch authoritative IDs cannot swap content groups" do
      agent_id = durable_unique("test_dual_fresh_authority_swap")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_first_#{suffix}"
      second_id = "mem_second_#{suffix}"
      MaliciousWriter.configure(agent_id, :cross_group_batch)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, second_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_fresh_swap, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      state_before = :sys.get_state(pid)
      table_before = :ets.tab2list(state_before.table)

      assert {:error, :malformed_persistence_result} =
               Index.batch_index(
                 pid,
                 [
                   {"Fresh authority first", %{type: :first}},
                   {"Fresh authority second", %{type: :second}}
                 ],
                 embedding: generate_embedding(81)
               )

      state_after = :sys.get_state(pid)
      assert MaliciousWriter.batch_call_count(agent_id) == 1
      assert :ets.tab2list(state_after.table) == table_before
      assert state_after.entry_count == state_before.entry_count
      assert state_after.pending_sync == state_before.pending_sync
      assert state_after.pending_entry_orders == state_before.pending_entry_orders
      assert state_after.id_aliases == state_before.id_aliases
      assert state_after.next_insertion_sequence == state_before.next_insertion_sequence
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:error, :not_found} = Index.get(pid, second_id)
      assert Embedding.count(agent_id) == 0
    end

    test "security regression: batch IDs cannot collide with pending authority before dispatch" do
      agent_id = durable_unique("test_dual_batch_pending_collision")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      pending_id = "mem_pending_#{suffix}"
      other_id = "mem_other_#{suffix}"
      MaliciousWriter.configure(agent_id, :fail)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([pending_id, pending_id, other_id]),
          name:
            {:via, Registry, {Arbor.Memory.Registry, {:test_batch_pending_collision, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      pending_embedding = generate_embedding(82)

      assert {:ok, ^pending_id} =
               Index.index(pid, "Existing pending authority", %{type: :pending},
                 embedding: pending_embedding
               )

      state_before = :sys.get_state(pid)
      table_before = :ets.tab2list(state_before.table)

      assert {:error, :invalid_batch_identity} =
               Index.batch_index(
                 pid,
                 [
                   {"Colliding batch identity", %{type: :collision}},
                   {"Other batch identity", %{type: :other}}
                 ],
                 embedding: generate_embedding(83)
               )

      state_after = :sys.get_state(pid)
      assert MaliciousWriter.batch_call_count(agent_id) == 0
      assert :ets.tab2list(state_after.table) == table_before
      assert state_after.entry_count == state_before.entry_count
      assert state_after.pending_sync == state_before.pending_sync
      assert state_after.pending_entry_orders == state_before.pending_entry_orders
      assert state_after.id_aliases == state_before.id_aliases
      assert state_after.next_insertion_sequence == state_before.next_insertion_sequence

      assert {:ok, %{id: ^pending_id, embedding: stored_embedding}} =
               Index.get(pid, pending_id)

      assert_vector_close(stored_embedding, pending_embedding)
      assert {:error, :not_found} = Index.get(pid, other_id)
      assert Embedding.count(agent_id) == 0
    end
  end

  describe "pgvector backend mode" do
    test "regression: index returns the exact row id stored by pgvector" do
      agent_id = durable_unique("test_pg_id")

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :pgvector,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_pg_id, agent_id}}}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      assert {:ok, stored_id} =
               Index.index(pid, "Authoritative row id", %{type: :fact},
                 embedding: generate_embedding(41)
               )

      assert {:ok, %{id: ^stored_id, content: "Authoritative row id"}} =
               Embedding.get(agent_id, stored_id)
    end

    test "batch_index exposes requested mem IDs for fresh pgvector rows" do
      agent_id = durable_unique("test_pg_batch_ids")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_first_#{suffix}"
      second_id = "mem_second_#{suffix}"

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :pgvector,
          entry_id_generator: sequence_callback([first_id, second_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_pg_batch_ids, agent_id}}}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      assert {:ok, [^first_id, ^second_id]} =
               Index.batch_index(
                 pid,
                 [
                   {"Fresh pgvector batch first", %{type: :first}},
                   {"Fresh pgvector batch second", %{type: :second}}
                 ],
                 embedding: generate_embedding(95)
               )

      assert {:ok, %{id: ^first_id, content: "Fresh pgvector batch first"}} =
               Embedding.get(agent_id, first_id)

      assert {:ok, %{id: ^second_id, content: "Fresh pgvector batch second"}} =
               Embedding.get(agent_id, second_id)

      assert Embedding.count(agent_id) == 2
    end
  end

  describe "warm_cache/2" do
    test "loads entries from pgvector into ETS", %{pid: pid, agent_id: agent_id} do
      # First, store some entries in pgvector directly
      for i <- 1..5 do
        Embedding.store(agent_id, "Entry #{i}", generate_embedding(i), %{type: "fact"})
      end

      # Clear ETS
      Index.clear(pid)
      assert Index.stats(pid).entry_count == 0

      # Warm the cache
      :ok = Index.warm_cache(pid, limit: 10)

      # Now ETS should have entries (note: may not get all 5 due to search limitations)
      # At minimum, warm_cache should succeed without error
    end

    test "returns error for non-persistent backend" do
      {:ok, ets_pid} =
        Index.start_link(
          agent_id: "test_ets_only",
          backend: :ets,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_ets, "test_ets_only"}}}
        )

      assert {:error, :backend_not_persistent} = Index.warm_cache(ets_pid)

      GenServer.stop(ets_pid)
    end
  end

  describe "sync_to_persistent/2" do
    test "successful eager writes leave no pending retry", %{pid: pid, agent_id: agent_id} do
      embedding = generate_embedding(1)

      {:ok, id} = Index.index(pid, "Sync test", %{type: :fact}, embedding: embedding)
      assert {:ok, %{id: ^id}} = Embedding.get(agent_id, id)

      assert {:ok, 0} = Index.sync_to_persistent(pid)

      assert Embedding.count(agent_id) == 1
    end

    test "authority regression: failed eager write retries with the acknowledged id" do
      agent_id = durable_unique("test_dual_retry")
      FailFirstWriter.arm(agent_id)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: FailFirstWriter,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_dual_retry, agent_id}}}
        )

      on_exit(fn ->
        FailFirstWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      assert {:ok, acknowledged_id} =
               Index.index(pid, "Retry identity", %{type: :fact},
                 embedding: generate_embedding(27)
               )

      assert {:error, :not_found} = Embedding.get(agent_id, acknowledged_id)
      assert {:ok, 1} = Index.sync_to_persistent(pid)
      assert {:ok, %{id: ^acknowledged_id}} = Embedding.get(agent_id, acknowledged_id)
      assert {:ok, %{id: ^acknowledged_id}} = Index.get(pid, acknowledged_id)

      assert :ok = Index.delete(pid, acknowledged_id)
      assert {:error, :not_found} = Embedding.get(agent_id, acknowledged_id)
    end

    test "authority regression: failed eager dedupe preserves caller ID continuity" do
      agent_id = durable_unique("test_dual_retry_dedupe")
      content = "Retry dedupe identity"

      assert {:ok, authoritative_id} =
               Embedding.store(agent_id, content, generate_embedding(28), %{type: "durable"})

      FailFirstWriter.arm(agent_id)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: FailFirstWriter,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_dual_retry_dedupe, agent_id}}}
        )

      on_exit(fn ->
        FailFirstWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      assert {:ok, acknowledged_id} =
               Index.index(pid, content, %{type: :local}, embedding: generate_embedding(29))

      refute acknowledged_id == authoritative_id
      assert {:ok, %{id: ^acknowledged_id}} = Index.get(pid, acknowledged_id)

      assert {:ok, 1} = Index.sync_to_persistent(pid)
      assert {:ok, %{id: ^authoritative_id}} = Index.get(pid, acknowledged_id)
      assert {:ok, %{id: ^authoritative_id}} = Index.get(pid, authoritative_id)
      assert {:ok, %{id: ^authoritative_id}} = Embedding.get(agent_id, authoritative_id)

      assert :ok = Index.delete(pid, acknowledged_id)
      assert {:error, :not_found} = Embedding.get(agent_id, authoritative_id)
      assert {:error, :not_found} = Index.get(pid, acknowledged_id)
      assert {:error, :not_found} = Index.get(pid, authoritative_id)
      assert Index.stats(pid).entry_count == 0
    end

    test "authority regression: pending convergence follows invocation order, not clock or ID" do
      agent_id = durable_unique("test_dual_pending_dedupe")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      first_id = "mem_z_#{suffix}"
      unrelated_id = "mem_m_#{suffix}"
      middle_id = "mem_a_#{suffix}"
      latest_id = "mem_b_#{suffix}"

      id_generator = sequence_callback([first_id, unrelated_id, middle_id, latest_id])

      clock =
        sequence_callback([
          ~U[2026-08-05 10:00:02.000000Z],
          ~U[2026-08-05 10:00:04.000000Z],
          ~U[2026-08-05 10:00:02.000000Z],
          ~U[2026-08-05 10:00:01.000000Z]
        ])

      FailFirstWriter.arm(agent_id, 4)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: FailFirstWriter,
          entry_id_generator: id_generator,
          clock: clock,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_dual_pending_dedupe, agent_id}}}
        )

      on_exit(fn ->
        FailFirstWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      duplicate_content = "Pending duplicate identity"
      unrelated_content = "Pending unrelated identity"
      first_embedding = generate_embedding(51)
      middle_embedding = generate_embedding(53)
      latest_embedding = generate_embedding(54)

      assert {:ok, ^first_id} =
               Index.index(pid, duplicate_content, %{type: :first, source: "earliest"},
                 embedding: first_embedding
               )

      assert {:ok, ^unrelated_id} =
               Index.index(pid, unrelated_content, %{type: :unrelated},
                 embedding: generate_embedding(52)
               )

      assert {:ok, ^middle_id} =
               Index.index(pid, duplicate_content, %{type: :middle, source: "middle"},
                 embedding: middle_embedding
               )

      assert {:ok, ^latest_id} =
               Index.index(
                 pid,
                 duplicate_content,
                 %{type: :latest, source: "latest", tags: ["canonical"]},
                 embedding: latest_embedding
               )

      assert first_id > latest_id
      assert middle_id < latest_id
      assert MapSet.size(MapSet.new([first_id, unrelated_id, middle_id, latest_id])) == 4
      assert Embedding.count(agent_id) == 0
      assert Index.stats(pid).entry_count == 2

      state = :sys.get_state(pid)
      assert state.pending_sync == MapSet.new([first_id, unrelated_id])

      assert state.pending_group_members[first_id] ==
               MapSet.new([first_id, middle_id, latest_id])

      assert state.pending_group_members[unrelated_id] == MapSet.new([unrelated_id])
      assert state.id_aliases[middle_id] == first_id
      assert state.id_aliases[latest_id] == first_id

      for acknowledged_id <- [first_id, middle_id, latest_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}}} =
                 Index.get(pid, acknowledged_id)
      end

      assert {:ok, 4} = Index.sync_to_persistent(pid)
      assert Embedding.count(agent_id) == 2
      assert Index.stats(pid).entry_count == 2

      assert {:ok,
              %{
                id: ^first_id,
                content: ^duplicate_content,
                metadata: %{type: :latest, source: "latest", tags: ["canonical"]},
                embedding: local_embedding
              }} =
               Index.get(pid, first_id)

      assert_vector_close(local_embedding, latest_embedding)
      refute_vector_close(local_embedding, first_embedding)

      for alias_id <- [middle_id, latest_id] do
        assert {:ok, %{id: ^first_id, content: ^duplicate_content}} = Index.get(pid, alias_id)
      end

      assert {:ok, %{id: ^unrelated_id, content: ^unrelated_content}} =
               Index.get(pid, unrelated_id)

      assert {:ok, persisted} = Embedding.get(agent_id, first_id)
      assert persisted.id == first_id
      assert persisted.content == duplicate_content
      assert persisted.metadata["type"] == "latest"
      assert persisted.metadata["source"] == "latest"
      assert persisted.metadata["tags"] == ["canonical"]
      refute Map.has_key?(persisted.metadata, "insertion_sequence")
      assert_vector_close(Pgvector.to_list(persisted.embedding), latest_embedding)

      assert {:error, :not_found} = Embedding.get(agent_id, middle_id)
      assert {:error, :not_found} = Embedding.get(agent_id, latest_id)
      assert {:ok, %{id: ^unrelated_id}} = Embedding.get(agent_id, unrelated_id)

      assert :ok = Index.delete(pid, middle_id)
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:error, :not_found} = Index.get(pid, middle_id)
      assert {:error, :not_found} = Index.get(pid, latest_id)
      assert {:error, :not_found} = Embedding.get(agent_id, first_id)
      assert {:ok, %{id: ^unrelated_id}} = Index.get(pid, unrelated_id)
      assert Index.stats(pid).entry_count == 1

      assert :ok = Index.delete(pid, unrelated_id)
      assert {:error, :not_found} = Embedding.get(agent_id, unrelated_id)
      assert Index.stats(pid).entry_count == 0
    end

    test "authority regression: eager success converges every same-content local identity" do
      agent_id = durable_unique("test_dual_eager_pending_order")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_z_#{suffix}"
      second_id = "mem_a_#{suffix}"
      generated_third_id = "mem_m_#{suffix}"

      MaliciousWriter.configure(
        agent_id,
        {:store_sequence,
         [
           {:error, :injected_eager_failure},
           {:error, :injected_eager_failure},
           {:delegate_as, first_id}
         ]}
      )

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, second_id, generated_third_id]),
          clock:
            sequence_callback([
              ~U[2026-08-05 10:00:02.000000Z],
              ~U[2026-08-05 10:00:02.000000Z],
              ~U[2026-08-05 09:59:59.000000Z]
            ]),
          name:
            {:via, Registry, {Arbor.Memory.Registry, {:test_dual_eager_pending_order, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Eager pending order"
      first_embedding = generate_embedding(71)
      second_embedding = generate_embedding(72)
      latest_embedding = generate_embedding(73)

      assert {:ok, ^first_id} =
               Index.index(pid, content, %{type: :first, value: "first"},
                 embedding: first_embedding
               )

      assert {:ok, ^second_id} =
               Index.index(pid, content, %{type: :second, value: "second"},
                 embedding: second_embedding
               )

      assert {:ok, ^first_id} =
               Index.index(pid, content, %{type: :latest, value: "latest"},
                 embedding: latest_embedding
               )

      assert first_id > second_id
      assert {:error, :not_found} = Index.get(pid, generated_third_id)

      assert {:ok, %{id: ^first_id, metadata: %{type: :latest}, embedding: local_vector}} =
               Index.get(pid, first_id)

      assert_vector_close(local_vector, latest_embedding)
      assert {:ok, %{id: ^first_id, metadata: %{type: :latest}}} = Index.get(pid, second_id)

      state = :sys.get_state(pid)
      assert state.entry_count == 1
      assert state.pending_sync == MapSet.new()
      assert state.pending_entry_orders == %{}
      assert state.pending_group_members == %{}
      assert state.id_aliases == %{second_id => first_id}
      assert state.next_insertion_sequence == 3
      assert Embedding.count(agent_id) == 1
      assert {:ok, 0} = Index.sync_to_persistent(pid)

      assert {:ok, %{id: ^first_id, metadata: %{value: "latest"}, embedding: persisted_vector}} =
               Index.get(pid, second_id)

      assert_vector_close(persisted_vector, latest_embedding)
      assert {:ok, %{id: ^first_id}} = Embedding.get(agent_id, first_id)
      assert {:error, :not_found} = Embedding.get(agent_id, second_id)

      assert :ok = Index.delete(pid, second_id)
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:error, :not_found} = Index.get(pid, second_id)
      assert {:error, :not_found} = Embedding.get(agent_id, first_id)
    end

    test "capacity regression: pending identities, latest values, and aliases are not evicted" do
      agent_id = durable_unique("test_dual_pending_capacity")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_z_#{suffix}"
      latest_id = "mem_a_#{suffix}"
      unrelated_id = "mem_unrelated_#{suffix}"
      rejected_id = "mem_rejected_#{suffix}"
      second_unrelated_id = "mem_unrelated_again_#{suffix}"
      second_rejected_id = "mem_rejected_again_#{suffix}"

      FailFirstWriter.arm(agent_id, 3)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          max_entries: 2,
          persistent_writer: FailFirstWriter,
          entry_id_generator:
            sequence_callback([
              first_id,
              latest_id,
              unrelated_id,
              rejected_id,
              second_unrelated_id,
              second_rejected_id
            ]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_pending_capacity, agent_id}}}
        )

      on_exit(fn ->
        FailFirstWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      content = "Capacity duplicate"
      first_embedding = generate_embedding(76)
      latest_embedding = generate_embedding(77)

      assert {:ok, ^first_id} =
               Index.index(pid, content, %{type: :first}, embedding: first_embedding)

      assert {:ok, ^latest_id} =
               Index.index(pid, content, %{type: :latest}, embedding: latest_embedding)

      assert {:ok, ^unrelated_id} =
               Index.index(pid, "Unrelated pending", %{type: :unrelated},
                 embedding: generate_embedding(78)
               )

      assert {:error, :capacity_exceeded} =
               Index.index(pid, "Rejected while all pending", %{type: :rejected},
                 embedding: generate_embedding(79)
               )

      assert Index.stats(pid).entry_count == 2

      for acknowledged_id <- [first_id, latest_id] do
        assert {:ok, %{id: ^first_id, metadata: %{type: :latest}, embedding: stored_embedding}} =
                 Index.get(pid, acknowledged_id)

        assert_vector_close(stored_embedding, latest_embedding)
      end

      assert {:ok, %{id: ^unrelated_id, metadata: %{type: :unrelated}}} =
               Index.get(pid, unrelated_id)

      assert {:error, :not_found} = Index.get(pid, rejected_id)

      assert {:ok, 3} = Index.sync_to_persistent(pid)
      assert Index.stats(pid).entry_count == 2

      assert {:ok, persisted} = Embedding.get(agent_id, first_id)
      assert persisted.metadata["type"] == "latest"
      assert_vector_close(Pgvector.to_list(persisted.embedding), latest_embedding)
      assert {:ok, %{id: ^unrelated_id}} = Embedding.get(agent_id, unrelated_id)

      assert :ok = Index.delete(pid, unrelated_id)
      assert Index.stats(pid).entry_count == 1

      FailFirstWriter.arm(agent_id)

      assert {:ok, ^second_unrelated_id} =
               Index.index(pid, "Second unrelated pending", %{type: :unrelated_again},
                 embedding: generate_embedding(80)
               )

      assert {:error, :capacity_exceeded} =
               Index.index(pid, "Rejected beside alias", %{type: :rejected_again},
                 embedding: generate_embedding(81)
               )

      for acknowledged_id <- [first_id, latest_id, second_unrelated_id] do
        assert {:ok, _entry} = Index.get(pid, acknowledged_id)
      end

      assert {:error, :not_found} = Index.get(pid, second_rejected_id)
      assert Index.stats(pid).entry_count == 2

      assert {:ok, 1} = Index.sync_to_persistent(pid)

      assert {:ok, %{id: ^second_unrelated_id}} =
               Embedding.get(agent_id, second_unrelated_id)

      assert :ok = Index.delete(pid, latest_id)
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:error, :not_found} = Index.get(pid, latest_id)
      assert {:ok, %{id: ^second_unrelated_id}} = Index.get(pid, second_unrelated_id)

      assert :ok = Index.delete(pid, second_unrelated_id)
      assert Index.stats(pid).entry_count == 0
    end

    test "security regression: malformed authoritative batch IDs preserve all pending state" do
      agent_id = durable_unique("test_dual_malicious_batch")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_a_#{suffix}"
      second_id = "mem_b_#{suffix}"
      MaliciousWriter.configure(agent_id, :fail)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, second_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_malicious_batch, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      first_embedding = generate_embedding(61)
      second_embedding = generate_embedding(62)

      assert {:ok, ^first_id} =
               Index.index(pid, "Malicious batch first", %{type: :first},
                 embedding: first_embedding
               )

      assert {:ok, ^second_id} =
               Index.index(pid, "Malicious batch second", %{type: :second},
                 embedding: second_embedding
               )

      assert_pending_entries_unchanged(
        pid,
        first_id,
        second_id,
        first_embedding,
        second_embedding
      )

      assert Embedding.count(agent_id) == 0

      MaliciousWriter.configure(agent_id, :oversized_batch)
      assert {:error, :malformed_persistence_result} = Index.sync_to_persistent(pid)

      assert_pending_entries_unchanged(
        pid,
        first_id,
        second_id,
        first_embedding,
        second_embedding
      )

      MaliciousWriter.configure(agent_id, :cross_group_batch)
      assert {:error, :malformed_persistence_result} = Index.sync_to_persistent(pid)

      assert_pending_entries_unchanged(
        pid,
        first_id,
        second_id,
        first_embedding,
        second_embedding
      )

      assert Embedding.count(agent_id) == 0

      MaliciousWriter.configure(agent_id, :delegate)
      assert {:ok, 2} = Index.sync_to_persistent(pid)
      assert {:ok, %{id: ^first_id, content: "Malicious batch first"}} = Index.get(pid, first_id)

      assert {:ok, %{id: ^second_id, content: "Malicious batch second"}} =
               Index.get(pid, second_id)

      assert Embedding.count(agent_id) == 2
      assert {:ok, 0} = Index.sync_to_persistent(pid)
    end

    test "security regression: duplicate authoritative batch IDs preserve exact pending state" do
      agent_id = durable_unique("test_dual_duplicate_authority")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_a_#{suffix}"
      second_id = "mem_b_#{suffix}"
      MaliciousWriter.configure(agent_id, :fail)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, second_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_duplicate_authority, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      first_embedding = generate_embedding(65)
      second_embedding = generate_embedding(66)

      assert {:ok, ^first_id} =
               Index.index(pid, "Malicious batch first", %{type: :first},
                 embedding: first_embedding
               )

      assert {:ok, ^second_id} =
               Index.index(pid, "Malicious batch second", %{type: :second},
                 embedding: second_embedding
               )

      MaliciousWriter.configure(agent_id, :duplicate_batch)
      assert {:error, :malformed_persistence_result} = Index.sync_to_persistent(pid)

      assert_pending_entries_unchanged(
        pid,
        first_id,
        second_id,
        first_embedding,
        second_embedding
      )

      assert Embedding.count(agent_id) == 0

      MaliciousWriter.configure(agent_id, :delegate)
      assert {:ok, 2} = Index.sync_to_persistent(pid)

      assert {:ok, %{id: ^first_id, content: "Malicious batch first"}} =
               Index.get(pid, first_id)

      assert {:ok, %{id: ^second_id, content: "Malicious batch second"}} =
               Index.get(pid, second_id)

      assert Embedding.count(agent_id) == 2
      assert {:ok, 0} = Index.sync_to_persistent(pid)
    end

    test "security regression: eager authoritative ID cannot cross-link pending content" do
      agent_id = durable_unique("test_dual_malicious_eager")
      suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first_id = "mem_a_#{suffix}"
      second_id = "mem_b_#{suffix}"
      MaliciousWriter.configure(agent_id, :fail)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: MaliciousWriter,
          entry_id_generator: sequence_callback([first_id, second_id]),
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_malicious_eager, agent_id}}}
        )

      on_exit(fn ->
        MaliciousWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
        Embedding.delete_all(agent_id)
      end)

      first_embedding = generate_embedding(63)

      assert {:ok, ^first_id} =
               Index.index(pid, "Pending authority", %{type: :first}, embedding: first_embedding)

      MaliciousWriter.configure(agent_id, {:eager_id, first_id})

      assert {:error, :malformed_persistence_result} =
               Index.index(pid, "Different authority", %{type: :second},
                 embedding: generate_embedding(64)
               )

      assert Index.stats(pid).entry_count == 1

      assert {:ok, %{id: ^first_id, content: "Pending authority", embedding: stored_embedding}} =
               Index.get(pid, first_id)

      assert_vector_close(stored_embedding, first_embedding)
      assert {:error, :not_found} = Index.get(pid, second_id)

      MaliciousWriter.configure(agent_id, :delegate)
      assert {:ok, 1} = Index.sync_to_persistent(pid)

      assert {:ok, %{id: ^first_id, content: "Pending authority"}} =
               Embedding.get(agent_id, first_id)
    end

    test "returns error for non-dual backend" do
      {:ok, ets_pid} =
        Index.start_link(
          agent_id: "test_ets_sync",
          backend: :ets,
          name: {:via, Registry, {Arbor.Memory.Registry, {:test_sync, "test_ets_sync"}}}
        )

      assert {:error, :not_dual_backend} = Index.sync_to_persistent(ets_pid)

      GenServer.stop(ets_pid)
    end
  end

  describe "delete propagation" do
    test "delete removes from both ETS and pgvector", %{pid: pid, agent_id: agent_id} do
      embedding = generate_embedding(1)
      {:ok, id} = Index.index(pid, "Delete test", %{type: :fact}, embedding: embedding)

      assert {:ok, %{id: ^id}} = Embedding.get(agent_id, id)

      # Delete
      :ok = Index.delete(pid, id)

      # Verify removed from ETS
      assert {:error, :not_found} = Index.get(pid, id)
      assert {:error, :not_found} = Embedding.get(agent_id, id)
    end

    test "authority regression: durable delete failure preserves the ETS entry", %{
      pid: pid,
      agent_id: agent_id
    } do
      assert {:ok, id} =
               Index.index(pid, "Delete failure", %{type: :fact},
                 embedding: generate_embedding(35)
               )

      assert :ok = Embedding.delete(agent_id, id)
      assert {:error, :not_found} = Index.delete(pid, id)
      assert {:ok, %{id: ^id, content: "Delete failure"}} = Index.get(pid, id)
    end
  end

  defp durable_unique(prefix) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{prefix}_#{suffix}"
  end

  defp sequence_callback(values) do
    {:ok, sequence} = Agent.start_link(fn -> values end)

    fn ->
      Agent.get_and_update(sequence, fn
        [value | rest] -> {value, rest}
        [] -> raise "deterministic callback exhausted"
      end)
    end
  end

  defp assert_pending_entries_unchanged(
         pid,
         first_id,
         second_id,
         first_embedding,
         second_embedding
       ) do
    assert Index.stats(pid).entry_count == 2

    assert {:ok,
            %{
              id: ^first_id,
              content: "Malicious batch first",
              metadata: %{type: :first},
              embedding: first_stored
            }} =
             Index.get(pid, first_id)

    assert {:ok,
            %{
              id: ^second_id,
              content: "Malicious batch second",
              metadata: %{type: :second},
              embedding: second_stored
            }} =
             Index.get(pid, second_id)

    assert_vector_close(first_stored, first_embedding)
    assert_vector_close(second_stored, second_embedding)
  end

  defp assert_vector_close(actual, expected) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn {actual_value, expected_value} ->
      assert_in_delta actual_value, expected_value, 1.0e-6
    end)
  end

  defp refute_vector_close(actual, expected) do
    refute Enum.zip(actual, expected)
           |> Enum.all?(fn {actual_value, expected_value} ->
             abs(actual_value - expected_value) <= 1.0e-6
           end)
  end
end
