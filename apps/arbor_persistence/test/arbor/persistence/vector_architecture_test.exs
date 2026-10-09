defmodule Arbor.Persistence.VectorArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @boundary_sources [
    "config.ex",
    "vector_store.ex",
    "vector_store/unsupported.ex",
    "vector_boundary.ex"
  ]

  @ecto_sources [
    "vector_store/ecto.ex",
    "vector_store/ecto/codec.ex",
    "vector_store/ecto/vector_row.ex",
    "vector_store/ecto/operation_receipt_row.ex",
    "vector_store/ecto/agent_fence_row.ex"
  ]

  test "new vector boundary has no Repo, schema, Ecto, Pgvector, Memory, or runtime bridge" do
    root = Path.expand("../../../lib/arbor/persistence", __DIR__)

    for filename <- @boundary_sources do
      source = File.read!(Path.join(root, filename))
      scanned = vector_boundary_source(filename, source)

      refute scanned =~ "Arbor.Persistence.Repo"
      refute scanned =~ "Arbor.Persistence.Schemas"
      refute scanned =~ "Ecto."
      refute scanned =~ "Pgvector"
      refute scanned =~ "Arbor.Memory"
      refute scanned =~ "Code.ensure_loaded"
      refute scanned =~ ~r/\bapply\s*\(/
    end
  end

  # config.ex is the shared seam. sql_repository/0 names the conversation SQL
  # repo, and the moduledoc names VectorStore.Ecto as the product default.
  # Those are outside the vector functions, which must stay free of that bridge.
  defp vector_boundary_source("config.ex", source) do
    [_sql_seam, vector] = String.split(source, "def vector_store_backend", parts: 2)
    "def vector_store_backend" <> vector
  end

  defp vector_boundary_source(_filename, source), do: source

  test "public facade vector section is only a boundary delegate" do
    source = File.read!(Path.expand("../../../lib/arbor/persistence.ex", __DIR__))
    [_, after_marker] = String.split(source, "# Validated vector-store boundary", parts: 2)
    # Vector section ends at the next domain section (relationship records sit
    # between vector and session transcript; do not over-scan into it).
    [section, _] = String.split(after_marker, "# Relationship records", parts: 2)

    assert section =~ "VectorBoundary.execute"
    assert section =~ "VectorBoundary.reconcile"
    assert section =~ "VectorBoundary.fetch"
    assert section =~ "VectorBoundary.list"
    assert section =~ "VectorBoundary.search"
    assert section =~ "VectorBoundary.destroy"
    refute section =~ "Repo"
    refute section =~ "Schemas"
    refute section =~ "Ecto"
    refute section =~ "Pgvector"
  end

  test "Persistence adds no Memory dependency for vector storage" do
    mix_source = File.read!(Path.expand("../../../mix.exs", __DIR__))
    refute mix_source =~ "{:arbor_memory"
  end

  test "Ecto vector storage stays library-owned and does not import Memory or persistence_ecto" do
    root = Path.expand("../../../lib/arbor/persistence", __DIR__)

    for filename <- @ecto_sources do
      source = File.read!(Path.join(root, filename))

      refute source =~ "Arbor.Memory"
      refute source =~ "arbor_persistence_ecto"
      refute source =~ "Arbor.Persistence.Schemas.MemoryEmbedding"
      refute source =~ "Code.ensure_loaded"
      refute source =~ ~r/\bapply\s*\(/
    end
  end
end
