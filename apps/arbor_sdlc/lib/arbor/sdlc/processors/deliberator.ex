defmodule Arbor.SDLC.Processors.Deliberator do
  @moduledoc """
  Analyzes brainstorming items and uses consensus council for decisions.

  The Deliberator processor handles the transition from brainstorming to planned
  (or discarded). It:

  1. Analyzes the item for unknowns, decision points, missing requirements
  2. If decisions are needed: convenes `Arbor.Consensus` council with SDLC evaluator
  3. If rejected: revises proposal from concerns/recommendations, resubmits (max 3 attempts)
  4. Documents each decision in `.arbor/decisions/`
  5. Updates the item with resolved decisions
  6. Moves resolved items to `2-planned/` or `8-discarded/`

  If no decisions are needed (well-specified item), it passes straight through.

  ## Pipeline Stage

  Handles: `brainstorming` -> `planned` | `discarded`

  ## Iterative Refinement

  When the council rejects a proposal, the Deliberator:

  1. Collects `concerns` and `recommendations` from all evaluations
  2. Uses LLM to revise the proposal addressing the feedback
  3. Resubmits to council (max 3 attempts)
  4. On persistent deadlock: documents as Open Question, moves to planned anyway

  ## Decision Documentation

  Each council decision is written to `.arbor/decisions/` with:
  - The item that triggered it
  - The decision points
  - Council deliberation and vote
  - Final outcome

  ## Usage

      {:ok, result} = Deliberator.process_item(item, [])

      case result do
        {:moved, :planned} -> ...
        {:moved, :discarded} -> ...
        {:moved_and_updated, :planned, updated_item} -> ...
      end
  """

  @behaviour Arbor.Contracts.Flow.Processor

  require Logger

  alias Arbor.Contracts.Consensus.Proposal
  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Evaluator, Events}

  @processor_id "sdlc_deliberator"

  @impl true
  def processor_id, do: @processor_id

  @impl true
  def can_handle?(%{path: path}) when is_binary(path) do
    # Check if item is in brainstorming directory
    path
    |> Path.dirname()
    |> Path.basename()
    |> String.starts_with?("1-brainstorming")
  end

  def can_handle?(_), do: false

  @impl true
  def process_item(item, opts \\ []) do
    config = Keyword.get(opts, :config, Config.new())
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("Deliberator processing item", title: item.title, path: item.path)

    Events.emit_processing_started(item, :deliberator,
      complexity_tier: Config.routing_for(config, :deliberator, item)
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      if dry_run do
        {:ok, :no_action}
      else
        deliberate_item(item, config, opts)
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, outcome} ->
        Events.emit_processing_completed(item, :deliberator, {:ok, outcome},
          duration_ms: duration_ms
        )

        {:ok, outcome}

      {:error, reason} = error ->
        Events.emit_processing_failed(item, :deliberator, reason, retryable: true)
        error
    end
  end

  # =============================================================================
  # Internal Functions
  # =============================================================================

  defp deliberate_item(item, config, opts) do
    ai_module = Keyword.get(opts, :ai_module, config.ai_module)
    ai_backend = Keyword.get(opts, :ai_backend, config.ai_backend)

    # Step 1: Analyze item for decision points
    case analyze_for_decisions(item, ai_module, ai_backend) do
      {:ok, :well_specified} ->
        # No decisions needed, pass through to planned
        Logger.info("Item well-specified, moving to planned", title: item.title)
        {:ok, {:moved, :planned}}

      {:ok, {:needs_decisions, decision_points}} ->
        # Submit to council for deliberation
        Logger.info("Item needs decisions, convening council",
          title: item.title,
          decision_points: length(decision_points)
        )

        deliberate_with_council(item, decision_points, config, opts)

      {:error, reason} ->
        {:error, {:analysis_failed, reason}}
    end
  end

  defp analyze_for_decisions(item, ai_module, ai_backend) do
    prompt = build_analysis_prompt(item)

    system_prompt = """
    You are an SDLC analyst examining a work item for decision points.

    Analyze the item and identify:
    1. Unknowns that need clarification
    2. Scope ambiguities
    3. Missing requirements
    4. Technical decisions that need to be made

    If the item is well-specified with clear acceptance criteria and no major
    unknowns, respond with: {"needs_decisions": false}

    If decisions are needed, respond with:
    {
      "needs_decisions": true,
      "decision_points": [
        {"question": "...", "context": "...", "options": ["...", "..."]}
      ]
    }

    Respond with valid JSON only.
    """

    case ai_module.generate_text(prompt,
           system_prompt: system_prompt,
           max_tokens: 2048,
           temperature: 0.3,
           backend: ai_backend
         ) do
      {:ok, response} ->
        parse_analysis_response(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_analysis_prompt(item) do
    """
    # Item to Analyze

    ## Title
    #{item.title}

    ## Summary
    #{item.summary || "No summary provided."}

    ## Priority
    #{item.priority || "Not set"}

    ## Category
    #{item.category || "Not set"}

    ## Acceptance Criteria
    #{format_criteria(item.acceptance_criteria)}

    ## Definition of Done
    #{format_criteria(item.definition_of_done)}

    ## Why It Matters
    #{item.why_it_matters || "Not specified."}

    ## Notes
    #{item.notes || "None."}
    """
  end

  defp format_criteria([]), do: "None specified."

  defp format_criteria(criteria) when is_list(criteria) do
    criteria
    |> Enum.map(fn
      %{text: text} -> "- #{text}"
      text when is_binary(text) -> "- #{text}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_criteria(_), do: "None specified."

  defp parse_analysis_response(response) do
    text = Map.get(response, :text) || ""

    case Jason.decode(text) do
      {:ok, %{"needs_decisions" => false}} ->
        {:ok, :well_specified}

      {:ok, %{"needs_decisions" => true, "decision_points" => points}} ->
        {:ok, {:needs_decisions, points}}

      {:ok, %{"needs_decisions" => true}} ->
        # Has decisions but no points specified
        {:ok, {:needs_decisions, []}}

      {:error, _} ->
        # Try to extract JSON
        case extract_json(text) do
          {:ok, data} -> parse_analysis_response(%{text: Jason.encode!(data)})
          :error -> {:ok, :well_specified}
        end
    end
  end

  defp extract_json(text) do
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

  # =============================================================================
  # Council Deliberation
  # =============================================================================

  defp deliberate_with_council(item, decision_points, config, opts) do
    max_attempts = config.max_deliberation_attempts
    deliberate_with_retries(item, decision_points, config, opts, 1, max_attempts)
  end

  defp deliberate_with_retries(item, decision_points, config, opts, attempt, max_attempts) do
    Logger.info("Council deliberation attempt #{attempt}/#{max_attempts}", title: item.title)

    # Build proposal for council
    proposal_attrs = build_proposal(item, decision_points, attempt)

    case Proposal.new(proposal_attrs) do
      {:ok, proposal} ->
        # Submit to consensus
        submit_result =
          Arbor.Consensus.submit(proposal,
            evaluator_backend: Evaluator,
            server: config.consensus_server
          )

        case submit_result do
          {:ok, proposal_id} ->
            Events.emit_decision_requested(item, proposal_id, attempt: attempt)

            handle_council_decision(
              item,
              proposal_id,
              decision_points,
              config,
              opts,
              attempt,
              max_attempts
            )

          {:error, reason} ->
            {:error, {:council_submit_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:proposal_creation_failed, reason}}
    end
  end

  defp build_proposal(item, decision_points, attempt) do
    description =
      if attempt == 1 do
        build_initial_description(item, decision_points)
      else
        build_retry_description(item, decision_points, attempt)
      end

    %{
      proposer: @processor_id,
      change_type: :sdlc_decision,
      description: description,
      target_layer: 4,
      metadata: %{
        item: item_to_map(item),
        decision_points: decision_points,
        attempt: attempt
      }
    }
  end

  defp build_initial_description(item, decision_points) do
    points_text =
      if decision_points == [] do
        "General approval for moving to planned status."
      else
        decision_points
        |> Enum.map(fn
          %{"question" => q} -> "- #{q}"
          point when is_binary(point) -> "- #{point}"
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end

    """
    SDLC Planning Decision: #{item.title}

    This item is being evaluated for transition from brainstorming to planned.

    ## Decision Points

    #{points_text}

    ## Item Summary

    #{item.summary || "No summary provided."}
    """
  end

  defp build_retry_description(item, decision_points, attempt) do
    """
    SDLC Planning Decision: #{item.title} (Attempt #{attempt})

    This is a revised proposal addressing previous council feedback.

    ## Decision Points

    #{format_decision_points(decision_points)}

    ## Item Summary

    #{item.summary || "No summary provided."}

    Previous attempts were rejected. This revision incorporates council feedback.
    """
  end

  defp format_decision_points([]), do: "General approval for moving to planned status."

  defp format_decision_points(points) do
    points
    |> Enum.map(fn
      %{"question" => q} -> "- #{q}"
      point when is_binary(point) -> "- #{point}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp handle_council_decision(
         item,
         proposal_id,
         decision_points,
         config,
         opts,
         attempt,
         max_attempts
       ) do
    # Wait for decision (poll with timeout)
    case wait_for_decision(proposal_id, config) do
      {:ok, decision} ->
        Events.emit_decision_rendered(
          proposal_id,
          decision.verdict,
          %{
            approval_count: count_votes(decision.evaluations, :approve),
            rejection_count: count_votes(decision.evaluations, :reject),
            abstain_count: count_votes(decision.evaluations, :abstain)
          }
        )

        process_decision(item, decision, decision_points, config, opts, attempt, max_attempts)

      {:error, :timeout} ->
        # Deadlock - document as open question and move to planned
        Logger.warning("Council decision timeout, treating as deadlock", title: item.title)
        handle_deadlock(item, decision_points, config, opts)

      {:error, reason} ->
        {:error, {:council_decision_failed, reason}}
    end
  end

  defp wait_for_decision(proposal_id, config) do
    # Poll for decision with timeout
    timeout = config.ai_timeout * 10
    poll_interval = 500
    max_polls = div(timeout, poll_interval)

    wait_for_decision_loop(proposal_id, max_polls, poll_interval)
  end

  defp wait_for_decision_loop(_proposal_id, 0, _interval), do: {:error, :timeout}

  defp wait_for_decision_loop(proposal_id, remaining, interval) do
    case Arbor.Consensus.get_decision(proposal_id) do
      {:ok, decision} ->
        {:ok, decision}

      {:error, :pending} ->
        Process.sleep(interval)
        wait_for_decision_loop(proposal_id, remaining - 1, interval)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_votes(evaluations, vote_type) when is_list(evaluations) do
    Enum.count(evaluations, fn eval -> eval.vote == vote_type end)
  end

  defp count_votes(_, _), do: 0

  defp process_decision(item, decision, decision_points, config, opts, attempt, max_attempts) do
    case decision.verdict do
      :approved ->
        # Document decision and move to planned
        document_decision(item, decision, config, opts)
        Events.emit_item_deliberated(item, :approved, decision_id: decision.id)
        {:ok, {:moved, :planned}}

      :rejected when attempt < max_attempts ->
        # Collect feedback and revise
        ai_module = Keyword.get(opts, :ai_module, config.ai_module)
        ai_backend = Keyword.get(opts, :ai_backend, config.ai_backend)
        revised_points = revise_from_feedback(item, decision, decision_points, ai_module, ai_backend)
        deliberate_with_retries(item, revised_points, config, opts, attempt + 1, max_attempts)

      :rejected ->
        # Max retries reached, discard
        document_decision(item, decision, config, opts)
        Events.emit_item_deliberated(item, :rejected, decision_id: decision.id)
        {:ok, {:moved, :discarded}}

      :deadlock ->
        handle_deadlock(item, decision_points, config, opts)

      _other ->
        # Unknown verdict, treat as deadlock
        handle_deadlock(item, decision_points, config, opts)
    end
  end

  defp handle_deadlock(item, decision_points, config, opts) do
    # Document as open question and move to planned anyway
    Logger.info("Deadlock on item, moving to planned with open questions", title: item.title)

    # Update item with open questions in notes
    updated_item = add_open_questions(item, decision_points)

    document_deadlock(item, decision_points, config, opts)
    Events.emit_item_deliberated(item, :deadlock)

    {:ok, {:moved_and_updated, :planned, updated_item}}
  end

  defp add_open_questions(item, decision_points) do
    questions_text =
      decision_points
      |> Enum.map(fn
        %{"question" => q} -> "- [ ] #{q}"
        point when is_binary(point) -> "- [ ] #{point}"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    new_notes =
      case item.notes do
        nil -> "## Open Questions\n\n#{questions_text}"
        notes -> notes <> "\n\n## Open Questions\n\n#{questions_text}"
      end

    struct(item, notes: new_notes)
  end

  defp revise_from_feedback(item, decision, decision_points, ai_module, ai_backend) do
    # Collect concerns and recommendations from all evaluations
    evaluations = decision.evaluations || []

    concerns =
      evaluations
      |> Enum.flat_map(fn eval -> eval.concerns || [] end)
      |> Enum.uniq()

    recommendations =
      evaluations
      |> Enum.flat_map(fn eval -> eval.recommendations || [] end)
      |> Enum.uniq()

    prompt = """
    # Council Feedback on Item: #{item.title}

    ## Previous Decision Points
    #{format_decision_points(decision_points)}

    ## Concerns Raised
    #{Enum.join(concerns, "\n- ")}

    ## Recommendations
    #{Enum.join(recommendations, "\n- ")}

    # Task

    Revise the decision points to address the council's feedback.
    Create clearer, more specific questions that address the concerns.

    Respond with valid JSON:
    {"revised_decision_points": [{"question": "...", "context": "...", "options": ["..."]}]}
    """

    case ai_module.generate_text(prompt, max_tokens: 2048, temperature: 0.4, backend: ai_backend) do
      {:ok, response} ->
        case Jason.decode(response.text) do
          {:ok, %{"revised_decision_points" => points}} -> points
          _ -> decision_points
        end

      {:error, _} ->
        decision_points
    end
  end

  # =============================================================================
  # Decision Documentation
  # =============================================================================

  defp document_decision(item, decision, _config, _opts) do
    decisions_dir = Config.absolute_decisions_directory()
    File.mkdir_p!(decisions_dir)

    date = Date.utc_today() |> Date.to_iso8601()

    slug =
      item.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 40)

    filename = "#{date}-sdlc-#{slug}.md"
    path = Path.join(decisions_dir, filename)

    content = format_decision_document(item, decision)

    case File.write(path, content) do
      :ok ->
        Events.emit_decision_documented(decision.id, path)
        Logger.info("Decision documented", path: path)

      {:error, reason} ->
        Logger.warning("Failed to document decision", path: path, reason: inspect(reason))
    end
  end

  defp document_deadlock(item, decision_points, _config, _opts) do
    decisions_dir = Config.absolute_decisions_directory()
    File.mkdir_p!(decisions_dir)

    date = Date.utc_today() |> Date.to_iso8601()

    slug =
      item.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 40)

    filename = "#{date}-sdlc-deadlock-#{slug}.md"
    path = Path.join(decisions_dir, filename)

    content = format_deadlock_document(item, decision_points)

    case File.write(path, content) do
      :ok ->
        Logger.info("Deadlock documented", path: path)

      {:error, reason} ->
        Logger.warning("Failed to document deadlock", path: path, reason: inspect(reason))
    end
  end

  defp format_decision_document(item, decision) do
    evaluations_text =
      (decision.evaluations || [])
      |> Enum.map_join("\n", fn eval ->
        """
        ### #{eval.perspective}

        **Vote:** #{eval.vote}
        **Confidence:** #{Float.round(eval.confidence * 100, 1)}%

        #{eval.reasoning}

        #{if eval.concerns != [], do: "**Concerns:** " <> Enum.join(eval.concerns, ", "), else: ""}
        #{if eval.recommendations != [], do: "**Recommendations:** " <> Enum.join(eval.recommendations, ", "), else: ""}
        """
      end)

    """
    # SDLC Decision: #{item.title}

    **Date:** #{Date.utc_today() |> Date.to_iso8601()}
    **Status:** #{decision.verdict}
    **Decision ID:** #{decision.id}

    ## Item Summary

    #{item.summary || "No summary provided."}

    ## Decision

    The council #{decision.verdict} this item for transition to planned status.

    ## Council Deliberation

    #{evaluations_text}

    ## Final Vote

    - Approvals: #{count_votes(decision.evaluations, :approve)}
    - Rejections: #{count_votes(decision.evaluations, :reject)}
    - Abstentions: #{count_votes(decision.evaluations, :abstain)}
    """
  end

  defp format_deadlock_document(item, decision_points) do
    """
    # SDLC Deadlock: #{item.title}

    **Date:** #{Date.utc_today() |> Date.to_iso8601()}
    **Status:** Deadlock - Moved to planned with open questions

    ## Item Summary

    #{item.summary || "No summary provided."}

    ## Unresolved Decision Points

    #{format_decision_points(decision_points)}

    ## Notes

    The council could not reach consensus on this item. It has been moved to
    planned status with the decision points recorded as open questions.

    A human reviewer should examine this item and either:
    1. Resolve the open questions manually
    2. Send the item back to brainstorming with more context
    """
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp item_to_map(%Item{} = item) do
    %{
      title: item.title,
      summary: item.summary,
      priority: item.priority,
      category: item.category,
      effort: item.effort,
      acceptance_criteria: item.acceptance_criteria,
      definition_of_done: item.definition_of_done,
      why_it_matters: item.why_it_matters
    }
  end

  defp item_to_map(item) when is_map(item), do: item

  @doc """
  Serialize an item back to markdown.
  """
  @spec serialize_item(Item.t()) :: String.t()
  def serialize_item(%Item{} = item) do
    item
    |> Map.from_struct()
    |> ItemParser.serialize()
  end
end
