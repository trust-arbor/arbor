defmodule Arbor.Orchestrator.AgentLoop.ProviderProfiles.Anthropic do
  @moduledoc false

  @behaviour Arbor.Orchestrator.AgentLoop.ProviderProfile

  alias Arbor.Orchestrator.AgentLoop.ProviderProfiles.Default

  @impl true
  def provider, do: "anthropic"

  @impl true
  def system_prompt(_opts) do
    "You are Anthropic coding assistant mode. Prefer edit_file exact replacements, keep edits surgical, and explain assumptions explicitly."
  end

  @impl true
  def default_tools(_opts) do
    [
      %{
        name: "read_file",
        description: "Read file contents with optional ranges",
        input_schema: %{"type" => "object"}
      },
      %{
        name: "write_file",
        description: "Write full file content",
        input_schema: %{"type" => "object"}
      },
      %{
        name: "edit_file",
        description: "Replace exact old_string with new_string",
        input_schema: %{"type" => "object"}
      },
      %{name: "shell", description: "Run shell command", input_schema: %{"type" => "object"}},
      %{name: "grep", description: "Search code by regex", input_schema: %{"type" => "object"}},
      %{
        name: "glob",
        description: "Find files by glob pattern",
        input_schema: %{"type" => "object"}
      }
    ]
  end

  @impl true
  def build_request(session, opts) do
    Default.build_request(
      session,
      opts
      |> Keyword.put_new(:llm_provider, provider())
      |> Keyword.put_new(:profile_system_prompt, system_prompt(opts))
      |> Keyword.put_new(:profile_tools, default_tools(opts))
    )
  end

  @impl true
  def decode_response(response, session, opts),
    do: Default.decode_response(response, session, opts)
end
