defmodule Arbor.Dashboard.Live.ConsensusLive do
  @moduledoc """
  Council deliberation dashboard.

  Shows proposals, evaluator perspectives, votes, and decisions
  from the Arbor consensus system.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Consensus.TopicRegistry
  alias Arbor.Web.{Helpers, Icons}

  @impl true
  def mount(_params, _session, socket) do
    subscription_id =
      if connected?(socket) do
        safe_subscribe()
      end

    {proposals, decisions, stats, topics} = safe_load_all()

    socket =
      socket
      |> assign(
        page_title: "Consensus",
        stats: stats,
        topics: topics,
        selected_proposal: nil,
        selected_decision: nil,
        selected_events: [],
        status_filter: :all,
        tab: :proposals,
        subscription_id: subscription_id
      )
      |> stream(:proposals, proposals)
      |> stream(:decisions, decisions)

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if sub_id = socket.assigns[:subscription_id] do
      try do
        Arbor.Signals.unsubscribe(sub_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  @impl true
  def handle_info({:signal_received, signal}, socket) do
    case signal.type do
      type when type in ~w(evaluation_completed decision_rendered advice_rendered)a ->
        {proposals, decisions, stats, _topics} = safe_load_all()

        socket =
          socket
          |> assign(:stats, stats)
          |> stream(:proposals, proposals, reset: true)
          |> stream(:decisions, decisions, reset: true)

        {:noreply, socket}

      type when type in ~w(topic_registered topic_removed)a ->
        {:noreply, assign(socket, :topics, safe_topics())}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  def handle_event("close-detail", _params, socket) do
    socket =
      socket
      |> assign(:selected_proposal, nil)
      |> assign(:selected_decision, nil)
      |> assign(:selected_events, [])

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
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@stats.total_proposals} label="Total proposals" color={:blue} />
      <.stat_card value={@stats.active_councils} label="Active councils" color={:purple} />
      <.stat_card value={@stats.approved_count} label="Approved" color={:green} />
      <.stat_card value={@stats.rejected_count} label="Rejected" color={:error} />
    </div>

    <div :if={@tab == :proposals}>
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

    <div :if={@tab == :decisions}>
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

  defp safe_stats do
    stats = Arbor.Consensus.stats()
    proposals = Map.get(stats, :proposals, %{})

    %{
      total_proposals: Map.get(proposals, :total, 0),
      active_councils: Map.get(proposals, :evaluating, 0),
      approved_count: Map.get(proposals, :approved, 0),
      rejected_count: Map.get(proposals, :rejected, 0)
    }
  rescue
    _ -> %{total_proposals: 0, active_councils: 0, approved_count: 0, rejected_count: 0}
  catch
    :exit, _ -> %{total_proposals: 0, active_councils: 0, approved_count: 0, rejected_count: 0}
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

  defp safe_events_for(proposal_id) do
    Arbor.Consensus.events_for(proposal_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_subscribe do
    pid = self()

    case Arbor.Signals.subscribe("consensus.*", fn signal ->
           send(pid, {:signal_received, signal})
           :ok
         end) do
      {:ok, id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
