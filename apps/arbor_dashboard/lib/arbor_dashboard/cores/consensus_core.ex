defmodule Arbor.Dashboard.Cores.ConsensusCore do
  @moduledoc """
  Pure display formatters for the consensus dashboard.

  Follows the Construct-Reduce-Convert pattern, but scoped to the
  display-formatting concerns of consensus_live. State management
  (data fetching, streams, tab selection) stays in the LiveView for now.

  This is a Phase A extraction. A future Phase B could pull the full
  state-management pipeline into the core like MonitorCore does — but
  consensus_live is large (939 lines) with stream-based item rendering
  that doesn't translate as cleanly. Phase A pays off the main pain
  (display logic was scattered) without a sweeping rewrite.

  ## Functions

  - `show_proposal/1` — proposal → display map
  - `show_decision/1` — decision → display map
  - `show_consultation/1` — consultation → display map (question, subtitle, count)
  - `show_consultation_result/1` — single perspective result → display map
  - `show_event/1` — proposal event → display map
  - `show_approval/1` — pending approval → display map (resource, age, actor)
  - `show_stats/1` — raw stats → normalized display stats
  """

  alias Arbor.Web.{Helpers, Icons}

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc "Format a proposal for the proposal list / detail."
  @spec show_proposal(map() | nil) :: map() | nil
  def show_proposal(nil), do: nil

  def show_proposal(proposal) do
    %{
      id: proposal.id,
      status: proposal.status,
      topic: Map.get(proposal, :topic),
      mode: Map.get(proposal, :mode),
      proposer: Map.get(proposal, :proposer),
      title: Map.get(proposal, :title) || Map.get(proposal, :description, ""),
      description: Map.get(proposal, :description, ""),
      subtitle: format_proposal_subtitle(proposal),
      created_at: Map.get(proposal, :created_at),
      created_at_relative: format_relative(Map.get(proposal, :created_at)),
      metadata: Map.get(proposal, :metadata, %{})
    }
  end

  @doc "Format a decision for the decision list / detail."
  @spec show_decision(map() | nil) :: map() | nil
  def show_decision(nil), do: nil

  def show_decision(decision) do
    %{
      id: Map.get(decision, :id) || Map.get(decision, :proposal_id),
      proposal_id: Map.get(decision, :proposal_id),
      outcome: Map.get(decision, :outcome) || Map.get(decision, :decision),
      vote_count: Map.get(decision, :vote_count, 0),
      decided_at: Map.get(decision, :decided_at) || Map.get(decision, :created_at),
      decided_at_relative:
        format_relative(Map.get(decision, :decided_at) || Map.get(decision, :created_at)),
      summary: Map.get(decision, :summary, "")
    }
  end

  @doc "Format a consultation for the consultation list."
  @spec show_consultation(map() | nil) :: map() | nil
  def show_consultation(nil), do: nil

  def show_consultation(consultation) do
    %{
      id: Map.get(consultation, :id) || Map.get(consultation, :run_id),
      run_id: Map.get(consultation, :run_id),
      question: consultation_question(consultation),
      subtitle: consultation_subtitle(consultation),
      perspective_count: Map.get(consultation, :sample_count, 0),
      status: Map.get(consultation, :status, :unknown),
      dataset: Map.get(consultation, :dataset),
      created_at: Map.get(consultation, :created_at),
      created_at_relative: format_relative(Map.get(consultation, :created_at)),
      results: consultation_results(consultation)
    }
  end

  @doc "Format a single perspective result within a consultation."
  @spec show_consultation_result(map()) :: map()
  def show_consultation_result(result) do
    perspective_name = Map.get(result, :perspective) || Map.get(result, "perspective", "unknown")

    %{
      perspective: perspective_name,
      perspective_icon: perspective_icon_from_string(perspective_name),
      vote: result_vote(result),
      confidence: result_confidence(result),
      model: result_model(result),
      cost: result_cost(result),
      concerns: result_concerns(result),
      recommendations: result_recommendations(result)
    }
  end

  @doc "Format a proposal event for the timeline."
  @spec show_event(map()) :: map()
  def show_event(event) do
    type = Map.get(event, :type) || Map.get(event, :event_type) || :unknown

    %{
      type: type,
      formatted_type: format_event_type(type),
      timestamp: Map.get(event, :timestamp) || Map.get(event, :occurred_at),
      timestamp_relative:
        format_relative(Map.get(event, :timestamp) || Map.get(event, :occurred_at)),
      payload: Map.get(event, :payload, %{}),
      actor: Map.get(event, :actor) || Map.get(event, :agent_id)
    }
  end

  @doc "Format a pending approval for the approvals tab."
  @spec show_approval(map()) :: map()
  def show_approval(proposal) do
    %{
      id: proposal.id,
      id_short: String.slice(proposal.id, 0..15),
      resource: approval_resource(proposal),
      description: Map.get(proposal, :description, ""),
      proposer: Map.get(proposal, :proposer),
      created_at: Map.get(proposal, :created_at),
      age: format_relative(Map.get(proposal, :created_at)),
      metadata: Map.get(proposal, :metadata, %{})
    }
  end

  @doc "Normalize raw stats into the display shape used by stat_cards."
  @spec show_stats(map() | nil) :: map()
  def show_stats(nil) do
    %{
      total_proposals: 0,
      active_councils: 0,
      approved_count: 0,
      rejected_count: 0,
      consultation_count: 0
    }
  end

  def show_stats(stats) when is_map(stats) do
    %{
      total_proposals: Map.get(stats, :total_proposals, 0),
      active_councils: Map.get(stats, :active_councils, 0),
      approved_count: Map.get(stats, :approved_count, 0),
      rejected_count: Map.get(stats, :rejected_count, 0),
      consultation_count: Map.get(stats, :consultation_count, 0)
    }
  end

  # ===========================================================================
  # Pure Helpers (visible for testing and reuse)
  # ===========================================================================

  @doc "Format the proposal subtitle line: topic | mode | proposer"
  @spec format_proposal_subtitle(map()) :: String.t()
  def format_proposal_subtitle(proposal) do
    topic = Map.get(proposal, :topic, "—")
    mode = Map.get(proposal, :mode, "—")
    proposer = Map.get(proposal, :proposer, "—")
    "#{topic} | #{mode} | #{proposer}"
  end

  @doc "Format a confidence value as a percentage string (always integer-rounded)."
  @spec format_confidence(float() | integer() | nil) :: String.t()
  def format_confidence(val) when is_float(val), do: "#{round(val * 100)}%"
  def format_confidence(val) when is_integer(val), do: "#{val}%"
  def format_confidence(_), do: "0%"

  @doc "Format an event type atom for display: snake_case → 'snake case'."
  @spec format_event_type(atom() | String.t()) :: String.t()
  def format_event_type(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
  end

  @doc "Extract the human-readable question from a consultation."
  @spec consultation_question(map()) :: String.t()
  def consultation_question(consultation) do
    case get_in(consultation, [Access.key(:config, %{}), "question"]) do
      q when is_binary(q) and q != "" -> Helpers.truncate(q, 120)
      _ -> Map.get(consultation, :dataset) || "Unknown question"
    end
  end

  @doc "Format consultation subtitle: 'N perspectives | status'"
  @spec consultation_subtitle(map()) :: String.t()
  def consultation_subtitle(consultation) do
    perspectives = Map.get(consultation, :sample_count, 0)
    status = Map.get(consultation, :status, "unknown")
    "#{perspectives} perspectives | #{status}"
  end

  @doc "Pull results from a consultation, handling Ecto unloaded associations."
  @spec consultation_results(map()) :: list()
  def consultation_results(consultation) do
    case Map.get(consultation, :results) do
      %Ecto.Association.NotLoaded{} -> []
      results when is_list(results) -> results
      _ -> []
    end
  end

  @doc "Look up a perspective icon from a string name (defends against bad atoms)."
  @spec perspective_icon_from_string(String.t() | atom() | nil) :: String.t()
  def perspective_icon_from_string(name) when is_atom(name) do
    Icons.perspective_icon(name)
  end

  def perspective_icon_from_string(name) when is_binary(name) do
    atom =
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError -> nil
      end

    if atom, do: Icons.perspective_icon(atom), else: "🔍"
  end

  def perspective_icon_from_string(_), do: "🔍"

  @doc "Extract the vote from a consultation result."
  @spec result_vote(map()) :: String.t()
  def result_vote(result) do
    get_in(result, [Access.key(:scores, %{}), "vote"]) || "unknown"
  end

  @doc "Format the confidence from a consultation result."
  @spec result_confidence(map()) :: String.t()
  def result_confidence(result) do
    case get_in(result, [Access.key(:scores, %{}), "confidence"]) do
      val when is_float(val) -> format_confidence(val)
      val when is_integer(val) -> "#{val}%"
      _ -> "0%"
    end
  end

  @doc "Extract the model name from a consultation result's metadata."
  @spec result_model(map()) :: String.t()
  def result_model(result) do
    get_in(result, [Access.key(:metadata, %{}), "model"]) || ""
  end

  @doc "Extract the cost (rounded to 4 decimals) from a consultation result."
  @spec result_cost(map()) :: float() | nil
  def result_cost(result) do
    case get_in(result, [Access.key(:metadata, %{}), "cost"]) do
      cost when is_number(cost) and cost > 0 -> Float.round(cost * 1.0, 4)
      _ -> nil
    end
  end

  @doc "Extract the concerns list from a consultation result."
  @spec result_concerns(map()) :: list()
  def result_concerns(result) do
    case get_in(result, [Access.key(:metadata, %{}), "concerns"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Extract the recommendations list from a consultation result."
  @spec result_recommendations(map()) :: list()
  def result_recommendations(result) do
    case get_in(result, [Access.key(:metadata, %{}), "recommendations"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Determine the resource URI for an approval proposal.

  Falls back to the description if no resource_uri is in the metadata.
  """
  @spec approval_resource(map()) :: String.t()
  def approval_resource(proposal) do
    case Map.get(proposal, :metadata) do
      %{resource_uri: uri} when is_binary(uri) -> uri
      _ -> Map.get(proposal, :description, "")
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp format_relative(nil), do: nil
  defp format_relative(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_relative(_), do: nil
end
