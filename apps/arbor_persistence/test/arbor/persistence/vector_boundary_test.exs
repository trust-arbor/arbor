defmodule Arbor.Persistence.VectorBoundaryTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorOperation, VectorReceipt, VectorRecord}

  defmodule SpyBackend do
    @behaviour Arbor.Persistence.VectorStore

    @impl true
    def execute(operation, opts), do: invoke(:execute, [operation, opts])

    @impl true
    def reconcile(operation, opts), do: invoke(:reconcile, [operation, opts])

    @impl true
    def fetch(identity, opts), do: invoke(:fetch, [identity, opts])

    @impl true
    def list(agent_id, opts), do: invoke(:list, [agent_id, opts])

    @impl true
    def search(agent_id, vector, opts), do: invoke(:search, [agent_id, vector, opts])

    @impl true
    def destroy(agent_id, opts), do: invoke(:destroy, [agent_id, opts])

    defp invoke(callback, args) do
      send(self(), {:vector_backend_called, callback, args})

      case Process.get({__MODULE__, :response}, {:error, :unsupported}) do
        {:raise, message} -> raise message
        {:exit, reason} -> exit(reason)
        {:throw, reason} -> throw(reason)
        response -> response
      end
    end
  end

  setup do
    original = Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)
    Application.put_env(:arbor_persistence, :vector_store_backend, SpyBackend)

    on_exit(fn ->
      case original do
        :not_configured -> Application.delete_env(:arbor_persistence, :vector_store_backend)
        backend -> Application.put_env(:arbor_persistence, :vector_store_backend, backend)
      end
    end)

    :ok
  end

  test "invalid requests never dispatch" do
    operation = operation!(:insert, record!())
    batch = batch!([operation])
    forged_batch = %{batch | operations: [operation | :improper]}

    assert {:error, :invalid_request} =
             Arbor.Persistence.execute_vector_operation("agent_alpha", %{kind: :insert})

    assert {:error, :tenant_mismatch} =
             Arbor.Persistence.execute_vector_operation("agent_beta", operation)

    assert {:error, :invalid_request} =
             Arbor.Persistence.execute_vector_operation("agent_alpha", forged_batch)

    assert {:error, :invalid_request} =
             Arbor.Persistence.execute_vector_operation("agent_alpha", operation,
               caller_metadata: %{taint: :trusted}
             )

    assert {:error, :invalid_request} =
             Arbor.Persistence.fetch_vector_record(
               "agent_alpha",
               "goals",
               "goal_1",
               include_tombstone: false,
               include_tombstone: true
             )

    assert {:error, :invalid_request} =
             Arbor.Persistence.list_vector_records("agent_alpha", [{:limit, 1} | :improper])

    assert {:error, :invalid_request} =
             Arbor.Persistence.search_vector_records("agent_alpha", [0.0], search_opts())

    assert {:error, :invalid_request} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               List.duplicate(0.0, VectorRecord.dimensions()),
               search_opts()
             )

    refute_receive {:vector_backend_called, _callback, _args}
  end

  test "destroy rejects invalid agent_id and improper opts without dispatch" do
    assert {:error, :invalid_request} = Arbor.Persistence.destroy_vector_agent("")
    assert {:error, :invalid_request} = Arbor.Persistence.destroy_vector_agent("   ")
    assert {:error, :invalid_request} = Arbor.Persistence.destroy_vector_agent(nil)

    assert {:error, :invalid_request} =
             Arbor.Persistence.destroy_vector_agent(String.duplicate("a", 257))

    assert {:error, :invalid_request} =
             Arbor.Persistence.destroy_vector_agent("agent_alpha", bad: true)

    assert {:error, :invalid_request} =
             Arbor.Persistence.destroy_vector_agent("agent_alpha", [{:noop, true} | :improper])

    assert {:error, :invalid_request} =
             Arbor.Persistence.destroy_vector_agent("agent_alpha", %{not: :keyword})

    refute_receive {:vector_backend_called, _callback, _args}
  end

  test "destroy normalizes injected backend outcomes and admitted errors" do
    respond(:ok)
    assert :ok = Arbor.Persistence.destroy_vector_agent("agent_alpha")
    assert_receive {:vector_backend_called, :destroy, ["agent_alpha", []]}

    respond({:error, :indeterminate})
    assert {:error, :indeterminate} = Arbor.Persistence.destroy_vector_agent("agent_alpha")

    respond({:error, :unsupported})
    assert {:error, :unsupported} = Arbor.Persistence.destroy_vector_agent("agent_alpha")

    respond({:error, :backend_failure})
    assert {:error, :backend_failure} = Arbor.Persistence.destroy_vector_agent("agent_alpha")

    respond({:error, {:database, "sqlstate leaked"}})
    assert {:error, :backend_failure} = Arbor.Persistence.destroy_vector_agent("agent_alpha")

    respond({:ok, :closed})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.destroy_vector_agent("agent_alpha")

    respond(:closed)

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.destroy_vector_agent("agent_alpha")

    respond("ok")

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.destroy_vector_agent("agent_alpha")

    respond({:raise, "destroy adapter blew up"})
    assert {:error, :backend_failure} = Arbor.Persistence.destroy_vector_agent("agent_alpha")
  end

  test "canonical mutation dispatches the exact operation and verifies its receipt" do
    operation = operation!(:insert, record!())
    result = rebuild_record!(operation.record, generation: 1, revision: 1)
    receipt = receipt!(operation, result)
    respond({:ok, receipt})

    assert {:ok, ^receipt} =
             Arbor.Persistence.execute_vector_operation("agent_alpha", operation)

    assert_receive {:vector_backend_called, :execute, [^operation, []]}
  end

  test "canonical bounded batch dispatches unchanged and verifies every child receipt" do
    first = operation!(:insert, record!(source_key: "one"))
    second = operation!(:insert, record!(source_key: "two"))
    batch = batch!([first, second])

    first_receipt = receipt!(first, rebuild_record!(first.record, generation: 1, revision: 1))
    second_receipt = receipt!(second, rebuild_record!(second.record, generation: 1, revision: 1))

    {:ok, batch_receipt} =
      VectorReceipt.new(%{operation: batch, receipts: [first_receipt, second_receipt]})

    respond({:ok, batch_receipt})

    assert {:ok, ^batch_receipt} =
             Arbor.Persistence.execute_vector_operation("agent_alpha", batch)

    assert_receive {:vector_backend_called, :execute, [^batch, []]}
  end

  test "reconciliation requires the original operation, not a plausible fingerprint" do
    operation = operation!(:insert, record!())
    unrelated = record!(source_key: "unrelated", generation: 1, revision: 1)

    forged = %VectorReceipt{
      operation_fingerprint: operation.fingerprint,
      kind: :insert,
      record: unrelated,
      receipts: []
    }

    assert {:ok, ^forged} = VectorReceipt.validate(forged)
    respond({:ok, forged})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.reconcile_vector_operation("agent_alpha", operation)

    assert_receive {:vector_backend_called, :reconcile, [^operation, []]}

    respond({:ok, :absent})
    assert {:ok, :absent} = Arbor.Persistence.reconcile_vector_operation("agent_alpha", operation)
  end

  test "backend exceptions, exits, throws, and rich errors map to bounded failures" do
    operation = operation!(:insert, record!(payload: %{"secret" => "never echo this"}))

    for response <- [
          {:raise, "payload leaked from adapter"},
          {:exit, {:payload, operation.record.payload}},
          {:throw, operation.record.vector},
          {:error, {:database, operation.record.payload}}
        ] do
      respond(response)
      result = Arbor.Persistence.execute_vector_operation("agent_alpha", operation)

      assert result == {:error, :backend_failure}
      refute inspect(result) =~ "never echo this"
      refute inspect(result) =~ "0.25"
      assert_receive {:vector_backend_called, :execute, [^operation, []]}
    end
  end

  test "fetch validates identity and tombstone policy after dispatch" do
    record = record!(generation: 1, revision: 1)
    respond({:ok, record})

    assert {:ok, ^record} =
             Arbor.Persistence.fetch_vector_record("agent_alpha", "goals", "goal_1")

    assert_receive {:vector_backend_called, :fetch,
                    [{"agent_alpha", "goals", "goal_1"}, [include_tombstone: false]]}

    respond({:ok, record!(source_key: "other", generation: 1, revision: 1)})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.fetch_vector_record("agent_alpha", "goals", "goal_1")

    tombstone = rebuild_record!(record, revision: 2, tombstone: true)
    respond({:ok, tombstone})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.fetch_vector_record("agent_alpha", "goals", "goal_1")

    respond({:ok, tombstone})

    assert {:ok, ^tombstone} =
             Arbor.Persistence.fetch_vector_record("agent_alpha", "goals", "goal_1",
               include_tombstone: true
             )
  end

  test "list validates every row, tenant, filters, uniqueness, and bound" do
    first = record!(source_key: "one", generation: 1, revision: 1)
    second = record!(source_key: "two", generation: 1, revision: 1)
    respond({:ok, [first, second]})

    assert {:ok, [^first, ^second]} =
             Arbor.Persistence.list_vector_records("agent_alpha",
               category: "goal",
               source_namespace: "goals",
               limit: 2
             )

    assert_receive {:vector_backend_called, :list,
                    [
                      "agent_alpha",
                      [
                        category: "goal",
                        source_namespace: "goals",
                        include_tombstones: false,
                        limit: 2
                      ]
                    ]}

    respond({:ok, [first, record!(agent_id: "agent_beta", source_key: "foreign")]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.list_vector_records("agent_alpha")

    respond({:ok, [first, first]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.list_vector_records("agent_alpha")

    respond({:ok, [first, second]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.list_vector_records("agent_alpha", limit: 1)
  end

  test "search normalizes its query and validates every exact-descriptor match" do
    record = record!(generation: 1, revision: 1)
    {:ok, match} = VectorMatch.new(%{record: record, similarity: 0.9})
    respond({:ok, [match]})

    query = [0.1 | List.duplicate(0.25, 767)]
    {:ok, normalized_query} = VectorRecord.normalize_vector(query)

    assert {:ok, [^match]} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts(encoding: "ieee754_float32_be_v1", limit: 1)
             )

    assert_receive {:vector_backend_called, :search,
                    [
                      "agent_alpha",
                      ^normalized_query,
                      [
                        model_id: "provider/model-v1",
                        dimensions: 768,
                        encoding: :ieee754_float32_be_v1,
                        category: "goal",
                        source_namespace: nil,
                        threshold: nil,
                        limit: 1
                      ]
                    ]}

    wrong_descriptor = record!(model_id: "provider/model-v2", generation: 1, revision: 1)
    {:ok, wrong_match} = VectorMatch.new(%{record: wrong_descriptor, similarity: 0.8})
    respond({:ok, [match, wrong_match]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.search_vector_records("agent_alpha", query, search_opts())
  end

  test "search admits optional scopes, closed grammar, limit ceiling, and canonical thresholds" do
    goal = record!(source_key: "goal_1", category: "goal", generation: 1, revision: 1)
    note = record!(source_key: "note_1", category: "note", generation: 1, revision: 1)
    {:ok, goal_match} = VectorMatch.new(%{record: goal, similarity: 0.95})
    {:ok, note_match} = VectorMatch.new(%{record: note, similarity: 0.9})
    respond({:ok, [goal_match, note_match]})

    query = vector()

    assert {:ok, [^goal_match, ^note_match]} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts()
               |> Keyword.delete(:category)
               |> Keyword.put(:source_namespace, "goals")
               |> Keyword.put(:limit, 1000)
             )

    assert_receive {:vector_backend_called, :search,
                    [
                      "agent_alpha",
                      _vector,
                      [
                        model_id: "provider/model-v1",
                        dimensions: 768,
                        encoding: :ieee754_float32_be_v1,
                        category: nil,
                        source_namespace: "goals",
                        threshold: nil,
                        limit: 1000
                      ]
                    ]}

    assert {:error, :invalid_request} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts(limit: 1001)
             )

    refute_receive {:vector_backend_called, :search, _args}

    assert {:error, :invalid_request} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts() ++ [unknown: true]
             )

    refute_receive {:vector_backend_called, :search, _args}

    for raw_threshold <- [-1, 0, 1, -1.0, 0.0, 1.0, 0.5] do
      respond({:ok, []})
      {:ok, expected} = VectorMatch.normalize_similarity(raw_threshold)

      assert {:ok, []} =
               Arbor.Persistence.search_vector_records(
                 "agent_alpha",
                 query,
                 search_opts(threshold: raw_threshold)
               )

      assert_receive {:vector_backend_called, :search,
                      [
                        "agent_alpha",
                        _vector,
                        [
                          model_id: "provider/model-v1",
                          dimensions: 768,
                          encoding: :ieee754_float32_be_v1,
                          category: "goal",
                          source_namespace: nil,
                          threshold: ^expected,
                          limit: 20
                        ]
                      ]}

      assert is_float(expected)
    end

    for bad_threshold <- [1.5, -1.5, :atom, "0.5", %{v: 0.5}] do
      assert {:error, :invalid_request} =
               Arbor.Persistence.search_vector_records(
                 "agent_alpha",
                 query,
                 search_opts(threshold: bad_threshold)
               )

      refute_receive {:vector_backend_called, :search, _args}
    end

    respond({:ok, []})

    assert {:ok, []} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts() |> Keyword.delete(:category) |> Keyword.delete(:limit)
             )

    assert_receive {:vector_backend_called, :search,
                    [
                      "agent_alpha",
                      _vector,
                      [
                        model_id: "provider/model-v1",
                        dimensions: 768,
                        encoding: :ieee754_float32_be_v1,
                        category: nil,
                        source_namespace: nil,
                        threshold: nil,
                        limit: 20
                      ]
                    ]}
  end

  test "search rejects forged namespace, category, and below-threshold backend members" do
    query = vector()
    valid = record!(source_key: "valid", generation: 1, revision: 1)

    forged_ns =
      record!(source_key: "forged_ns", source_namespace: "other", generation: 1, revision: 1)

    forged_cat = record!(source_key: "forged_cat", category: "other", generation: 1, revision: 1)

    low = record!(source_key: "low", generation: 1, revision: 1)
    {:ok, valid_match} = VectorMatch.new(%{record: valid, similarity: 0.95})
    {:ok, ns_match} = VectorMatch.new(%{record: forged_ns, similarity: 0.94})
    {:ok, cat_match} = VectorMatch.new(%{record: forged_cat, similarity: 0.93})
    {:ok, low_match} = VectorMatch.new(%{record: low, similarity: 0.1})

    respond({:ok, [valid_match, ns_match]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts(source_namespace: "goals")
             )

    respond({:ok, [valid_match, cat_match]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts(category: "goal")
             )

    respond({:ok, [valid_match, low_match]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               query,
               search_opts(threshold: 0.5)
             )
  end

  test "exact-descriptor verbose callback requires total non-nil category presence" do
    query = vector()
    respond({:ok, []})

    assert {:ok, []} =
             Arbor.Persistence.search_vector_records_by_exact_descriptor_for_agent(
               "agent_alpha",
               query,
               search_opts()
             )

    assert_receive {:vector_backend_called, :search,
                    [
                      "agent_alpha",
                      _vector,
                      [
                        model_id: "provider/model-v1",
                        dimensions: 768,
                        encoding: :ieee754_float32_be_v1,
                        category: "goal",
                        source_namespace: nil,
                        threshold: nil,
                        limit: 20
                      ]
                    ]}

    for opts <- [
          %{
            model_id: "provider/model-v1",
            dimensions: 768,
            encoding: :ieee754_float32_be_v1,
            category: "goal"
          },
          [{:model_id, "provider/model-v1"} | :improper],
          [
            model_id: "provider/model-v1",
            dimensions: VectorRecord.dimensions(),
            encoding: VectorRecord.encoding()
          ],
          search_opts(category: nil),
          search_opts() ++ [category: "goal"],
          search_opts() ++ [unknown: "x"],
          List.duplicate({:noise, 0}, 100) ++ search_opts()
        ] do
      assert {:error, :invalid_request} =
               Arbor.Persistence.search_vector_records_by_exact_descriptor_for_agent(
                 "agent_alpha",
                 query,
                 opts
               )

      refute_receive {:vector_backend_called, :search, _args}
    end

    respond({:ok, []})

    assert {:ok, []} =
             Arbor.Persistence.search_vector_records_by_exact_model_descriptor_and_scope_for_agent(
               "agent_alpha",
               query,
               search_opts() |> Keyword.delete(:category)
             )

    assert_receive {:vector_backend_called, :search,
                    [
                      "agent_alpha",
                      _vector,
                      [
                        model_id: "provider/model-v1",
                        dimensions: 768,
                        encoding: :ieee754_float32_be_v1,
                        category: nil,
                        source_namespace: nil,
                        threshold: nil,
                        limit: 20
                      ]
                    ]}
  end

  test "activation regression: default vector backend stays fail-closed until operator config" do
    operation = operation!(:insert, record!())
    Application.delete_env(:arbor_persistence, :vector_store_backend)

    assert {:ok, Arbor.Persistence.VectorStore.Unsupported} =
             Arbor.Persistence.Config.vector_store_backend()

    assert {:error, :unsupported} =
             Arbor.Persistence.execute_vector_operation("agent_alpha", operation)

    refute_receive {:vector_backend_called, _callback, _args}

    Application.put_env(:arbor_persistence, :vector_store_backend, %{})

    assert {:error, :backend_failure} =
             Arbor.Persistence.execute_vector_operation("agent_alpha", operation)

    refute_receive {:vector_backend_called, _callback, _args}
  end

  defp respond(response), do: Process.put({SpyBackend, :response}, response)

  defp vector, do: List.duplicate(0.25, VectorRecord.dimensions())

  defp record!(overrides \\ []) do
    overrides = Map.new(overrides)
    payload = Map.get(overrides, :payload, %{"content" => "remember this"})
    vector = Map.get(overrides, :vector, vector())
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    attrs = %{
      id: "vec_row_1",
      agent_id: "agent_alpha",
      source_namespace: "goals",
      source_key: "goal_1",
      payload: payload,
      vector: vector,
      payload_digest: payload_digest,
      vector_digest: vector_digest,
      model_id: "provider/model-v1",
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding(),
      category: "goal",
      generation: 0,
      revision: 0,
      tombstone: false
    }

    {:ok, record} = VectorRecord.new(Map.merge(attrs, overrides))
    record
  end

  defp rebuild_record!(record, overrides) do
    overrides = Map.new(overrides)
    attrs = Map.merge(Map.from_struct(record), overrides)
    {:ok, payload_digest} = VectorRecord.payload_digest(attrs.payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(attrs.vector)

    attrs =
      attrs
      |> Map.put(:payload_digest, payload_digest)
      |> Map.put(:vector_digest, vector_digest)

    {:ok, rebuilt} = VectorRecord.new(attrs)
    rebuilt
  end

  defp operation!(kind, record) do
    attrs =
      if kind == :insert do
        %{kind: kind, record: record, expected_generation: nil, expected_revision: nil}
      else
        %{
          kind: kind,
          record: record,
          expected_generation: record.generation,
          expected_revision: record.revision
        }
      end

    {:ok, operation} = VectorOperation.new(attrs)
    operation
  end

  defp batch!(operations) do
    {:ok, batch} = VectorOperation.new(%{kind: :batch, operations: operations})
    batch
  end

  defp receipt!(operation, record) do
    {:ok, receipt} = VectorReceipt.new(%{operation: operation, record: record})
    receipt
  end

  defp search_opts(overrides \\ []) do
    Keyword.merge(
      [
        model_id: "provider/model-v1",
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        category: "goal"
      ],
      overrides
    )
  end
end
