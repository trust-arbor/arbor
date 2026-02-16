defmodule Arbor.Actions.Judge.RubricsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Judge.Rubrics
  alias Arbor.Contracts.Judge.Rubric

  describe "advisory/0" do
    test "returns a valid rubric" do
      rubric = Rubrics.advisory()
      assert %Rubric{domain: "advisory"} = rubric
      assert length(rubric.dimensions) == 6
      assert :ok = Rubric.validate_weights(rubric.dimensions)
    end

    test "has expected dimensions" do
      rubric = Rubrics.advisory()
      names = Enum.map(rubric.dimensions, & &1[:name])
      assert :depth in names
      assert :perspective_relevance in names
      assert :actionability in names
      assert :accuracy in names
      assert :originality in names
      assert :calibration in names
    end
  end

  describe "code/0" do
    test "returns a valid rubric" do
      rubric = Rubrics.code()
      assert %Rubric{domain: "code"} = rubric
      assert length(rubric.dimensions) == 6
      assert :ok = Rubric.validate_weights(rubric.dimensions)
    end
  end

  describe "for_domain/1" do
    test "returns advisory rubric" do
      assert {:ok, %Rubric{domain: "advisory"}} = Rubrics.for_domain("advisory")
    end

    test "returns code rubric" do
      assert {:ok, %Rubric{domain: "code"}} = Rubrics.for_domain("code")
    end

    test "returns error for unknown domain" do
      assert {:error, :unknown_domain} = Rubrics.for_domain("unknown")
    end
  end

  describe "available_domains/0" do
    test "lists known domains" do
      assert "advisory" in Rubrics.available_domains()
      assert "code" in Rubrics.available_domains()
    end
  end
end
