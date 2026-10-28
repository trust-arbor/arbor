defmodule Arbor.Persistence.LegacyEmbeddingDestroyTest do
  @moduledoc """
  DB-agnostic unit evidence for VP-05D2C3I0C3 destroy_legacy_embeddings.
  """

  use ExUnit.Case, async: true

  alias Arbor.Persistence
  alias Arbor.Persistence.LegacyEmbeddingStore

  @moduletag :fast
  @moduletag voice_packet: "VP-05D2C3I0C3"

  defmodule FakeRepo do
    @moduledoc false

    def configure(opts) when is_list(opts) do
      Process.put({__MODULE__, :opts}, Map.new(opts))
      :ok
    end

    def clear, do: Process.delete({__MODULE__, :opts})

    def calls, do: Process.get({__MODULE__, :calls}, [])

    def transaction(fun) when is_function(fun, 0) do
      record_call({:transaction, :start})

      try do
        result = fun.()
        record_call({:transaction, :commit})
        {:ok, result}
      catch
        :throw, {:rollback, reason} ->
          record_call({:transaction, {:rollback, reason}})
          {:error, reason}
      end
    end

    def rollback(reason) do
      record_call({:rollback, reason})
      throw({:rollback, reason})
    end

    def delete_all(query) do
      record_call({:delete_all, query})

      case get(:delete_reply, {1, nil}) do
        {:raise, exception} -> raise exception
        {:throw, value} -> throw(value)
        reply -> reply
      end
    end

    def one(query) do
      record_call({:one, query})

      case get(:count_reply, 0) do
        {:raise, exception} -> raise exception
        {:throw, value} -> throw(value)
        reply -> reply
      end
    end

    defp get(key, default) do
      Map.get(Process.get({__MODULE__, :opts}, %{}), key, default)
    end

    defp record_call(call) do
      Process.put({__MODULE__, :calls}, [call | Process.get({__MODULE__, :calls}, [])])
    end
  end

  setup do
    FakeRepo.clear()
    Process.delete({FakeRepo, :calls})
    on_exit(fn -> FakeRepo.clear() end)
    :ok
  end

  test "rejects invalid agent ids with closed :invalid_request" do
    assert {:error, :invalid_request} = Persistence.destroy_legacy_embeddings("")
    assert {:error, :invalid_request} = Persistence.destroy_legacy_embeddings(123)
    assert {:error, :invalid_request} = Persistence.destroy_legacy_embeddings("   ")
    assert {:error, :invalid_request} = Persistence.legacy_embeddings_absent?("")
  end

  test "rejects malformed options" do
    assert {:error, :invalid_options} =
             Persistence.destroy_legacy_embeddings("agent_ok", repo: "not-atom")

    assert {:error, :invalid_options} =
             Persistence.destroy_legacy_embeddings("agent_ok", unknown: true)

    assert {:error, :invalid_options} =
             Persistence.legacy_embeddings_absent?("agent_ok", repo: 1)
  end

  test "destroy deletes then confirms zero with the same injected repository" do
    FakeRepo.configure(delete_reply: {2, nil}, count_reply: 0)

    assert :ok =
             Persistence.destroy_legacy_embeddings("agent_target", repo: FakeRepo)

    calls = Enum.reverse(FakeRepo.calls())
    assert Enum.any?(calls, &match?({:delete_all, _}, &1))
    assert Enum.any?(calls, &match?({:one, _}, &1))
    assert Enum.any?(calls, &match?({:transaction, :commit}, &1))
  end

  test "destroy is idempotent when count is already zero" do
    FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)

    assert :ok = Persistence.destroy_legacy_embeddings("agent_empty", repo: FakeRepo)
    assert {:ok, true} = Persistence.legacy_embeddings_absent?("agent_empty", repo: FakeRepo)
  end

  test "destroy fails closed when confirming count is non-zero" do
    FakeRepo.configure(delete_reply: {1, nil}, count_reply: 1)

    assert {:error, :indeterminate} =
             Persistence.destroy_legacy_embeddings("agent_leak", repo: FakeRepo)

    calls = Enum.reverse(FakeRepo.calls())
    assert Enum.any?(calls, &match?({:transaction, {:rollback, :indeterminate}}, &1))
  end

  test "destroy fails closed on malformed delete reply" do
    FakeRepo.configure(delete_reply: :not_a_count, count_reply: 0)

    assert {:error, :backend_failure} =
             Persistence.destroy_legacy_embeddings("agent_bad_delete", repo: FakeRepo)
  end

  test "destroy fails closed on malformed count reply" do
    FakeRepo.configure(delete_reply: {1, nil}, count_reply: :nope)

    assert {:error, :backend_failure} =
             Persistence.destroy_legacy_embeddings("agent_bad_count", repo: FakeRepo)
  end

  test "security regression: nil count cannot prove legacy absence" do
    FakeRepo.configure(delete_reply: {1, nil}, count_reply: nil)

    assert {:error, :backend_failure} =
             Persistence.destroy_legacy_embeddings("agent_nil_count", repo: FakeRepo)

    assert {:error, :backend_failure} =
             Persistence.legacy_embeddings_absent?("agent_nil_count", repo: FakeRepo)
  end

  test "destroy fails closed when repository raises" do
    FakeRepo.configure(delete_reply: {:raise, RuntimeError.exception("boom")}, count_reply: 0)

    assert {:error, :backend_failure} =
             Persistence.destroy_legacy_embeddings("agent_raise", repo: FakeRepo)
  end

  test "absent? returns false when legacy rows remain" do
    FakeRepo.configure(count_reply: 3)
    assert {:ok, false} = Persistence.legacy_embeddings_absent?("agent_rows", repo: FakeRepo)
  end

  test "absent? fails closed on count exception" do
    FakeRepo.configure(count_reply: {:raise, RuntimeError.exception("count boom")})

    assert {:error, :backend_failure} =
             Persistence.legacy_embeddings_absent?("agent_raise", repo: FakeRepo)
  end

  test "post-delete override forces indeterminate without inventing success" do
    FakeRepo.configure(delete_reply: {1, nil}, count_reply: 0)
    assert :ok = LegacyEmbeddingStore.__set_post_delete_remaining_override__(2)

    try do
      assert {:error, :indeterminate} =
               Persistence.destroy_legacy_embeddings("agent_override", repo: FakeRepo)
    after
      LegacyEmbeddingStore.__clear_post_delete_remaining_override__()
    end
  end

  test "delete and count queries bind legacy predicate and exact agent equality" do
    FakeRepo.configure(delete_reply: {0, nil}, count_reply: 0)
    agent_id = "agent_query_bind_#{System.unique_integer([:positive])}"

    assert :ok = Persistence.destroy_legacy_embeddings(agent_id, repo: FakeRepo)

    calls = Enum.reverse(FakeRepo.calls())
    delete_queries = for {:delete_all, query} <- calls, do: query
    count_queries = for {:one, query} <- calls, do: query

    assert length(delete_queries) == 1
    assert length(count_queries) == 1

    for query <- delete_queries ++ count_queries do
      assert_query_binds_legacy_and_agent(query, agent_id)
    end
  end

  defp assert_query_binds_legacy_and_agent(%Ecto.Query{} = query, agent_id) do
    wheres = query.wheres
    assert is_list(wheres)
    assert length(wheres) >= 1

    params =
      wheres
      |> Enum.flat_map(fn
        %{params: params} when is_list(params) -> Enum.map(params, &elem(&1, 0))
        _ -> []
      end)

    assert agent_id in params

    encoded = inspect(query)
    assert encoded =~ "agent_id"
    assert encoded =~ "vector_protocol" or encoded =~ "source_namespace" or encoded =~ "is_nil"
  end
end
