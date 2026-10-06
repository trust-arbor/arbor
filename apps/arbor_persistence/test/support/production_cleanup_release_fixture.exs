defmodule Arbor.Persistence.ProductionCleanupReleaseFixture do
  @moduledoc false

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Persistence
  alias Arbor.Persistence.Repo

  def run do
    false = Code.ensure_loaded?(Mix)
    nil = Process.whereis(Arbor.Persistence.Supervisor)
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Application.ensure_all_started(:jason)

    {:ok, _} =
      Repo.start_link(
        database: System.fetch_env!("ARBOR_PERSISTENCE_RELEASE_DATABASE"),
        pool_size: 1,
        busy_timeout: 5_000
      )

    migrate()

    Application.put_env(
      :arbor_persistence,
      :vector_store_backend,
      Arbor.Persistence.VectorStore.Ecto
    )

    Application.put_env(:arbor_persistence, :vector_store_repo, Repo)

    target = "release-cleanup-agent"
    control = "release-cleanup-control"

    for agent <- [target, control] do
      {:ok, _} = Persistence.execute_vector_operation(agent, insert(agent))
      seed_legacy_row(agent)
      {:ok, _} = Persistence.put_relationship(agent, %{id: "rel-" <> agent, name: "Grace"})
    end

    for {module, function, arity} <- [
          {Arbor.Persistence.VectorStore.Ecto, :__set_post_destroy_residual_override__, 1},
          {Arbor.Persistence.LegacyEmbeddingStore, :__set_post_delete_remaining_override__, 1},
          {Arbor.Persistence.RelationshipStore, :__set_post_delete_remaining_override__, 1}
        ] do
      true = Code.ensure_loaded?(module)
      false = function_exported?(module, function, arity)
    end

    # Production must ignore forged process-local test hooks.
    Process.put(:arbor_vector_destroy_residual_override, true)
    Process.put({Arbor.Persistence.LegacyEmbeddingStore, :post_delete_remaining_override}, 99)
    Process.put({Arbor.Persistence.RelationshipStore, :post_delete_remaining_override}, 99)

    results = [
      vector: Persistence.destroy_vector_agent(target),
      legacy: Persistence.destroy_legacy_embeddings(target),
      relationship: Persistence.delete_all_relationships(target)
    ]

    IO.inspect(results, label: "PUBLIC_PRODUCTION_CLEANUP_RESULTS")
    [vector: :ok, legacy: :ok, relationship: :ok] = results
    {:error, :closed} = Persistence.execute_vector_operation(target, insert(target))
    {:ok, true} = Persistence.legacy_embeddings_absent?(target)
    {:ok, true} = Persistence.relationships_absent?(target)
    {:ok, %{agent_id: ^control}} = Persistence.fetch_vector_record(control, "release", "one")
    1 = Persistence.count_legacy_embeddings(control)
    {:ok, %{name: "Grace"}} = Persistence.fetch_relationship(control, "rel-" <> control)
    false = Code.ensure_loaded?(Mix)
    IO.puts("PUBLIC_PRODUCTION_CLEANUP_NO_MIX_OK")
    :ok
  end

  defp migrate do
    for {version, name, module} <- [
          {20_260_131_000_001, "20260131000001_create_relationships.exs",
           Arbor.Persistence.Repo.Migrations.CreateRelationships},
          {20_260_201_000_001, "20260201000001_create_memory_embeddings.exs",
           Arbor.Persistence.Repo.Migrations.CreateMemoryEmbeddings},
          {20_260_805_000_001, "20260805000001_prepare_vector_store_v1.exs",
           Arbor.Persistence.Repo.Migrations.PrepareVectorStoreV1},
          {20_260_805_000_002, "20260805000002_widen_vector_agent_ids.exs",
           Arbor.Persistence.Repo.Migrations.WidenVectorAgentIds},
          {20_260_805_000_003, "20260805000003_isolate_vector_store_v1_rows.exs",
           Arbor.Persistence.Repo.Migrations.IsolateVectorStoreV1Rows},
          {20_260_805_000_004, "20260805000004_harden_vector_receipt_inserts.exs",
           Arbor.Persistence.Repo.Migrations.HardenVectorReceiptInserts},
          {20_260_805_000_005, "20260805000005_harden_vector_receipt_rowids.exs",
           Arbor.Persistence.Repo.Migrations.HardenVectorReceiptRowids},
          {20_260_807_000_001, "20260807000001_create_vector_agent_fences.exs",
           Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences}
        ] do
      Code.require_file(Application.app_dir(:arbor_persistence, "priv/repo/migrations/" <> name))
      :ok = Ecto.Migrator.up(Repo, version, module, log: false)
    end
  end

  defp insert(agent) do
    payload = %{"content" => "strict " <> agent}
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector())

    {:ok, record} =
      VectorRecord.new(%{
        id: "vec-" <> agent,
        agent_id: agent,
        source_namespace: "release",
        source_key: "one",
        payload: payload,
        payload_digest: payload_digest,
        vector: vector(),
        vector_digest: vector_digest,
        model_id: "release/model-v1",
        dimensions: 768,
        encoding: VectorRecord.encoding(),
        category: "fixture",
        generation: 0,
        revision: 0,
        tombstone: false
      })

    {:ok, operation} =
      VectorOperation.new(%{
        kind: :insert,
        record: record,
        expected_generation: nil,
        expected_revision: nil
      })

    operation
  end

  defp seed_legacy_row(agent) do
    # This proof owns cleanup, not the separate legacy Pgvector write port.
    # Seed the canonical SQLite legacy representation just as the SQL
    # conformance fixtures do; exercise deletion and absence through the facade.
    content = "legacy " <> agent
    digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      """
      INSERT INTO memory_embeddings
        (id, agent_id, content, content_hash, embedding, metadata, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      ["legacy-" <> agent, agent, content, digest, Jason.encode!(vector()), "{}", now, now]
    )
  end

  defp vector, do: List.duplicate(0.25, 768)
end
