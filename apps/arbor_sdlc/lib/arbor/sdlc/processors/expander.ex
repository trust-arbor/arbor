defmodule Arbor.SDLC.Processors.Expander do
  @moduledoc """
  Expands raw inbox items via LLM.

  The Expander processor transforms minimal inbox items (title + rough idea) into
  well-structured brainstorming items with:

  - Priority and category determination
  - Summary generation
  - Acceptance criteria
  - Definition of done
  - Why it matters explanation

  ## Pipeline Stage

  Handles: `inbox` -> `brainstorming`

  ## AI Routing

  Uses `Arbor.AI.generate_text/2` with complexity-based routing:
  - Simple items (docs, bugs, ideas) -> moderate-tier API call
  - Features/infrastructure -> escalated to complex tier if needed

  ## Preserving Authoritative Fields

  If the input item already has priority, category, or other fields set,
  those are preserved. LLM suggestions only fill in missing fields.

  ## Usage

      {:ok, result} = Expander.process_item(item, [])

      case result do
        {:moved_and_updated, :brainstorming, expanded_item} -> ...
        :no_action -> ...
      end
  """

  @behaviour Arbor.Contracts.Flow.Processor

  require Logger

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Events}

  @processor_id "sdlc_expander"

  @impl true
  def processor_id, do: @processor_id

  @impl true
  def can_handle?(%{path: path}) when is_binary(path) do
    # Check if item is in inbox directory
    path
    |> Path.dirname()
    |> Path.basename()
    |> String.starts_with?("0-inbox")
  end

  def can_handle?(_), do: false

  @impl true
  def process_item(item, opts \\ []) do
    config = Keyword.get(opts, :config, Config.new())
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("Expander processing item", title: item.title, path: item.path)

    Events.emit_processing_started(item, :expander,
      complexity_tier: Config.routing_for(config, :expander, item)
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      if dry_run do
        {:ok, :no_action}
      else
        expand_item(item, config, opts)
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, {:moved_and_updated, stage, expanded_item}} ->
        Events.emit_item_expanded(expanded_item)
        Events.emit_processing_completed(item, :expander, result, duration_ms: duration_ms)
        {:ok, {:moved_and_updated, stage, expanded_item}}

      {:ok, outcome} ->
        Events.emit_processing_completed(item, :expander, {:ok, outcome},
          duration_ms: duration_ms
        )

        {:ok, outcome}

      {:error, reason} = error ->
        Events.emit_processing_failed(item, :expander, reason, retryable: true)
        error
    end
  end

  # =============================================================================
  # Internal Functions
  # =============================================================================

  defp expand_item(item, config, opts) do
    ai_module = Keyword.get(opts, :ai_module, config.ai_module)

    prompt = build_expansion_prompt(item)
    system_prompt = system_prompt_for_expansion()

    ai_opts = [
      system_prompt: system_prompt,
      max_tokens: 4096,
      temperature: 0.4
    ]

    Logger.debug("Calling AI for expansion", title: item.title)

    case ai_module.generate_text(prompt, ai_opts) do
      {:ok, response} ->
        parse_and_merge_expansion(item, response)

      {:error, reason} ->
        Logger.warning("Expansion AI call failed", reason: inspect(reason), title: item.title)
        {:error, {:ai_call_failed, reason}}
    end
  end

  defp build_expansion_prompt(item) do
    """
    # Item to Expand

    ## Title
    #{item.title}

    ## Current Content
    #{item.raw_content || "No additional content provided."}

    ## Existing Fields
    - Priority: #{item.priority || "not set"}
    - Category: #{item.category || "not set"}
    - Effort: #{item.effort || "not set"}

    # Instructions

    Expand this item into a well-structured work item. Analyze the title and any
    provided content to determine:

    1. **Priority** (if not already set): critical, high, medium, low, or someday
    2. **Category** (if not already set): feature, bug, refactor, infrastructure, idea, research, documentation, or content
    3. **Effort** (if not already set): small, medium, large, or ongoing
    4. **Summary**: A clear 2-3 sentence description of what this item is about
    5. **Why It Matters**: Why is this valuable? What problem does it solve?
    6. **Acceptance Criteria**: 3-5 specific, testable criteria for completion
    7. **Definition of Done**: Checklist items for full completion (tests pass, docs updated, etc.)

    # Response Format

    Respond with ONLY a valid JSON object (no markdown code blocks):

    {
      "priority": "high",
      "category": "feature",
      "effort": "medium",
      "summary": "...",
      "why_it_matters": "...",
      "acceptance_criteria": ["Criterion 1", "Criterion 2", "..."],
      "definition_of_done": ["Tests pass", "Documentation updated", "..."]
    }

    Only include fields that need to be set. If the item already has a valid priority,
    category, or effort, don't include those in your response.
    """
  end

  defp system_prompt_for_expansion do
    """
    You are a technical project planner for an Elixir/OTP software project.
    Your job is to expand rough work item ideas into well-structured specifications.

    Guidelines:
    - Be specific and actionable in acceptance criteria
    - Write criteria that can be verified objectively
    - Consider what "done" means in the context of an Elixir umbrella project
    - For features: include API design, tests, documentation
    - For bugs: include reproduction steps, expected behavior, verification
    - For refactors: include before/after state, affected modules
    - For infrastructure: include configuration, deployment, monitoring

    Always respond with valid JSON only. No explanations or markdown formatting.
    """
  end

  defp parse_and_merge_expansion(item, response) do
    case Jason.decode(response.text) do
      {:ok, expansion_data} ->
        merge_expansion(item, expansion_data)

      {:error, _} ->
        # Try to extract JSON from the response
        case extract_json(response.text) do
          {:ok, expansion_data} ->
            merge_expansion(item, expansion_data)

          :error ->
            Logger.warning("Failed to parse expansion response",
              title: item.title,
              response: String.slice(response.text, 0, 200)
            )

            {:error, :invalid_expansion_response}
        end
    end
  end

  defp extract_json(text) do
    # Try to find JSON object in the response
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> :error
        end

      nil ->
        :error
    end
  end

  defp merge_expansion(item, expansion_data) do
    # Merge expansion data with existing item, preserving authoritative fields
    merged_attrs = [
      title: item.title,
      id: item.id,
      path: item.path,
      raw_content: nil,
      content_hash: item.content_hash,
      created_at: item.created_at || Date.utc_today(),
      # Preserve existing or use expansion
      priority: item.priority || parse_priority(expansion_data["priority"]),
      category: item.category || parse_category(expansion_data["category"]),
      effort: item.effort || parse_effort(expansion_data["effort"]),
      # Always take expansion for these
      summary: expansion_data["summary"],
      why_it_matters: expansion_data["why_it_matters"],
      acceptance_criteria: parse_criteria_list(expansion_data["acceptance_criteria"]),
      definition_of_done: parse_criteria_list(expansion_data["definition_of_done"]),
      # Preserve existing
      depends_on: item.depends_on,
      blocks: item.blocks,
      related_files: item.related_files,
      notes: item.notes,
      metadata: Map.merge(item.metadata || %{}, %{"expanded_at" => DateTime.utc_now()})
    ]

    case Item.new(merged_attrs) do
      {:ok, expanded_item} ->
        {:ok, {:moved_and_updated, :brainstorming, expanded_item}}

      {:error, reason} ->
        {:error, {:item_merge_failed, reason}}
    end
  end

  defp parse_priority(nil), do: nil

  defp parse_priority(priority) when is_binary(priority) do
    priority = String.downcase(priority)

    if priority in ~w(critical high medium low someday) do
      String.to_existing_atom(priority)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_priority(_), do: nil

  defp parse_category(nil), do: nil

  defp parse_category(category) when is_binary(category) do
    category = String.downcase(category)

    if category in ~w(feature refactor bug infrastructure idea research documentation content) do
      String.to_existing_atom(category)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_category(_), do: nil

  defp parse_effort(nil), do: nil

  defp parse_effort(effort) when is_binary(effort) do
    effort = String.downcase(effort)

    if effort in ~w(small medium large ongoing) do
      String.to_existing_atom(effort)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_effort(_), do: nil

  defp parse_criteria_list(nil), do: []
  defp parse_criteria_list([]), do: []

  defp parse_criteria_list(criteria) when is_list(criteria) do
    criteria
    |> Enum.map(fn
      text when is_binary(text) -> %{text: text, completed: false}
      %{"text" => text} -> %{text: text, completed: false}
      %{text: text} -> %{text: text, completed: false}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_criteria_list(_), do: []

  @doc """
  Serialize an expanded item back to markdown.

  This is used when writing the expanded item to the brainstorming directory.
  """
  @spec serialize_item(Item.t()) :: String.t()
  def serialize_item(%Item{} = item) do
    item
    |> Map.from_struct()
    |> ItemParser.serialize()
  end
end
