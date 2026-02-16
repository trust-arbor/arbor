defmodule Arbor.Contracts.Judge.RubricTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Judge.Rubric

  @valid_attrs %{
    domain: "advisory",
    dimensions: [
      %{name: :depth, weight: 0.5, description: "Analytical depth"},
      %{name: :clarity, weight: 0.5, description: "Clarity of expression"}
    ]
  }

  describe "new/1" do
    test "creates rubric with valid attributes" do
      assert {:ok, %Rubric{domain: "advisory", version: 1}} = Rubric.new(@valid_attrs)
    end

    test "accepts custom version" do
      attrs = Map.put(@valid_attrs, :version, 2)
      assert {:ok, %Rubric{version: 2}} = Rubric.new(attrs)
    end

    test "rejects missing domain" do
      attrs = Map.delete(@valid_attrs, :domain)
      assert {:error, {:missing_required_field, :domain}} = Rubric.new(attrs)
    end

    test "rejects empty domain" do
      attrs = Map.put(@valid_attrs, :domain, "")
      assert {:error, {:invalid_field, :domain, _}} = Rubric.new(attrs)
    end

    test "rejects missing dimensions" do
      attrs = Map.delete(@valid_attrs, :dimensions)
      assert {:error, {:missing_required_field, :dimensions}} = Rubric.new(attrs)
    end

    test "rejects empty dimensions list" do
      attrs = Map.put(@valid_attrs, :dimensions, [])
      assert {:error, {:invalid_field, :dimensions, _}} = Rubric.new(attrs)
    end

    test "rejects weights that don't sum to 1.0" do
      attrs = %{
        domain: "test",
        dimensions: [
          %{name: :a, weight: 0.3, description: "A"},
          %{name: :b, weight: 0.3, description: "B"}
        ]
      }

      assert {:error, {:invalid_weights, _}} = Rubric.new(attrs)
    end
  end

  describe "validate_weights/1" do
    test "passes for weights summing to 1.0" do
      dims = [%{weight: 0.6}, %{weight: 0.4}]
      assert :ok = Rubric.validate_weights(dims)
    end

    test "allows small floating point tolerance" do
      dims = [%{weight: 0.333}, %{weight: 0.333}, %{weight: 0.334}]
      assert :ok = Rubric.validate_weights(dims)
    end

    test "fails for weights summing to 0.5" do
      dims = [%{weight: 0.25}, %{weight: 0.25}]
      assert {:error, {:invalid_weights, _}} = Rubric.validate_weights(dims)
    end
  end

  describe "snapshot/1" do
    test "produces JSON-serializable map" do
      {:ok, rubric} = Rubric.new(@valid_attrs)
      snapshot = Rubric.snapshot(rubric)

      assert snapshot["domain"] == "advisory"
      assert snapshot["version"] == 1
      assert length(snapshot["dimensions"]) == 2
      assert is_binary(Jason.encode!(snapshot))
    end
  end
end
