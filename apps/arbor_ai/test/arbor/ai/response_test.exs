defmodule Arbor.AI.ResponseTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Response

  describe "thinking blocks" do
    test "new/1 includes thinking field" do
      response = Response.new(text: "Hello", thinking: [%{text: "Let me think..."}])
      assert response.thinking == [%{text: "Let me think..."}]
    end

    test "from_map/1 normalizes thinking blocks with type: thinking" do
      response =
        Response.from_map(%{
          text: "Result",
          thinking: [
            %{"type" => "thinking", "thinking" => "First thought", "signature" => "sig1"},
            %{"type" => "thinking", "thinking" => "Second thought"}
          ],
          provider: :anthropic
        })

      assert length(response.thinking) == 2
      [first, second] = response.thinking
      assert first.text == "First thought"
      assert first.signature == "sig1"
      assert second.text == "Second thought"
      assert second.signature == nil
    end

    test "from_map/1 normalizes already-normalized thinking blocks" do
      response =
        Response.from_map(%{
          text: "Result",
          thinking: [
            %{text: "Already normalized", signature: "sig"}
          ],
          provider: :anthropic
        })

      assert length(response.thinking) == 1
      assert hd(response.thinking).text == "Already normalized"
      assert hd(response.thinking).signature == "sig"
    end

    test "from_map/1 returns nil for empty thinking" do
      response = Response.from_map(%{text: "Result", thinking: [], provider: :anthropic})
      assert response.thinking == nil
    end

    test "from_map/1 returns nil for nil thinking" do
      response = Response.from_map(%{text: "Result", provider: :anthropic})
      assert response.thinking == nil
    end

    test "from_map/1 handles single thinking block" do
      response =
        Response.from_map(%{
          text: "Result",
          thinking: %{"type" => "thinking", "thinking" => "Single thought"},
          provider: :anthropic
        })

      assert length(response.thinking) == 1
      assert hd(response.thinking).text == "Single thought"
    end
  end
end
