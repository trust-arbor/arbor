defmodule Arbor.Actions.Coding.WorkerTerminalEnvelopeCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.WorkerTerminalEnvelopeCore

  @moduletag :fast

  test "accepts exact whole-message implemented envelope" do
    text = ~s({"status":"implemented","summary":"done"})
    assert {:ok, fields} = WorkerTerminalEnvelopeCore.parse(text)
    assert fields["valid"] == true
    assert fields["status"] == "implemented"
    assert fields["summary"] == "done"
    assert fields["protocol_error"] == nil
  end

  test "accepts declined without summary" do
    assert {:ok, fields} = WorkerTerminalEnvelopeCore.parse(~s({"status":"declined"}))
    assert fields["valid"] == true
    assert fields["status"] == "declined"
    assert fields["summary"] == nil
  end

  test "rejects prose wrapper as not_whole_message or invalid_json" do
    text = ~s(Here you go: {"status":"implemented","summary":"x"})
    assert {:error, code, evidence} = WorkerTerminalEnvelopeCore.parse(text)
    assert code in ["invalid_json", "not_whole_message", "not_object"]
    assert evidence["valid"] == false
  end

  test "rejects dual objects as not whole message or invalid json" do
    text = ~s({"status":"implemented"}{"status":"declined"})
    assert {:error, code, evidence} = WorkerTerminalEnvelopeCore.parse(text)
    assert code in ["not_whole_message", "invalid_json"]
    assert evidence["valid"] == false
  end

  test "rejects unknown status and unknown fields" do
    assert {:error, "unknown_status", _} =
             WorkerTerminalEnvelopeCore.parse(~s({"status":"maybe"}))

    assert {:error, "unknown_fields", _} =
             WorkerTerminalEnvelopeCore.parse(
               ~s({"status":"implemented","extra":true})
             )
  end

  test "rejects non-binary input as text_required" do
    assert {:error, "text_required", evidence} = WorkerTerminalEnvelopeCore.parse(nil)
    assert evidence["valid"] == false
    assert evidence["protocol_error"] == "text_required"
  end
end
