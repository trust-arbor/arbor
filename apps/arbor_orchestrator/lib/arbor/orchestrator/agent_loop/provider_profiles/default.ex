defmodule Arbor.Orchestrator.AgentLoop.ProviderProfiles.Default do
  @moduledoc false

  @behaviour Arbor.Orchestrator.AgentLoop.ProviderProfile

  alias Arbor.Orchestrator.AgentLoop.Session
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request, Response}

  @impl true
  def provider, do: "openai"

  @impl true
  def system_prompt(_opts) do
    "You are a coding agent. Prefer safe, deterministic edits and explain tool intent clearly."
  end

  @impl true
  def default_tools(_opts), do: []

  @impl true
  def build_request(%Session{} = session, opts) do
    provider = Keyword.get(opts, :llm_provider, provider())
    model = Keyword.get(opts, :llm_model, "gpt-5")
    profile_prompt = Keyword.get(opts, :profile_system_prompt, system_prompt(opts))
    profile_tools = Keyword.get(opts, :profile_tools, default_tools(opts))
    custom_tools = Keyword.get(opts, :llm_tools, [])

    messages =
      Enum.map(session.messages, fn msg ->
        Message.new(msg.role, msg.content, msg.metadata || %{})
      end)

    messages =
      if is_binary(profile_prompt) and profile_prompt != "" do
        [Message.new(:system, profile_prompt) | messages]
      else
        messages
      end

    %Request{
      provider: provider,
      model: model,
      messages: messages,
      tools: merge_tools(profile_tools, custom_tools),
      provider_options: profile_provider_options(opts)
    }
  end

  @impl true
  def decode_response(%Response{} = response, _session, _opts) do
    raw = response.raw || %{}

    type = get(raw, "type") || get(raw, :type)

    case type do
      "tool_call" ->
        %{
          type: :tool_call,
          assistant_content: get(raw, "assistant_content") || response.text,
          tool_calls: get(raw, "tool_calls") || []
        }

      :tool_call ->
        %{
          type: :tool_call,
          assistant_content: get(raw, :assistant_content) || response.text,
          tool_calls: get(raw, :tool_calls) || []
        }

      "final" ->
        %{type: :final, content: get(raw, "content") || response.text}

      :final ->
        %{type: :final, content: get(raw, :content) || response.text}

      _ ->
        # Default to final text response for broad compatibility.
        %{type: :final, content: response.text}
    end
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key)
  defp get(_, _), do: nil

  defp merge_tools(profile_tools, custom_tools) do
    profile_map = tools_to_map(profile_tools)
    custom_map = tools_to_map(custom_tools)

    Map.merge(profile_map, custom_map)
    |> Map.values()
  end

  defp tools_to_map(tools) when is_list(tools) do
    Enum.reduce(tools, %{}, fn tool, acc ->
      name = Map.get(tool, :name) || Map.get(tool, "name")

      if is_binary(name) and name != "" do
        Map.put(acc, name, normalize_tool(tool))
      else
        acc
      end
    end)
  end

  defp tools_to_map(_), do: %{}

  defp normalize_tool(tool) when is_map(tool) do
    %{
      name: Map.get(tool, :name) || Map.get(tool, "name"),
      description: Map.get(tool, :description) || Map.get(tool, "description"),
      input_schema:
        Map.get(tool, :input_schema) || Map.get(tool, "input_schema") ||
          Map.get(tool, :parameters) || Map.get(tool, "parameters") || %{}
    }
  end

  defp profile_provider_options(opts) do
    case Keyword.get(opts, :provider_options) do
      options when is_map(options) -> options
      _ -> %{}
    end
  end
end
