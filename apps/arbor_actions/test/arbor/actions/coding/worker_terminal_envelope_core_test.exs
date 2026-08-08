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
             WorkerTerminalEnvelopeCore.parse(~s({"status":"implemented","extra":true}))
  end

  test "rejects non-binary input as text_required" do
    assert {:error, "text_required", evidence} = WorkerTerminalEnvelopeCore.parse(nil)
    assert evidence["valid"] == false
    assert evidence["protocol_error"] == "text_required"
  end

  test "invalid UTF-8 returns exact invalid_json bounded evidence without raising" do
    # Lone continuation byte — invalid UTF-8.
    text = <<0x80, 0x81, 0x82>>

    assert {:error, "invalid_json", evidence} = WorkerTerminalEnvelopeCore.parse(text)
    assert evidence["valid"] == false
    assert evidence["protocol_error"] == "invalid_json"
    assert evidence["status"] == nil
    assert evidence["summary"] == nil
    assert evidence["text_byte_size"] == byte_size(text)
    assert is_binary(evidence["text_sha256"])
    assert String.starts_with?(evidence["text_sha256"], "sha256:")
    refute Map.has_key?(evidence, "text")
  end

  test "oversized input returns oversized evidence without raising" do
    oversize = WorkerTerminalEnvelopeCore.max_text_bytes() + 1
    text = :binary.copy("a", oversize)

    assert {:error, "oversized", evidence} = WorkerTerminalEnvelopeCore.parse(text)
    assert evidence["valid"] == false
    assert evidence["protocol_error"] == "oversized"
    assert evidence["text_byte_size"] == oversize
    assert is_binary(evidence["text_sha256"])
    # Evidence must never echo the full raw payload.
    refute Map.has_key?(evidence, "text")
  end

  test "oversized invalid UTF-8 is classified oversized before decode" do
    oversize = WorkerTerminalEnvelopeCore.max_text_bytes() + 8
    text = :binary.copy(<<0x80>>, oversize)

    assert {:error, "oversized", evidence} = WorkerTerminalEnvelopeCore.parse(text)
    assert evidence["valid"] == false
    assert evidence["text_byte_size"] == oversize
  end
end
