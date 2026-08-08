defmodule Arbor.Actions.Coding.WorkerTerminalParseTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.WorkerTerminalParse

  @moduletag :fast

  test "registered under public Actions facade" do
    assert {:ok, WorkerTerminalParse} =
             Arbor.Actions.name_to_module("coding_worker_terminal_parse")
  end

  test "returns JSON-clean evidence for invalid input without raising" do
    assert {:ok, fields} = WorkerTerminalParse.run(%{text: "not-json"}, %{})
    assert fields["valid"] == false
    assert fields["protocol_error"] == "invalid_json"
    assert is_integer(fields["text_byte_size"])
  end

  test "returns exact valid envelope fields for whole-message JSON" do
    text = ~s({"status":"implemented","summary":"changed two files"})
    assert {:ok, fields} = WorkerTerminalParse.run(%{"text" => text}, %{})
    assert fields["valid"] == true
    assert fields["status"] == "implemented"
    assert fields["summary"] == "changed two files"
    assert fields["protocol_error"] == nil
  end

  test "missing text params project text_required evidence" do
    assert {:ok, fields} = WorkerTerminalParse.run(%{}, %{})
    assert fields["valid"] == false
    assert fields["protocol_error"] == "text_required"
  end

  test "invalid UTF-8 projects exact invalid_json bounded evidence without raising" do
    text = <<0xFF, 0xFE, "not-json">>
    assert {:ok, fields} = WorkerTerminalParse.run(%{text: text}, %{})
    assert fields["valid"] == false
    assert fields["protocol_error"] == "invalid_json"
    assert fields["status"] == nil
    assert fields["summary"] == nil
    assert fields["text_byte_size"] == byte_size(text)
    assert is_binary(fields["text_sha256"])
    refute Map.has_key?(fields, "text")
  end

  test "oversized text projects oversized evidence without raising" do
    text = :binary.copy("x", Arbor.Actions.Coding.WorkerTerminalEnvelopeCore.max_text_bytes() + 1)
    assert {:ok, fields} = WorkerTerminalParse.run(%{text: text}, %{})
    assert fields["valid"] == false
    assert fields["protocol_error"] == "oversized"
    assert fields["text_byte_size"] == byte_size(text)
    refute Map.has_key?(fields, "text")
  end
end
