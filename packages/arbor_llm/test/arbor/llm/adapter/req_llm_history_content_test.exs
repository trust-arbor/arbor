defmodule Arbor.LLM.Adapter.ReqLLMHistoryContentTest do
  use ExUnit.Case, async: true

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.ContentPart
  alias Arbor.LLM.Message
  alias ReqLLM.Message.ContentPart, as: NativePart

  @moduletag :fast

  defmodule OpaquePart do
    defstruct type: :text, text: "opaque struct payload"
  end

  test "regression: persisted conversation text survives OpenRouter request encoding" do
    # Session persistence stores these JSON-clean blocks. Restoring their roles
    # does not convert the blocks into ReqLLM structs before the adapter runs.
    [user_content, assistant_content] =
      json_roundtrip([
        [%{type: "text", text: "The test phrase is silver birch remembers rain."}],
        [%{type: "text", text: "I will remember silver birch remembers rain."}]
      ])

    messages = [
      Message.new(:user, user_content),
      Message.new(:assistant, assistant_content),
      Message.new(:user, "What is the test phrase?")
    ]

    assert Enum.map(wire_messages(messages), &Map.take(&1, ["role", "content"])) == [
             %{
               "role" => "user",
               "content" => "The test phrase is silver birch remembers rain."
             },
             %{
               "role" => "assistant",
               "content" => "I will remember silver birch remembers rain."
             },
             %{"role" => "user", "content" => "What is the test phrase?"}
           ]
  end

  test "JSON-roundtripped text blocks encode for every message role" do
    content = json_roundtrip([%{type: "text", text: "persisted text"}])

    messages =
      for role <- [:system, :developer, :user, :assistant, :tool] do
        Message.new(role, content, %{"tool_call_id" => "call_history"})
      end

    encoded = wire_messages(messages)

    assert Enum.map(encoded, & &1["role"]) == ["system", "system", "user", "assistant", "tool"]
    assert Enum.map(encoded, & &1["content"]) == List.duplicate("persisted text", 5)
    assert List.last(encoded)["tool_call_id"] == "call_history"
  end

  test "plain strings and recognized text representations preserve their bytes" do
    text = "  text with spacing\nλ and a trailing newline\n"

    variants = [
      text,
      [text],
      [ContentPart.text(text)],
      [%{kind: "text", text: text}],
      [%{"kind" => "text", "text" => text}],
      [%{type: :text, text: text}],
      [%{type: "text", text: text}],
      [%{"type" => "text", "text" => text}],
      [NativePart.text(text)]
    ]

    for role <- [:system, :developer, :user, :assistant, :tool], content <- variants do
      [encoded] = wire_messages([Message.new(role, content, %{tool_call_id: "call_text"})])
      assert encoded["content"] == text
    end
  end

  test "mixed text representations keep their order across provider encoding" do
    content = [
      %{"type" => "text", "text" => "first"},
      ContentPart.text("second"),
      NativePart.text("third"),
      "fourth"
    ]

    for role <- [:user, :assistant] do
      [encoded] = wire_messages([Message.new(role, content)])

      assert encoded["content"] ==
               Enum.map(["first", "second", "third", "fourth"], fn text ->
                 %{"type" => "text", "text" => text}
               end)
    end
  end

  test "native user multimodal parts retain identity and cache metadata" do
    content = [
      NativePart.text("describe this", %{cache_control: %{type: "ephemeral"}}),
      NativePart.image_url("https://example.test/image.png"),
      NativePart.image(<<1, 2, 3>>, "image/png")
    ]

    message = Message.new(:user, content)
    [translated] = Adapter.translate_messages([message])
    assert translated.content === content

    for role <- [:system, :developer, :tool] do
      [translated] = Adapter.translate_messages([Message.new(role, content)])
      assert translated.content === content
    end

    [encoded] = wire_messages([message])

    assert encoded["content"] == [
             %{
               "type" => "text",
               "text" => "describe this",
               "cache_control" => %{"type" => "ephemeral"}
             },
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.test/image.png"}
             },
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/png;base64,AQID"}
             }
           ]
  end

  test "assistant retains native text metadata without expanding its nontext boundary" do
    text = NativePart.text("visible", %{cache_control: %{type: "ephemeral"}})

    message =
      Message.new(:assistant, [
        text,
        NativePart.image_url("https://example.test/image.png"),
        NativePart.image(<<1, 2, 3>>, "image/png"),
        NativePart.file("private file", "private.txt", "text/plain"),
        NativePart.thinking("private thought"),
        NativePart.text(%{"not" => "binary text"}),
        ContentPart.image_base64("AQID", "image/png"),
        ContentPart.thinking("private Arbor thought")
      ])

    [translated] = Adapter.translate_messages([message])
    assert translated.content === [text]

    [encoded] = wire_messages([message])

    assert encoded["content"] == [
             %{
               "type" => "text",
               "text" => "visible",
               "cache_control" => %{"type" => "ephemeral"}
             }
           ]
  end

  test "Arbor images preserve URLs and already-base64 payloads beside history text" do
    content = [
      %{"type" => "text", "text" => "an image"},
      ContentPart.image_url("https://example.test/image.png"),
      ContentPart.image_base64("AQID", "image/png")
    ]

    [encoded] = wire_messages([Message.new(:user, content)])

    assert encoded["content"] == [
             %{"type" => "text", "text" => "an image"},
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.test/image.png"}
             },
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/png;base64,AQID"}
             }
           ]

    for role <- [:system, :developer, :tool] do
      [translated] = Adapter.translate_messages([Message.new(role, content)])

      assert translated.content === [
               NativePart.text("an image"),
               ContentPart.image_url("https://example.test/image.png"),
               ContentPart.image_base64("AQID", "image/png")
             ]
    end
  end

  test "live tool calls keep their IDs and arguments beside normalized assistant text" do
    messages = [
      Message.new(:assistant, [
        %{"type" => "text", "text" => "checking"},
        ContentPart.tool_call("call_lookup", "lookup", %{"query" => "birch"})
      ]),
      Message.new(:tool, [%{"type" => "text", "text" => "lookup result"}], %{
        "tool_call_id" => "call_lookup"
      })
    ]

    [assistant, tool] = wire_messages(messages)

    assert assistant["content"] == "checking"
    assert [call] = assistant["tool_calls"]
    assert call["id"] == "call_lookup"
    assert call["type"] == "function"
    assert call["function"]["name"] == "lookup"
    assert Jason.decode!(call["function"]["arguments"]) == %{"query" => "birch"}
    assert tool["content"] == "lookup result"
    assert tool["tool_call_id"] == "call_lookup"
  end

  test "tool-only assistant messages remain tool calls without fabricated text" do
    message = Message.new(:assistant, [ContentPart.tool_call("call_only", "lookup", "{}")])
    [encoded] = wire_messages([message])

    # ReqLLM 1.25 collapses an empty content array to "" because strict OpenAI
    # and vLLM reject "content": [].
    assert encoded["content"] == ""

    assert [%{"id" => "call_only", "function" => %{"arguments" => "{}"}}] =
             encoded["tool_calls"]
  end

  test "unknown blocks, malformed text and opaque structs are never promoted to text or tools" do
    opaque = [
      %{"type" => "thinking", "text" => "private thought"},
      NativePart.thinking("private native thought", %{signature: "opaque signature"}),
      %{"type" => "tool_use", "id" => "old_call", "name" => "old_tool", "input" => %{}},
      %{"type" => "text", "text" => %{"nested" => "opaque payload"}},
      %{kind: :text, text: 42},
      %{"text" => "not a declared text block"},
      %{kind: :text, type: :thinking, text: "conflicting kind and type"},
      %{"type" => "thinking", :kind => :text, :text => "conflicting key styles"},
      %{"type" => "thinking", :type => :text, :text => "duplicate discriminator"},
      %{"text" => "other text", :kind => :text, :text => "duplicate payload"},
      %{"text" => "declared text", "type" => "text", :text => nil},
      %OpaquePart{}
    ]

    for role <- [:user, :assistant] do
      message = Message.new(role, [NativePart.text("visible") | opaque])
      [translated] = Adapter.translate_messages([message])

      if role == :assistant do
        # The adapter itself excludes these blocks; provider-specific fallback
        # encoders must never get an opportunity to promote them to plain text.
        assert translated.content === [NativePart.text("visible")]

        assert wire_body([message], ReqLLM.Providers.Google)["contents"] == [
                 %{"role" => "model", "parts" => [%{"text" => "visible"}]}
               ]
      else
        assert translated.content === [NativePart.text("visible") | opaque]
      end

      assert translated.tool_calls == nil

      [encoded] = wire_messages([message])
      assert encoded["content"] == "visible"
      refute Map.has_key?(encoded, "tool_calls")
    end
  end

  # Build the actual provider JSON body locally. No request is prepared, sent,
  # authenticated or billed; this exercises encoding beyond Arbor's structs.
  defp wire_messages(messages) do
    messages |> wire_body(ReqLLM.Providers.OpenRouter) |> Map.fetch!("messages")
  end

  defp wire_body(messages, provider) do
    context = messages |> Adapter.translate_messages() |> ReqLLM.Context.new()

    request =
      %Req.Request{options: %{context: context, model: "openrouter/free", operation: :chat}}
      |> provider.encode_body()

    # ReqLLM 1.25 stores the provider body in options[:json]. Req encodes that
    # map into request.body only when its own encode_body step runs.
    payload =
      case request.options[:json] do
        %{} = json -> json
        _ -> request.body
      end

    payload |> Jason.encode!() |> Jason.decode!()
  end

  defp json_roundtrip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
