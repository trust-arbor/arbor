defmodule Arbor.Trust.EventHandler do
  @moduledoc """
  PubSub event handler for trust-affecting events.

  This GenServer subscribes to system events and translates them
  into trust events for the Trust.Manager. It bridges the gap between
  system activities and trust score updates.

  ## Subscribed Topics

  - `agent:actions` - Agent action success/failure events
  - `self_improvement` - Self-improvement events (improvements, rollbacks)
  - `security:audit` - Security audit events (violations)

  ## Event Translation

  | System Event | Trust Event |
  |--------------|-------------|
  | `{:action_executed, %{status: :success}}` | `:action_success` |
  | `{:action_executed, %{status: :failure}}` | `:action_failure` |
  | `{:self_test_completed, %{result: :passed}}` | `:test_passed` |
  | `{:self_test_completed, %{result: :failed}}` | `:test_failed` |
  | `{:rollback_executed, _}` | `:rollback_executed` |
  | `{:improvement_applied, _}` | `:improvement_applied` |
  | `{:authorization_denied, %{reason: :policy_violation}}` | `:security_violation` |

  ## Usage

  The EventHandler is typically started as part of the trust supervision tree:

      children = [
        Trust.Store,
        Trust.Manager,
        Trust.EventHandler
      ]
  """

  use GenServer

  alias Arbor.Trust.{Config, Manager}

  require Logger

  defstruct [
    :subscriptions,
    :enabled
  ]

  # Client API

  @doc """
  Start the event handler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enable event handling (default).
  """
  @spec enable() :: :ok
  def enable do
    GenServer.call(__MODULE__, :enable)
  end

  @doc """
  Disable event handling (for testing).
  """
  @spec disable() :: :ok
  def disable do
    GenServer.call(__MODULE__, :disable)
  end

  @doc """
  Check if event handling is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)

    if enabled do
      subscribe_to_topics()
    end

    state = %__MODULE__{
      subscriptions: [],
      enabled: enabled
    }

    Logger.info("Trust.EventHandler started", enabled: enabled)

    {:ok, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    unless state.enabled do
      subscribe_to_topics()
    end

    {:reply, :ok, %{state | enabled: true}}
  end

  @impl true
  def handle_call(:disable, _from, state) do
    {:reply, :ok, %{state | enabled: false}}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  # Agent action events (direct format)
  @impl true
  def handle_info({:action_executed, event}, state) do
    if state.enabled do
      handle_action_event(event)
    end

    {:noreply, state}
  end

  # ClusterEvents format: {:cluster_event, event_type, enriched_event}
  @impl true
  def handle_info({:cluster_event, :agent_started, event}, state) do
    if state.enabled do
      handle_action_event(Map.put(event, :status, :success))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:cluster_event, :agent_failed, event}, state) do
    if state.enabled do
      handle_action_event(Map.put(event, :status, :failure))
    end

    {:noreply, state}
  end

  # Self-improvement events (ClusterEvents format: {event_type, enriched_event})
  @impl true
  def handle_info({:self_test_completed, event}, state) do
    if state.enabled do
      handle_test_event(event)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:self_test_passed, event}, state) do
    if state.enabled do
      handle_test_event(Map.put(event, :result, :passed))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:self_test_failed, event}, state) do
    if state.enabled do
      handle_test_event(Map.put(event, :result, :failed))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:rollback_executed, event}, state) do
    if state.enabled do
      handle_rollback_event(event)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:improvement_applied, event}, state) do
    if state.enabled do
      handle_improvement_event(event)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:reload_succeeded, event}, state) do
    if state.enabled do
      handle_improvement_event(Map.put(event, :improvement_type, :reload))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:reload_failed, event}, state) do
    if state.enabled do
      # Reload failure is a form of action failure
      handle_action_event(Map.put(event, :status, :failure))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:compilation_succeeded, event}, state) do
    if state.enabled do
      handle_action_event(Map.put(event, :status, :success))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:compilation_failed, event}, state) do
    if state.enabled do
      handle_action_event(Map.put(event, :status, :failure))
    end

    {:noreply, state}
  end

  # Security audit events
  @impl true
  def handle_info({:authorization_denied, event}, state) do
    if state.enabled do
      handle_authorization_denied_event(event)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:policy_violation, event}, state) do
    if state.enabled do
      handle_policy_violation_event(event)
    end

    {:noreply, state}
  end

  # Catch-all for other messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp subscribe_to_topics do
    topics = [
      "agent_events",
      "self_improvement",
      "security:audit"
    ]

    Enum.each(topics, fn topic ->
      try do
        Phoenix.PubSub.subscribe(Config.pubsub(), topic)
      rescue
        _ -> Logger.debug("Failed to subscribe to #{topic} on #{inspect(Config.pubsub())}")
      end
    end)
  end

  defp handle_action_event(%{agent_id: agent_id, status: :success} = event) do
    metadata = Map.take(event, [:action, :duration_ms, :result])
    Manager.record_trust_event(agent_id, :action_success, metadata)
  end

  defp handle_action_event(%{agent_id: agent_id, status: :failure} = event) do
    metadata = Map.take(event, [:action, :error, :reason])
    Manager.record_trust_event(agent_id, :action_failure, metadata)
  end

  defp handle_action_event(_), do: :ok

  defp handle_test_event(%{agent_id: agent_id, result: :passed} = event) do
    metadata = Map.take(event, [:test_name, :duration_ms])
    Manager.record_trust_event(agent_id, :test_passed, metadata)
  end

  defp handle_test_event(%{agent_id: agent_id, result: :failed} = event) do
    metadata = Map.take(event, [:test_name, :error, :reason])
    Manager.record_trust_event(agent_id, :test_failed, metadata)
  end

  defp handle_test_event(_), do: :ok

  defp handle_rollback_event(%{agent_id: agent_id} = event) do
    metadata = Map.take(event, [:commit, :reason, :reverted_to])
    Manager.record_trust_event(agent_id, :rollback_executed, metadata)
  end

  defp handle_rollback_event(_), do: :ok

  defp handle_improvement_event(%{agent_id: agent_id} = event) do
    metadata = Map.take(event, [:improvement_type, :commit, :changes])
    Manager.record_trust_event(agent_id, :improvement_applied, metadata)
  end

  defp handle_improvement_event(_), do: :ok

  defp handle_authorization_denied_event(
         %{principal_id: agent_id, reason: :policy_violation} = event
       ) do
    metadata = Map.take(event, [:resource_uri, :operation, :policy])
    Manager.record_trust_event(agent_id, :security_violation, metadata)
  end

  defp handle_authorization_denied_event(_), do: :ok

  defp handle_policy_violation_event(%{principal_id: agent_id} = event) do
    metadata = Map.take(event, [:resource_uri, :operation, :violation_type])
    Manager.record_trust_event(agent_id, :security_violation, metadata)
  end

  defp handle_policy_violation_event(_), do: :ok
end
