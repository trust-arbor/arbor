defmodule Arbor.Orchestrator.AgentLoop.ProviderProfiles.OpenAI do
  @moduledoc false

  @behaviour Arbor.Orchestrator.AgentLoop.ProviderProfile

  alias Arbor.Orchestrator.AgentLoop.ProviderProfiles.Default

  @impl true
  def provider, do: "openai"

  @impl true
  def system_prompt(_opts) do
    "You are OpenAI coding assistant mode. Prefer apply_patch for edits, use tools deliberately, and produce production-quality code changes."
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
        name: "apply_patch",
        description: "Apply patch-format edits",
        input_schema: %{"type" => "object"}
      },
      %{
        name: "write_file",
        description: "Write full file content",
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
      |> with_reasoning_option()
    )
  end

  @impl true
  def decode_response(response, session, opts),
    do: Default.decode_response(response, session, opts)

  defp with_reasoning_option(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      effort when is_binary(effort) and effort != "" ->
        put_provider_option(opts, "reasoning", %{"effort" => effort})

      _ ->
        opts
    end
  end

  defp put_provider_option(opts, key, value) do
    base =
      case Keyword.get(opts, :provider_options) do
        map when is_map(map) -> map
        _ -> %{}
      end

    Keyword.put(opts, :provider_options, Map.put(base, key, value))
  end
end
