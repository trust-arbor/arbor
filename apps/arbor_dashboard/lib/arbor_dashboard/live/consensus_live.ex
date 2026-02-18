defmodule Arbor.Dashboard.Live.ConsensusLive do
  @moduledoc """
  Council deliberation dashboard.

  Shows proposals, evaluator perspectives, votes, decisions,
  and advisory council consultations from the Arbor consensus system.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components

  alias Arbor.Consensus.TopicRegistry
  alias Arbor.Web.{Helpers, Icons}

  @impl true
  def mount(_params, _session, socket) do
    {proposals, decisions, stats, topics} = safe_load_all()
    consultations = safe_consultations()

    socket =
      socket
      |> assign(
        page_title: "Consensus",
        stats: stats,
        topics: topics,
        selected_proposal: nil,
        selected_decision: nil,
        selected_events: [],
        selected_consultation: nil,
        status_filter: :all,
        tab: :proposals
      )
      |> stream(:proposals, proposals)
      |> stream(:decisions, decisions)
      |> stream(:consultations, consultations)

    socket = subscribe_signals(socket, "consensus.*", &reload_consensus/1)

    {:ok, socket}
  end

  defp reload_consensus(socket) do
    {proposals, decisions, stats, topics} = safe_load_all()
    consultations = safe_consultations()

    socket
    |> assign(stats: stats, topics: topics)
    |> stream(:proposals, proposals, reset: true)
    |> stream(:decisions, decisions, reset: true)
    |> stream(:consultations, consultations, reset: true)
  end

  @impl true
  def handle_event("select-tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("filter-status", %{"status" => "all"}, socket) do
    proposals = safe_proposals()

    socket =
      socket
      |> assign(:status_filter, :all)
      |> stream(:proposals, proposals, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-status", %{"status" => status}, socket) do
    status_atom = String.to_existing_atom(status)
    all = safe_proposals()
    filtered = Enum.filter(all, &(&1.status == status_atom))

    socket =
      socket
      |> assign(:status_filter, status_atom)
      |> stream(:proposals, filtered, reset: true)

    {:noreply, socket}
  end

  def handle_event("select-proposal", %{"id" => proposal_id}, socket) do
    proposal = safe_get_proposal(proposal_id)
    decision = safe_get_decision(proposal_id)
    events = safe_events_for(proposal_id)

    socket =
      socket
      |> assign(:selected_proposal, proposal)
      |> assign(:selected_decision, decision)
      |> assign(:selected_events, events)

    {:noreply, socket}
  end

  def handle_event("select-consultation", %{"id" => run_id}, socket) do
    consultation = safe_get_consultation(run_id)
    {:noreply, assign(socket, :selected_consultation, consultation)}
  end

  def handle_event("close-detail", _params, socket) do
    socket =
      socket
      |> assign(:selected_proposal, nil)
      |> assign(:selected_decision, nil)
      |> assign(:selected_events, [])
      |> assign(:selected_consultation, nil)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Consensus" subtitle="Council deliberation and decisions">
      <:actions>
        <button
          phx-click="select-tab"
          phx-value-tab="proposals"
          class={"aw-btn #{if @tab == :proposals, do: "aw-btn-primary", else: "aw-btn-default"}"}
        >
          Proposals
        </button>
        <button
          phx-click="select-tab"
          phx-value-tab="decisions"
          class={"aw-btn #{if @tab == :decisions, do: "aw-btn-primary", else: "aw-btn-default"}"}
        >
          Decisions
        </button>
        <button
          phx-click="select-tab"
          phx-value-tab="consultations"
          class={"aw-btn #{if @tab == :consultations, do: "aw-btn-primary", else: "aw-btn-default"}"}
        >
          Consultations
        </button>
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@stats.total_proposals} label="Total proposals" color={:blue} />
      <.stat_card value={@stats.active_councils} label="Active councils" color={:purple} />
      <.stat_card value={@stats.approved_count} label="Approved" color={:green} />
      <.stat_card value={@stats.rejected_count} label="Rejected" color={:error} />
      <.stat_card value={@stats.consultation_count} label="Consultations" color={:blue} />
    </div>

    <%!-- Use display:none instead of :if for stream containers — streams inside
         :if blocks lose their items when the container isn't in the DOM at mount time --%>
    <div style={if @tab != :proposals, do: "display: none;"}>
      <.filter_bar>
        <button
          :for={status <- [:all, :pending, :evaluating, :approved, :rejected]}
          phx-click="filter-status"
          phx-value-status={status}
          class={"aw-filter-btn #{if @status_filter == status, do: "aw-filter-active"}"}
        >
          {status_label(status)}
        </button>
      </.filter_bar>

      <div id="proposals-stream" phx-update="stream" style="margin-top: 1rem;">
        <div
          :for={{dom_id, proposal} <- @streams.proposals}
          id={dom_id}
          phx-click="select-proposal"
          phx-value-id={proposal.id}
          style="cursor: pointer;"
        >
          <.event_card
            icon={Icons.status_icon(proposal.status)}
            title={Helpers.truncate(proposal.description, 80)}
            subtitle={format_proposal_subtitle(proposal)}
            timestamp={Helpers.format_relative_time(proposal.created_at)}
          />
        </div>
      </div>

      <div :if={@stats.total_proposals == 0} style="margin-top: 1rem;">
        <.empty_state
          icon="🗳"
          title="No proposals yet"
          hint="Proposals will appear here when submitted to the consensus system."
        />
      </div>
    </div>

    <div style={if @tab != :decisions, do: "display: none;"}>
      <div id="decisions-stream" phx-update="stream" style="margin-top: 1rem;">
        <div
          :for={{dom_id, decision} <- @streams.decisions}
          id={dom_id}
          phx-click="select-proposal"
          phx-value-id={decision.proposal_id}
          style="cursor: pointer;"
        >
          <.event_card
            icon={decision_icon(decision.decision)}
            title={decision_title(decision)}
            subtitle={decision_subtitle(decision)}
            timestamp={Helpers.format_relative_time(decision.decided_at)}
          />
        </div>
      </div>

      <div :if={@stats.approved_count + @stats.rejected_count == 0} style="margin-top: 1rem;">
        <.empty_state
          icon="📋"
          title="No decisions yet"
          hint="Decisions will appear here after proposals are evaluated."
        />
      </div>
    </div>

    <div style={if @tab != :consultations, do: "display: none;"}>
      <div id="consultations-stream" phx-update="stream" style="margin-top: 1rem;">
        <div
          :for={{dom_id, consultation} <- @streams.consultations}
          id={dom_id}
          phx-click="select-consultation"
          phx-value-id={consultation.id}
          style="cursor: pointer;"
        >
          <.event_card
            icon="🔮"
            title={consultation_question(consultation)}
            subtitle={consultation_subtitle(consultation)}
            timestamp={Helpers.format_relative_time(consultation.inserted_at)}
          />
        </div>
      </div>

      <div :if={@stats.consultation_count == 0} style="margin-top: 1rem;">
        <.empty_state
          icon="🔮"
          title="No consultations yet"
          hint="Advisory council consultations will appear here after running Consult.ask/3."
        />
      </div>
    </div>

    <.modal
      :if={@selected_proposal}
      id="proposal-detail"
      show={@selected_proposal != nil}
      title={"Proposal: #{Helpers.truncate(@selected_proposal.description, 60)}"}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div class="aw-proposal-detail">
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin-bottom: 1rem;">
          <div>
            <strong>ID:</strong>
            <code style="font-size: 0.85em; word-break: break-all;">{@selected_proposal.id}</code>
          </div>
          <div>
            <strong>Status:</strong>
            <.badge
              label={to_string(@selected_proposal.status)}
              color={status_color(@selected_proposal.status)}
            />
          </div>
          <div>
            <strong>Topic:</strong>
            <span>{@selected_proposal.topic}</span>
          </div>
          <div>
            <strong>Mode:</strong>
            <span>{@selected_proposal.mode}</span>
          </div>
          <div>
            <strong>Proposer:</strong>
            <span>{@selected_proposal.proposer}</span>
          </div>
          <div>
            <strong>Created:</strong>
            <span>{Helpers.format_timestamp(@selected_proposal.created_at)}</span>
          </div>
        </div>

        <div style="margin-top: 1rem;">
          <strong>Description:</strong>
          <p style="margin-top: 0.5rem; color: var(--aw-text-muted, #888);">
            {@selected_proposal.description}
          </p>
        </div>

        <div :if={@selected_decision} style="margin-top: 1.5rem;">
          <h4 style="margin-bottom: 0.75rem;">Decision</h4>
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 0.5rem; margin-bottom: 1rem;">
            <.stat_card value={@selected_decision.approve_count} label="Approve" color={:green} />
            <.stat_card value={@selected_decision.reject_count} label="Reject" color={:error} />
            <.stat_card value={@selected_decision.abstain_count} label="Abstain" color={:gray} />
            <.stat_card
              value={format_confidence(@selected_decision.average_confidence)}
              label="Confidence"
              color={:blue}
            />
          </div>

          <div :if={@selected_decision.evaluations != []} style="margin-top: 1rem;">
            <h4 style="margin-bottom: 0.75rem;">Evaluations</h4>
            <div
              :for={eval <- @selected_decision.evaluations}
              style="border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.75rem; margin-bottom: 0.5rem;"
            >
              <div style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.5rem;">
                <span>{Icons.perspective_icon(eval.perspective)}</span>
                <strong>{eval.perspective}</strong>
                <.badge label={to_string(eval.vote)} color={vote_color(eval.vote)} />
                <span style="margin-left: auto; color: var(--aw-text-muted, #888); font-size: 0.85em;">
                  confidence: {format_confidence(eval.confidence)}
                </span>
              </div>
              <p style="font-size: 0.9em; color: var(--aw-text-muted, #888);">{eval.reasoning}</p>
              <div :if={eval.concerns != []} style="margin-top: 0.5rem; font-size: 0.85em;">
                <strong>Concerns:</strong>
                <span>{Enum.join(eval.concerns, ", ")}</span>
              </div>
            </div>
          </div>
        </div>

        <div :if={@selected_events != []} style="margin-top: 1.5rem;">
          <h4 style="margin-bottom: 0.75rem;">Timeline</h4>
          <div
            :for={event <- @selected_events}
            style="display: flex; gap: 0.5rem; padding: 0.25rem 0; font-size: 0.85em;"
          >
            <span style="color: var(--aw-text-muted, #888); white-space: nowrap;">
              {Helpers.format_timestamp(event.timestamp)}
            </span>
            <.badge label={format_event_type(event.event_type)} color={:gray} />
            <span :if={event.perspective} style="color: var(--aw-text-muted, #888);">
              {event.perspective}
            </span>
          </div>
        </div>
      </div>
    </.modal>

    <.modal
      :if={@selected_consultation}
      id="consultation-detail"
      show={@selected_consultation != nil}
      title={"Consultation: #{Helpers.truncate(consultation_question(@selected_consultation), 60)}"}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div class="aw-consultation-detail">
        <div style="margin-bottom: 1rem;">
          <strong>Question:</strong>
          <p style="margin-top: 0.5rem; color: var(--aw-text-muted, #888);">
            {consultation_question(@selected_consultation)}
          </p>
        </div>

        <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 0.75rem; margin-bottom: 1rem;">
          <div>
            <strong>Perspectives:</strong>
            <span>{@selected_consultation.sample_count || 0}</span>
          </div>
          <div>
            <strong>Status:</strong>
            <.badge
              label={@selected_consultation.status || "unknown"}
              color={consultation_status_color(@selected_consultation.status)}
            />
          </div>
          <div>
            <strong>Created:</strong>
            <span>{Helpers.format_timestamp(@selected_consultation.inserted_at)}</span>
          </div>
        </div>

        <div :if={consultation_results(@selected_consultation) != []} style="margin-top: 1rem;">
          <h4 style="margin-bottom: 0.75rem;">Perspective Results</h4>
          <div
            :for={result <- consultation_results(@selected_consultation)}
            style="border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.75rem; margin-bottom: 0.5rem;"
          >
            <div style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.5rem;">
              <span>{perspective_icon_from_string(result.sample_id)}</span>
              <strong>{result.sample_id}</strong>
              <.badge
                label={result_vote(result)}
                color={vote_color_from_string(result_vote(result))}
              />
              <span style="margin-left: auto; color: var(--aw-text-muted, #888); font-size: 0.85em;">
                confidence: {result_confidence(result)}
              </span>
            </div>

            <div style="display: flex; gap: 1rem; font-size: 0.85em; color: var(--aw-text-muted, #888); margin-bottom: 0.5rem;">
              <span :if={result_model(result) != ""}>
                {result_model(result)}
              </span>
              <span :if={result_cost(result)}>
                ${result_cost(result)}
              </span>
              <span :if={result.duration_ms && result.duration_ms > 0}>
                {Float.round(result.duration_ms / 1000, 1)}s
              </span>
            </div>

            <details style="margin-top: 0.5rem;">
              <summary style="cursor: pointer; font-size: 0.9em; color: var(--aw-text-muted, #888);">
                Reasoning
              </summary>
              <p style="font-size: 0.85em; color: var(--aw-text-muted, #888); margin-top: 0.5rem; white-space: pre-wrap; max-height: 300px; overflow-y: auto;">
                {Helpers.truncate(result.actual || "", 2000)}
              </p>
            </details>

            <div :if={result_concerns(result) != []} style="margin-top: 0.5rem; font-size: 0.85em;">
              <strong>Concerns:</strong>
              <ul style="margin: 0.25rem 0 0 1rem; padding: 0;">
                <li :for={concern <- result_concerns(result)}>{concern}</li>
              </ul>
            </div>

            <div
              :if={result_recommendations(result) != []}
              style="margin-top: 0.5rem; font-size: 0.85em;"
            >
              <strong>Recommendations:</strong>
              <ul style="margin: 0.25rem 0 0 1rem; padding: 0;">
                <li :for={rec <- result_recommendations(result)}>{rec}</li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </.modal>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp status_label(:all), do: "All"
  defp status_label(status), do: status |> to_string() |> String.capitalize()

  defp status_color(:approved), do: :green
  defp status_color(:rejected), do: :error
  defp status_color(:evaluating), do: :blue
  defp status_color(:pending), do: :gray
  defp status_color(:deadlock), do: :purple
  defp status_color(_), do: :gray

  defp vote_color(:approve), do: :green
  defp vote_color(:reject), do: :error
  defp vote_color(:abstain), do: :gray
  defp vote_color(_), do: :gray

  defp vote_color_from_string("approve"), do: :green
  defp vote_color_from_string("reject"), do: :error
  defp vote_color_from_string("abstain"), do: :gray
  defp vote_color_from_string(_), do: :gray

  defp consultation_status_color("completed"), do: :green
  defp consultation_status_color("running"), do: :blue
  defp consultation_status_color("failed"), do: :error
  defp consultation_status_color(_), do: :gray

  defp decision_icon(:approved), do: "✅"
  defp decision_icon(:rejected), do: "❌"
  defp decision_icon(:deadlock), do: "⚖️"
  defp decision_icon(_), do: "📋"

  defp decision_title(decision) do
    "#{decision.decision} (#{decision.approve_count}/#{decision.reject_count}/#{decision.abstain_count})"
  end

  defp decision_subtitle(decision) do
    quorum = if decision.quorum_met, do: "quorum met", else: "no quorum"
    "#{quorum}, confidence: #{format_confidence(decision.average_confidence)}"
  end

  defp format_proposal_subtitle(proposal) do
    "#{proposal.topic} | #{proposal.mode} | #{proposal.proposer}"
  end

  defp format_confidence(val) when is_float(val), do: "#{Float.round(val * 100, 0)}%"
  defp format_confidence(_), do: "0%"

  defp format_event_type(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
  end

  # ── Consultation helpers ───────────────────────────────────────────

  defp consultation_question(consultation) do
    case get_in(consultation, [Access.key(:config, %{}), "question"]) do
      q when is_binary(q) and q != "" -> Helpers.truncate(q, 120)
      _ -> consultation.dataset || "Unknown question"
    end
  end

  defp consultation_subtitle(consultation) do
    perspectives = consultation.sample_count || 0
    status = consultation.status || "unknown"
    "#{perspectives} perspectives | #{status}"
  end

  defp consultation_results(consultation) do
    case Map.get(consultation, :results) do
      %Ecto.Association.NotLoaded{} -> []
      results when is_list(results) -> results
      _ -> []
    end
  end

  defp perspective_icon_from_string(name) when is_binary(name) do
    atom =
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError -> nil
      end

    if atom, do: Icons.perspective_icon(atom), else: "🔍"
  end

  defp perspective_icon_from_string(_), do: "🔍"

  defp result_vote(result) do
    get_in(result, [Access.key(:scores, %{}), "vote"]) || "unknown"
  end

  defp result_confidence(result) do
    case get_in(result, [Access.key(:scores, %{}), "confidence"]) do
      val when is_float(val) -> format_confidence(val)
      val when is_integer(val) -> "#{val}%"
      _ -> "0%"
    end
  end

  defp result_model(result) do
    get_in(result, [Access.key(:metadata, %{}), "model"]) || ""
  end

  defp result_cost(result) do
    case get_in(result, [Access.key(:metadata, %{}), "cost"]) do
      cost when is_number(cost) and cost > 0 -> Float.round(cost * 1.0, 4)
      _ -> nil
    end
  end

  defp result_concerns(result) do
    case get_in(result, [Access.key(:metadata, %{}), "concerns"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp result_recommendations(result) do
    case get_in(result, [Access.key(:metadata, %{}), "recommendations"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # ── Safe API wrappers ───────────────────────────────────────────────

  defp safe_load_all do
    {safe_proposals(), safe_decisions(), safe_stats(), safe_topics()}
  end

  defp safe_proposals do
    Arbor.Consensus.list_proposals()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_decisions do
    Arbor.Consensus.recent_decisions(50)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_consultations do
    case Arbor.Consensus.list_consultations(limit: 50) do
      {:ok, consultations} -> consultations
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_stats do
    stats = Arbor.Consensus.stats()
    proposals = Map.get(stats, :proposals, %{})
    consultation_count = safe_consultation_count()

    %{
      total_proposals: Map.get(proposals, :total, 0),
      active_councils: Map.get(proposals, :evaluating, 0),
      approved_count: Map.get(proposals, :approved, 0),
      rejected_count: Map.get(proposals, :rejected, 0),
      consultation_count: consultation_count
    }
  rescue
    _ ->
      %{
        total_proposals: 0,
        active_councils: 0,
        approved_count: 0,
        rejected_count: 0,
        consultation_count: 0
      }
  catch
    :exit, _ ->
      %{
        total_proposals: 0,
        active_councils: 0,
        approved_count: 0,
        rejected_count: 0,
        consultation_count: 0
      }
  end

  defp safe_consultation_count do
    case Arbor.Consensus.list_consultations(limit: 1000) do
      {:ok, list} -> length(list)
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp safe_topics do
    TopicRegistry.list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_get_proposal(id) do
    case Arbor.Consensus.get_proposal(id) do
      {:ok, proposal} -> proposal
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_get_decision(proposal_id) do
    case Arbor.Consensus.get_decision(proposal_id) do
      {:ok, decision} -> decision
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_get_consultation(run_id) do
    case Arbor.Consensus.get_consultation(run_id) do
      {:ok, consultation} -> consultation
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_events_for(proposal_id) do
    Arbor.Consensus.events_for(proposal_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
