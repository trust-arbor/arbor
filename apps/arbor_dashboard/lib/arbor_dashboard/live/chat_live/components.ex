defmodule Arbor.Dashboard.Live.ChatLive.Components do
  @moduledoc """
  Function components for the ChatLive view.

  Extracted from the monolithic render/1 to keep each panel section
  in a focused, testable component.
  """

  use Phoenix.Component

  import Arbor.Web.Components
  import Arbor.Web.Helpers, only: [format_token_count: 1, format_duration: 1, stream_empty?: 1]

  alias Arbor.Dashboard.Live.ChatLive.Helpers, as: H
  alias Arbor.Web.Helpers, as: WebHelpers

  # ── Stats Bar ──────────────────────────────────────────────────────

  @doc "Top-level status badges showing agent state, memory, queries, etc."
  def stats_bar(assigns) do
    ~H"""
    <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; padding: 0.4rem 0.75rem; margin-top: 0.5rem; border: 1px solid var(--aw-border, #333); border-radius: 6px; font-size: 0.85em;">
      <.badge :if={@agent} label={"Agent: #{@display_name || @agent_id}"} color={:green} />
      <.badge :if={!@agent} label="No Agent" color={:gray} />
      <.badge
        :if={@session_id}
        label={"Session: #{String.slice(@session_id || "", 0..7)}..."}
        color={:blue}
      />
      <.badge :if={@memory_stats && @memory_stats[:enabled]} label="Memory: ON" color={:purple} />
      <.badge :if={@memory_stats && !@memory_stats[:enabled]} label="Memory: OFF" color={:gray} />
      <.badge label={"Queries: #{@query_count}"} color={:blue} />
      <.badge
        :if={@memory_stats && @memory_stats[:enabled]}
        label={"Index: #{get_in(@memory_stats, [:index, :count]) || 0}"}
        color={:purple}
      />
      <.badge
        :if={@memory_stats && @memory_stats[:enabled]}
        label={"Knowledge: #{get_in(@memory_stats, [:knowledge, :node_count]) || 0}"}
        color={:green}
      />
      <.badge
        :if={@heartbeat_count > 0}
        label={"Heartbeats: #{@heartbeat_count}"}
        color={:yellow}
      />
      <.badge
        :if={@llm_call_count > 0}
        label={"LLM Calls: #{@llm_call_count}"}
        color={:blue}
      />
      <.badge
        :if={@memory_notes_total > 0}
        label={"Notes: #{@memory_notes_total}"}
        color={:purple}
      />
      <.badge
        :if={@last_llm_mode}
        label={"Mode: #{@last_llm_mode}"}
        color={:yellow}
      />
    </div>
    """
  end

  # ── Token Counter Bar ──────────────────────────────────────────────

  @doc "Token usage display for chat and heartbeat."
  def token_bar(assigns) do
    ~H"""
    <div
      :if={@agent && (@llm_call_count > 0 or @heartbeat_count > 0)}
      style="display: flex; justify-content: space-between; padding: 0.4rem 0.75rem; margin-top: 0.35rem; border: 1px solid rgba(74, 158, 255, 0.3); border-radius: 6px; font-size: 0.8em; background: rgba(74, 158, 255, 0.05);"
    >
      <%!-- Chat tokens (left) --%>
      <div :if={@llm_call_count > 0} style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
        <span style="color: #94a3b8; font-weight: 600;">CHAT</span>
        <span style="color: #4a9eff;">
          IN: <strong>{format_token_count(@input_tokens)}</strong>
        </span>
        <span style="color: #22c55e;">
          OUT: <strong>{format_token_count(@output_tokens)}</strong>
        </span>
        <span :if={@cached_tokens > 0} style="color: #a855f7;">
          CACHED: <strong>{format_token_count(@cached_tokens)}</strong>
        </span>
        <span style="color: #e2e8f0;">
          TOTAL: <strong>{format_token_count(@input_tokens + @output_tokens)}</strong>
        </span>
        <span style="color: #4a9eff;">
          CALLS: <strong>{@llm_call_count}</strong>
        </span>
        <span :if={@last_duration_ms} style="color: #eab308;">
          LAST: <strong>{format_duration(@last_duration_ms)}</strong>
        </span>
      </div>
      <%!-- Heartbeat tokens (right) --%>
      <div :if={@heartbeat_count > 0} style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
        <span style="color: #f97316; font-weight: 600;">HB</span>
        <span style="color: #4a9eff;">
          IN: <strong>{format_token_count(@hb_input_tokens)}</strong>
        </span>
        <span style="color: #22c55e;">
          OUT: <strong>{format_token_count(@hb_output_tokens)}</strong>
        </span>
        <span :if={@hb_cached_tokens > 0} style="color: #a855f7;">
          CACHED: <strong>{format_token_count(@hb_cached_tokens)}</strong>
        </span>
        <span style="color: #e2e8f0;">
          TOTAL: <strong>{format_token_count(@hb_input_tokens + @hb_output_tokens)}</strong>
        </span>
        <span style="color: #f97316;">
          BEATS: <strong>{@heartbeat_count}</strong>
        </span>
      </div>
    </div>
    """
  end

  # ── Left Panel: Signals ────────────────────────────────────────────

  @doc "Signal stream panel."
  def signals_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; flex: 1; min-height: 0;">
      <div style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); display: flex; justify-content: space-between; align-items: center; flex-shrink: 0;">
        <strong style="font-size: 0.85em;">📡 Signals</strong>
        <span style="color: #22c55e; font-size: 0.7em;">● LIVE</span>
      </div>
      <div
        id="signals-container"
        phx-update="stream"
        style="flex: 1; overflow-y: auto; padding: 0.4rem; min-height: 0;"
      >
        <div
          :for={{dom_id, sig} <- @streams.signals}
          id={dom_id}
          style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(74, 255, 158, 0.1); font-size: 0.8em;"
        >
          <div style="display: flex; align-items: center; gap: 0.25rem;">
            <span>{H.signal_icon(sig.category)}</span>
            <span style="font-weight: 500; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
              {sig.event}
            </span>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.75em; flex-shrink: 0;">
              {H.format_time(sig.timestamp)}
            </span>
          </div>
        </div>
      </div>
      <div style="padding: 0.4rem; text-align: center; flex-shrink: 0;">
        <.empty_state
          :if={stream_empty?(@streams.signals)}
          icon="📡"
          title="Waiting for signals..."
          hint=""
        />
      </div>
    </div>
    """
  end

  # ── Left Panel: Actions ────────────────────────────────────────────

  @doc "Actions panel with collapsible tool call details."
  def actions_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-actions"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">⚡ Actions</strong>
        <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
          {if @show_actions, do: "▼", else: "▶"}
        </span>
      </div>
      <div
        :if={@show_actions}
        id="actions-container"
        phx-update="stream"
        style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
      >
        <details
          :for={{dom_id, action} <- @streams.actions}
          id={dom_id}
          style={"margin-bottom: 0.35rem; border-radius: 4px; font-size: 0.8em; " <> H.action_style(action.outcome)}
        >
          <summary style="padding: 0.35rem; cursor: pointer; list-style: none; user-select: none;">
            <div style="display: flex; align-items: center; gap: 0.25rem;">
              <span style={"padding: 0.1rem 0.3rem; border-radius: 3px; font-size: 0.85em; font-weight: 600; " <> H.tool_badge_style(action.name)}>
                {action.name}
              </span>
              <span style="color: var(--aw-text-muted, #888); font-size: 0.85em; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                {H.action_input_summary(action)}
              </span>
              <.badge label={to_string(action.outcome)} color={H.outcome_color(action.outcome)} />
            </div>
          </summary>
          <div style="padding: 0.35rem; border-top: 1px solid var(--aw-border, #333);">
            <div style="margin-bottom: 0.3rem;">
              <strong style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                Input:
              </strong>
              <pre style="margin: 0.2rem 0; padding: 0.3rem; background: rgba(0,0,0,0.3); border-radius: 3px; overflow-x: auto; white-space: pre-wrap; font-size: 0.85em; max-height: 15vh; overflow-y: auto;">{H.format_tool_input(action.input)}</pre>
            </div>
            <div :if={action[:result]}>
              <strong style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                Result:
              </strong>
              <pre style="margin: 0.2rem 0; padding: 0.3rem; background: rgba(0,0,0,0.3); border-radius: 3px; overflow-x: auto; white-space: pre-wrap; font-size: 0.85em; max-height: 15vh; overflow-y: auto;">{H.format_tool_result(action.result)}</pre>
            </div>
          </div>
        </details>
      </div>
      <div :if={@show_actions} style="padding: 0.4rem; text-align: center;">
        <.empty_state
          :if={stream_empty?(@streams.actions)}
          icon="⚡"
          title="No actions yet"
          hint=""
        />
      </div>
    </div>
    """
  end

  # ── Left Panel: Heartbeat LLM ──────────────────────────────────────

  @doc "LLM heartbeat interaction panel."
  def heartbeat_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-llm-panel"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">🔄 Heartbeat LLM</strong>
        <div style="display: flex; align-items: center; gap: 0.5rem;">
          <.badge :if={@llm_call_count > 0} label={"#{@llm_call_count}"} color={:blue} />
          <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
            {if @show_llm_panel, do: "▼", else: "▶"}
          </span>
        </div>
      </div>
      <div :if={@show_llm_panel} style="flex: 1; overflow-y: auto; min-height: 0;">
        <%!-- Last heartbeat thinking --%>
        <div
          :if={@last_llm_thinking}
          style="padding: 0.4rem; border-bottom: 1px solid var(--aw-border, #333);"
        >
          <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem;">
            Last heartbeat ({@last_llm_mode || "unknown"} mode):
          </div>
          <p style="color: var(--aw-text, #ccc); font-size: 0.8em; white-space: pre-wrap; margin: 0;">
            {WebHelpers.truncate(@last_llm_thinking, 500)}
          </p>
        </div>
        <%!-- LLM interaction stream --%>
        <div
          id="llm-interactions-container"
          phx-update="stream"
          style="padding: 0.4rem;"
        >
          <div
            :for={{dom_id, interaction} <- @streams.llm_interactions}
            id={dom_id}
            style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(74, 158, 255, 0.05); font-size: 0.8em;"
          >
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.2rem;">
              <.badge label={to_string(interaction.mode)} color={:yellow} />
              <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
                {H.format_time(interaction.timestamp)}
              </span>
            </div>
            <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
              {WebHelpers.truncate(interaction.thinking, 250)}
            </p>
            <div
              :if={interaction.actions > 0 || interaction.notes > 0}
              style="margin-top: 0.2rem; display: flex; gap: 0.25rem;"
            >
              <.badge
                :if={interaction.actions > 0}
                label={"#{interaction.actions} actions"}
                color={:green}
              />
              <.badge
                :if={interaction.notes > 0}
                label={"#{interaction.notes} notes"}
                color={:purple}
              />
            </div>
          </div>
        </div>
        <div style="padding: 0.4rem; text-align: center;">
          <.empty_state
            :if={stream_empty?(@streams.llm_interactions)}
            icon="🔄"
            title="No LLM heartbeats yet"
            hint="LLM calls happen during heartbeat cycles"
          />
        </div>
      </div>
    </div>
    """
  end

  # ── Left Panel: Code Modules ───────────────────────────────────────

  @doc "Code modules panel."
  def code_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-code"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">💻 Code</strong>
        <div style="display: flex; align-items: center; gap: 0.5rem;">
          <.badge :if={@code_modules != []} label={"#{length(@code_modules)}"} color={:green} />
          <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
            {if @show_code, do: "▼", else: "▶"}
          </span>
        </div>
      </div>
      <div :if={@show_code} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
        <div
          :for={mod <- @code_modules}
          style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(34, 197, 94, 0.1); font-size: 0.8em;"
        >
          <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.15rem;">
            <span style="font-weight: 500;">{mod[:name] || "unnamed"}</span>
            <.badge
              :if={mod[:sandbox_level]}
              label={to_string(mod[:sandbox_level])}
              color={:yellow}
            />
          </div>
          <span :if={mod[:purpose]} style="color: var(--aw-text-muted, #888); font-size: 0.9em;">
            {WebHelpers.truncate(mod[:purpose], 100)}
          </span>
        </div>
        <.empty_state
          :if={@code_modules == []}
          icon="💻"
          title="No code modules"
          hint="Code appears when the agent creates modules"
        />
      </div>
    </div>
    """
  end

  # ── Left Panel: Proposals ──────────────────────────────────────────

  @doc "Proposals panel with accept/reject/defer actions."
  def proposals_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-proposals"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">📋 Proposals</strong>
        <div style="display: flex; align-items: center; gap: 0.5rem;">
          <.badge :if={@proposals != []} label={"#{length(@proposals)}"} color={:yellow} />
          <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
            {if @show_proposals, do: "▼", else: "▶"}
          </span>
        </div>
      </div>
      <div
        :if={@show_proposals}
        style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
      >
        <div
          :for={proposal <- @proposals}
          style="margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.8em;"
        >
          <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.2rem;">
            <.badge
              :if={Map.get(proposal, :type)}
              label={to_string(Map.get(proposal, :type))}
              color={:yellow}
            />
            <.badge
              :if={Map.get(proposal, :confidence)}
              label={"#{round(Map.get(proposal, :confidence) * 100)}%"}
              color={:blue}
            />
          </div>
          <p style="color: var(--aw-text-muted, #888); margin: 0 0 0.3rem 0; white-space: pre-wrap;">
            {WebHelpers.truncate(
              Map.get(proposal, :content) || Map.get(proposal, :description) || "",
              200
            )}
          </p>
          <div style="display: flex; gap: 0.3rem;">
            <button
              phx-click="accept-proposal"
              phx-value-id={Map.get(proposal, :id)}
              style="padding: 0.2rem 0.5rem; border: none; border-radius: 3px; background: #22c55e; color: white; cursor: pointer; font-size: 0.8em;"
            >
              Accept
            </button>
            <button
              phx-click="reject-proposal"
              phx-value-id={Map.get(proposal, :id)}
              style="padding: 0.2rem 0.5rem; border: none; border-radius: 3px; background: #ff4a4a; color: white; cursor: pointer; font-size: 0.8em;"
            >
              Reject
            </button>
            <button
              phx-click="defer-proposal"
              phx-value-id={Map.get(proposal, :id)}
              style="padding: 0.2rem 0.5rem; border: none; border-radius: 3px; background: #888; color: white; cursor: pointer; font-size: 0.8em;"
            >
              Defer
            </button>
          </div>
        </div>
        <.empty_state
          :if={@proposals == []}
          icon="📋"
          title="No pending proposals"
          hint="Proposals appear from reflection & analysis"
        />
      </div>
    </div>
    """
  end

  # ── Center Panel: Chat ─────────────────────────────────────────────

  @doc "Main chat panel with agent controls, messages, and input."
  def chat_panel(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; min-height: 0;">
      <%!-- Agent controls --%>
      <.chat_controls
        agent={@agent}
        display_name={@display_name}
        available_models={@available_models}
        current_model={@current_model}
        chat_backend={@chat_backend}
        heartbeat_models={@heartbeat_models}
        selected_heartbeat_model={@selected_heartbeat_model}
        group_mode={@group_mode}
      />

      <%!-- Group participants list --%>
      <.group_participants_bar
        group_mode={@group_mode}
        group_participants={@group_participants}
      />

      <%!-- Messages --%>
      <div
        id="messages-container"
        phx-update="stream"
        style="flex: 1; overflow-y: auto; padding: 0.75rem; min-height: 0;"
      >
        <div
          :for={{dom_id, msg} <- @streams.messages}
          id={dom_id}
          style={"margin-bottom: 0.75rem; padding: 0.6rem; border-radius: 6px; " <> H.message_style(msg.role, msg[:sender_type], @group_mode)}
        >
          <div style="display: flex; justify-content: space-between; margin-bottom: 0.2rem;">
            <%!-- Group mode: show sender name with color/icon --%>
            <div
              :if={@group_mode && msg[:sender_name]}
              style="display: flex; align-items: center; gap: 0.4rem;"
            >
              <span>{if msg[:sender_type] == :agent, do: "🤖", else: "👤"}</span>
              <strong style={"font-size: 0.9em; color: " <> H.sender_color(msg[:sender_color])}>
                {msg.sender_name}
              </strong>
            </div>
            <%!-- Single-agent mode: show role label or agent display name --%>
            <strong :if={!@group_mode} style="font-size: 0.9em;">
              {if msg.role == :assistant && @display_name,
                do: @display_name,
                else: H.role_label(msg.role)}
            </strong>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {H.format_time(msg.timestamp)}
            </span>
          </div>
          <div :if={msg.content != ""} style="white-space: pre-wrap; font-size: 0.9em;">
            {msg.content}
          </div>
          <%!-- Tool use count (details in Actions panel) --%>
          <div
            :if={msg[:tool_uses] && msg[:tool_uses] != []}
            style="margin-top: 0.3rem;"
          >
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              ⚡ {length(msg.tool_uses)} tool call{if length(msg.tool_uses) != 1, do: "s", else: ""} — see Actions panel
            </span>
          </div>
          <div
            :if={msg[:model] || msg[:memory_count]}
            style="margin-top: 0.4rem; display: flex; gap: 0.5rem;"
          >
            <.badge :if={msg[:model]} label={to_string(msg.model)} color={:gray} />
            <.badge
              :if={msg[:memory_count] && msg[:memory_count] > 0}
              label={"#{msg.memory_count} memories"}
              color={:purple}
            />
          </div>
        </div>
      </div>

      <%!-- Loading indicator --%>
      <div
        :if={@loading}
        style="padding: 0.75rem; border-top: 1px solid var(--aw-border, #333); flex-shrink: 0;"
      >
        <span style="color: var(--aw-text-muted, #888);">🤔 Thinking...</span>
      </div>

      <%!-- Error display --%>
      <div
        :if={@error}
        style="padding: 0.5rem 0.75rem; background: rgba(255, 74, 74, 0.1); color: var(--aw-error, #ff4a4a); border-top: 1px solid var(--aw-error, #ff4a4a); flex-shrink: 0; font-size: 0.85em;"
      >
        {@error}
      </div>

      <%!-- Input area --%>
      <form
        phx-submit="send-message"
        phx-change="update-input"
        style="padding: 0.5rem 0.75rem; border-top: 1px solid var(--aw-border, #333); display: flex; gap: 0.5rem; flex-shrink: 0;"
      >
        <input
          type="text"
          name="message"
          value={@input}
          placeholder={if @agent, do: "Type a message...", else: "Start an agent first"}
          disabled={@agent == nil or @loading}
          style="flex: 1; padding: 0.4rem 0.6rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit; font-size: 0.9em;"
          autocomplete="off"
        />
        <button
          type="submit"
          disabled={@agent == nil or @loading or @input == ""}
          style={"padding: 0.4rem 0.75rem; border: none; border-radius: 4px; color: white; font-size: 0.9em; cursor: " <> if(@agent && !@loading, do: "pointer", else: "not-allowed") <> "; background: " <> if(@agent && !@loading, do: "var(--aw-accent, #4a9eff)", else: "var(--aw-text-muted, #888)") <> ";"}
        >
          Send
        </button>
      </form>
    </div>
    """
  end

  # ── Chat Controls (sub-component) ─────────────────────────────────

  defp chat_controls(assigns) do
    ~H"""
    <div style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); display: flex; align-items: center; gap: 0.75rem; flex-shrink: 0;">
      <div :if={@agent == nil}>
        <form phx-submit="start-agent" style="display: flex; gap: 0.5rem;">
          <select
            name="model"
            style="padding: 0.4rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit; font-size: 0.9em;"
          >
            <%= for model <- @available_models do %>
              <option value={model.id}>{model.label}</option>
            <% end %>
          </select>
          <button
            type="submit"
            style="padding: 0.4rem 0.75rem; background: var(--aw-accent, #4a9eff); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.9em;"
          >
            Start Agent
          </button>
        </form>
      </div>
      <div
        :if={@agent != nil}
        style="display: flex; align-items: center; gap: 0.5rem; width: 100%;"
      >
        <span style="color: var(--aw-text-muted, #888); font-size: 0.9em;">
          <%= if @current_model && @current_model[:label] do %>
            Chat with {@current_model.label} ({@current_model[:provider]})
          <% else %>
            Chat with {@display_name || "Agent"}
          <% end %>
        </span>
        <div style="flex: 1;"></div>
        <form
          :if={@chat_backend == :api and @heartbeat_models != []}
          phx-change="set-heartbeat-model"
          style="display: flex; align-items: center; gap: 0.3rem;"
        >
          <label style="color: var(--aw-text-muted, #888); font-size: 0.8em;">HB:</label>
          <select
            name="heartbeat_model"
            style="padding: 0.2rem 0.4rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit; font-size: 0.8em;"
          >
            <option value="">default</option>
            <%= for hb <- @heartbeat_models do %>
              <option
                value={hb.id}
                selected={@selected_heartbeat_model && @selected_heartbeat_model[:id] == hb.id}
              >
                {hb.label}
              </option>
            <% end %>
          </select>
        </form>
        <button
          phx-click="stop-agent"
          style="padding: 0.4rem 0.75rem; background: var(--aw-error, #ff4a4a); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.9em;"
        >
          Stop Agent
        </button>
      </div>
      <%!-- Group chat controls (outside agent-specific div) --%>
      <div style="display: flex; align-items: center; gap: 0.5rem; width: 100%; padding: 0 0.75rem;">
        <button
          :if={!@group_mode}
          phx-click="show-group-modal"
          style="padding: 0.4rem 0.75rem; background: var(--aw-success, #22c55e); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.9em;"
          title="Create multi-agent group chat"
        >
          👥 Group
        </button>
        <button
          :if={!@group_mode}
          phx-click="show-join-groups"
          style="padding: 0.4rem 0.75rem; background: var(--aw-info, #3b82f6); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.9em;"
          title="Join an existing group chat"
        >
          Join Room
        </button>
        <button
          :if={@group_mode}
          phx-click="leave-group"
          style="padding: 0.4rem 0.75rem; background: var(--aw-warning, #f59e0b); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.9em;"
          title="Leave group chat"
        >
          ← Leave Group
        </button>
      </div>
    </div>
    """
  end

  # ── Group Participants Bar (sub-component) ─────────────────────────

  defp group_participants_bar(assigns) do
    ~H"""
    <div
      :if={@group_mode && @group_participants != []}
      style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); background: rgba(74, 158, 255, 0.05);"
    >
      <div style="font-size: 0.8em; color: var(--aw-text-muted, #888); margin-bottom: 0.3rem;">
        👥 Participants ({length(@group_participants)}):
      </div>
      <div style="display: flex; flex-wrap: wrap; gap: 0.4rem;">
        <%= for participant <- @group_participants do %>
          <div style={"padding: 0.2rem 0.5rem; border-radius: 4px; font-size: 0.75em; display: flex; align-items: center; gap: 0.3rem; " <> H.participant_badge_style(participant)}>
            <span>{if participant.type == :agent, do: "🤖", else: "👤"}</span>
            <span>{participant.name}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Right Panel: Goals ─────────────────────────────────────────────

  @doc "Goals tracking panel with progress bars."
  def goals_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-goals"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">🎯 Goals</strong>
        <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
          {if @show_goals, do: "▼", else: "▶"}
        </span>
      </div>
      <div :if={@show_goals} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
        <%!-- Toggle for completed goals --%>
        <div
          :if={@agent != nil}
          style="margin-bottom: 0.4rem; padding: 0.3rem 0.4rem; border-radius: 4px; background: rgba(128,128,128,0.1); display: flex; justify-content: space-between; align-items: center; cursor: pointer;"
          phx-click="toggle-completed-goals"
        >
          <span style="font-size: 0.75em; color: var(--aw-text-muted, #888);">
            Show completed
          </span>
          <span style="font-size: 0.8em;">
            {if @show_completed_goals, do: "✓", else: "○"}
          </span>
        </div>
        <div
          :for={goal <- @agent_goals}
          style={"margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; font-size: 0.8em; " <> H.goal_background_style(goal.status)}
        >
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.2rem;">
            <span style={"flex: 1; " <> H.goal_text_style(goal.status)}>{goal.description}</span>
            <.badge label={to_string(goal.status)} color={H.goal_status_color(goal.status)} />
          </div>
          <div style="background: rgba(128,128,128,0.2); height: 3px; border-radius: 2px; overflow: hidden;">
            <div style={"background: #{H.goal_progress_color(goal.progress)}; height: 100%; width: #{round(goal.progress * 100)}%; transition: width 0.3s ease;"}>
            </div>
          </div>
          <div style="display: flex; justify-content: space-between; margin-top: 2px;">
            <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
              Priority: {goal.priority}
            </span>
            <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
              {round(goal.progress * 100)}%
            </span>
          </div>
          <div
            :if={goal.achieved_at && goal.status == :achieved}
            style="margin-top: 0.2rem; font-size: 0.7em; color: var(--aw-text-muted, #888);"
          >
            ✓ Achieved {H.format_time(goal.achieved_at)}
          </div>
        </div>
        <.empty_state
          :if={@agent_goals == []}
          icon="🎯"
          title="No active goals"
          hint="Goals appear as the agent works"
        />
      </div>
    </div>
    """
  end

  # ── Right Panel: Thinking ──────────────────────────────────────────

  @doc "Extended thinking blocks panel."
  def thinking_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; flex: 1; min-height: 0;">
      <div
        phx-click="toggle-thinking"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center; flex-shrink: 0;"
      >
        <strong style="font-size: 0.85em;">🧠 Thinking</strong>
        <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
          {if @show_thinking, do: "▼", else: "▶"}
        </span>
      </div>
      <div
        :if={@show_thinking}
        id="thinking-container"
        phx-update="stream"
        style="flex: 1; overflow-y: auto; padding: 0.4rem; min-height: 0;"
      >
        <div
          :for={{dom_id, block} <- @streams.thinking}
          id={dom_id}
          style="margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; background: rgba(74, 158, 255, 0.1); font-size: 0.8em;"
        >
          <div style="display: flex; justify-content: space-between; margin-bottom: 0.2rem;">
            <.badge :if={block.has_signature} label="signed" color={:blue} />
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {H.format_time(block.timestamp)}
            </span>
          </div>
          <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
            {WebHelpers.truncate(block.text, 300)}
          </p>
        </div>
      </div>
      <div :if={@show_thinking} style="padding: 0.4rem; text-align: center; flex-shrink: 0;">
        <.empty_state
          :if={stream_empty?(@streams.thinking)}
          icon="🧠"
          title="No thinking yet"
          hint="Thinking blocks appear after queries"
        />
      </div>
    </div>
    """
  end

  # ── Right Panel: Working Thoughts ──────────────────────────────────

  @doc "Working memory thoughts panel."
  def thoughts_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-thoughts"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">💭 Working Thoughts</strong>
        <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
          {if @show_thoughts, do: "▼", else: "▶"}
        </span>
      </div>
      <div :if={@show_thoughts} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
        <div
          :for={thought <- @working_thoughts}
          style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(255, 165, 0, 0.1); font-size: 0.8em;"
        >
          <span>💭</span>
          <span style="color: var(--aw-text-muted, #888); white-space: pre-wrap;">
            {WebHelpers.truncate(thought.content, 200)}
          </span>
        </div>
        <.empty_state
          :if={@working_thoughts == []}
          icon="💭"
          title="Waiting for activity..."
          hint=""
        />
      </div>
    </div>
    """
  end

  # ── Right Panel: Memory Notes ──────────────────────────────────────

  @doc "Recalled memory notes panel."
  def memories_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-memories"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">📝 Memory Notes</strong>
        <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
          {if @show_memories, do: "▼", else: "▶"}
        </span>
      </div>
      <div
        :if={@show_memories}
        id="memories-container"
        phx-update="stream"
        style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
      >
        <div
          :for={{dom_id, memory} <- @streams.memories}
          id={dom_id}
          style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(138, 43, 226, 0.1); font-size: 0.8em;"
        >
          <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.2rem;">
            <span>📝</span>
            <.badge
              :if={memory.score}
              label={"score: #{Float.round(memory.score, 2)}"}
              color={:purple}
            />
          </div>
          <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
            {WebHelpers.truncate(memory.content, 200)}
          </p>
        </div>
      </div>
      <div :if={@show_memories} style="padding: 0.4rem; text-align: center; flex-shrink: 0;">
        <.empty_state
          :if={stream_empty?(@streams.memories)}
          icon="📝"
          title="No memories recalled"
          hint="Relevant memories appear here"
        />
      </div>
    </div>
    """
  end

  # ── Right Panel: Identity Evolution ────────────────────────────────

  @doc "Identity evolution panel with self-insights and changes."
  def identity_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-identity"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">🪞 Identity</strong>
        <div style="display: flex; align-items: center; gap: 0.5rem;">
          <.badge :if={@self_insights != []} label={"#{length(@self_insights)}"} color={:purple} />
          <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
            {if @show_identity, do: "▼", else: "▶"}
          </span>
        </div>
      </div>
      <div :if={@show_identity} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
        <div :if={@self_insights != []} style="margin-bottom: 0.5rem;">
          <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">
            Self Insights
          </div>
          <div
            :for={insight <- Enum.take(@self_insights, 5)}
            style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(168, 85, 247, 0.1); font-size: 0.8em;"
          >
            <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.15rem;">
              <.badge
                :if={insight[:category]}
                label={to_string(insight[:category])}
                color={:purple}
              />
              <.badge
                :if={insight[:confidence]}
                label={"#{round(insight[:confidence] * 100)}%"}
                color={:blue}
              />
            </div>
            <span style="color: var(--aw-text-muted, #888);">
              {WebHelpers.truncate(insight[:content] || "", 150)}
            </span>
          </div>
        </div>
        <div :if={@identity_changes != []} style="margin-bottom: 0.5rem;">
          <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">
            Identity Changes
          </div>
          <div
            :for={change <- Enum.take(@identity_changes, 5)}
            style="margin-bottom: 0.25rem; padding: 0.3rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.8em;"
          >
            <.badge :if={change[:field]} label={to_string(change[:field])} color={:yellow} />
            <.badge
              :if={change[:change_type]}
              label={to_string(change[:change_type])}
              color={:gray}
            />
            <span
              :if={change[:reason]}
              style="color: var(--aw-text-muted, #888); font-size: 0.9em;"
            >
              {WebHelpers.truncate(change[:reason], 100)}
            </span>
          </div>
        </div>
        <div
          :if={@last_consolidation}
          style="font-size: 0.75em; color: var(--aw-text-muted, #888); padding: 0.3rem; background: rgba(128,128,128,0.1); border-radius: 4px;"
        >
          Last consolidation: promoted {Map.get(@last_consolidation, :promoted, 0)}, deferred {Map.get(
            @last_consolidation,
            :deferred,
            0
          )}
        </div>
        <.empty_state
          :if={@self_insights == [] && @identity_changes == [] && @last_consolidation == nil}
          icon="🪞"
          title="No identity data"
          hint="Identity changes appear as the agent evolves"
        />
      </div>
    </div>
    """
  end

  # ── Right Panel: Cognitive Preferences ─────────────────────────────

  @doc "Cognitive preferences and adjustments panel."
  def cognitive_panel(assigns) do
    ~H"""
    <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
      <div
        phx-click="toggle-cognitive"
        style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
      >
        <strong style="font-size: 0.85em;">🧠 Cognitive</strong>
        <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
          {if @show_cognitive, do: "▼", else: "▶"}
        </span>
      </div>
      <div
        :if={@show_cognitive}
        style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
      >
        <div :if={@cognitive_prefs} style="margin-bottom: 0.4rem;">
          <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 0.3rem;">
            <.badge label={"Decay: #{Map.get(@cognitive_prefs, :decay_rate, "—")}"} color={:blue} />
            <.badge
              label={"Threshold: #{Map.get(@cognitive_prefs, :retrieval_threshold, "—")}"}
              color={:green}
            />
            <.badge :if={@pinned_count > 0} label={"Pinned: #{@pinned_count}"} color={:purple} />
          </div>
        </div>
        <div :if={@cognitive_adjustments != []}>
          <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">
            Adjustments
          </div>
          <div
            :for={adj <- Enum.take(@cognitive_adjustments, 5)}
            style="margin-bottom: 0.25rem; padding: 0.3rem; border-radius: 4px; background: rgba(74, 158, 255, 0.05); font-size: 0.8em;"
          >
            <span style="color: var(--aw-text-muted, #888);">{inspect(adj)}</span>
          </div>
        </div>
        <.empty_state
          :if={@cognitive_prefs == nil && @cognitive_adjustments == []}
          icon="🧠"
          title="No cognitive data"
          hint="Preferences appear as the agent adapts"
        />
      </div>
    </div>
    """
  end

  # ── Group Creation Modal ───────────────────────────────────────────

  @doc "Modal dialog for creating a group chat."
  def group_modal(assigns) do
    ~H"""
    <div
      :if={@show_group_modal}
      style="position: fixed; inset: 0; background: rgba(0,0,0,0.7); display: flex; align-items: center; justify-content: center; z-index: 1000;"
      phx-click="cancel-group-modal"
    >
      <div
        style="background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); border-radius: 8px; padding: 1.5rem; max-width: 500px; width: 90%; max-height: 80vh; overflow-y: auto;"
        phx-click="noop"
      >
        <h3 style="margin: 0 0 1rem 0; color: var(--aw-text, #e0e0e0);">
          <%= if @existing_groups != [] do %>
            Join or Create Group Chat
          <% else %>
            👥 Create Group Chat
          <% end %>
        </h3>

        <%= if @existing_groups != [] do %>
          <div style="margin-bottom: 1rem; padding-bottom: 1rem; border-bottom: 1px solid var(--aw-border, #333);">
            <label style="display: block; margin-bottom: 0.5rem; color: var(--aw-text-muted, #888); font-size: 0.9em;">
              Active Rooms
            </label>
            <%= for {group_id, _pid} <- @existing_groups do %>
              <div style="display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem; border-radius: 4px; margin-bottom: 0.25rem; background: rgba(59, 130, 246, 0.1); border: 1px solid rgba(59, 130, 246, 0.3);">
                <span style="color: var(--aw-text, #e0e0e0); flex: 1;">
                  {group_id}
                </span>
                <button
                  phx-click="join-group"
                  phx-value-group-id={group_id}
                  style="padding: 0.3rem 0.75rem; background: var(--aw-info, #3b82f6); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.85em;"
                >
                  Join
                </button>
              </div>
            <% end %>
          </div>
        <% end %>

        <div style="margin-bottom: 1rem;">
          <label style="display: block; margin-bottom: 0.5rem; color: var(--aw-text-muted, #888); font-size: 0.9em;">
            Group Name
          </label>
          <input
            type="text"
            value={@group_name_input}
            phx-keyup="update-group-name"
            phx-debounce="300"
            style="width: 100%; padding: 0.5rem; background: var(--aw-bg-secondary, #222); border: 1px solid var(--aw-border, #333); border-radius: 4px; color: var(--aw-text, #e0e0e0);"
          />
        </div>

        <div style="margin-bottom: 1rem;">
          <label style="display: block; margin-bottom: 0.5rem; color: var(--aw-text-muted, #888); font-size: 0.9em;">
            Select Agents ({map_size(@group_selection)} selected)
          </label>
          <div style="max-height: 300px; overflow-y: auto; border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.5rem;">
            <%= if @available_for_group == [] do %>
              <div style="text-align: center; padding: 2rem; color: var(--aw-text-muted, #888);">
                No agents available. Create an agent first.
              </div>
            <% else %>
              <%= for profile <- @available_for_group do %>
                <div
                  phx-click="toggle-group-agent"
                  phx-value-agent-id={profile.agent_id}
                  style={"display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem; border-radius: 4px; cursor: pointer; margin-bottom: 0.25rem; background: #{if Map.has_key?(@group_selection, profile.agent_id), do: "rgba(74, 158, 255, 0.15)", else: "transparent"};"}
                >
                  <span style={"display: inline-block; width: 18px; height: 18px; border: 2px solid #{if Map.has_key?(@group_selection, profile.agent_id), do: "var(--aw-primary, #60a5fa)", else: "var(--aw-border, #555)"}; border-radius: 3px; text-align: center; line-height: 14px; font-size: 12px; color: var(--aw-primary, #60a5fa);"}>
                    {if Map.has_key?(@group_selection, profile.agent_id), do: "✓", else: ""}
                  </span>
                  <span style="color: var(--aw-text, #e0e0e0);">
                    {profile.display_name || profile.agent_id}
                  </span>
                  <span
                    :if={!Arbor.Agent.running?(profile.agent_id)}
                    style="margin-left: auto; font-size: 0.75em; color: var(--aw-text-muted, #888);"
                  >
                    (stopped)
                  </span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <div style="display: flex; gap: 0.5rem; justify-content: flex-end;">
          <button
            phx-click="cancel-group-modal"
            style="padding: 0.5rem 1rem; background: var(--aw-bg-secondary, #222); border: 1px solid var(--aw-border, #333); border-radius: 4px; color: var(--aw-text, #e0e0e0); cursor: pointer;"
          >
            Cancel
          </button>
          <button
            phx-click="confirm-create-group"
            style="padding: 0.5rem 1rem; background: var(--aw-success, #22c55e); border: none; border-radius: 4px; color: white; cursor: pointer;"
          >
            Create Group
          </button>
        </div>
      </div>
    </div>
    """
  end
end
