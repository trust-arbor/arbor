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

  test "security regression: lexical JSON limits run before numeric materialization" do
    huge_integer = String.duplicate("9", 1_000)

    assert {:error, {:decoded_term_limit_exceeded, :number_bytes, 128}} =
             ResponseBudget.decode_json(huge_integer, @limits)

    deep_json = String.duplicate("[", 10) <> "0" <> String.duplicate("]", 10)

    assert {:error, {:decoded_term_limit_exceeded, :depth, 8}} =
             ResponseBudget.decode_json(deep_json, @limits)

    assert {:error, {:decoded_term_limit_exceeded, :list_items, 20}} =
             ResponseBudget.decode_json(
               "[" <> Enum.map_join(1..21, ",", &to_string/1) <> "]",
               @limits
             )
  end

  test "security regression: secondary tool argument JSON is structurally bounded" do
    arguments = String.duplicate("[", 10) <> "0" <> String.duplicate("]", 10)

    body =
      Jason.encode!(%{
        "tool_calls" => [
          %{"function" => %{"name" => "bounded", "arguments" => arguments}}
        ]
      })

    assert {:error, {:decoded_term_limit_exceeded, :depth, 8}} =
             ResponseBudget.decode_json(body, @limits)
  end

  test "security regression: embedded tool arguments share one retained aggregate budget" do
    arguments = Jason.encode!(%{"items" => List.duplicate(0, 4_500)})

    body =
      Jason.encode!(%{
        "tool_calls" =>
          List.duplicate(%{"function" => %{"name" => "bounded", "arguments" => arguments}}, 30)
      })

    limits =
      @limits
      |> Keyword.put(:max_bytes, 16_777_216)
      |> Keyword.put(:max_nodes, 100_000)
      |> Keyword.put(:max_map_keys, 10_000)
      |> Keyword.put(:max_list_items, 100_000)

    assert {:error, {:decoded_term_limit_exceeded, boundary, 100_000}} =
             ResponseBudget.decode_json(body, limits)

    assert boundary in [:nodes, :list_items]
  end

  test "security regression: exact score lexemes cannot round or underflow into range" do
    for token <- ["1.0000000000000000001", "-1e-999", "9", "true", "\"1\""] do
      body = ~s({"score":#{token}})

      case ResponseBudget.decode_json_numbers(body, @limits, ["score"]) do
        {:ok, _decoded, %{"score" => lexeme}} ->
          refute ResponseBudget.exact_unit_number?(lexeme)

        {:error, _reason} ->
          :ok
      end
    end

    for token <- ["0", "1", "0.25", "5e-1", "10e-1"] do
      assert {:ok, _decoded, %{"score" => ^token}} =
               ResponseBudget.decode_json_numbers(~s({"score":#{token}}), @limits, ["score"])

      assert ResponseBudget.exact_unit_number?(token)
    end
  end

  test "security regression: iterative term validation rejects improper lists and non-string keys" do
    assert {:error, {:decoded_term_invalid, :proper_list_required}} =
             ResponseBudget.validate([1 | 2], @limits)

    assert {:error, {:decoded_term_invalid, :string_or_atom_map_keys_required}} =
             ResponseBudget.validate(%{1 => "value"}, @limits)
  end
end
