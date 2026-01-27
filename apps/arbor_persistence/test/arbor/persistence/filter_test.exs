defmodule Arbor.Persistence.FilterTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Filter

  describe "builder functions" do
    test "creates empty filter" do
      filter = Filter.new()
      assert filter.conditions == []
      assert filter.since == nil
      assert filter.until == nil
      assert filter.order_by == nil
      assert filter.limit == nil
      assert filter.offset == 0
    end

    test "chains conditions" do
      filter =
        Filter.new()
        |> Filter.where(:type, :eq, "test")
        |> Filter.where(:count, :gt, 5)

      assert length(filter.conditions) == 2
    end

    test "sets time range" do
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600)

      filter =
        Filter.new()
        |> Filter.since(now)
        |> Filter.until(later)

      assert filter.since == now
      assert filter.until == later
    end

    test "sets ordering" do
      filter = Filter.new() |> Filter.order_by(:inserted_at, :desc)
      assert filter.order_by == {:inserted_at, :desc}
    end

    test "sets limit and offset" do
      filter = Filter.new() |> Filter.limit(10) |> Filter.offset(5)
      assert filter.limit == 10
      assert filter.offset == 5
    end
  end

  describe "matches?/2" do
    test "empty filter matches everything" do
      assert Filter.matches?(Filter.new(), %{anything: true})
    end

    test "eq condition" do
      filter = Filter.new() |> Filter.where(:type, :eq, "test")
      assert Filter.matches?(filter, %{type: "test"})
      refute Filter.matches?(filter, %{type: "other"})
    end

    test "neq condition" do
      filter = Filter.new() |> Filter.where(:type, :neq, "skip")
      assert Filter.matches?(filter, %{type: "keep"})
      refute Filter.matches?(filter, %{type: "skip"})
    end

    test "gt/gte/lt/lte conditions" do
      assert Filter.matches?(
               Filter.new() |> Filter.where(:count, :gt, 5),
               %{count: 10}
             )

      refute Filter.matches?(
               Filter.new() |> Filter.where(:count, :gt, 5),
               %{count: 5}
             )

      assert Filter.matches?(
               Filter.new() |> Filter.where(:count, :gte, 5),
               %{count: 5}
             )

      assert Filter.matches?(
               Filter.new() |> Filter.where(:count, :lt, 10),
               %{count: 5}
             )

      assert Filter.matches?(
               Filter.new() |> Filter.where(:count, :lte, 5),
               %{count: 5}
             )
    end

    test "in condition" do
      filter = Filter.new() |> Filter.where(:status, :in, ["active", "pending"])
      assert Filter.matches?(filter, %{status: "active"})
      refute Filter.matches?(filter, %{status: "archived"})
    end

    test "contains condition for strings" do
      filter = Filter.new() |> Filter.where(:name, :contains, "alice")
      assert Filter.matches?(filter, %{name: "alice-in-wonderland"})
      refute Filter.matches?(filter, %{name: "bob"})
    end

    test "contains condition for lists" do
      filter = Filter.new() |> Filter.where(:tags, :contains, "elixir")
      assert Filter.matches?(filter, %{tags: ["elixir", "otp"]})
      refute Filter.matches?(filter, %{tags: ["python"]})
    end

    test "since time range" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600)

      filter = Filter.new() |> Filter.since(now)
      refute Filter.matches?(filter, %{inserted_at: past})
      assert Filter.matches?(filter, %{inserted_at: now})
    end

    test "until time range" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 3600)

      filter = Filter.new() |> Filter.until(now)
      assert Filter.matches?(filter, %{inserted_at: now})
      refute Filter.matches?(filter, %{inserted_at: future})
    end

    test "multiple conditions are ANDed" do
      filter =
        Filter.new()
        |> Filter.where(:type, :eq, "test")
        |> Filter.where(:count, :gt, 0)

      assert Filter.matches?(filter, %{type: "test", count: 5})
      refute Filter.matches?(filter, %{type: "test", count: 0})
      refute Filter.matches?(filter, %{type: "other", count: 5})
    end

    test "looks up fields in data map for structs" do
      record = %{__struct__: :fake, data: %{nested_field: "found"}}
      filter = Filter.new() |> Filter.where(:nested_field, :eq, "found")
      assert Filter.matches?(filter, record)
    end
  end

  describe "apply/2" do
    setup do
      records = [
        %{id: "1", type: "a", count: 10, inserted_at: ~U[2024-01-01 00:00:00Z]},
        %{id: "2", type: "b", count: 5, inserted_at: ~U[2024-01-02 00:00:00Z]},
        %{id: "3", type: "a", count: 20, inserted_at: ~U[2024-01-03 00:00:00Z]},
        %{id: "4", type: "b", count: 15, inserted_at: ~U[2024-01-04 00:00:00Z]}
      ]

      {:ok, records: records}
    end

    test "filters by condition", %{records: records} do
      filter = Filter.new() |> Filter.where(:type, :eq, "a")
      result = Filter.apply(filter, records)
      assert length(result) == 2
      assert Enum.all?(result, &(&1.type == "a"))
    end

    test "orders results", %{records: records} do
      filter = Filter.new() |> Filter.order_by(:count, :desc)
      result = Filter.apply(filter, records)
      counts = Enum.map(result, & &1.count)
      assert counts == [20, 15, 10, 5]
    end

    test "applies offset and limit", %{records: records} do
      filter = Filter.new() |> Filter.order_by(:count, :asc) |> Filter.offset(1) |> Filter.limit(2)
      result = Filter.apply(filter, records)
      assert length(result) == 2
      counts = Enum.map(result, & &1.count)
      assert counts == [10, 15]
    end

    test "combines filter + order + limit", %{records: records} do
      filter =
        Filter.new()
        |> Filter.where(:count, :gt, 5)
        |> Filter.order_by(:count, :asc)
        |> Filter.limit(2)

      result = Filter.apply(filter, records)
      counts = Enum.map(result, & &1.count)
      assert counts == [10, 15]
    end
  end
end
