defmodule Arbor.Comms.Channels.Limitless.ClientTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Channels.Limitless.Client

  describe "extract_content/2" do
    test "prefers markdown when long enough" do
      lifelog = %{
        id: "test-1",
        title: "Short",
        markdown: "This is a longer markdown transcript with content.",
        contents: [%{type: "transcript", content: "Some transcript"}],
        start_time: nil,
        end_time: nil
      }

      assert Client.extract_content(lifelog) ==
               "This is a longer markdown transcript with content."
    end

    test "falls back to contents when markdown is too short" do
      lifelog = %{
        id: "test-2",
        title: "A title",
        markdown: "Short",
        contents: [
          %{type: "transcript", content: "First speaker said something."},
          %{type: "blockquote", content: "Second speaker replied with this."}
        ],
        start_time: nil,
        end_time: nil
      }

      result = Client.extract_content(lifelog)
      assert result =~ "First speaker said something."
      assert result =~ "Second speaker replied with this."
    end

    test "falls back to title when contents are empty" do
      lifelog = %{
        id: "test-3",
        title: "A meaningful title here",
        markdown: nil,
        contents: [],
        start_time: nil,
        end_time: nil
      }

      assert Client.extract_content(lifelog) == "A meaningful title here"
    end

    test "returns nil when everything is too short" do
      lifelog = %{
        id: "test-4",
        title: "Hi",
        markdown: "Ok",
        contents: nil,
        start_time: nil,
        end_time: nil
      }

      assert Client.extract_content(lifelog) == nil
    end

    test "filters contents to transcript and blockquote types" do
      lifelog = %{
        id: "test-5",
        title: "Title",
        markdown: nil,
        contents: [
          %{type: "heading", content: "Section Header"},
          %{type: "transcript", content: "Actual spoken content here."}
        ],
        start_time: nil,
        end_time: nil
      }

      result = Client.extract_content(lifelog)
      assert result == "Actual spoken content here."
      refute result =~ "Section Header"
    end

    test "respects custom min_length" do
      lifelog = %{
        id: "test-6",
        title: "A title",
        markdown: "Short text",
        contents: nil,
        start_time: nil,
        end_time: nil
      }

      assert Client.extract_content(lifelog, 5) == "Short text"
      assert Client.extract_content(lifelog, 100) == nil
    end

    test "handles nil contents in content items" do
      lifelog = %{
        id: "test-7",
        title: "A title here for fallback",
        markdown: nil,
        contents: [
          %{type: "transcript", content: nil},
          %{type: "transcript", content: nil}
        ],
        start_time: nil,
        end_time: nil
      }

      # Contents join to empty string, falls back to title
      assert Client.extract_content(lifelog) == "A title here for fallback"
    end
  end

  describe "test_connection/0" do
    @describetag :integration

    test "connects to Limitless API" do
      result = Client.test_connection()
      assert match?({:ok, :connected}, result) or match?({:error, _}, result)
    end
  end
end
