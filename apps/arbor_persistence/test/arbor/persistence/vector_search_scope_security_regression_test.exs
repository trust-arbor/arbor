defmodule Arbor.Persistence.VectorSearchScopeSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorRecord}

  defmodule RegressionBackend do
    def search(agent_id, vector, opts) do
      send(self(), {:regression_backend_called, agent_id, vector, opts})

      case Process.get({__MODULE__, :response}, {:ok, []}) do
        response -> response
      end
    end
  end

  setup do
    original = Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)
    Application.put_env(:arbor_persistence, :vector_store_backend, RegressionBackend)

    on_exit(fn ->
      case original do
        :not_configured -> Application.delete_env(:arbor_persistence, :vector_store_backend)
        backend -> Application.put_env(:arbor_persistence, :vector_store_backend, backend)
      end
    end)

    :ok
  end

  test "security regression: category-omitted namespace search admits mixed categories and rejects forged scopes" do
    goal = record!(source_key: "goal_1", category: "goal")
    note = record!(source_key: "note_1", category: "note")
    forged_ns = record!(source_key: "foreign", source_namespace: "other", category: "goal")
    forged_cat = record!(source_key: "wrong_cat", category: "other")

    {:ok, goal_match} = VectorMatch.new(%{record: goal, similarity: 0.95})
    {:ok, note_match} = VectorMatch.new(%{record: note, similarity: 0.9})
    {:ok, forged_ns_match} = VectorMatch.new(%{record: forged_ns, similarity: 0.99})
    {:ok, forged_cat_match} = VectorMatch.new(%{record: forged_cat, similarity: 0.98})
    low =
      record!(source_key: "low", category: "goal", source_namespace: "goals")

    {:ok, below_threshold} = VectorMatch.new(%{record: low, similarity: 0.1})

    respond({:ok, [goal_match, note_match]})

    assert {:ok, [^goal_match, ^note_match]} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               vector(),
               model_id: "provider/model-v1",
               dimensions: VectorRecord.dimensions(),
               encoding: VectorRecord.encoding(),
               source_namespace: "goals",
               threshold: 0.5,
               limit: 10
             )

    assert_receive {:regression_backend_called, "agent_alpha", _vector,
                    [
                      model_id: "provider/model-v1",
                      dimensions: 768,
                      encoding: :ieee754_float32_be_v1,
                      category: nil,
                      source_namespace: "goals",
                      threshold: 0.5,
                      limit: 10
                    ]}

    respond({:ok, [goal_match, forged_ns_match]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               vector(),
               model_id: "provider/model-v1",
               dimensions: VectorRecord.dimensions(),
               encoding: VectorRecord.encoding(),
               source_namespace: "goals"
             )

    respond({:ok, [goal_match, forged_cat_match]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               vector(),
               model_id: "provider/model-v1",
               dimensions: VectorRecord.dimensions(),
               encoding: VectorRecord.encoding(),
               category: "goal"
             )

    respond({:ok, [goal_match, below_threshold]})

    assert {:error, :invalid_backend_result} =
             Arbor.Persistence.search_vector_records(
               "agent_alpha",
               vector(),
               model_id: "provider/model-v1",
               dimensions: VectorRecord.dimensions(),
               encoding: VectorRecord.encoding(),
               threshold: 0.5
             )
  end

  defp respond(response), do: Process.put({RegressionBackend, :response}, response)

  defp vector, do: List.duplicate(0.25, VectorRecord.dimensions())

  defp record!(overrides) do
    overrides = Map.new(overrides)
    payload = Map.get(overrides, :payload, %{"content" => "remember this"})
    vector = Map.get(overrides, :vector, vector())
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    attrs = %{
      id: "vec_row_#{Map.get(overrides, :source_key, "default")}",
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
      generation: 1,
      revision: 1,
      tombstone: false
    }

    {:ok, record} = VectorRecord.new(Map.merge(attrs, overrides))
    record
  end
end
