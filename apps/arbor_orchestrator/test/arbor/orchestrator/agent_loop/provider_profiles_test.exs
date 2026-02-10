defmodule Arbor.Orchestrator.AgentLoop.ProviderProfilesTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.AgentLoop.Session
  alias Arbor.Orchestrator.AgentLoop.ProviderProfiles.{Anthropic, Gemini, OpenAI}

  test "openai profile includes apply_patch and openai system prompt" do
    request = OpenAI.build_request(%Session{}, llm_model: "gpt-5")

    assert request.provider == "openai"
    assert Enum.any?(request.tools, &(Map.get(&1, :name) == "apply_patch"))

    [system_msg | _] = request.messages
    assert system_msg.role == :system
    assert String.contains?(system_msg.content, "OpenAI coding assistant mode")
  end

  test "anthropic profile includes edit_file and anthropic system prompt" do
    request = Anthropic.build_request(%Session{}, llm_model: "claude-sonnet-4-0")

    assert request.provider == "anthropic"
    assert Enum.any?(request.tools, &(Map.get(&1, :name) == "edit_file"))

    [system_msg | _] = request.messages
    assert system_msg.role == :system
    assert String.contains?(system_msg.content, "Anthropic coding assistant mode")
  end

  test "gemini profile includes gemini-cli aligned tools and prompt" do
    request = Gemini.build_request(%Session{}, llm_model: "gemini-2.5-pro")

    assert request.provider == "gemini"
    assert Enum.any?(request.tools, &(Map.get(&1, :name) == "read_many_files"))
    assert Enum.any?(request.tools, &(Map.get(&1, :name) == "list_dir"))

    [system_msg | _] = request.messages
    assert system_msg.role == :system
    assert String.contains?(system_msg.content, "Gemini coding assistant mode")
  end

  test "custom tools override profile tool collisions by name" do
    custom =
      %{
        name: "apply_patch",
        description: "custom patch tool",
        input_schema: %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}
      }

    request = OpenAI.build_request(%Session{}, llm_tools: [custom])

    apply_patch =
      Enum.find(request.tools, fn tool ->
        Map.get(tool, :name) == "apply_patch"
      end)

    assert apply_patch.description == "custom patch tool"
    assert get_in(apply_patch, [:input_schema, "properties", "x", "type"]) == "string"
  end
end
