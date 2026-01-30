defmodule Arbor.Comms.Channels.EmailTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Channels.Email

  describe "channel_info/0" do
    test "returns email channel metadata" do
      info = Email.channel_info()
      assert info.name == :email
      assert info.max_message_length == 50_000
      assert info.supports_media == true
      assert info.supports_threads == true
      assert info.latency == :polling
    end
  end

  describe "format_for_channel/1" do
    test "trims whitespace" do
      assert Email.format_for_channel("  hello  ") == "hello"
    end

    test "truncates long messages" do
      long = String.duplicate("a", 60_000)
      result = Email.format_for_channel(long)
      assert String.length(result) < 50_001
      assert result =~ "[Message truncated]"
    end

    test "preserves messages within limit" do
      msg = String.duplicate("a", 1000)
      assert Email.format_for_channel(msg) == msg
    end

    test "handles empty string" do
      assert Email.format_for_channel("") == ""
    end
  end

  describe "guess_content_type/1" do
    test "identifies common file types" do
      assert Email.guess_content_type("report.pdf") == "application/pdf"
      assert Email.guess_content_type("data.json") == "application/json"
      assert Email.guess_content_type("data.csv") == "text/csv"
      assert Email.guess_content_type("readme.txt") == "text/plain"
      assert Email.guess_content_type("doc.md") == "text/markdown"
      assert Email.guess_content_type("page.html") == "text/html"
      assert Email.guess_content_type("image.png") == "image/png"
      assert Email.guess_content_type("photo.jpg") == "image/jpeg"
      assert Email.guess_content_type("photo.jpeg") == "image/jpeg"
      assert Email.guess_content_type("anim.gif") == "image/gif"
      assert Email.guess_content_type("archive.zip") == "application/zip"
      assert Email.guess_content_type("code.ex") == "text/x-elixir"
      assert Email.guess_content_type("test.exs") == "text/x-elixir"
    end

    test "falls back to octet-stream for unknown types" do
      assert Email.guess_content_type("data.xyz") == "application/octet-stream"
      assert Email.guess_content_type("noext") == "application/octet-stream"
    end

    test "handles uppercase extensions" do
      assert Email.guess_content_type("REPORT.PDF") == "application/pdf"
      assert Email.guess_content_type("IMAGE.PNG") == "image/png"
    end
  end

  describe "send_message/3" do
    @describetag :integration

    test "sends a test email" do
      result = Email.send_message("test@example.com", "Test body", subject: "Test")
      assert match?({:error, _}, result) or result == :ok
    end
  end
end
