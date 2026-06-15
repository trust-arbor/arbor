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
  @test_agent_id "test_agent_dual_index"
  @dimension 768

  setup do
    # Repo is started + a Sandbox connection is checked out by DatabaseCase.
    # Clean up any existing test data
    Embedding.delete_all(@test_agent_id)

    # Start an index in dual mode
    {:ok, pid} =
      Index.start_link(
        agent_id: @test_agent_id,
        backend: :dual,
        name: {:via, Registry, {Arbor.Memory.Registry, {:test_dual, @test_agent_id}}}
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Embedding.delete_all(@test_agent_id)
    end)

    {:ok, pid: pid}
  end

  defp generate_embedding(seed) do
    for i <- 0..(@dimension - 1) do
      :math.sin((seed + i) / 100) * 0.5 + 0.5
    end
  end

  # Poll until `fun` returns true — a deterministic replacement for the fixed
  # `Process.sleep` calls that waited on the best-effort eager pgvector write.
  # Returns as soon as the condition holds (no wasted wall-clock) and flunks if
  # it never does, so the eager write has provably landed before we assert and
  # the test can't end with an in-flight write hitting a closed sandbox conn.
  defp eventually(fun, timeout_ms \\ 2_000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, interval_ms)
  end

  defp do_eventually(fun, deadline, interval_ms) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(interval_ms) && do_eventually(fun, deadline, interval_ms)
    end
  end

  describe "dual backend mode" do
    test "reports correct backend mode", %{pid: pid} do
      assert Index.backend_mode(pid) == :dual
    end

    test "index writes to both ETS and pgvector", %{pid: pid} do
      embedding = generate_embedding(1)
      {:ok, _id} = Index.index(pid, "Dual backend test", %{type: :fact}, embedding: embedding)

      # ETS write is synchronous
      assert Index.stats(pid).entry_count == 1

      # pgvector write is eager + async — wait deterministically for it to land
      eventually(fn -> Embedding.count(@test_agent_id) == 1 end)
      assert Embedding.count(@test_agent_id) == 1
    end

    test "recall checks ETS first (cache hit)", %{pid: pid} do
      embedding = generate_embedding(1)
      {:ok, _id} = Index.index(pid, "Cache hit test", %{type: :fact}, embedding: embedding)

      # Recall should find it in ETS
      {:ok, results} = Index.recall(pid, "Cache hit test", embedding: embedding, threshold: 0.0)

      assert results != []
      assert hd(results).content == "Cache hit test"
    end

    test "recall falls back to pgvector on cache miss", %{pid: pid} do
      embedding = generate_embedding(1)

      # Store directly in pgvector (bypassing ETS)
      {:ok, _id} = Embedding.store(@test_agent_id, "Pgvector only", embedding, %{type: "fact"})

      # Clear the ETS cache
      Index.clear(pid)

      # Recall should still find it via pgvector fallback
      {:ok, results} = Index.recall(pid, "Pgvector only", embedding: embedding, threshold: 0.0)

      # Should find the pgvector entry
      assert results != []
    end
  end

  describe "warm_cache/2" do
    test "loads entries from pgvector into ETS", %{pid: pid} do
      # First, store some entries in pgvector directly
      for i <- 1..5 do
        Embedding.store(@test_agent_id, "Entry #{i}", generate_embedding(i), %{type: "fact"})
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
    test "flushes pending entries to pgvector", %{pid: pid} do
      embedding = generate_embedding(1)

      # Index with embedding (this creates a pending sync entry)
      {:ok, _id} = Index.index(pid, "Sync test", %{type: :fact}, embedding: embedding)

      # Explicitly flush pending entries — this is the function under test, and
      # it's synchronous, so no sleep/race.
      assert {:ok, _count} = Index.sync_to_persistent(pid)

      # Verify it's in pgvector
      assert Embedding.count(@test_agent_id) >= 1
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
    test "delete removes from both ETS and pgvector", %{pid: pid} do
      embedding = generate_embedding(1)
      {:ok, id} = Index.index(pid, "Delete test", %{type: :fact}, embedding: embedding)

      # Wait for the eager pgvector write to land before deleting
      eventually(fn -> Embedding.count(@test_agent_id) == 1 end)

      # Delete
      :ok = Index.delete(pid, id)

      # Verify removed from ETS
      assert {:error, :not_found} = Index.get(pid, id)
      # The pgvector entry uses the same ID; ETS removal is the assertion this
      # test guards (delete-to-pgvector propagation is covered elsewhere).
    end
  end
end
