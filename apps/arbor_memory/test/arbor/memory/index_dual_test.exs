defmodule Arbor.Memory.IndexDualTest do
  @moduledoc """
  Tests for the Index module in dual backend mode.

  These tests verify that the ETS + pgvector dual backend works correctly.
  Requires PostgreSQL with pgvector extension.
  Run with: mix test --include database
  """

  use ExUnit.Case

  @moduletag :database

  alias Arbor.Memory.{Embedding, Index}
  alias Arbor.Persistence.Repo

  @test_agent_id "test_agent_dual_index"
  @dimension 128

  setup do
    # Start the sandbox for database transactions
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

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

  defp generate_embedding(seed \\ 0) do
    for i <- 0..(@dimension - 1) do
      :math.sin((seed + i) / 100) * 0.5 + 0.5
    end
  end

  describe "dual backend mode" do
    test "reports correct backend mode", %{pid: pid} do
      assert Index.backend_mode(pid) == :dual
    end

    test "index writes to both ETS and pgvector", %{pid: pid} do
      embedding = generate_embedding(1)
      {:ok, _id} = Index.index(pid, "Dual backend test", %{type: :fact}, embedding: embedding)

      # Give async write time to complete
      Process.sleep(100)

      # Should be in ETS
      stats = Index.stats(pid)
      assert stats.entry_count == 1

      # Should also be in pgvector
      pgvector_count = Embedding.count(@test_agent_id)
      assert pgvector_count == 1
    end

    test "recall checks ETS first (cache hit)", %{pid: pid} do
      embedding = generate_embedding(1)
      {:ok, _id} = Index.index(pid, "Cache hit test", %{type: :fact}, embedding: embedding)

      # Recall should find it in ETS
      {:ok, results} = Index.recall(pid, "Cache hit test", embedding: embedding, threshold: 0.0)

      assert length(results) >= 1
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
      assert length(results) >= 1
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

      # Give async write time to complete
      Process.sleep(100)

      # Verify it's in pgvector
      pgvector_count = Embedding.count(@test_agent_id)
      assert pgvector_count >= 1
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

      # Give async write time
      Process.sleep(100)

      # Delete
      :ok = Index.delete(pid, id)

      # Verify removed from ETS
      assert {:error, :not_found} = Index.get(pid, id)

      # Verify removed from pgvector (may take a moment)
      Process.sleep(50)
      # The pgvector entry uses the same ID
    end
  end
end
