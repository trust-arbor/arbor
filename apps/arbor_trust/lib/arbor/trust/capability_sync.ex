defmodule Arbor.Trust.CapabilitySync do
  @moduledoc """
  Synchronizes capabilities with trust profile lifecycle events.

  Capability changes require a caller-owned Security signing authority. Trust
  events remain observability messages and never mint or revoke authority.

  ## Behavior

  - Explicit authenticated sync: Grant the universal baseline capabilities
  - Trust lifecycle events: Observe only; they carry no authenticated actor

  ## Usage

  The sync handler is started automatically by the Trust.Supervisor.
  It subscribes to the `trust:events` PubSub topic.
  """

  use GenServer

  alias Arbor.Trust.{Config, Manager}

  require Logger

  defstruct [:enabled, :subscribed, :retry_count]

  # Maximum retry attempts for PubSub subscription
  @max_retries 10
  # Base delay for exponential backoff (ms)
  @base_delay 100

  # Client API

  @doc """
  Start the capability sync handler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually sync the universal baseline capabilities for an agent.

  This is useful for initial setup or recovery scenarios. The caller must pass
  its owner-bound Security signing authority in `:actor_authority`.
  """
  @spec sync_capabilities(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_capabilities(agent_id, opts \\ []) do
    case Keyword.fetch(opts, :actor_authority) do
      {:ok, authority} when not is_nil(authority) ->
        # Signing authorities are bound to the caller PID. Execute the sync in
        # this process rather than transferring bearer authority to the
        # long-lived CapabilitySync server.
        do_sync_capabilities(agent_id, authority)

      _ ->
        {:error, :capability_mutation_unauthorized}
    end
  end

  @doc """
  Get the universal baseline capabilities an agent should have.
  """
  @spec expected_capabilities(String.t()) :: {:ok, [map()]} | {:error, term()}
  def expected_capabilities(agent_id) do
    case Manager.get_trust_profile(agent_id) do
      {:ok, _profile} ->
        caps = Config.generate_capabilities(agent_id)
        {:ok, caps}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)
    state = %__MODULE__{enabled: enabled, subscribed: false, retry_count: 0}

    if enabled do
      # Use handle_continue to attempt subscription after init completes
      # This allows the GenServer to fully start before we try to subscribe
      {:ok, state, {:continue, :subscribe_to_pubsub}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:subscribe_to_pubsub, state) do
    case attempt_subscribe() do
      :ok ->
        Logger.info("CapabilitySync subscribed to trust events")
        {:noreply, %{state | subscribed: true, retry_count: 0}}

      :error ->
        # Schedule retry with exponential backoff
        schedule_subscription_retry(state.retry_count)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:sync_capabilities, _agent_id}, _from, state) do
    {:reply, {:error, :capability_mutation_unauthorized}, state}
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    if state.retry_count < @max_retries do
      case attempt_subscribe() do
        :ok ->
          Logger.info(
            "CapabilitySync subscribed to trust events after #{state.retry_count + 1} retries"
          )

          {:noreply, %{state | subscribed: true, retry_count: 0}}

        :error ->
          new_count = state.retry_count + 1
          schedule_subscription_retry(new_count)
          {:noreply, %{state | retry_count: new_count}}
      end
    else
      Logger.warning(
        "CapabilitySync: Failed to subscribe after #{@max_retries} retries, running in standalone mode"
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:trust_event, agent_id, event_type, metadata}, state) do
    if state.enabled do
      try do
        handle_trust_event(agent_id, event_type, metadata)
      catch
        :exit, reason ->
          Logger.warning(
            "CapabilitySync: Failed to handle #{event_type} for #{agent_id}: #{inspect(reason)}"
          )
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp handle_trust_event(agent_id, event_type, _metadata) do
    if event_type in [:trust_frozen, :trust_unfrozen, :profile_created] do
      Logger.debug("CapabilitySync observed non-authoritative trust event",
        agent_id: agent_id,
        event_type: event_type
      )
    end

    :ok
  end

  defp do_sync_capabilities(agent_id, actor_authority) do
    case Manager.get_trust_profile(agent_id) do
      {:ok, _profile} ->
        grant_base_capabilities(agent_id, actor_authority)

      {:error, :not_found} ->
        # Create profile first
        case Manager.create_trust_profile(agent_id) do
          {:ok, _profile} ->
            grant_base_capabilities(agent_id, actor_authority)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp grant_base_capabilities(agent_id, actor_authority) do
    principal_id = ensure_agent_prefix(agent_id)
    templates = Config.base_capabilities()

    results =
      Enum.map(templates, fn template ->
        resource_uri = expand_resource_uri(template.resource_uri, agent_id)
        grant_or_skip_capability(principal_id, resource_uri, template, actor_authority)
      end)

    granted = Enum.count(results, fn r -> match?({:granted, _}, r) end)
    existing = Enum.count(results, fn r -> match?({:already_exists, _}, r) end)
    errors = Enum.count(results, fn r -> match?({:error, _, _}, r) end)

    Logger.info("Baseline capability sync complete",
      agent_id: agent_id,
      granted: granted,
      existing: existing,
      errors: errors
    )

    {:ok, %{granted: granted, existing: existing, errors: errors}}
  end

  defp grant_or_skip_capability(principal_id, resource_uri, template, actor_authority) do
    case find_existing_capability(principal_id, resource_uri) do
      {:ok, _cap} ->
        {:already_exists, resource_uri}

      {:error, :not_found} ->
        do_grant_capability(principal_id, resource_uri, template, actor_authority)
    end
  end

  defp do_grant_capability(principal_id, resource_uri, template, actor_authority) do
    case Arbor.Security.grant(
           principal: principal_id,
           resource: resource_uri,
           constraints: template.constraints,
           metadata: %{
             source: :trust_baseline,
             synced_at: DateTime.utc_now()
           },
           actor_authority: actor_authority
         ) do
      {:ok, cap} ->
        {:granted, cap.id}

      {:error, reason} ->
        {:error, resource_uri, reason}
    end
  end

  defp find_existing_capability(principal_id, resource_uri) do
    case Arbor.Security.list_capabilities(principal_id) do
      {:ok, capabilities} ->
        find_matching_capability(capabilities, resource_uri)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_matching_capability(capabilities, resource_uri) do
    case Enum.find(capabilities, fn cap ->
           capability_matches_uri?(cap.resource_uri, resource_uri)
         end) do
      nil -> {:error, :not_found}
      cap -> {:ok, cap}
    end
  end

  defp expand_resource_uri(template_uri, agent_id) do
    String.replace(template_uri, "/self/", "/#{ensure_agent_prefix(agent_id)}/")
  end

  defp capability_matches_uri?(cap_uri, target_uri) do
    cap_uri == target_uri
  end

  # Attempt to subscribe to PubSub using configured module
  defp attempt_subscribe do
    pubsub = Config.pubsub()

    try do
      case Process.whereis(pubsub) do
        nil ->
          Logger.debug("CapabilitySync: PubSub not available yet")
          :error

        _pid ->
          Phoenix.PubSub.subscribe(pubsub, "trust:events")
          :ok
      end
    rescue
      e ->
        Logger.debug("CapabilitySync: PubSub subscription failed: #{inspect(e)}")
        :error
    end
  end

  # Schedule a retry with exponential backoff
  defp schedule_subscription_retry(retry_count) do
    delay = (@base_delay * :math.pow(2, retry_count)) |> round() |> min(5000)
    Logger.debug("CapabilitySync: Scheduling retry #{retry_count + 1} in #{delay}ms")
    Process.send_after(self(), :retry_subscribe, delay)
  end

  defp ensure_agent_prefix(agent_id) do
    if String.starts_with?(agent_id, "agent_") do
      agent_id
    else
      "agent_#{agent_id}"
    end
  end
end
