defmodule Arbor.Memory.UnownedConversationRecallSecurityRegressionTest do
  @moduledoc """
  Public-reader regressions for recognized conversation exclusion (SU-3/M1a).

  The seam uses real strict envelope encoding/decoding and deterministic vectors.
  Its explicit view overrides exercise malformed or legacy-shaped boundary data.
  No admission policy is mocked. These tests prove the exclusion class, not full
  human-owner isolation or the safety of other memory types.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory
  alias Arbor.Memory.{Embedding, Index, StrictEmbeddingInput}

  @moduletag :fast

  defmodule StrictSeam do
    @moduledoc false
    use Agent

    alias Arbor.Memory.Embedding

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            records: %{},
            search_error: nil,
            search_override: nil,
            list_override: nil,
            searches: 0
          }
        end,
        name: __MODULE__
      )
    end

    def put(record, similarity) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:records, {record.agent_id, record.source_key}], {record, similarity})
      end)
    end

    def configure(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
    def searches, do: Agent.get(__MODULE__, & &1.searches)
    def records, do: Agent.get(__MODULE__, & &1.records)

    def encode_operation(input), do: Embedding.encode_strict_operation(input)
    def encode_batch(inputs), do: Embedding.encode_strict_batch(inputs)

    def execute(_agent_id, operation, _opts) do
      put(operation.record, 1.0)
      {:ok, %{kind: operation.kind, record: operation.record}}
    end

    def reconcile(_agent_id, _operation, _opts), do: {:ok, :absent}

    def fetch(agent_id, namespace, key, _opts) do
      case Map.get(records(), {agent_id, key}) do
        {%{source_namespace: ^namespace} = record, _similarity} ->
          Embedding.decode_strict_record(record)

        _ ->
          {:error, :not_found}
      end
    end

    def list(agent_id, opts) do
      state = Agent.get(__MODULE__, & &1)

      views =
        case state.list_override do
          nil ->
            state.records
            |> matches(agent_id, opts)
            |> Enum.map(& &1.match)

          override ->
            override
        end

      {:ok, views}
    end

    def search(agent_id, _vector, opts) do
      state =
        Agent.get_and_update(__MODULE__, fn state ->
          {state, %{state | searches: state.searches + 1}}
        end)

      cond do
        state.search_error -> {:error, state.search_error}
        state.search_override -> {:ok, state.search_override}
        true -> {:ok, matches(state.records, agent_id, opts)}
      end
    end

    defp matches(records, agent_id, opts) do
      namespace = Keyword.get(opts, :source_namespace, "memory_index")
      category = Keyword.get(opts, :category)
      model_id = Keyword.get(opts, :model_id)

      records
      |> Map.values()
      |> Enum.filter(fn {record, _similarity} ->
        record.agent_id == agent_id and record.source_namespace == namespace and
          (is_nil(category) or record.category == category) and
          (is_nil(model_id) or record.model_id == model_id)
      end)
      |> Enum.map(fn {record, similarity} ->
        {:ok, view} = Embedding.decode_strict_record(record)
        %{match: view, similarity: similarity}
      end)
      |> Enum.sort_by(&{-&1.similarity, &1.match.id})
      |> Enum.take(Keyword.get(opts, :limit, 1000))
    end
  end

  setup do
    start_supervised!(StrictSeam)
    previous = Application.fetch_env(:arbor_memory, :strict_vector_seam)
    Application.put_env(:arbor_memory, :strict_vector_seam, StrictSeam)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_memory, :strict_vector_seam, value)
        :error -> Application.delete_env(:arbor_memory, :strict_vector_seam)
      end
    end)

    {:ok, agent_id: "agent_recall_admission_#{System.unique_integer([:positive])}"}
  end

  test "security regression: public ETS recall excludes conversations before ranking", ctx do
    start_index(ctx.agent_id, :ets)

    for metadata <- conversation_metadata() do
      assert {:ok, _} =
               Memory.index(ctx.agent_id, "excluded conversation", metadata, embedding: vector())
    end

    assert {:ok, control_id} =
             Memory.index(ctx.agent_id, "unmarked control", %{type: :fact},
               embedding: less_similar_vector()
             )

    assert {:ok, [%{id: ^control_id}]} =
             Memory.recall(ctx.agent_id, "query", embedding: vector(), threshold: -1.0, limit: 1)

    assert {:ok, %{entry_count: 6}} = Memory.index_stats(ctx.agent_id)
  end

  test "security regression: Index.get withholds conversations without removing entries", ctx do
    pid = start_index(ctx.agent_id, :ets)

    assert {:ok, hidden_id} =
             Memory.index(ctx.agent_id, "excluded conversation", forged_metadata(),
               embedding: vector()
             )

    assert {:ok, control_id} =
             Memory.index(ctx.agent_id, "unmarked control", %{type: :fact}, embedding: vector())

    # Observe the test-owned cache only to prove the secondary no-access-mutation
    # invariant; the disclosure assertion itself remains on the public API.
    table = :sys.get_state(pid).table
    hidden_before = :ets.lookup(table, hidden_id)
    assert {:error, :not_found} = Index.get(pid, hidden_id)
    assert :ets.lookup(table, hidden_id) == hidden_before
    assert {:ok, %{id: ^control_id}} = Index.get(pid, control_id)
    assert {:ok, %{entry_count: 2}} = Memory.index_stats(ctx.agent_id)
  end

  test "security regression: default formatted recall omits conversations", ctx do
    start_index(ctx.agent_id, :ets)

    assert {:ok, _} =
             Memory.index(ctx.agent_id, "HIDDEN_TRANSCRIPT", %{type: :conversation},
               embedding: vector()
             )

    assert {:ok, _} =
             Memory.index(ctx.agent_id, "VISIBLE_CONTROL", %{type: :fact}, embedding: vector())

    assert {:ok, text} = Memory.let_me_recall(ctx.agent_id, "query", embedding: vector())
    assert text =~ "VISIBLE_CONTROL"
    refute text =~ "HIDDEN_TRANSCRIPT"
  end

  test "security regression: public ANN recall excludes metadata and category conversations",
       ctx do
    seed_pair(ctx.agent_id)
    start_index(ctx.agent_id, :pgvector, rehydrate: false)

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.recall(ctx.agent_id, "query", embedding: vector(), limit: 10)

    assert StrictSeam.searches() == 1
    assert map_size(StrictSeam.records()) == 3
  end

  test "security regression: direct embedding search cannot bypass conversation exclusion", ctx do
    seed_pair(ctx.agent_id)

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.search_embeddings(ctx.agent_id, vector(), limit: 10)

    assert StrictSeam.searches() == 1
    assert map_size(StrictSeam.records()) == 3
  end

  test "security regression: persistent formatted recall cannot bypass conversation exclusion",
       ctx do
    seed_pair(ctx.agent_id)

    assert {:ok, text} =
             Memory.let_me_recall(ctx.agent_id, "query",
               backend: :persistent,
               embedding: vector()
             )

    assert text =~ "VISIBLE_CONTROL"
    refute text =~ "HIDDEN_TRANSCRIPT"
    assert StrictSeam.searches() == 1
  end

  test "security regression: ANN exclusion preserves the requested backend limit", ctx do
    seed_pair(ctx.agent_id)
    start_index(ctx.agent_id, :pgvector, rehydrate: false)

    # A backend top-1 conversation is omitted; this slice does not implement
    # owner-aware overfetch/completeness or a replacement ANN query engine.
    assert {:ok, []} = Memory.recall(ctx.agent_id, "query", embedding: vector(), limit: 1)
    assert StrictSeam.searches() == 1
  end

  test "security regression: public type filters do not reopen conversation recall", ctx do
    seed_pair(ctx.agent_id)
    start_index(ctx.agent_id, :pgvector, rehydrate: false)

    assert {:ok, []} =
             Memory.recall(ctx.agent_id, "query", embedding: vector(), type: :conversation)

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.recall(ctx.agent_id, "query",
               embedding: vector(),
               types: [:conversation, :fact]
             )

    assert {:ok, []} =
             Memory.search_embeddings(ctx.agent_id, vector(), type_filter: :conversation)

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.search_embeddings(ctx.agent_id, vector(), type_filter: :fact)

    assert {:ok, ""} =
             Memory.let_me_recall(ctx.agent_id, "query",
               backend: :persistent,
               embedding: vector(),
               type: :conversation
             )

    assert {:ok, text} =
             Memory.let_me_recall(ctx.agent_id, "query",
               backend: :persistent,
               embedding: vector(),
               types: [:conversation, :fact]
             )

    assert text =~ "VISIBLE_CONTROL"
    refute text =~ "HIDDEN_TRANSCRIPT"
  end

  for backend <- [:pgvector, :dual] do
    @backend backend
    test "security regression: #{@backend} fallback excludes cold-rehydrated conversations",
         ctx do
      seed_pair(ctx.agent_id)
      stored = StrictSeam.records()
      StrictSeam.configure(:search_error, :unsupported)
      pid = start_index(ctx.agent_id, @backend)

      assert {:ok, %{entry_count: 3}} = Memory.index_stats(ctx.agent_id)

      assert {:ok, [%{id: "mem_control"}]} =
               Memory.recall(ctx.agent_id, "query", embedding: vector(), limit: 10)

      assert {:error, :not_found} = Index.get(pid, "mem_category_conversation")
      assert {:error, :not_found} = Index.get(pid, "mem_metadata_conversation")
      assert StrictSeam.searches() == 1
      assert StrictSeam.records() == stored
    end
  end

  test "security regression: warm cache preserves excluded records and authoritative category",
       ctx do
    seed_pair(ctx.agent_id)
    stored = StrictSeam.records()
    StrictSeam.configure(:search_error, :unsupported)
    pid = start_index(ctx.agent_id, :dual, rehydrate: false)
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(ctx.agent_id)

    assert :ok = Memory.warm_index_cache(ctx.agent_id, limit: 10)
    assert {:ok, %{entry_count: 3}} = Memory.index_stats(ctx.agent_id)
    assert {:error, :not_found} = Index.get(pid, "mem_category_conversation")

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.recall(ctx.agent_id, "query", embedding: vector(), limit: 10)

    assert StrictSeam.records() == stored
  end

  test "security regression: conflicting legacy metadata aliases stay excluded after warm normalization",
       ctx do
    {_record, hidden} = seed(ctx.agent_id, "mem_legacy_alias", %{"type" => "fact"}, "fact")

    {_record, reverse} =
      seed(ctx.agent_id, "mem_reverse_alias", %{"type" => "conversation"}, "fact")

    {_record, control} = seed(ctx.agent_id, "mem_control", %{"type" => "fact"}, "fact")

    # A trusted seam's legacy view can retain mixed-key metadata. Restrictive
    # evidence must survive the cache's existing key normalization. The stored
    # strict record itself remains unchanged; this is a view-boundary fixture.
    hidden = put_in(hidden, [:body, "metadata", :type], :conversation)
    reverse = put_in(reverse, [:body, "metadata", :type], :fact)
    StrictSeam.configure(:list_override, [hidden, reverse, control])
    StrictSeam.configure(:search_error, :unsupported)
    stored = StrictSeam.records()
    pid = start_index(ctx.agent_id, :dual, rehydrate: false)

    assert :ok = Memory.warm_index_cache(ctx.agent_id, limit: 10)
    assert {:ok, %{entry_count: 3}} = Memory.index_stats(ctx.agent_id)
    assert {:error, :not_found} = Index.get(pid, "mem_legacy_alias")
    assert {:error, :not_found} = Index.get(pid, "mem_reverse_alias")

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.recall(ctx.agent_id, "query", embedding: vector(), limit: 10)

    assert StrictSeam.records() == stored

    assert :ok = stop_supervised({Index, ctx.agent_id})
    cold_pid = start_index(ctx.agent_id, :dual)
    assert {:error, :not_found} = Index.get(cold_pid, "mem_legacy_alias")
    assert {:error, :not_found} = Index.get(cold_pid, "mem_reverse_alias")

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.recall(ctx.agent_id, "query", embedding: vector(), limit: 10)

    assert StrictSeam.records() == stored
  end

  test "security regression: cold restart retains exclusion and stored records", ctx do
    seed_pair(ctx.agent_id)
    stored = StrictSeam.records()
    StrictSeam.configure(:search_error, :unsupported)
    start_index(ctx.agent_id, :dual)
    assert :ok = stop_supervised({Index, ctx.agent_id})
    pid = start_index(ctx.agent_id, :dual)

    assert {:ok, %{entry_count: 3}} = Memory.index_stats(ctx.agent_id)
    assert {:error, :not_found} = Index.get(pid, "mem_category_conversation")

    assert {:ok, [%{id: "mem_control"}]} =
             Memory.recall(ctx.agent_id, "query", embedding: vector(), limit: 10)

    assert StrictSeam.records() == stored
  end

  for reader <- [:index, :embeddings, :formatted] do
    @reader reader
    test "#{@reader} validates excluded conversations and later malformed rows before replying",
         ctx do
      {_record, hidden} =
        seed(ctx.agent_id, "mem_hidden", %{"type" => "conversation"}, "conversation")

      {_record, control} = seed(ctx.agent_id, "mem_control", %{"type" => "fact"}, "fact")
      start_index(ctx.agent_id, :pgvector, rehydrate: false)

      for views <- [
            [Map.put(hidden, :provenance_status, :invalid_durable_provenance), control],
            [hidden, Map.put(control, :provenance_status, :invalid_durable_provenance)],
            [hidden, Map.put(hidden, :provenance_status, :invalid_durable_provenance)],
            [Map.put(hidden, :provenance_status, :invalid_durable_provenance), hidden]
          ] do
        matches = Enum.map(views, &%{match: &1, similarity: 1.0})
        StrictSeam.configure(:search_override, matches)
        assert {:error, :invalid_durable_provenance} = read(@reader, ctx.agent_id)
      end
    end
  end

  test "dual recall does not replace a malformed conversation result with cached controls", ctx do
    {_record, hidden} =
      seed(ctx.agent_id, "mem_hidden", %{"type" => "conversation"}, "conversation")

    seed(ctx.agent_id, "mem_control", %{"type" => "fact"}, "fact")
    start_index(ctx.agent_id, :dual)

    StrictSeam.configure(:search_override, [
      %{match: hidden, similarity: 1.0},
      %{match: Map.put(hidden, :provenance_status, :invalid_durable_provenance), similarity: 1.0}
    ])

    assert {:error, :invalid_durable_provenance} = read(:index, ctx.agent_id)
    assert {:ok, %{entry_count: 2}} = Memory.index_stats(ctx.agent_id)
  end

  test "malformed conversation warm data remains an error and never installs a partial cache",
       ctx do
    {_record, hidden} =
      seed(ctx.agent_id, "mem_hidden", %{"type" => "conversation"}, "conversation")

    {_record, control} = seed(ctx.agent_id, "mem_control", %{"type" => "fact"}, "fact")
    start_index(ctx.agent_id, :dual, rehydrate: false)

    StrictSeam.configure(:list_override, [
      control,
      Map.put(hidden, :provenance_status, :invalid_durable_provenance)
    ])

    assert {:error, :unverified_strict_provenance} =
             Memory.warm_index_cache(ctx.agent_id, limit: 10)

    assert {:ok, %{entry_count: 0}} = Memory.index_stats(ctx.agent_id)
    assert map_size(StrictSeam.records()) == 2
  end

  defp read(:index, agent_id),
    do: Memory.recall(agent_id, "query", embedding: vector(), limit: 10)

  defp read(:embeddings, agent_id), do: Memory.search_embeddings(agent_id, vector(), limit: 10)

  defp read(:formatted, agent_id),
    do: Memory.let_me_recall(agent_id, "query", backend: :persistent, embedding: vector())

  defp start_index(agent_id, backend, opts \\ []) do
    defaults = [agent_id: agent_id, backend: backend, strict_vector_seam: StrictSeam]
    start_supervised!({Index, Keyword.merge(defaults, opts)}, id: {Index, agent_id})
  end

  defp seed_pair(agent_id) do
    seed(agent_id, "mem_metadata_conversation", forged_metadata(), "fact", 1.0)

    seed(
      agent_id,
      "mem_category_conversation",
      %{"type" => "fact", "visibility" => "public"},
      "conversation",
      0.9
    )

    seed(agent_id, "mem_control", %{"type" => "fact"}, "fact", 0.8)
  end

  defp seed(agent_id, entry_id, metadata, category, similarity \\ 1.0) do
    content = if entry_id == "mem_control", do: "VISIBLE_CONTROL", else: "HIDDEN_TRANSCRIPT"

    input =
      StrictEmbeddingInput.index_insert(%{
        agent_id: agent_id,
        entry_id: entry_id,
        content: content,
        vector: vector(),
        metadata: metadata,
        model_evidence: :absent,
        taint: TaintEnvelope.missing_fallback()
      })
      |> Map.put(:category, category)

    {:ok, operation, view} = Embedding.encode_strict_operation(input)
    assert view.provenance_status == :verified
    StrictSeam.put(operation.record, similarity)
    {operation.record, view}
  end

  defp conversation_metadata do
    [
      %{type: :conversation},
      %{type: "conversation"},
      %{"type" => :conversation},
      %{"type" => "conversation"},
      forged_metadata()
    ]
  end

  defp forged_metadata do
    %{
      type: :conversation,
      owner_id: "claimed_owner",
      engagement_id: "claimed_engagement",
      visibility: :public,
      provenance_status: :verified,
      trusted: true
    }
  end

  defp vector do
    List.duplicate(0.0, VectorRecord.dimensions()) |> List.replace_at(0, 1.0)
  end

  defp less_similar_vector do
    vector() |> List.replace_at(0, 0.8) |> List.replace_at(1, 0.6)
  end
end
