defmodule Arbor.Contracts.Persistence.FilterTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Filter

  describe "new/0" do
    test "creates empty filter" do
      f = Filter.new()
      assert %Filter{} = f
      assert f.conditions == []
      assert f.since == nil
      assert f.until == nil
      assert f.order_by == nil
      assert f.limit == nil
      assert f.offset == 0
    end
  end

  describe "where/4" do
    test "adds equality condition" do
      f = Filter.new() |> Filter.where(:type, :eq, "agent_started")
      assert [{:type, :eq, "agent_started"}] = f.conditions
    end

    test "chains multiple conditions" do
      f =
        Filter.new()
        |> Filter.where(:type, :eq, "event")
        |> Filter.where(:level, :gte, 3)

      assert length(f.conditions) == 2
    end

    test "supports all operators" do
      for op <- [:eq, :neq, :gt, :gte, :lt, :lte, :in, :contains] do
        f = Filter.new() |> Filter.where(:field, op, "val")
        assert [{:field, ^op, "val"}] = f.conditions
      end
    end
  end

  describe "since/2 and until/2" do
    test "sets since timestamp" do
      dt = ~U[2024-01-01 00:00:00Z]
      f = Filter.new() |> Filter.since(dt)
      assert f.since == dt
    end

    test "sets until timestamp" do
      dt = ~U[2024-12-31 23:59:59Z]
      f = Filter.new() |> Filter.until(dt)
      assert f.until == dt
    end
  end

  describe "order_by/3" do
    test "sets ascending order" do
      f = Filter.new() |> Filter.order_by(:inserted_at, :asc)
      assert f.order_by == {:inserted_at, :asc}
    end

    test "sets descending order" do
      f = Filter.new() |> Filter.order_by(:inserted_at, :desc)
      assert f.order_by == {:inserted_at, :desc}
    end
  end

  describe "limit/2 and offset/2" do
    test "sets limit" do
      f = Filter.new() |> Filter.limit(10)
      assert f.limit == 10
    end

    test "sets offset" do
      f = Filter.new() |> Filter.offset(20)
      assert f.offset == 20
    end
  end

  describe "matches?/2" do
    test "matches record with eq condition" do
      f = Filter.new() |> Filter.where(:type, :eq, "event")
      assert Filter.matches?(f, %{type: "event"})
      refute Filter.matches?(f, %{type: "other"})
    end

    test "matches record with neq condition" do
      f = Filter.new() |> Filter.where(:status, :neq, :deleted)
      assert Filter.matches?(f, %{status: :active})
      refute Filter.matches?(f, %{status: :deleted})
    end

    test "matches record with gt/gte/lt/lte conditions" do
      f = Filter.new() |> Filter.where(:level, :gte, 3)
      assert Filter.matches?(f, %{level: 3})
      assert Filter.matches?(f, %{level: 5})
      refute Filter.matches?(f, %{level: 2})
    end

    test "matches record with :in condition" do
      f = Filter.new() |> Filter.where(:status, :in, [:active, :pending])
      assert Filter.matches?(f, %{status: :active})
      refute Filter.matches?(f, %{status: :deleted})
    end

    test "matches record with :contains for string" do
      f = Filter.new() |> Filter.where(:name, :contains, "foo")
      assert Filter.matches?(f, %{name: "foobar"})
      refute Filter.matches?(f, %{name: "bazqux"})
    end

    test "matches with since filter" do
      f = Filter.new() |> Filter.since(~U[2024-06-01 00:00:00Z])
      assert Filter.matches?(f, %{inserted_at: ~U[2024-07-01 00:00:00Z]})
      refute Filter.matches?(f, %{inserted_at: ~U[2024-05-01 00:00:00Z]})
    end

    test "matches with until filter" do
      f = Filter.new() |> Filter.until(~U[2024-06-01 00:00:00Z])
      assert Filter.matches?(f, %{inserted_at: ~U[2024-05-01 00:00:00Z]})
      refute Filter.matches?(f, %{inserted_at: ~U[2024-07-01 00:00:00Z]})
    end

    test "empty filter matches everything" do
      f = Filter.new()
      assert Filter.matches?(f, %{anything: "value"})
    end

    test "matches string keys in plain maps" do
      f = Filter.new() |> Filter.where(:type, :eq, "event")
      # Plain maps can match on string keys via fallback
      record = %{"type" => "event"}
      assert Filter.matches?(f, record)
    end
  end

  describe "apply/2" do
    @records [
      %{id: 1, type: "a", level: 3, inserted_at: ~U[2024-01-01 00:00:00Z]},
      %{id: 2, type: "b", level: 1, inserted_at: ~U[2024-06-01 00:00:00Z]},
      %{id: 3, type: "a", level: 5, inserted_at: ~U[2024-12-01 00:00:00Z]}
    ]

    test "filters by condition" do
      f = Filter.new() |> Filter.where(:type, :eq, "a")
      result = Filter.apply(f, @records)
      assert length(result) == 2
    end

    test "orders results" do
      f = Filter.new() |> Filter.order_by(:level, :desc)
      result = Filter.apply(f, @records)
      assert [%{level: 5}, %{level: 3}, %{level: 1}] = result
    end

    test "limits results" do
      f = Filter.new() |> Filter.limit(2)
      result = Filter.apply(f, @records)
      assert length(result) == 2
    end

    test "offsets results" do
      f = Filter.new() |> Filter.offset(1)
      result = Filter.apply(f, @records)
      assert length(result) == 2
    end

    test "combines filter, order, offset, limit" do
      f =
        Filter.new()
        |> Filter.order_by(:level, :asc)
        |> Filter.offset(1)
        |> Filter.limit(1)

      result = Filter.apply(f, @records)
      assert [%{level: 3}] = result
    end
  end
end
