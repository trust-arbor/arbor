defmodule Arbor.Memory.HybridSelectionCoreTest do
  use ExUnit.Case, async: true
  alias Arbor.Memory.HybridSelectionCore, as: Core
  @moduletag :fast

  test "input bound counts complete JSON escaping, schema and system text" do
    candidate = %{id: "node", payload: %{"content" => ""}}
    assert {:ok, empty} = Core.input("query", [candidate])
    schema_bytes = byte_size(Jason.encode!(Core.response_format([candidate])))
    room = 32_768 - byte_size(empty) - byte_size(Core.system_prompt()) - schema_bytes
    exact = put_in(candidate, [:payload, "content"], String.duplicate("a", room))
    assert {:ok, encoded} = Core.input("query", [exact])
    assert byte_size(encoded) + byte_size(Core.system_prompt()) + schema_bytes == 32_768
    oversized = put_in(candidate, [:payload, "content"], String.duplicate("a", room + 1))

    assert {:error, {:hybrid_selection_limit_exceeded, :input_bytes, 32_768}} =
             Core.input("query", [oversized])

    escaped = put_in(candidate, [:payload, "content"], String.duplicate("\"", div(room, 2) + 1))

    assert {:error, {:hybrid_selection_limit_exceeded, :input_bytes, 32_768}} =
             Core.input("query", [escaped])
  end
end
