defmodule Arbor.Memory.IndexDualTest do
  @moduledoc """
  PostgreSQL integration coverage for the C3G2 strict Index and MemoryStore paths.

  These tests exercise the real strict vector boundary. Reliability behavior that
  does not require a database remains in `index_test.exs` and the focused C3G2
  seam tests.
  """

  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope

  alias Arbor.Memory.{
    Embedding,
    Index,
    MemoryStore,
    MemoryStoreIdentity,
    StrictEmbeddingInput,
    StrictVectorSeam
  }

  @moduletag :database
  @moduletag :integration
  @moduletag :postgres

  if Arbor.Persistence.Repo.__adapter__() != Ecto.Adapters.Postgres do
    @moduletag skip: "strict dual pgvector coverage requires ARBOR_DB=postgres"
  end

  defmodule AckLossSeam do
    @moduledoc false

    alias Arbor.Memory.StrictVectorSeam

    def arm(agent_id) do
      :persistent_term.put({__MODULE__, agent_id}, :lose_once)
      :persistent_term.put({__MODULE__, :execute_count, agent_id}, 0)
    end

    def disarm(agent_id) do
      :persistent_term.erase({__MODULE__, agent_id})
      :persistent_term.erase({__MODULE__, :execute_count, agent_id})
    end

    def execute_count(agent_id),
      do: :persistent_term.get({__MODULE__, :execute_count, agent_id}, 0)

    def encode_operation(input), do: StrictVectorSeam.Default.encode_operation(input)
    def encode_batch(inputs), do: StrictVectorSeam.Default.encode_batch(inputs)

    def execute(agent_id, operation, opts) do
      :persistent_term.put(
        {__MODULE__, :execute_count, agent_id},
        execute_count(agent_id) + 1
      )

      case :persistent_term.get({__MODULE__, agent_id}, :pass) do
        :lose_once ->
          :persistent_term.put({__MODULE__, agent_id}, :pass)

          case StrictVectorSeam.Default.execute(agent_id, operation, opts) do
            {:ok, _receipt} -> {:error, :indeterminate}
            error -> error
          end

        :pass ->
          StrictVectorSeam.Default.execute(agent_id, operation, opts)
      end
    end

    def reconcile(agent_id, operation, opts),
      do: StrictVectorSeam.Default.reconcile(agent_id, operation, opts)

    def search(agent_id, vector, opts),
      do: StrictVectorSeam.Default.search(agent_id, vector, opts)

    def fetch(agent_id, namespace, key, opts),
      do: StrictVectorSeam.Default.fetch(agent_id, namespace, key, opts)

    def list(agent_id, opts), do: StrictVectorSeam.Default.list(agent_id, opts)
  end

  setup do
    original_backend =
      Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)

    original_repo = Application.get_env(:arbor_persistence, :vector_store_repo, :not_configured)

    original_seam = Application.get_env(:arbor_memory, :strict_vector_seam, :not_configured)

    Application.put_env(
      :arbor_persistence,
      :vector_store_backend,
      Arbor.Persistence.VectorStore.Ecto
    )

    Application.put_env(:arbor_persistence, :vector_store_repo, Arbor.Persistence.Repo)
    Application.put_env(:arbor_memory, :strict_vector_seam, StrictVectorSeam.Default)

    agent_id = unique("strict_index_agent")

    on_exit(fn ->
      AckLossSeam.disarm(agent_id)
      restore_env(:arbor_persistence, :vector_store_backend, original_backend)
      restore_env(:arbor_persistence, :vector_store_repo, original_repo)
      restore_env(:arbor_memory, :strict_vector_seam, original_seam)
    end)

    {:ok, agent_id: agent_id}
  end

  test "dual writes preserve exact entry identities and equal content remains distinct", %{
    agent_id: agent_id
  } do
    pid = start_index(agent_id, :dual)
    vector = unit_vector(0)

    assert {:ok, first_id} =
             Index.index(pid, "same content", %{type: :fact}, embedding: vector)

    assert {:ok, second_id} =
             Index.index(pid, "same content", %{type: :fact}, embedding: vector)

    assert first_id != second_id
    assert Index.stats(pid).entry_count == 2

    for id <- [first_id, second_id] do
      assert {:ok, %{id: ^id, content: "same content"}} = Index.get(pid, id)

      assert {:ok,
              %{
                id: ^id,
                agent_id: ^agent_id,
                source_namespace: "memory_index",
                source_key: ^id,
                model_id: "legacy:unspecified",
                provenance_status: :verified,
                tombstone: false
              }} = Embedding.fetch_strict(agent_id, "memory_index", id)
    end
  end

  test "pgvector recall uses strict ANN and returns the exact stored row id", %{
    agent_id: agent_id
  } do
    pid = start_index(agent_id, :pgvector)
    target_vector = unit_vector(0)

    assert {:ok, target_id} =
             Index.index(pid, "target", %{type: :fact}, embedding: target_vector)

    assert {:ok, distractor_id} =
             Index.index(pid, "distractor", %{type: :fact}, embedding: unit_vector(1))

    assert {:ok, [%{id: ^target_id, content: "target"} | rest]} =
             Index.recall(pid, "ignored",
               embedding: target_vector,
               type: :fact,
               threshold: -1.0,
               limit: 10
             )

    assert Enum.any?(rest, &(&1.id == distractor_id))
  end

  test "strict batch preserves ordered distinct identities for equal content", %{
    agent_id: agent_id
  } do
    pid = start_index(agent_id, :dual)
    vector = unit_vector(2)

    assert {:ok, [first_id, second_id]} =
             Index.batch_index(
               pid,
               [{"same batch content", %{type: :note}}, {"same batch content", %{type: :note}}],
               embedding: vector
             )

    assert first_id != second_id

    for id <- [first_id, second_id] do
      assert {:ok, %{id: ^id, source_key: ^id, tombstone: false}} =
               Embedding.fetch_strict(agent_id, "memory_index", id)
    end
  end

  test "warm cache admits only decoded strict rows with their descriptor intact", %{
    agent_id: agent_id
  } do
    writer = start_index(agent_id, :pgvector)
    vector = unit_vector(3)

    assert {:ok, entry_id} =
             Index.index(writer, "warm me", %{type: :thought}, embedding: vector)

    cache = start_index(agent_id, :dual)
    assert {:error, :not_found} = Index.get(cache, entry_id)
    assert :ok = Index.warm_cache(cache, limit: 10)

    assert {:ok,
            %{
              id: ^entry_id,
              content: "warm me",
              model_id: "legacy:unspecified",
              dimensions: dimensions,
              encoding: encoding,
              category: "thought",
              provenance_status: :verified
            }} = Index.get(cache, entry_id)

    assert dimensions == VectorRecord.dimensions()
    assert encoding == VectorRecord.encoding()
  end

  test "explicit delete commits an exact tombstone before removing the local projection", %{
    agent_id: agent_id
  } do
    pid = start_index(agent_id, :dual)

    assert {:ok, entry_id} =
             Index.index(pid, "delete me", %{type: :fact}, embedding: unit_vector(4))

    assert :ok = Index.delete(pid, entry_id)
    assert {:error, :not_found} = Index.get(pid, entry_id)
    assert {:error, :not_found} = Embedding.fetch_strict(agent_id, "memory_index", entry_id)

    assert {:ok,
            %{
              id: ^entry_id,
              source_key: ^entry_id,
              generation: 1,
              revision: 2,
              tombstone: true
            }} =
             Embedding.fetch_strict(agent_id, "memory_index", entry_id, include_tombstone: true)
  end

  test "commit acknowledgement loss reconciles the immutable operation", %{agent_id: agent_id} do
    AckLossSeam.arm(agent_id)
    pid = start_index(agent_id, :pgvector, strict_vector_seam: AckLossSeam)

    assert {:ok, entry_id} =
             Index.index(pid, "ack lost", %{type: :fact}, embedding: unit_vector(5))

    assert AckLossSeam.execute_count(agent_id) == 1

    assert {:ok, %{id: ^entry_id, source_key: ^entry_id, tombstone: false}} =
             Embedding.fetch_strict(agent_id, "memory_index", entry_id)
  end

  test "MemoryStore fetch and delete use original namespace and key, never the row digest", %{
    agent_id: agent_id
  } do
    key = "shared-key"
    first_namespace = "goals"
    second_namespace = "thinking"

    for {namespace, content, vector} <- [
          {first_namespace, "goal", unit_vector(6)},
          {second_namespace, "thought", unit_vector(7)}
        ] do
      input =
        StrictEmbeddingInput.memory_store_insert(%{
          agent_id: agent_id,
          namespace: namespace,
          key: key,
          content: content,
          vector: vector,
          type: :memory,
          model_evidence: :absent,
          taint: TaintEnvelope.missing_fallback()
        })

      assert {:ok, _receipt} = Embedding.execute_strict(agent_id, input)
    end

    first_id = MemoryStoreIdentity.row_id(agent_id, first_namespace, key)
    second_id = MemoryStoreIdentity.row_id(agent_id, second_namespace, key)
    assert first_id != second_id

    assert {:ok, %{id: ^first_id, source_key: ^key}} =
             Embedding.fetch_strict(agent_id, first_namespace, key)

    assert {:ok, %{id: ^second_id, source_key: ^key}} =
             Embedding.fetch_strict(agent_id, second_namespace, key)

    assert :ok = MemoryStore.delete_embedding(first_namespace, key, agent_id: agent_id)
    assert {:error, :not_found} = Embedding.fetch_strict(agent_id, first_namespace, key)

    assert {:ok, %{id: ^second_id, tombstone: false}} =
             Embedding.fetch_strict(agent_id, second_namespace, key)
  end

  defp start_index(agent_id, backend, opts \\ []) do
    registry_key = {:strict_dual_test, agent_id, unique("index")}

    {:ok, pid} =
      Index.start_link(
        Keyword.merge(
          [
            agent_id: agent_id,
            backend: backend,
            strict_vector_seam: StrictVectorSeam.Default,
            name: {:via, Registry, {Arbor.Memory.Registry, registry_key}}
          ],
          opts
        )
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    pid
  end

  defp unit_vector(index) do
    List.duplicate(0.0, VectorRecord.dimensions())
    |> List.replace_at(index, 1.0)
  end

  defp unique(prefix),
    do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp restore_env(app, key, :not_configured), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
