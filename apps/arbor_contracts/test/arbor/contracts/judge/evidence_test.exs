defmodule Arbor.Contracts.Judge.EvidenceTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Judge.Evidence

  @valid_attrs %{
    type: :format_compliance,
    score: 0.85,
    passed: true,
    detail: "All sections present"
  }

  describe "new/1" do
    test "creates evidence with valid attributes" do
      assert {:ok, %Evidence{} = e} = Evidence.new(@valid_attrs)
      assert e.type == :format_compliance
      assert e.score == 0.85
      assert e.passed == true
      assert e.detail == "All sections present"
    end

    test "defaults for optional fields" do
      {:ok, e} = Evidence.new(%{type: :check, score: 0.5, passed: true})
      assert e.detail == ""
      assert e.producer == nil
      assert e.duration_ms == 0
    end

    test "accepts producer and duration_ms" do
      {:ok, e} =
        Evidence.new(
          Map.merge(@valid_attrs, %{producer: SomeModule, duration_ms: 42})
        )

      assert e.producer == SomeModule
      assert e.duration_ms == 42
    end

    test "rejects missing type" do
      attrs = Map.delete(@valid_attrs, :type)
      assert {:error, {:missing_required_field, :type}} = Evidence.new(attrs)
    end

    test "rejects non-atom type" do
      attrs = %{@valid_attrs | type: "string"}
      assert {:error, {:invalid_field, :type, _}} = Evidence.new(attrs)
    end

    test "rejects missing score" do
      attrs = Map.delete(@valid_attrs, :score)
      assert {:error, {:missing_required_field, :score}} = Evidence.new(attrs)
    end

    test "rejects score out of range" do
      assert {:error, {:invalid_field, :score, _}} =
               Evidence.new(%{@valid_attrs | score: 1.5})

      assert {:error, {:invalid_field, :score, _}} =
               Evidence.new(%{@valid_attrs | score: -0.1})
    end

    test "rejects non-number score" do
      assert {:error, {:invalid_field, :score, _}} =
               Evidence.new(%{@valid_attrs | score: "high"})
    end

    test "rejects missing passed" do
      attrs = Map.delete(@valid_attrs, :passed)
      assert {:error, {:missing_required_field, :passed}} = Evidence.new(attrs)
    end

    test "rejects non-boolean passed" do
      assert {:error, {:invalid_field, :passed, _}} =
               Evidence.new(%{@valid_attrs | passed: "yes"})
    end

    test "accepts boundary scores 0.0 and 1.0" do
      assert {:ok, _} = Evidence.new(%{@valid_attrs | score: 0.0})
      assert {:ok, _} = Evidence.new(%{@valid_attrs | score: 1.0})
    end
  end
end
