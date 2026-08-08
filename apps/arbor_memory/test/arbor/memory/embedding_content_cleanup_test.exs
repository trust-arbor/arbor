defmodule Arbor.Memory.EmbeddingContentCleanupTest do
  @moduledoc """
  VP-05D2C3I0C3 Embedding + Index ownership content cleanup evidence.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{Embedding, Index, IndexSupervisor, Provenance}

  @moduletag :fast
  @moduletag voice_packet: "VP-05D2C3I0C3"
  @moduletag spec: "VOICE-17"

  @persistent_dimension 768

  defmodule FakeRepo do
    @moduledoc false

    def configure(opts) when is_list(opts) do
      Process.put({__MODULE__, :cfg}, Map.new(opts))
      :ok
    end

    def clear, do: Process.delete({__MODULE__, :cfg})

    def transaction(fun) when is_function(fun, 0) do
      try do
        {:ok, fun.()}
      catch
        :throw, {:rollback, reason} -> {:error, reason}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})

    def delete_all(_query) do
      maybe_sleep(:delete_sleep_ms)

      case cfg(:delete_reply, {0, nil}) do
        {:raise, e} -> raise e
        reply -> reply
      end
    end

    def one(_query) do
      maybe_sleep(:count_sleep_ms)

      case cfg(:count_reply, 0) do
        {:raise, e} -> raise e
        reply -> reply
      end
    end

    defp maybe_sleep(key) do
      case cfg(key, 0) do
        n when is_integer(n) and n > 0 -> Process.sleep(n)
        _ -> :ok
      end
    end

    defp cfg(key, default) do
      Map.get(Process.get({__MODULE__, :cfg}, %{}), key, default)
    end
  end

  defmodule FakeEvidence do
    @moduledoc false

    def configure(opts) when is_list(opts) do
      Process.put({__MODULE__, :cfg}, Map.new(opts))
      Process.put({__MODULE__, :inventory_calls}, 0)
      Process.put({__MODULE__, :timeout_log}, [])
      Process.put({__MODULE__, :call_log}, [])
      :ok
    end

    def clear do
      Process.delete({__MODULE__, :cfg})
      Process.delete({__MODULE__, :inventory_calls})
      Process.delete({__MODULE__, :timeout_log})
      Process.delete({__MODULE__, :call_log})
      Process.delete({__MODULE__, :terminated})
    end

    def inventory_calls, do: Process.get({__MODULE__, :inventory_calls}, 0)
    def timeout_log, do: Process.get({__MODULE__, :timeout_log}, []) |> Enum.reverse()
    def call_log, do: Process.get({__MODULE__, :call_log}, []) |> Enum.reverse()
    def terminated_pid, do: Process.get({__MODULE__, :terminated})

    def registry_inventory(timeout_ms) when is_integer(timeout_ms) and timeout_ms <= 0,
      do: {:error, :timeout}

    def registry_inventory(timeout_ms) when is_integer(timeout_ms) do
      record_timeout(:registry, timeout_ms)
      bump_inventory()
      maybe_sleep(:inventory_sleep_ms)

      case take_scripted(:inventory_script) do
        nil -> cfg(:inventory, {:ok, %{}})
        reply -> reply
      end
    end

    def supervisor_live_pids(timeout_ms) when is_integer(timeout_ms) and timeout_ms <= 0,
      do: {:error, :timeout}

    def supervisor_live_pids(timeout_ms) when is_integer(timeout_ms) do
      record_timeout(:supervisor, timeout_ms)
      maybe_sleep(:supervisor_sleep_ms)

      case take_scripted(:supervisor_script) do
        nil ->
          case cfg(:inventory, {:ok, %{}}) do
            {:ok, map} when is_map(map) ->
              {:ok, MapSet.new(Map.values(map))}

            _ ->
              cfg(:supervisor, {:ok, MapSet.new()})
          end

        reply ->
          reply
      end
    end

    def terminate_child(pid, timeout_ms)
        when is_pid(pid) and is_integer(timeout_ms) and timeout_ms <= 0,
        do: {:error, :timeout}

    def terminate_child(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
      record_timeout(:terminate, timeout_ms)
      Process.put({__MODULE__, :terminated}, pid)
      maybe_sleep(:terminate_sleep_ms)

      case cfg(:terminate_reply, :ok) do
        :ok ->
          case cfg(:inventory, {:ok, %{}}) do
            {:ok, map} when is_map(map) ->
              next =
                map
                |> Enum.reject(fn {_agent, p} -> p == pid end)
                |> Map.new()

              Process.put(
                {__MODULE__, :cfg},
                Map.put(Process.get({__MODULE__, :cfg}, %{}), :inventory, {:ok, next})
              )

            _ ->
              :ok
          end

          :ok

        other ->
          other
      end
    end

    defp record_timeout(op, timeout_ms) do
      Process.put(
        {__MODULE__, :timeout_log},
        [{op, timeout_ms} | Process.get({__MODULE__, :timeout_log}, [])]
      )

      Process.put(
        {__MODULE__, :call_log},
        [op | Process.get({__MODULE__, :call_log}, [])]
      )
    end

    defp bump_inventory do
      Process.put(
        {__MODULE__, :inventory_calls},
        Process.get({__MODULE__, :inventory_calls}, 0) + 1
      )
    end

    defp maybe_sleep(key) do
      case cfg(key, 0) do
        n when is_integer(n) and n > 0 -> Process.sleep(n)
        _ -> :ok
      end
    end

    defp take_scripted(key) do
      cfg = Process.get({__MODULE__, :cfg}, %{})

      case Map.get(cfg, key) do
        [next | rest] ->
          Process.put({__MODULE__, :cfg}, Map.put(cfg, key, rest))
          next

        [] ->
          nil

        nil ->
          nil

        other ->
          other
      end
    end

    defp cfg(key, default) do
      Map.get(Process.get({__MODULE__, :cfg}, %{}), key, default)
    end
  end

  defmodule ControlledWriter do
    @moduledoc false

    def configure(agent_id, mode) do
      counter = :counters.new(1, [:atomics])
      :persistent_term.put({__MODULE__, agent_id}, {mode, counter})
    end

    def set_mode(agent_id, mode) do
      {_old, counter} = :persistent_term.get({__MODULE__, agent_id})
      :persistent_term.put({__MODULE__, agent_id}, {mode, counter})
    end

    def disarm(agent_id), do: :persistent_term.erase({__MODULE__, agent_id})

    def encode_operation(input), do: Arbor.Memory.Embedding.encode_strict_operation(input)
    def encode_batch(inputs), do: Arbor.Memory.Embedding.encode_strict_batch(inputs)

    def execute(agent_id, operation, _opts) do
      {mode, counter} = :persistent_term.get({__MODULE__, agent_id})
      :counters.add(counter, 1, 1)

      case {mode, operation} do
        {{:block_then_error, owner}, %{record: %{source_key: _key}}} ->
          send(owner, {:writer_waiting_to_fail, agent_id, self()})

          receive do
            :fail -> {:error, :backend_failure}
          after
            2_000 -> {:error, :backend_failure}
          end

        {:error, _} ->
          {:error, :backend_failure}

        {_, %{record: %{source_key: key}}} ->
          ok_receipt(key)

        {_, %{kind: :batch, operations: ops}} ->
          keys = Enum.map(ops, fn op -> op.record.source_key end)
          ok_batch_receipt(keys)

        _ ->
          {:error, :invalid_request}
      end
    end

    def reconcile(_agent_id, _operation, _opts), do: {:ok, :absent}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def fetch(_agent_id, _ns, _key, _opts), do: {:error, :not_found}
    def list(_agent_id, _opts), do: {:ok, []}

    defp ok_receipt(key), do: {:ok, %{kind: :insert, record: %{source_key: key, id: key}}}

    defp ok_batch_receipt(keys) do
      receipts = Enum.map(keys, fn k -> %{kind: :insert, record: %{source_key: k, id: k}} end)
      {:ok, %{kind: :batch, receipts: receipts, record: nil}}
    end
  end

  setup do
    FakeRepo.clear()
    FakeEvidence.clear()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_emb_cleanup_t_#{uid}"
    survivor = "agent_emb_cleanup_s_#{uid}"

    # Unconditional cleanup even when a test fails: always erase ControlledWriter
    # persistent_term and tear down indexes/provenance.
    on_exit(fn ->
      ControlledWriter.disarm(target)
      FakeRepo.clear()
      FakeEvidence.clear()
      ensure_provenance!()
      _ = Provenance.delete_agent(target)
      _ = Provenance.delete_agent(survivor)

      for agent <- [target, survivor] do
        case IndexSupervisor.get_index(agent) do
          {:ok, pid} ->
            _ = DynamicSupervisor.terminate_child(IndexSupervisor, pid)

          _ ->
            :ok
        end
      end
    end)

    %{target: target, survivor: survivor}
  end

  describe "validation and opts" do
    test "rejects invalid agent ids" do
      assert {:error, :invalid_agent_id} = Embedding.delete_agent_content("")
      assert {:error, :invalid_agent_id} = Embedding.agent_content_absent?("   ")
      assert {:error, :invalid_agent_id} = Embedding.delete_agent_content(1)
    end

    test "rejects malformed options including public deadline control" do
      assert {:error, :invalid_options} =
               Embedding.delete_agent_content("agent_x", unknown: true)

      assert {:error, :invalid_options} =
               Embedding.agent_content_absent?("agent_x", timeout_ms: -1)

      assert {:error, :invalid_options} =
               Embedding.delete_agent_content("agent_x", repo: "bad")

      assert {:error, :invalid_options} =
               Embedding.delete_agent_content("agent_x", deadline_ms: 1)

      assert {:error, :invalid_options} =
               IndexSupervisor.terminate_index_ownership("agent_x", deadline_ms: 1)
    end
  end

  describe "composed absence truth table with injected fakes" do
    test "legacy-only residue returns false", %{target: target} do
      FakeRepo.configure(count_reply: 2)
      FakeEvidence.configure(inventory: {:ok, %{}})

      assert {:ok, false} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "index-only residue returns false", %{target: target} do
      pid = spawn_keepalive()
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:ok, %{target => pid}})

      assert {:ok, false} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "true requires both legacy zero and process absence", %{target: target} do
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:ok, %{}})

      assert {:ok, true} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end
  end

  describe "evidence failure matrix never claims absence" do
    test "malformed inventory", %{target: target} do
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:ok, %{"bad" => :not_a_pid}})

      assert {:error, :conflict} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "invalid binary agent-id key with live pid never claims absence", %{target: target} do
      pid = spawn_keepalive()
      FakeRepo.configure(count_reply: 0)

      # Empty binary is not a valid VectorRecord identity; consumer must reject
      # before bijection even when the pid is live and sets match.
      FakeEvidence.configure(
        inventory: {:ok, %{"" => pid}},
        supervisor_script: [{:ok, MapSet.new([pid])}]
      )

      result =
        Embedding.agent_content_absent?(target,
          repo: FakeRepo,
          process_evidence: FakeEvidence
        )

      refute match?({:ok, true}, result)
      assert {:error, :conflict} = result
    end

    test "actually dead pid in inventory never claims absence", %{target: target} do
      dead = spawn(fn -> :ok end)
      wait_until_dead(dead)
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:ok, %{target => dead}})

      result =
        Embedding.agent_content_absent?(target,
          repo: FakeRepo,
          process_evidence: FakeEvidence
        )

      refute match?({:ok, true}, result)
      assert {:error, :conflict} = result
    end

    test "actually dead pid in supervisor set never claims absence", %{target: target} do
      dead = spawn(fn -> :ok end)
      wait_until_dead(dead)
      FakeRepo.configure(count_reply: 0)

      FakeEvidence.configure(
        inventory: {:ok, %{}},
        supervisor_script: [{:ok, MapSet.new([dead])}]
      )

      result =
        Embedding.agent_content_absent?(target,
          repo: FakeRepo,
          process_evidence: FakeEvidence
        )

      refute match?({:ok, true}, result)
      assert {:error, :absence_uncertain} = result
    end

    test "dead pid inventory", %{target: target} do
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:error, :dead})

      assert {:error, :conflict} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "duplicate_agent", %{target: target} do
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:error, :duplicate_agent})

      assert {:error, :conflict} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "duplicate_pid", %{target: target} do
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:error, :duplicate_pid})

      assert {:error, :conflict} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "registry unavailable", %{target: target} do
      FakeRepo.configure(count_reply: 0)
      FakeEvidence.configure(inventory: {:error, :unavailable})

      assert {:error, :registry_unavailable} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "supervisor unavailable", %{target: target} do
      FakeRepo.configure(count_reply: 0)

      FakeEvidence.configure(
        inventory: {:ok, %{}},
        supervisor_script: [{:error, :unavailable}]
      )

      assert {:error, :supervisor_unavailable} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "supervisor restarting_present", %{target: target} do
      FakeRepo.configure(count_reply: 0)

      FakeEvidence.configure(
        inventory: {:ok, %{}},
        supervisor_script: [{:error, :restarting_present}]
      )

      assert {:error, :absence_uncertain} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "bijection mismatch inventory supersets supervisor", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(count_reply: 0)

      FakeEvidence.configure(
        inventory: {:ok, %{target => pid}},
        supervisor_script: [{:ok, MapSet.new()}]
      )

      assert {:error, :absence_uncertain} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "bijection mismatch supervisor supersets inventory", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(count_reply: 0)

      FakeEvidence.configure(
        inventory: {:ok, %{}},
        supervisor_script: [{:ok, MapSet.new([pid])}]
      )

      assert {:error, :absence_uncertain} =
               Embedding.agent_content_absent?(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )
    end

    test "pre-effect timeout with elapsed budget", %{target: target} do
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0, delete_sleep_ms: 30)
      FakeEvidence.configure(inventory: {:ok, %{}})

      assert {:error, reason} =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 10
               )

      assert reason in [:timeout, :outcome_unknown]
      assert FakeEvidence.terminated_pid() == nil
    end
  end

  describe "delete_agent_content composition" do
    test "destroys legacy then terminates target under absolute deadline", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {1, nil}, count_reply: 0)

      FakeEvidence.configure(
        inventory: {:ok, %{target => pid}},
        terminate_reply: :ok,
        inventory_sleep_ms: 5
      )

      assert :ok =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 2_000
               )

      assert FakeEvidence.terminated_pid() == pid
      assert FakeEvidence.inventory_calls() >= 2
    end

    test "elapsed-budget remainings strictly decrease across sequential evidence calls", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

      # Sleep quanta large enough that every adjacent remaining strictly decreases
      # across Registry → supervisor → terminate → post-effect → final-proof.
      FakeEvidence.configure(
        inventory: {:ok, %{target => pid}},
        terminate_reply: :ok,
        inventory_sleep_ms: 20,
        supervisor_sleep_ms: 15,
        terminate_sleep_ms: 15
      )

      assert :ok =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 500
               )

      timeouts = FakeEvidence.timeout_log()
      ops = Enum.map(timeouts, fn {op, _ms} -> op end)
      remainings = Enum.map(timeouts, fn {_op, ms} -> ms end)

      assert :registry in ops
      assert :supervisor in ops
      assert :terminate in ops

      registry_idxs =
        ops
        |> Enum.with_index()
        |> Enum.filter(fn {op, _} -> op == :registry end)
        |> Enum.map(&elem(&1, 1))

      # Pre + post-effect proof + final-proof each call registry (and supervisor)
      assert length(registry_idxs) >= 3
      # Minimum happy path: R,S,T,R,S,R,S
      assert length(ops) >= 7

      assert List.first(remainings) <= 500

      pairs = Enum.chunk_every(remainings, 2, 1, :discard)
      assert Enum.all?(pairs, fn [a, b] -> b < a end)
    end

    test "timeout or exit after terminate maps to closed error never success", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

      FakeEvidence.configure(
        inventory: {:ok, %{target => pid}},
        terminate_reply: {:error, :timeout}
      )

      assert {:error, :outcome_unknown} =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 500
               )

      FakeEvidence.configure(inventory: {:ok, %{target => pid}}, terminate_reply: {:error, :exit})

      assert {:error, :outcome_unknown} =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 500
               )
    end

    test "terminate not_found with fresh proof succeeds when already gone", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

      FakeEvidence.configure(
        inventory_script: [
          {:ok, %{target => pid}},
          {:ok, %{}}
        ],
        supervisor_script: [
          {:ok, MapSet.new([pid])},
          {:ok, MapSet.new()}
        ],
        terminate_reply: {:error, :not_found}
      )

      assert :ok =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 2_000
               )
    end

    test "malformed post-effect proof never succeeds", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

      # First snapshot admits the target; after terminate every subsequent
      # inventory observation is malformed so proof cannot claim absence.
      FakeEvidence.configure(
        inventory_script: [
          {:ok, %{target => pid}}
        ],
        inventory: {:error, :malformed},
        supervisor_script: [
          {:ok, MapSet.new([pid])}
        ],
        terminate_reply: :ok
      )

      assert {:error, reason} =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 200
               )

      # Post-effect proof never returns success; retries exhaust into closed errors.
      assert reason in [:conflict, :outcome_unknown]
      refute match?(:ok, reason)
    end

    test "failed final confirmation after successful ownership termination is outcome_unknown", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

      # 1) Pre-terminate admits target
      # 2) terminate succeeds
      # 3) Post-effect proof sees empty bijection → terminate_index_ownership_until :ok
      # 4) Final composed confirmation is unavailable → exactly :outcome_unknown
      FakeEvidence.configure(
        inventory_script: [
          {:ok, %{target => pid}},
          {:ok, %{}},
          {:error, :unavailable}
        ],
        supervisor_script: [
          {:ok, MapSet.new([pid])},
          {:ok, MapSet.new()}
        ],
        terminate_reply: :ok
      )

      assert {:error, :outcome_unknown} =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 2_000
               )

      assert FakeEvidence.terminated_pid() == pid
    end

    test "fresh post-terminate snapshot is required for success", %{
      target: target
    } do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

      FakeEvidence.configure(
        inventory_script: [
          {:ok, %{target => pid}},
          {:ok, %{target => pid}},
          {:ok, %{}}
        ],
        supervisor_script: [
          {:ok, MapSet.new([pid])},
          {:ok, MapSet.new([pid])},
          {:ok, MapSet.new()}
        ],
        terminate_reply: :ok
      )

      assert :ok =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence,
                 timeout_ms: 2_000
               )

      assert FakeEvidence.inventory_calls() >= 2
    end

    test "durable failure prevents process cleanup", %{target: target} do
      pid = spawn_keepalive()
      FakeRepo.configure(delete_reply: {:raise, RuntimeError.exception("boom")}, count_reply: 0)
      FakeEvidence.configure(inventory: {:ok, %{target => pid}})

      assert {:error, :backend_failure} =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )

      assert FakeEvidence.terminated_pid() == nil
      assert FakeEvidence.call_log() == []
    end

    test "provenance sidecars remain byte-identical across success retry and partial failure", %{
      target: target
    } do
      ensure_provenance!()
      taint = taint(:trusted, :internal, "embedding_cleanup")
      payload = %{"k" => "v"}
      assert :ok = Provenance.put(:embedding, target, "emb_1", payload, taint)
      assert :ok = Provenance.put(:index_entry, target, "idx_1", payload, taint)

      assert {:ok, before_emb_list} = Provenance.list_item_ids(:embedding, target)
      assert {:ok, before_idx_list} = Provenance.list_item_ids(:index_entry, target)

      assert {:ok, before_emb_view, :verified} =
               Provenance.resolve(:embedding, target, "emb_1", payload)

      assert {:ok, before_idx_view, :verified} =
               Provenance.resolve(:index_entry, target, "idx_1", payload)

      before_emb_list_bin = :erlang.term_to_binary(before_emb_list)
      before_idx_list_bin = :erlang.term_to_binary(before_idx_list)
      before_emb_resolve_bin = :erlang.term_to_binary(before_emb_view)
      before_idx_resolve_bin = :erlang.term_to_binary(before_idx_view)

      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)
      FakeEvidence.configure(inventory: {:ok, %{}})

      assert :ok =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )

      # Idempotent retry
      assert :ok =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )

      assert {:ok, after_emb_list} = Provenance.list_item_ids(:embedding, target)
      assert {:ok, after_idx_list} = Provenance.list_item_ids(:index_entry, target)
      assert :erlang.term_to_binary(after_emb_list) == before_emb_list_bin
      assert :erlang.term_to_binary(after_idx_list) == before_idx_list_bin

      assert {:ok, after_emb_view, :verified} =
               Provenance.resolve(:embedding, target, "emb_1", payload)

      assert {:ok, after_idx_view, :verified} =
               Provenance.resolve(:index_entry, target, "idx_1", payload)

      assert :erlang.term_to_binary(after_emb_view) == before_emb_resolve_bin
      assert :erlang.term_to_binary(after_idx_view) == before_idx_resolve_bin

      # Forced partial failure (terminate timeout after durable success)
      pid = spawn_keepalive()

      FakeEvidence.configure(
        inventory: {:ok, %{target => pid}},
        terminate_reply: {:error, :timeout}
      )

      assert {:error, :outcome_unknown} =
               Embedding.delete_agent_content(target,
                 repo: FakeRepo,
                 process_evidence: FakeEvidence
               )

      assert {:ok, partial_emb_list} = Provenance.list_item_ids(:embedding, target)
      assert {:ok, partial_idx_list} = Provenance.list_item_ids(:index_entry, target)
      assert :erlang.term_to_binary(partial_emb_list) == before_emb_list_bin
      assert :erlang.term_to_binary(partial_idx_list) == before_idx_list_bin

      assert {:ok, partial_emb_view, :verified} =
               Provenance.resolve(:embedding, target, "emb_1", payload)

      assert {:ok, partial_idx_view, :verified} =
               Provenance.resolve(:index_entry, target, "idx_1", payload)

      assert :erlang.term_to_binary(partial_emb_view) == before_emb_resolve_bin
      assert :erlang.term_to_binary(partial_idx_view) == before_idx_resolve_bin
    end
  end

  describe "internal until helpers ceiling" do
    test "rejects far-future deadline and admits expired deadline" do
      now = System.monotonic_time(:millisecond)

      assert {:error, :invalid_options} =
               IndexSupervisor.terminate_index_ownership_until(
                 "agent_ceiling",
                 [process_evidence: FakeEvidence],
                 now + 30_001
               )

      FakeEvidence.configure(inventory: {:ok, %{}})

      assert {:error, :timeout} =
               IndexSupervisor.index_ownership_absent_until?(
                 "agent_ceiling",
                 [process_evidence: FakeEvidence],
                 now - 1
               )
    end
  end

  describe "live Index isolation (ETS)" do
    test "target ownership disappears while survivor remains durable-stable", %{
      target: target,
      survivor: survivor
    } do
      scrub_index_ownership!()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

      {:ok, target_pid} =
        IndexSupervisor.start_index(target,
          backend: :ets,
          embedding_provider: stub_provider()
        )

      {:ok, survivor_pid} =
        IndexSupervisor.start_index(survivor,
          backend: :ets,
          embedding_provider: stub_provider()
        )

      emb = valid_embedding()
      assert {:ok, target_id} = Index.index(target_pid, "target-fact", %{}, embedding: emb)
      assert {:ok, survivor_id} = Index.index(survivor_pid, "survivor-fact", %{}, embedding: emb)

      assert {:ok, survivor_before} = Index.get(survivor_pid, survivor_id)
      durable_before = durable_entry_fields(survivor_before)

      # Index.get returns the entry map (id pin, not bare id string).
      assert {:ok, %{id: ^target_id}} = Index.get(target_pid, target_id)

      assert :ok = Embedding.delete_agent_content(target, repo: FakeRepo, timeout_ms: 5_000)

      assert {:error, :not_found} = IndexSupervisor.get_index(target)
      refute IndexSupervisor.has_index?(target)

      assert {:ok, ^survivor_pid} = IndexSupervisor.get_index(survivor)
      assert Process.alive?(survivor_pid)
      assert {:ok, survivor_after} = Index.get(survivor_pid, survivor_id)

      durable_after = durable_entry_fields(survivor_after)
      assert durable_after == durable_before
      assert :erlang.term_to_binary(durable_after) == :erlang.term_to_binary(durable_before)
      # Public get advances documented access metadata only.
      assert survivor_after.access_count == survivor_before.access_count + 1

      assert DateTime.compare(survivor_after.accessed_at, survivor_before.accessed_at) in [
               :gt,
               :eq
             ]

      {:ok, restarted} =
        IndexSupervisor.start_index(target,
          backend: :ets,
          embedding_provider: stub_provider()
        )

      assert {:error, :not_found} = Index.get(restarted, target_id)
    end
  end

  describe "live Index isolation (dual pending + settled workers)" do
    test "pending target state and settled workers are removed with ownership", %{
      target: target,
      survivor: survivor
    } do
      scrub_index_ownership!()
      FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)
      ControlledWriter.configure(target, {:block_then_error, self()})

      entry_id = "mem_pending_#{System.unique_integer([:positive])}"

      {:ok, target_pid} =
        IndexSupervisor.start_index(target,
          backend: :dual,
          strict_vector_seam: ControlledWriter,
          embedding_provider: stub_provider(),
          entry_id_generator: fn -> entry_id end
        )

      {:ok, survivor_pid} =
        IndexSupervisor.start_index(survivor,
          backend: :ets,
          embedding_provider: stub_provider()
        )

      emb = valid_embedding()
      assert {:ok, survivor_id} = Index.index(survivor_pid, "survivor-dual", %{}, embedding: emb)
      assert {:ok, survivor_before} = Index.get(survivor_pid, survivor_id)
      durable_before = durable_entry_fields(survivor_before)

      parent = self()

      spawn(fn ->
        result =
          try do
            Index.index(target_pid, "pending dual content", %{}, embedding: emb)
          catch
            :exit, reason -> {:caller_exit, reason}
          end

        send(parent, {:dual_index_result, result})
      end)

      assert_receive {:writer_waiting_to_fail, ^target, writer_pid}, 1_000
      send(writer_pid, :fail)

      assert_receive {:dual_index_result, {:ok, ^entry_id}}, 2_000
      assert {:ok, %{id: ^entry_id}} = Index.get(target_pid, entry_id)

      assert :ok = Embedding.delete_agent_content(target, repo: FakeRepo, timeout_ms: 5_000)

      assert {:error, :not_found} = IndexSupervisor.get_index(target)
      assert {:ok, ^survivor_pid} = IndexSupervisor.get_index(survivor)
      assert Process.alive?(survivor_pid)
      assert {:ok, survivor_after} = Index.get(survivor_pid, survivor_id)

      durable_after = durable_entry_fields(survivor_after)
      assert durable_after == durable_before
      assert :erlang.term_to_binary(durable_after) == :erlang.term_to_binary(durable_before)
      assert survivor_after.access_count == survivor_before.access_count + 1

      assert DateTime.compare(survivor_after.accessed_at, survivor_before.accessed_at) in [
               :gt,
               :eq
             ]

      ControlledWriter.disarm(target)
    end
  end

  defp spawn_keepalive do
    pid = spawn(fn -> Process.sleep(60_000) end)

    # Unconditional on_exit at creation — independent of setup Agent liveness
    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  defp wait_until_dead(pid, attempts \\ 50) do
    cond do
      not Process.alive?(pid) ->
        :ok

      attempts <= 0 ->
        flunk("expected pid #{inspect(pid)} to die")

      true ->
        Process.sleep(1)
        wait_until_dead(pid, attempts - 1)
    end
  end

  defp durable_entry_fields(entry) when is_map(entry) do
    Map.take(entry, [:id, :content, :embedding, :metadata, :indexed_at])
  end

  defp stub_provider do
    Module.concat(__MODULE__, EmbeddingProviderStub)
  end

  defmodule EmbeddingProviderStub do
    @moduledoc false
    def embed(_text, _opts \\ []), do: {:ok, List.duplicate(0.01, 768)}
  end

  defp valid_embedding do
    List.replace_at(List.duplicate(0.0, @persistent_dimension), 0, 1.0)
  end

  # Direct Index.start_link tests leave Registry entries outside IndexSupervisor.
  # Scrub both sides so production bijection evidence can be exercised live.
  defp scrub_index_ownership! do
    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(IndexSupervisor),
        is_pid(pid) do
      _ = DynamicSupervisor.terminate_child(IndexSupervisor, pid)
    end

    entries =
      Registry.select(Arbor.Memory.Registry, [
        {{{:index, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
      ])

    for {_agent_id, pid} <- entries, is_pid(pid), Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    Process.sleep(30)
    :ok
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      nil ->
        {:ok, _pid} = start_supervised(Provenance)
        :ok

      _pid ->
        :ok
    end
  end

  defp taint(level, sensitivity, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end
end
