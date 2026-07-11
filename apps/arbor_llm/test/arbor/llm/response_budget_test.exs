defmodule Arbor.LLM.ResponseBudgetTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.ResponseBudget

  @limits [
    max_bytes: 1_024,
    max_nodes: 100,
    max_depth: 8,
    max_map_keys: 20,
    max_list_items: 20
  ]

  test "security regression: signed-64 minimum and finite diagnostic floats pass" do
    assert :ok = ResponseBudget.validate(-9_223_372_036_854_775_808, @limits)
    assert :ok = ResponseBudget.validate(1.7976931348623157e308, @limits)
  end

  test "security regression: deep and over-count decoded terms fail before traversal consumers" do
    deep = Enum.reduce(1..10, "leaf", fn _, acc -> [acc] end)
    many = Enum.to_list(1..21)

    assert {:error, {:decoded_term_limit_exceeded, :depth, 8}} =
             ResponseBudget.validate(deep, @limits)

    assert {:error, {:decoded_term_limit_exceeded, :list_items, 20}} =
             ResponseBudget.validate(many, @limits)
  end
end
