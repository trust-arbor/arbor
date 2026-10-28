defmodule Arbor.Persistence.LegacyForwardersSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{AppendOperation, Filter, Record, Revision}
  alias Arbor.Persistence.Contracts
  alias Arbor.Persistence.Filter, as: LegacyFilter
  alias Arbor.Persistence.Record, as: LegacyRecord

  @moduletag :fast

  @host_contracts %{
    record: Record,
    revision: Revision,
    filter: Filter,
    append_operation: AppendOperation
  }
  @record_exports [new: 1, new: 2, new: 3, update: 2, update: 3]
  @filter_exports [
    apply: 2,
    limit: 2,
    matches?: 2,
    new: 0,
    offset: 2,
    order_by: 2,
    order_by: 3,
    since: 2,
    until: 2,
    where: 4
  ]
  @timestamp ~U[2026-01-01 00:00:00Z]

  setup do
    previous = Application.fetch_env(:arbor_persistence, :contract_modules)
    Application.put_env(:arbor_persistence, :contract_modules, @host_contracts)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_persistence, :contract_modules, value)
        :error -> Application.delete_env(:arbor_persistence, :contract_modules)
      end
    end)

    :ok
  end

  test "legacy module names retain every original public function and default arity" do
    assert Enum.sort(LegacyRecord.__info__(:functions)) == Enum.sort(@record_exports)
    assert Enum.sort(LegacyFilter.__info__(:functions)) == Enum.sort(@filter_exports)
  end

  test "legacy record constructors and updates preserve exact host identity and fencing data" do
    assert %Record{key: "empty", data: %{}, generation: 0, revision: 0} =
             LegacyRecord.new("empty")

    assert %Record{key: "data", data: %{value: 1}, generation: 0, revision: 0} =
             LegacyRecord.new("data", %{value: 1})

    opts = [
      id: "legacy:logical-id",
      metadata: %{source: :legacy},
      generation: 7,
      revision: 11,
      inserted_at: @timestamp,
      updated_at: @timestamp
    ]

    original = LegacyRecord.new("slot", %{value: 1}, opts)
    assert %Record{} = original
    assert original == Record.new("slot", %{value: 1}, opts)

    for {legacy, canonical, metadata} <- [
          {LegacyRecord.update(original, %{value: 2}), Record.update(original, %{value: 2}),
           original.metadata},
          {LegacyRecord.update(original, %{value: 2}, metadata: %{source: :updated}),
           Record.update(original, %{value: 2}, metadata: %{source: :updated}),
           %{source: :updated}}
        ] do
      assert %Record{} = legacy
      assert Map.delete(legacy, :updated_at) == Map.delete(canonical, :updated_at)

      assert {legacy.id, legacy.key, legacy.generation, legacy.revision} ==
               {original.id, original.key, 7, 11}

      assert legacy.data == %{value: 2}
      assert legacy.metadata == metadata
      assert legacy.inserted_at == @timestamp
      assert %DateTime{} = legacy.updated_at
    end

    assert original.data == %{value: 1}
    assert {original.generation, original.revision} == {7, 11}

    assert_raise FunctionClauseError, fn ->
      LegacyRecord.update(Contracts.Record.new("foreign"), %{value: 2})
    end
  end

  test "legacy filter operations preserve the host Filter and canonical query results" do
    assert %Filter{} = LegacyFilter.new()
    assert LegacyFilter.new() == Filter.new()

    assert LegacyFilter.order_by(LegacyFilter.new(), :key) ==
             Filter.order_by(Filter.new(), :key)

    legacy =
      LegacyFilter.new()
      |> LegacyFilter.where(:kind, :eq, :worker)
      |> LegacyFilter.since(@timestamp)
      |> LegacyFilter.until(DateTime.add(@timestamp, 60, :second))
      |> LegacyFilter.order_by(:key, :asc)
      |> LegacyFilter.offset(1)
      |> LegacyFilter.limit(1)

    canonical =
      Filter.new()
      |> Filter.where(:kind, :eq, :worker)
      |> Filter.since(@timestamp)
      |> Filter.until(DateTime.add(@timestamp, 60, :second))
      |> Filter.order_by(:key, :asc)
      |> Filter.offset(1)
      |> Filter.limit(1)

    assert %Filter{} = legacy
    assert legacy == canonical
    records = Enum.map(["c", "a", "b"], &record/1)
    expected = record("b")
    assert Enum.all?(records, &LegacyFilter.matches?(legacy, &1))
    refute LegacyFilter.matches?(legacy, Record.new("other", %{kind: :other}))
    assert LegacyFilter.apply(legacy, records) == Filter.apply(canonical, records)
    assert LegacyFilter.apply(legacy, records) == [expected]

    assert_raise FunctionClauseError, fn ->
      LegacyFilter.matches?(Contracts.Filter.new(), expected)
    end
  end

  defp record(key) do
    Record.new(key, %{kind: :worker},
      id: "legacy:#{key}",
      generation: 7,
      revision: 11,
      inserted_at: @timestamp,
      updated_at: @timestamp
    )
  end
end
