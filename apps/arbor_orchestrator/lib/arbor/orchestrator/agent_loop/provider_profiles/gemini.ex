defmodule Arbor.Orchestrator.AgentLoop.ProviderProfiles.Gemini do
  @moduledoc false

  @behaviour Arbor.Orchestrator.AgentLoop.ProviderProfile

  alias Arbor.Orchestrator.AgentLoop.ProviderProfiles.Default

  @impl true
  def provider, do: "gemini"

  @impl true
  def system_prompt(_opts) do
    "You are Gemini coding assistant mode. Favor concise plans, safe tool usage, and structured outputs for downstream automation."
  end

  @impl true
  def default_tools(_opts) do
    [
      %{
        name: "read_file",
        description: "Read file contents",
        input_schema: %{"type" => "object"}
      },
      %{
        name: "read_many_files",
        description: "Read multiple files in one call",
        input_schema: %{"type" => "object"}
      },
      %{
        name: "write_file",
        description: "Write full file content",
        input_schema: %{"type" => "object"}
      },
      %{
        name: "edit_file",
        description: "Search-and-replace edits",
        input_schema: %{"type" => "object"}
      },
      %{name: "shell", description: "Run shell command", input_schema: %{"type" => "object"}},
      %{name: "grep", description: "Search code by regex", input_schema: %{"type" => "object"}},
      %{
        name: "glob",
        description: "Find files by glob pattern",
        input_schema: %{"type" => "object"}
      },
      %{
        name: "list_dir",
        description: "List directory entries",
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
