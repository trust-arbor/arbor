defmodule Arbor.Orchestrator.UnifiedLLM.ContentPartTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Message}

  test "message text accessor concatenates text parts" do
    msg =
      Message.new(:user, [
        ContentPart.text("hello "),
        ContentPart.text("world")
      ])

    assert Message.text(msg) == "hello world"
  end

  test "normalizes local image path into inline data part" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_cp_#{System.unique_integer([:positive])}.png"
      )

    assert :ok = File.write(tmp, <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4>>)

    [part] = ContentPart.normalize([ContentPart.image_file(tmp)])
    assert part.kind == :image
    assert is_binary(part.data)
    assert part.media_type == "image/png"
  end

  test "normalizes local audio/document files into data parts" do
    wav =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_cp_#{System.unique_integer([:positive])}.wav"
      )

    pdf =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_cp_#{System.unique_integer([:positive])}.pdf"
      )

    assert :ok = File.write(wav, <<82, 73, 70, 70, 1, 2, 3, 4>>)
    assert :ok = File.write(pdf, <<37, 80, 68, 70, 45, 49, 46, 52>>)

    [audio_part] = ContentPart.normalize([ContentPart.audio_file(wav)])
    [doc_part] = ContentPart.normalize([ContentPart.document_file(pdf)])

    assert audio_part.kind == :audio
    assert is_binary(audio_part.data)
    assert audio_part.media_type == "audio/wav"

    assert doc_part.kind == :document
    assert is_binary(doc_part.data)
    assert doc_part.media_type == "application/pdf"
    assert doc_part.file_name == Path.basename(pdf)
  end

  test "normalizes tool and thinking parts" do
    parts =
      ContentPart.normalize([
        ContentPart.tool_call("call_1", "search", %{"q" => "x"}),
        ContentPart.tool_result("call_1", %{"ok" => true}, is_error: false),
        ContentPart.redacted_thinking("chain-of-thought", signature: "sig")
      ])

    assert Enum.at(parts, 0).kind == :tool_call
    assert Enum.at(parts, 0).name == "search"
    assert Enum.at(parts, 1).kind == :tool_result
    assert Enum.at(parts, 1).tool_call_id == "call_1"
    assert Enum.at(parts, 2).kind == :thinking
    assert Enum.at(parts, 2).signature == "sig"
    assert Enum.at(parts, 2).redacted == true
  end
end
