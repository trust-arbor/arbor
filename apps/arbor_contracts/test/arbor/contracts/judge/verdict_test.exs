defmodule Arbor.Contracts.Judge.VerdictTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Judge.Verdict

  @valid_attrs %{
    overall_score: 0.75,
    recommendation: :keep,
    mode: :critique,
    dimension_scores: %{depth: 0.8, clarity: 0.7},
    strengths: ["Good analysis"],
    weaknesses: ["Could be more specific"]
  }

  describe "new/1" do
    test "creates verdict with valid attributes" do
      assert {:ok, %Verdict{overall_score: 0.75}} = Verdict.new(@valid_attrs)
    end

    test "defaults for optional fields" do
      attrs = %{overall_score: 0.5, recommendation: :revise, mode: :verification}
      assert {:ok, %Verdict{dimension_scores: %{}, strengths: [], weaknesses: []}} = Verdict.new(attrs)
    end

    test "rejects missing overall_score" do
      attrs = Map.delete(@valid_attrs, :overall_score)
      assert {:error, {:missing_required_field, :overall_score}} = Verdict.new(attrs)
    end

    test "rejects score outside 0-1 range" do
      attrs = Map.put(@valid_attrs, :overall_score, 1.5)
      assert {:error, {:invalid_field, :overall_score, _}} = Verdict.new(attrs)
    end

    test "rejects missing recommendation" do
      attrs = Map.delete(@valid_attrs, :recommendation)
      assert {:error, {:missing_required_field, :recommendation}} = Verdict.new(attrs)
    end

    test "rejects invalid recommendation" do
      attrs = Map.put(@valid_attrs, :recommendation, :invalid)
      assert {:error, {:invalid_field, :recommendation, _}} = Verdict.new(attrs)
    end

    test "rejects missing mode" do
      attrs = Map.delete(@valid_attrs, :mode)
      assert {:error, {:missing_required_field, :mode}} = Verdict.new(attrs)
    end

    test "rejects invalid mode" do
      attrs = Map.put(@valid_attrs, :mode, :invalid)
      assert {:error, {:invalid_field, :mode, _}} = Verdict.new(attrs)
    end
  end

  describe "passed?/1" do
    test "returns true for :keep" do
      {:ok, v} = Verdict.new(%{@valid_attrs | recommendation: :keep})
      assert Verdict.passed?(v)
    end

    test "returns true for :revise" do
      {:ok, v} = Verdict.new(%{@valid_attrs | recommendation: :revise})
      assert Verdict.passed?(v)
    end

    test "returns false for :reject" do
      {:ok, v} = Verdict.new(%{@valid_attrs | recommendation: :reject})
      refute Verdict.passed?(v)
    end
  end
end
