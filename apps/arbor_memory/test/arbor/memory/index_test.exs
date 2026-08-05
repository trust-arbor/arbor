defmodule Arbor.Memory.IndexTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Index

  @moduletag :fast
  @persistent_dimension 768

  defmodule ControlledWriter do
    @behaviour Arbor.Memory.Index.PersistentWriter

    def configure(agent_id, mode) do
      counter = :counters.new(1, [:atomics])
      :persistent_term.put({__MODULE__, agent_id}, {mode, counter})
    end

    def set_mode(agent_id, mode) do
      {_old_mode, counter} = :persistent_term.get({__MODULE__, agent_id})
      :persistent_term.put({__MODULE__, agent_id}, {mode, counter})
    end

    def call_count(agent_id) do
      {_mode, counter} = :persistent_term.get({__MODULE__, agent_id})
      :counters.get(counter, 1)
    end

    def disarm(agent_id), do: :persistent_term.erase({__MODULE__, agent_id})

    @impl true
    def store(agent_id, _content, _embedding, metadata) do
      {mode, counter} = :persistent_term.get({__MODULE__, agent_id})
      :counters.add(counter, 1, 1)

      case mode do
        {:block, owner} ->
          send(owner, {:writer_started, agent_id, self()})

          receive do
            :release_writer -> {:ok, requested_id(metadata)}
          after
            6_000 -> {:ok, requested_id(metadata)}
          end

        {:block_for_kill, owner} ->
          send(owner, {:writer_waiting_for_kill, agent_id, self()})

          receive do
            :never_sent -> {:ok, requested_id(metadata)}
          end

        {:block_until_commit, owner} ->
          send(owner, {:writer_waiting_to_commit, agent_id, self()})

          receive do
            :commit ->
              send(owner, {:writer_committed, agent_id, self()})
              {:ok, requested_id(metadata)}
          end

        {:block_then_error, owner} ->
          send(owner, {:writer_waiting_to_fail, agent_id, self()})

          receive do
            :release_with_error -> {:error, :injected_transient_failure}
          end

        :success ->
          {:ok, requested_id(metadata)}

        :transient_error ->
          {:error, :injected_transient_failure}

        :permanent_error ->
          {:error, :protected_vector_row}

        :bare_ok ->
          :ok
      end
    end

    @impl true
    def store_batch_with_ids(agent_id, entries) do
      {mode, counter} = :persistent_term.get({__MODULE__, agent_id})
      :counters.add(counter, 1, 1)

      case mode do
        {:block_batch, owner} ->
          send(owner, {:batch_writer_started, agent_id, self()})

          receive do
            :release_batch ->
              {:ok,
               Enum.map(entries, fn {_content, _embedding, metadata} ->
                 requested_id(metadata)
               end)}
          after
            6_000 -> {:error, :injected_batch_timeout}
          end

        :success ->
          {:ok,
           Enum.map(entries, fn {_content, _embedding, metadata} -> requested_id(metadata) end)}

        :transient_error ->
          {:error, :injected_transient_failure}

        :permanent_error ->
          {:error, :protected_vector_row}

        :bare_ok ->
          :ok
      end
    end

    defp requested_id(metadata), do: Map.get(metadata, :id) || Map.get(metadata, "id")
  end

  defmodule ControlledProvider do
    def configure(content, mode) do
      counter = :counters.new(1, [:atomics])
      :persistent_term.put({__MODULE__, content}, {mode, counter})
    end

    def set_mode(content, mode) do
      {_old_mode, counter} = :persistent_term.get({__MODULE__, content})
      :persistent_term.put({__MODULE__, content}, {mode, counter})
    end

    def call_count(content) do
      {_mode, counter} = :persistent_term.get({__MODULE__, content})
      :counters.get(counter, 1)
    end

    def disarm(content), do: :persistent_term.erase({__MODULE__, content})

    def embed(content) do
      {mode, counter} = :persistent_term.get({__MODULE__, content})
      :counters.add(counter, 1, 1)

      case mode do
        :success ->
          {:ok, %{embedding: List.duplicate(0.5, 768)}}

        {:block, owner} ->
          send(owner, {:provider_started, content, self()})

          receive do
            :release_provider -> {:ok, %{embedding: List.duplicate(0.5, 768)}}
          end

        {:block_forever, owner} ->
          send(owner, {:provider_stalled, content, self()})

          receive do
            :never_sent -> {:ok, %{embedding: List.duplicate(0.5, 768)}}
          end
      end
    end
  end

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = Index.start_link(agent_id: agent_id, name: nil)
    %{pid: pid, agent_id: agent_id}
  end

  describe "start_link/1" do
    test "starts with required agent_id" do
      agent_id = "start_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = Index.start_link(agent_id: agent_id, name: nil)
      assert is_pid(pid)
      GenServer.stop(pid)
    end

    test "fails without agent_id" do
      assert_raise KeyError, fn ->
        Index.start_link([])
      end
    end
  end

  describe "index/3" do
    test "indexes content and returns entry id", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Hello, world!", %{type: :fact})

      assert is_binary(entry_id)
      assert String.starts_with?(entry_id, "mem_")
    end

    test "indexes content with metadata", %{pid: pid} do
      metadata = %{type: :fact, source: "test"}
      {:ok, entry_id} = Index.index(pid, "Test content", metadata)

      {:ok, entry} = Index.get(pid, entry_id)
      assert entry.metadata[:type] == :fact
      assert entry.metadata[:source] == "test"
    end

    test "can use pre-computed embedding", %{pid: pid} do
      embedding = List.duplicate(0.5, 128)
      {:ok, entry_id} = Index.index(pid, "Test", %{}, embedding: embedding)

      {:ok, entry} = Index.get(pid, entry_id)
      assert entry.embedding == embedding
    end

    test "acknowledgement regression: a slow durable writer does not time out or block reads" do
      agent_id = "slow_writer_#{System.unique_integer([:positive])}"
      entry_id = "mem_slow_writer"
      ControlledWriter.configure(agent_id, {:block, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          entry_id_generator: fn -> entry_id end,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()

      spawn(fn ->
        result =
          try do
            Index.index(pid, "Slow durable acknowledgement", %{type: :fact},
              embedding: valid_persistent_embedding()
            )
          catch
            :exit, reason -> {:caller_exit, reason}
          end

        send(parent, {:index_outcome, result})
      end)

      assert_receive {:writer_started, ^agent_id, writer_pid}, 1_000

      spawn(fn -> send(parent, {:stats_during_write, Index.stats(pid)}) end)

      Process.sleep(5_250)
      refute_received {:index_outcome, _result}
      assert_received {:stats_during_write, %{entry_count: 0}}
      assert Process.alive?(pid)

      send(writer_pid, :release_writer)
      assert_receive {:index_outcome, {:ok, ^entry_id}}, 1_000
      assert {:ok, %{id: ^entry_id}} = Index.get(pid, entry_id)
    end

    test "ownership regression: killed dual writer becomes pending without killing Index" do
      agent_id = "killed_dual_writer_#{System.unique_integer([:positive])}"
      entry_id = "mem_killed_dual_writer"
      ControlledWriter.configure(agent_id, {:block_for_kill, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          entry_id_generator: fn -> entry_id end,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()

      spawn(fn ->
        result =
          try do
            Index.index(pid, "Killed dual writer", %{}, embedding: valid_persistent_embedding())
          catch
            :exit, reason -> {:caller_exit, reason}
          end

        send(parent, {:killed_dual_result, result})
      end)

      assert_receive {:writer_waiting_for_kill, ^agent_id, writer_pid}, 1_000
      Process.exit(writer_pid, :kill)

      assert_receive {:killed_dual_result, {:ok, ^entry_id}}, 1_000
      assert Process.alive?(pid)
      assert {:ok, %{id: ^entry_id, content: "Killed dual writer"}} = Index.get(pid, entry_id)
      assert :sys.get_state(pid).pending_sync == MapSet.new([entry_id])

      ControlledWriter.set_mode(agent_id, :success)
      assert {:ok, 1} = Index.sync_to_persistent(pid)
      assert :sys.get_state(pid).pending_sync == MapSet.new()
      assert Process.alive?(pid)
    end

    test "ownership regression: killed persistent-only writer returns indeterminate and Index remains usable" do
      agent_id = "killed_persistent_writer_#{System.unique_integer([:positive])}"
      entry_id = "mem_killed_persistent_writer"
      ControlledWriter.configure(agent_id, {:block_for_kill, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :pgvector,
          persistent_writer: ControlledWriter,
          entry_id_generator: fn -> entry_id end,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()

      spawn(fn ->
        result =
          try do
            Index.index(pid, "Killed persistent writer", %{},
              embedding: valid_persistent_embedding()
            )
          catch
            :exit, reason -> {:caller_exit, reason}
          end

        send(parent, {:killed_persistent_result, result})
      end)

      assert_receive {:writer_waiting_for_kill, ^agent_id, writer_pid}, 1_000
      Process.exit(writer_pid, :kill)

      assert_receive {:killed_persistent_result, {:error, :persistence_indeterminate}}, 1_000
      assert Process.alive?(pid)
      assert %{entry_count: 0} = Index.stats(pid)
      assert :pgvector = Index.backend_mode(pid)

      ControlledWriter.set_mode(agent_id, :success)

      assert {:ok, ^entry_id} =
               Index.index(pid, "Usable after killed writer", %{},
                 embedding: valid_persistent_embedding()
               )

      assert Process.alive?(pid)
    end

    test "ownership regression: killed coordinator terminates its writer before any later commit" do
      agent_id = "killed_coordinator_#{System.unique_integer([:positive])}"
      entry_id = "mem_killed_coordinator"
      ControlledWriter.configure(agent_id, {:block_until_commit, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :pgvector,
          persistent_writer: ControlledWriter,
          entry_id_generator: fn -> entry_id end,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()

      spawn(fn ->
        send(
          parent,
          {:killed_coordinator_result,
           Index.index(pid, "Coordinator-owned writer", %{},
             embedding: valid_persistent_embedding()
           )}
        )
      end)

      assert_receive {:writer_waiting_to_commit, ^agent_id, writer_pid}, 1_000

      on_exit(fn ->
        if Process.alive?(writer_pid), do: Process.exit(writer_pid, :kill)
      end)

      %{inflight_mutation: %{coordinator_pid: coordinator_pid}} = :sys.get_state(pid)
      writer_monitor = Process.monitor(writer_pid)

      Process.exit(coordinator_pid, :kill)

      assert_receive {:DOWN, ^writer_monitor, :process, ^writer_pid, _reason}, 1_000

      assert_receive {:killed_coordinator_result, {:error, :persistence_indeterminate}},
                     1_000

      assert Process.alive?(pid)
      assert %{entry_count: 0} = Index.stats(pid)

      send(writer_pid, :commit)
      refute_receive {:writer_committed, ^agent_id, ^writer_pid}, 100

      ControlledWriter.set_mode(agent_id, :success)

      assert {:ok, ^entry_id} =
               Index.index(pid, "Usable after coordinator death", %{},
                 embedding: valid_persistent_embedding()
               )

      assert Process.alive?(pid)
    end

    test "security regression: single generated ID collision rejects before writer dispatch" do
      agent_id = "single_collision_#{System.unique_integer([:positive])}"
      duplicate_id = "mem_duplicate_single_identity"
      ControlledWriter.configure(agent_id, :success)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          entry_id_generator: fn -> duplicate_id end,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      embedding = valid_persistent_embedding()

      assert {:ok, ^duplicate_id} =
               Index.index(pid, "First collision owner", %{type: :first}, embedding: embedding)

      assert {:error, :invalid_entry_identity} =
               Index.index(pid, "Second collision owner", %{type: :second}, embedding: embedding)

      assert ControlledWriter.call_count(agent_id) == 1
      assert {:ok, %{content: "First collision owner"}} = Index.get(pid, duplicate_id)
      assert Process.alive?(pid)
    end

    test "validation regression: permanent caller errors consume no pending state or dispatch" do
      agent_id = "preflight_#{System.unique_integer([:positive])}"
      ControlledWriter.configure(agent_id, :success)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      valid_embedding = valid_persistent_embedding()

      assert {:error, {:invalid_legacy_embedding, :invalid_embedding}} =
               Index.index(pid, "Wrong dimensions", %{}, embedding: [0.5])

      assert {:error, {:invalid_legacy_embedding, :invalid_metadata}} =
               Index.index(pid, "Non JSON metadata", %{pid: self()}, embedding: valid_embedding)

      assert {:error, {:invalid_legacy_embedding, :invalid_metadata}} =
               Index.index(
                 pid,
                 "Oversized metadata",
                 %{value: String.duplicate("m", 65_537)},
                 embedding: valid_embedding
               )

      assert {:error, {:invalid_legacy_embedding, :invalid_content}} =
               Index.index(pid, String.duplicate("c", 65_537), %{}, embedding: valid_embedding)

      assert {:error, {:invalid_legacy_embedding, :invalid_metadata}} =
               Index.batch_index(
                 pid,
                 [
                   {"Valid batch member", %{type: :valid}},
                   {"Invalid batch member", %{pid: self()}}
                 ],
                 embedding: valid_embedding
               )

      assert ControlledWriter.call_count(agent_id) == 0
      assert Index.stats(pid).entry_count == 0

      state = :sys.get_state(pid)
      assert state.pending_sync == MapSet.new()
      assert state.pending_group_members == %{}
      assert state.id_aliases == %{}
      assert state.next_insertion_sequence == 0
      assert Process.alive?(pid)
    end

    test "malformed writer envelopes never acknowledge durability or crash the index" do
      agent_id = "malformed_writer_#{System.unique_integer([:positive])}"
      ControlledWriter.configure(agent_id, :bare_ok)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      embedding = valid_persistent_embedding()

      assert {:error, :malformed_persistence_result} =
               Index.index(pid, "Malformed eager", %{}, embedding: embedding)

      assert {:error, :malformed_persistence_result} =
               Index.batch_index(pid, [{"Malformed batch", %{type: :batch}}],
                 embedding: embedding
               )

      assert Index.stats(pid).entry_count == 0
      ControlledWriter.set_mode(agent_id, :transient_error)

      assert {:ok, pending_id} =
               Index.index(pid, "Pending for malformed sync", %{type: :pending},
                 embedding: embedding
               )

      pending_state = :sys.get_state(pid)
      ControlledWriter.set_mode(agent_id, :bare_ok)
      assert {:error, :malformed_persistence_result} = Index.sync_to_persistent(pid)

      state_after = :sys.get_state(pid)
      assert state_after.pending_sync == pending_state.pending_sync
      assert state_after.pending_entry_orders == pending_state.pending_entry_orders
      assert state_after.pending_group_members == pending_state.pending_group_members
      assert state_after.id_aliases == pending_state.id_aliases
      assert {:ok, %{id: ^pending_id}} = Index.get(pid, pending_id)
      assert Process.alive?(pid)
    end

    test "permanent writer rejection is not acknowledged as retryable pending state" do
      agent_id = "permanent_writer_#{System.unique_integer([:positive])}"
      ControlledWriter.configure(agent_id, :permanent_error)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, :protected_vector_row} =
               Index.index(pid, "Protected durable conflict", %{},
                 embedding: valid_persistent_embedding()
               )

      assert Index.stats(pid).entry_count == 0
      assert :sys.get_state(pid).pending_sync == MapSet.new()
      assert Process.alive?(pid)
    end

    test "resource regression: oversized calls reject before provider or writer dispatch" do
      agent_id = "bounded_input_#{System.unique_integer([:positive])}"
      oversized_content = String.duplicate("c", 65_537)
      aggregate_content = String.duplicate("b", 60_000)
      count_content = "count bounded"

      Enum.each([oversized_content, aggregate_content, count_content], fn content ->
        ControlledProvider.configure(content, :success)
      end)

      ControlledWriter.configure(agent_id, :success)

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          embedding_provider: ControlledProvider,
          persistent_writer: ControlledWriter,
          name: nil
        )

      on_exit(fn ->
        Enum.each([oversized_content, aggregate_content, count_content], fn content ->
          ControlledProvider.disarm(content)
        end)

        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, {:invalid_legacy_embedding, :invalid_content}} =
               Index.index(pid, oversized_content)

      assert {:error, :invalid_batch} =
               Index.batch_index(pid, List.duplicate({count_content, %{}}, 101))

      aggregate_batch = List.duplicate({aggregate_content, %{}}, 70)
      assert {:error, :invalid_batch} = Index.batch_index(pid, aggregate_batch)

      assert ControlledProvider.call_count(oversized_content) == 0
      assert ControlledProvider.call_count(aggregate_content) == 0
      assert ControlledProvider.call_count(count_content) == 0
      assert ControlledWriter.call_count(agent_id) == 0
      assert Index.stats(pid).entry_count == 0
    end

    test "resource regression: bounded mutation admission rejects queue saturation" do
      blocked_content = "queue blocked provider"
      ControlledProvider.configure(blocked_content, {:block, self()})

      ids = ["mem_queue_first", "mem_queue_second"]

      {:ok, pid} =
        Index.start_link(
          agent_id: "queue_bound_#{System.unique_integer([:positive])}",
          embedding_provider: ControlledProvider,
          entry_id_generator: sequence_callback(ids),
          max_pending_mutations: 1,
          operation_timeout_ms: 5_000,
          name: nil
        )

      on_exit(fn ->
        ControlledProvider.disarm(blocked_content)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()

      spawn(fn -> send(parent, {:queue_first, Index.index(pid, blocked_content)}) end)
      assert_receive {:provider_started, ^blocked_content, provider_pid}, 1_000

      spawn(fn ->
        send(
          parent,
          {:queue_second,
           Index.index(pid, "queued second", %{}, embedding: List.duplicate(0.5, 128))}
        )
      end)

      await_mutation_queue_length(pid, 1)

      assert {:error, :mutation_queue_full} =
               Index.index(pid, "rejected third", %{}, embedding: List.duplicate(0.5, 128))

      send(provider_pid, :release_provider)
      assert_receive {:queue_first, {:ok, "mem_queue_first"}}, 1_000
      assert_receive {:queue_second, {:ok, "mem_queue_second"}}, 1_000
      assert Index.stats(pid).entry_count == 2
    end

    test "resource regression: stalled preflight completes at its finite deadline" do
      content = "stalled preflight"
      ControlledProvider.configure(content, {:block_forever, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: "preflight_deadline_#{System.unique_integer([:positive])}",
          embedding_provider: ControlledProvider,
          operation_timeout_ms: 100,
          name: nil
        )

      on_exit(fn ->
        ControlledProvider.disarm(content)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()
      spawn(fn -> send(parent, {:stalled_preflight_result, Index.index(pid, content)}) end)

      assert_receive {:provider_stalled, ^content, provider_pid}, 1_000
      provider_monitor = Process.monitor(provider_pid)

      assert_receive {:stalled_preflight_result, {:error, :operation_timeout}}, 1_000
      assert_receive {:DOWN, ^provider_monitor, :process, ^provider_pid, _reason}, 1_000
      assert Process.alive?(pid)
      assert Index.stats(pid).entry_count == 0
    end

    test "resource regression: durable deadline preserves retryable lost-ack state" do
      agent_id = "durable_deadline_#{System.unique_integer([:positive])}"
      entry_id = "mem_durable_deadline"
      ControlledWriter.configure(agent_id, {:block_for_kill, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          entry_id_generator: fn -> entry_id end,
          operation_timeout_ms: 100,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()

      spawn(fn ->
        send(
          parent,
          {:durable_deadline_result,
           Index.index(pid, "Durable deadline", %{}, embedding: valid_persistent_embedding())}
        )
      end)

      assert_receive {:writer_waiting_for_kill, ^agent_id, writer_pid}, 1_000
      writer_monitor = Process.monitor(writer_pid)

      assert_receive {:durable_deadline_result, {:ok, ^entry_id}}, 1_000
      assert_receive {:DOWN, ^writer_monitor, :process, ^writer_pid, _reason}, 1_000
      assert :sys.get_state(pid).pending_sync == MapSet.new([entry_id])
      assert {:ok, %{id: ^entry_id}} = Index.get(pid, entry_id)

      ControlledWriter.set_mode(agent_id, :success)
      assert {:ok, 1} = Index.sync_to_persistent(pid)
      assert :sys.get_state(pid).pending_sync == MapSet.new()
    end

    test "ownership regression: owner death terminates coordinator and durable writer" do
      agent_id = "dead_index_owner_#{System.unique_integer([:positive])}"
      ControlledWriter.configure(agent_id, {:block_until_commit, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :pgvector,
          persistent_writer: ControlledWriter,
          operation_timeout_ms: 5_000,
          name: nil
        )

      Process.unlink(pid)

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      spawn(fn ->
        Index.index(pid, "Owner-bound durable write", %{},
          embedding: valid_persistent_embedding()
        )
      end)

      assert_receive {:writer_waiting_to_commit, ^agent_id, writer_pid}, 1_000
      %{inflight_mutation: %{coordinator_pid: coordinator_pid}} = :sys.get_state(pid)

      coordinator_monitor = Process.monitor(coordinator_pid)
      writer_monitor = Process.monitor(writer_pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator_pid, _reason}, 1_000
      assert_receive {:DOWN, ^writer_monitor, :process, ^writer_pid, _reason}, 1_000

      send(writer_pid, :commit)
      refute_receive {:writer_committed, ^agent_id, ^writer_pid}, 100
    end
  end

  describe "recall/2" do
    test "responsiveness regression: slow recall provider cannot monopolize the index" do
      query = "blocked recall provider"
      ControlledProvider.configure(query, {:block, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: "recall_provider_#{System.unique_integer([:positive])}",
          embedding_provider: ControlledProvider,
          operation_timeout_ms: 2_000,
          name: nil
        )

      on_exit(fn ->
        ControlledProvider.disarm(query)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:ok, entry_id} =
               Index.index(pid, "Recall cache entry", %{type: :fact},
                 embedding: valid_persistent_embedding()
               )

      parent = self()
      spawn(fn -> send(parent, {:recall_provider_result, Index.recall(pid, query)}) end)

      assert_receive {:provider_started, ^query, provider_pid}, 1_000
      assert %{entry_count: 1} = Index.stats(pid)
      assert {:ok, %{id: ^entry_id}} = Index.get(pid, entry_id)
      refute_received {:recall_provider_result, _result}

      send(provider_pid, :release_provider)
      assert_receive {:recall_provider_result, {:ok, results}}, 1_000
      assert Enum.any?(results, &(&1.id == entry_id))
      assert Process.alive?(pid)
    end

    test "returns similar content", %{pid: pid} do
      {:ok, _} = Index.index(pid, "The sky is blue", %{type: :fact})
      {:ok, _} = Index.index(pid, "Grass is green", %{type: :fact})
      {:ok, _} = Index.index(pid, "The ocean is blue", %{type: :fact})

      {:ok, results} = Index.recall(pid, "blue sky")

      assert is_list(results)
      assert results != []

      Enum.each(results, fn result ->
        assert Map.has_key?(result, :id)
        assert Map.has_key?(result, :content)
        assert Map.has_key?(result, :similarity)
      end)
    end

    test "filters by type", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Fact one", %{type: :fact})
      {:ok, _} = Index.index(pid, "Experience one", %{type: :experience})
      {:ok, _} = Index.index(pid, "Fact two", %{type: :fact})

      {:ok, results} = Index.recall(pid, "one", type: :fact)

      Enum.each(results, fn result ->
        assert result.metadata[:type] == :fact
      end)
    end

    test "filters by multiple types", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Fact one", %{type: :fact})
      {:ok, _} = Index.index(pid, "Skill one", %{type: :skill})
      {:ok, _} = Index.index(pid, "Insight one", %{type: :insight})

      {:ok, results} = Index.recall(pid, "one", types: [:fact, :skill])

      types = Enum.map(results, & &1.metadata[:type])
      assert Enum.all?(types, &(&1 in [:fact, :skill]))
    end

    test "respects limit", %{pid: pid} do
      for i <- 1..10 do
        {:ok, _} = Index.index(pid, "Content #{i}", %{type: :fact})
      end

      {:ok, results} = Index.recall(pid, "content", limit: 3)
      assert length(results) <= 3
    end

    test "respects threshold", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Exact match content", %{type: :fact})
      {:ok, _} = Index.index(pid, "Something completely different", %{type: :fact})

      {:ok, results} = Index.recall(pid, "exact match", threshold: 0.9)

      Enum.each(results, fn result ->
        assert result.similarity >= 0.9
      end)
    end
  end

  describe "batch_index/2" do
    test "indexes multiple items", %{pid: pid} do
      items = [
        {"Fact one", %{type: :fact}},
        {"Fact two", %{type: :fact}},
        {"Skill one", %{type: :skill}}
      ]

      {:ok, ids} = Index.batch_index(pid, items)

      assert length(ids) == 3
      Enum.each(ids, &assert(String.starts_with?(&1, "mem_")))
    end

    test "security regression: duplicate generated IDs reject before ETS mutation" do
      duplicate_id = "mem_duplicate_batch_identity"

      {:ok, duplicate_pid} =
        Index.start_link(
          agent_id: "duplicate_batch_agent",
          entry_id_generator: fn -> duplicate_id end,
          name: nil
        )

      on_exit(fn ->
        if Process.alive?(duplicate_pid), do: GenServer.stop(duplicate_pid)
      end)

      state_before = :sys.get_state(duplicate_pid)
      table_before = :ets.tab2list(state_before.table)

      assert {:error, :invalid_batch_identity} =
               Index.batch_index(
                 duplicate_pid,
                 [{"Duplicate first", %{type: :first}}, {"Duplicate second", %{type: :second}}],
                 embedding: List.duplicate(0.5, 128)
               )

      state_after = :sys.get_state(duplicate_pid)
      assert :ets.tab2list(state_after.table) == table_before
      assert state_after.entry_count == state_before.entry_count
      assert state_after.next_insertion_sequence == state_before.next_insertion_sequence
      assert {:error, :not_found} = Index.get(duplicate_pid, duplicate_id)
    end

    test "responsiveness regression: slow persistent batch leaves reads live and mutations ordered" do
      agent_id = "slow_batch_writer_#{System.unique_integer([:positive])}"
      [first_id, second_id, later_id] = ids = ["mem_batch_first", "mem_batch_second", "mem_later"]
      ControlledWriter.configure(agent_id, {:block_batch, self()})

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          entry_id_generator: sequence_callback(ids),
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      parent = self()

      spawn(fn ->
        send(
          parent,
          {:slow_batch_result,
           Index.batch_index(
             pid,
             [{"Slow batch first", %{type: :first}}, {"Slow batch second", %{type: :second}}],
             embedding: valid_persistent_embedding()
           )}
        )
      end)

      assert_receive {:batch_writer_started, ^agent_id, batch_writer_pid}, 1_000

      spawn(fn -> send(parent, {:stats_during_batch, Index.stats(pid)}) end)

      spawn(fn ->
        send(
          parent,
          {:later_mutation_result,
           Index.index(pid, "Mutation after batch", %{type: :later},
             embedding: valid_persistent_embedding()
           )}
        )
      end)

      assert_receive {:stats_during_batch, %{entry_count: 0}}, 250
      refute_received {:later_mutation_result, _result}

      ControlledWriter.set_mode(agent_id, :success)
      send(batch_writer_pid, :release_batch)

      assert_receive {:slow_batch_result, {:ok, [^first_id, ^second_id]}}, 1_000
      assert_receive {:later_mutation_result, {:ok, ^later_id}}, 1_000
      assert Index.stats(pid).entry_count == 3
      assert {:ok, %{id: ^first_id}} = Index.get(pid, first_id)
      assert {:ok, %{id: ^second_id}} = Index.get(pid, second_id)
      assert {:ok, %{id: ^later_id}} = Index.get(pid, later_id)
    end

    test "responsiveness regression: slow batch provider preflight leaves reads live" do
      first_content = "slow batch provider first"
      second_content = "slow batch provider second"
      ControlledProvider.configure(first_content, {:block, self()})
      ControlledProvider.configure(second_content, :success)

      ids = ["mem_preflight_existing", "mem_preflight_first", "mem_preflight_second"]

      {:ok, pid} =
        Index.start_link(
          agent_id: "slow_batch_preflight_#{System.unique_integer([:positive])}",
          embedding_provider: ControlledProvider,
          entry_id_generator: sequence_callback(ids),
          operation_timeout_ms: 5_000,
          name: nil
        )

      on_exit(fn ->
        ControlledProvider.disarm(first_content)
        ControlledProvider.disarm(second_content)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:ok, existing_id} =
               Index.index(pid, "existing before batch", %{},
                 embedding: valid_persistent_embedding()
               )

      parent = self()

      spawn(fn ->
        send(
          parent,
          {:batch_preflight_result,
           Index.batch_index(pid, [{first_content, %{}}, {second_content, %{}}])}
        )
      end)

      assert_receive {:provider_started, ^first_content, provider_pid}, 1_000
      assert %{entry_count: 1} = Index.stats(pid)
      assert {:ok, %{id: ^existing_id}} = Index.get(pid, existing_id)
      refute_received {:batch_preflight_result, _result}

      send(provider_pid, :release_provider)

      assert_receive {:batch_preflight_result,
                      {:ok, ["mem_preflight_first", "mem_preflight_second"]}},
                     1_000

      assert Index.stats(pid).entry_count == 3
    end
  end

  describe "stats/1" do
    test "returns index statistics", %{pid: pid, agent_id: agent_id} do
      {:ok, _} = Index.index(pid, "Content 1", %{})
      {:ok, _} = Index.index(pid, "Content 2", %{})

      stats = Index.stats(pid)

      assert stats.agent_id == agent_id
      assert stats.entry_count == 2
      assert is_integer(stats.max_entries)
      assert is_float(stats.default_threshold)
    end
  end

  describe "clear/1" do
    test "removes all entries", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Content 1", %{})
      {:ok, _} = Index.index(pid, "Content 2", %{})

      assert Index.stats(pid).entry_count == 2

      :ok = Index.clear(pid)

      assert Index.stats(pid).entry_count == 0
    end
  end

  describe "get/2" do
    test "returns entry by id", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Test content", %{type: :fact})

      {:ok, entry} = Index.get(pid, entry_id)

      assert entry.id == entry_id
      assert entry.content == "Test content"
    end

    test "returns error for unknown id", %{pid: pid} do
      assert {:error, :not_found} = Index.get(pid, "unknown_id")
    end

    test "updates access time and count", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Test", %{})

      {:ok, entry1} = Index.get(pid, entry_id)
      assert entry1.access_count == 1

      {:ok, entry2} = Index.get(pid, entry_id)
      assert entry2.access_count == 2
    end
  end

  describe "delete/2" do
    test "removes entry by id", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Test content", %{})

      :ok = Index.delete(pid, entry_id)

      assert {:error, :not_found} = Index.get(pid, entry_id)
    end

    test "returns error for unknown id", %{pid: pid} do
      assert {:error, :not_found} = Index.delete(pid, "unknown_id")
    end
  end

  describe "LRU eviction" do
    test "LRU regression: fallback admission uses access order at the commit point" do
      agent_id = "fresh_lru_#{System.unique_integer([:positive])}"
      ControlledWriter.configure(agent_id, :success)

      clock_values = [
        ~U[2020-01-01 00:00:00Z],
        ~U[2020-01-01 00:00:01Z],
        ~U[2020-01-01 00:00:02Z]
      ]

      {:ok, pid} =
        Index.start_link(
          agent_id: agent_id,
          backend: :dual,
          persistent_writer: ControlledWriter,
          entry_id_generator:
            sequence_callback(["mem_lru_first", "mem_lru_second", "mem_lru_new"]),
          clock: sequence_callback(clock_values),
          max_entries: 2,
          operation_timeout_ms: 5_000,
          name: nil
        )

      on_exit(fn ->
        ControlledWriter.disarm(agent_id)
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      embedding = valid_persistent_embedding()
      assert {:ok, "mem_lru_first"} = Index.index(pid, "LRU first", %{}, embedding: embedding)
      assert {:ok, "mem_lru_second"} = Index.index(pid, "LRU second", %{}, embedding: embedding)

      ControlledWriter.set_mode(agent_id, {:block_then_error, self()})
      parent = self()

      spawn(fn ->
        send(
          parent,
          {:fresh_lru_result, Index.index(pid, "LRU pending", %{}, embedding: embedding)}
        )
      end)

      assert_receive {:writer_waiting_to_fail, ^agent_id, writer_pid}, 1_000

      assert {:ok, %{id: "mem_lru_first"}} = Index.get(pid, "mem_lru_first")
      send(writer_pid, :release_with_error)

      assert_receive {:fresh_lru_result, {:ok, "mem_lru_new"}}, 1_000
      assert {:ok, %{id: "mem_lru_first"}} = Index.get(pid, "mem_lru_first")
      assert {:error, :not_found} = Index.get(pid, "mem_lru_second")
      assert {:ok, %{id: "mem_lru_new"}} = Index.get(pid, "mem_lru_new")
      assert :sys.get_state(pid).pending_sync == MapSet.new(["mem_lru_new"])
    end

    test "capacity regression: a one-entry cache evicts one synced row" do
      agent_id = "single_eviction_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = Index.start_link(agent_id: agent_id, max_entries: 1, name: nil)

      assert {:ok, first_id} = Index.index(pid, "First", %{})
      assert {:ok, second_id} = Index.index(pid, "Second", %{})

      assert Index.stats(pid).entry_count == 1
      assert {:error, :not_found} = Index.get(pid, first_id)
      assert {:ok, %{id: ^second_id}} = Index.get(pid, second_id)

      GenServer.stop(pid)
    end

    test "evicts least recently accessed entries when at capacity" do
      agent_id = "eviction_test_#{System.unique_integer([:positive])}"
      # Small max to test eviction
      {:ok, pid} = Index.start_link(agent_id: agent_id, max_entries: 10, name: nil)

      # Add 15 entries (5 over capacity)
      for i <- 1..15 do
        {:ok, _} = Index.index(pid, "Content #{i}", %{})
      end

      stats = Index.stats(pid)
      # Should have evicted some
      assert stats.entry_count < 15

      GenServer.stop(pid)
    end
  end

  defp valid_persistent_embedding, do: List.duplicate(0.5, @persistent_dimension)

  defp sequence_callback(values) do
    {:ok, sequence} = Agent.start_link(fn -> values end)

    fn ->
      Agent.get_and_update(sequence, fn
        [value | rest] -> {value, rest}
        [] -> raise "deterministic ID sequence exhausted"
      end)
    end
  end

  defp await_mutation_queue_length(pid, expected, attempts \\ 100)

  defp await_mutation_queue_length(pid, expected, attempts) when attempts > 0 do
    if :queue.len(:sys.get_state(pid).mutation_queue) == expected do
      :ok
    else
      Process.sleep(5)
      await_mutation_queue_length(pid, expected, attempts - 1)
    end
  end

  defp await_mutation_queue_length(_pid, expected, 0) do
    flunk("mutation queue did not reach #{expected}")
  end
end
