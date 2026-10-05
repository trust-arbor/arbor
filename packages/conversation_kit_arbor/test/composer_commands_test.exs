defmodule ConversationKit.Arbor.ComposerCommandsTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor

  test "the public classifier preserves ordinary Unicode and multiline input exactly" do
    for text <- ["", "   ", "  café 東京\nsecond line  ", "question /help", "```\n/model x\n```"] do
      assert Arbor.classify_composer_input(text) == {:message, text}
    end
  end

  test "bounded local intents accept leading whitespace but never command arguments" do
    for {text, action} <- [
          {"  /help", :help},
          {"\n\t/retry  ", :retry},
          {"/quit", :quit},
          {"/refresh", :refresh},
          {"/disconnect", :disconnect},
          {"/reconnect", :reconnect},
          {"/older", :older},
          {"/newer", :newer},
          {"/latest", :latest},
          {"/work", :work},
          {"/more-work", :more_activity},
          {"/latest-work", :latest_activity}
        ] do
      assert Arbor.classify_composer_input(text) == {:local, action}
    end

    for text <- [
          "/retry other-id",
          "/help\nplease send",
          "/ help",
          "/",
          "/MODEL",
          "/model anything",
          "\t/unknown"
        ] do
      assert Arbor.classify_composer_input(text) == {:unavailable, :runtime_command}
    end
  end

  test "management is guidance, never a local capability or host message" do
    for text <- [
          "/agent stop agent_private",
          "/connect remote",
          "/delete private"
        ] do
      assert Arbor.classify_composer_input(text) == {:unavailable, :management}
    end
  end

  test "navigation is a closed local intent with bounded literal Unicode target" do
    assert {:local, :agents} = Arbor.classify_composer_input("  /agents  ")

    assert {:local, {:attach, "Voice 東京 agent"}} =
             Arbor.classify_composer_input(" /attach Voice 東京 agent  ")

    for text <- [
          "/agents other",
          "/attach",
          "/attach\nagent_private",
          "/attach bad\e[2J",
          "/attach " <> String.duplicate("é", 129)
        ] do
      assert {:unavailable, :management} = Arbor.classify_composer_input(text)
    end

    for text <- ["/Agents", "/Attach agent_private"],
        do: assert({:unavailable, :runtime_command} == Arbor.classify_composer_input(text))
  end

  test "type, UTF-8 and byte bounds are checked before parsing" do
    for input <- [nil, 42, %{}, ["/help"], <<255>>, String.duplicate(" ", 32_769) <> "/help"] do
      assert Arbor.classify_composer_input(input) == {:error, :invalid_input}
    end

    text = String.duplicate("é", 16_384)
    assert Arbor.classify_composer_input(text) == {:message, text}
  end
end
