defmodule Arbor.LLM.ResponseBudgetTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.{ResponseBudget, ToolResultBudget}

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

  test "source-only decoding leaves incomplete embedded JSON for protocol-aware consumers" do
    body = Jason.encode!(%{"name" => "lookup", "arguments" => ""})

    assert {:ok, %{"name" => "lookup", "arguments" => ""}, measurements} =
             ResponseBudget.decode_json_source_with_measurements(body, @limits)

    assert measurements.nodes > 0
    assert {:error, {:invalid_json, _}} = ResponseBudget.decode_json(body, @limits)
  end

  test "streaming tool-call chunks are valid envelope JSON even with incomplete arguments" do
    limits = envelope_limits()

    for body <- streaming_tool_call_envelopes() do
      assert {:ok, _decoded} = JSON.decode(body)
      assert {:ok, _decoded} = Jason.decode(body)
      assert {:ok, _measurements} = ResponseBudget.preflight_json(body, limits)

      assert {:ok, decoded, _measurements} =
               ResponseBudget.decode_json_source_with_measurements(body, limits)

      assert {:ok, ^decoded} = JSON.decode(body)
      assert {:error, {:invalid_json, _}} = ResponseBudget.decode_json(body, limits)
    end
  end

  test "envelope preflight, source decode, and stdlib JSON agree on generated payloads" do
    :rand.seed(:exsss, {2026, 8, 25})
    limits = envelope_limits()

    for body <-
          streaming_tool_call_envelopes() ++
            generated_json_documents(80) ++ malformed_json_documents() do
      stdlib = JSON.decode(body)
      jason = Jason.decode(body)
      preflight = ResponseBudget.preflight_json(body, limits)
      source = ResponseBudget.decode_json_source_with_measurements(body, limits)

      stdlib_ok? = match?({:ok, _}, stdlib)
      jason_ok? = match?({:ok, _}, jason)
      preflight_ok? = match?({:ok, _}, preflight)
      source_ok? = match?({:ok, _, _}, source)

      assert jason_ok? == stdlib_ok?,
             "Jason/JSON disagreement for #{inspect(body)}"

      assert preflight_ok? == stdlib_ok?,
             "preflight disagreed with JSON.decode for #{inspect(body)}: #{inspect(preflight)}"

      assert source_ok? == preflight_ok?,
             "source decode disagreed with preflight for #{inspect(body)}: #{inspect(source)}"

      if source_ok? do
        {:ok, decoded, _measurements} = source
        {:ok, stdlib_decoded} = stdlib
        assert decoded == stdlib_decoded
      end
    end
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

  test "security regression: public budgets are total and caller limits cannot widen ceilings" do
    assert {:error, {:invalid_budget, :keyword_required}} =
             ResponseBudget.validate(%{}, [{:max_bytes, 10} | :improper])

    assert {:error, {:invalid_json, :binary_body_required}} =
             ResponseBudget.decode_json(%{}, max_bytes: 10)

    assert {:error, {:decoded_term_limit_exceeded, boundary, 100_000}} =
             ResponseBudget.validate(List.duplicate(0, 100_001),
               max_bytes: 1_000_000_000,
               max_nodes: 1_000_000_000,
               max_depth: 1_000_000,
               max_map_keys: 1_000_000,
               max_list_items: 1_000_000_000
             )

    assert boundary in [:nodes, :list_items]
  end

  test "security regression: tool result aggregate charges exact serialized bytes" do
    escape_heavy = String.duplicate(<<0>>, 1_400_000)

    assert {:ok, _encoded, aggregate} =
             ToolResultBudget.encode(escape_heavy, ToolResultBudget.new())

    assert {:error, {:invalid_tool_result, {:tool_result_aggregate_exceeded, :bytes, 16_777_216}}} =
             ToolResultBudget.encode(escape_heavy, aggregate)

    assert {:error, {:invalid_tool_result, :invalid_tool_result_budget}} =
             ToolResultBudget.account("value", %{bytes: :not_a_number})
  end

  defp envelope_limits do
    [
      max_bytes: 1_048_576,
      max_nodes: 100_000,
      max_depth: 32,
      max_map_keys: 10_000,
      max_list_items: 100_000,
      max_string_bytes: 1_048_576,
      max_number_bytes: 128
    ]
  end

  # Live OpenAI-style tool-call deltas: envelope JSON whose `arguments` string
  # is not yet complete JSON. Copied from the 2026-08-25 keyless streaming
  # failure (empty args and the first `{"` fragment).
  defp streaming_tool_call_envelopes do
    [
      ~s({"function":{"name":"memory_recall","arguments":"{\\""}}),
      ~s({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","type":"function","function":{"name":"m","arguments":"{\\""}}]}}]}),
      ~s({"id":"abc","object":"chat.completion.chunk","created":1787635097,"model":"x-preview-f-free","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_b0bcac3972eb44eb92165a9d","type":"function","function":{"name":"memory_recall","arguments":"{\\""}}]}}]}),
      Jason.encode!(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_empty",
                  "type" => "function",
                  "function" => %{"name" => "memory_recall", "arguments" => ""}
                }
              ]
            }
          }
        ]
      })
    ]
  end

  defp generated_json_documents(count) do
    Enum.map(1..count, fn _ -> Jason.encode!(generated_json_term(3)) end)
  end

  defp generated_json_term(0) do
    Enum.random([
      nil,
      true,
      false,
      0,
      1,
      -7,
      1.5,
      "",
      "a",
      "quote \" here",
      "back\\slash",
      "{\"",
      "café",
      "memory_recall"
    ])
  end

  defp generated_json_term(depth) do
    case :rand.uniform(6) do
      1 ->
        generated_json_term(0)

      2 ->
        Enum.map(1..:rand.uniform(4), fn _ -> generated_json_term(depth - 1) end)

      3 ->
        %{
          "name" => "memory_recall",
          "arguments" => Enum.random(["", "{\"", "{}", "{\"q\":1}"])
        }

      4 ->
        %{"function" => generated_json_term(depth - 1)}

      5 ->
        Map.new(1..:rand.uniform(3), fn i -> {"k#{i}", generated_json_term(depth - 1)} end)

      6 ->
        %{"choices" => [generated_json_term(depth - 1)]}
    end
  end

  defp malformed_json_documents do
    ["", "{", "[", "{]", "{\"a\":", "nul", "\"unterminated", "<<not-json>>"]
  end
end
