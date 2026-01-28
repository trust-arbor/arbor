defmodule Arbor.Trust.CapabilitySync do
  @moduledoc """
  Synchronizes capabilities with trust tier changes.

  This module subscribes to trust events and automatically grants or revokes
  capabilities when an agent's trust tier changes. This ensures the capability
  system stays in sync with the progressive trust model.

  ## Behavior

  - On tier promotion: Grant new capabilities for the new tier
  - On tier demotion: Revoke capabilities no longer available at lower tier
  - On trust freeze: Revoke all modifiable capabilities
  - On trust unfreeze: Restore capabilities for current tier

  ## Usage

  The sync handler is started automatically by the Trust.Supervisor.
  It subscribes to `trust:events` PubSub topic and reacts to tier changes.
  """

  use GenServer

  alias Arbor.Trust.{Manager, CapabilityTemplates}

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
  Manually sync capabilities for an agent based on their current trust tier.

  This is useful for initial setup or recovery scenarios.
  """
  @spec sync_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def sync_capabilities(agent_id) do
    GenServer.call(__MODULE__, {:sync_capabilities, agent_id})
  end

  @doc """
  Get capabilities an agent should have based on their trust tier.
  """
  @spec expected_capabilities(String.t()) :: {:ok, [map()]} | {:error, term()}
  def expected_capabilities(agent_id) do
    case Manager.get_trust_profile(agent_id) do
      {:ok, profile} ->
        caps = CapabilityTemplates.generate_capabilities(agent_id, profile.tier)
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
  def handle_call({:sync_capabilities, agent_id}, _from, state) do
    result = do_sync_capabilities(agent_id)
    {:reply, result, state}
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
          Logger.warning("CapabilitySync: Failed to handle #{event_type} for #{agent_id}: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp handle_trust_event(agent_id, event_type, metadata) do
    case event_type do
      :tier_changed ->
        old_tier = Map.get(metadata, :old_tier)
        new_tier = Map.get(metadata, :new_tier)
        handle_tier_change(agent_id, old_tier, new_tier)

      :trust_frozen ->
        handle_trust_frozen(agent_id, metadata)

      :trust_unfrozen ->
        handle_trust_unfrozen(agent_id)

      :profile_created ->
        # Grant initial capabilities for new profiles
        grant_tier_capabilities(agent_id, :untrusted)

      _ ->
        # Check if tier changed as a side effect
        check_tier_change(agent_id, metadata)
    end
  end

  defp check_tier_change(agent_id, metadata) do
    old_tier = Map.get(metadata, :previous_tier)
    new_tier = Map.get(metadata, :new_tier)

    if old_tier && new_tier && old_tier != new_tier do
      handle_tier_change(agent_id, old_tier, new_tier)
    end
  end

  defp handle_tier_change(agent_id, old_tier, new_tier) do
    Logger.info("Syncing capabilities for tier change",
      agent_id: agent_id,
      old_tier: old_tier,
      new_tier: new_tier
    )

    cond do
      tier_higher?(new_tier, old_tier) ->
        # Promotion - grant new capabilities
        grant_tier_upgrade_capabilities(agent_id, old_tier, new_tier)

      tier_higher?(old_tier, new_tier) ->
        # Demotion - revoke lost capabilities
        revoke_tier_downgrade_capabilities(agent_id, old_tier, new_tier)

      true ->
        :ok
    end
  end

  defp handle_trust_frozen(agent_id, metadata) do
    Logger.warning("Revoking capabilities due to trust freeze",
      agent_id: agent_id,
      reason: Map.get(metadata, :reason)
    )

    # Revoke all capabilities except read-only
    revoke_modifiable_capabilities(agent_id)
  end

  defp handle_trust_unfrozen(agent_id) do
    Logger.info("Restoring capabilities after trust unfreeze",
      agent_id: agent_id
    )

    # Restore capabilities based on current tier
    do_sync_capabilities(agent_id)
  end

  defp do_sync_capabilities(agent_id) do
    case Manager.get_trust_profile(agent_id) do
      {:ok, profile} ->
        if profile.frozen do
          # Only grant read capabilities if frozen
          grant_tier_capabilities(agent_id, :untrusted)
        else
          # Grant full tier capabilities
          grant_tier_capabilities(agent_id, profile.tier)
        end

      {:error, :not_found} ->
        # Create profile first
        case Manager.create_trust_profile(agent_id) do
          {:ok, profile} ->
            grant_tier_capabilities(agent_id, profile.tier)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp grant_tier_capabilities(agent_id, tier) do
    principal_id = ensure_agent_prefix(agent_id)
    templates = CapabilityTemplates.capabilities_for_tier(tier)

    results =
      Enum.map(templates, fn template ->
        resource_uri = expand_resource_uri(template.resource_uri, agent_id)

        # Check if capability already exists
        case find_existing_capability(principal_id, resource_uri) do
          {:ok, _cap} ->
            {:already_exists, resource_uri}

          {:error, :not_found} ->
            # Grant new capability via Security facade
            case Arbor.Security.grant(
                   principal: principal_id,
                   resource: resource_uri,
                   constraints: template.constraints,
                   metadata: %{
                     source: :trust_tier,
                     tier: tier,
                     granter_id: "trust_system",
                     synced_at: DateTime.utc_now()
                   }
                 ) do
              {:ok, cap} ->
                {:granted, cap.id}

              {:error, reason} ->
                {:error, resource_uri, reason}
            end
        end
      end)

    granted = Enum.count(results, fn r -> match?({:granted, _}, r) end)
    existing = Enum.count(results, fn r -> match?({:already_exists, _}, r) end)
    errors = Enum.count(results, fn r -> match?({:error, _, _}, r) end)

    Logger.info("Capability sync complete",
      agent_id: agent_id,
      tier: tier,
      granted: granted,
      existing: existing,
      errors: errors
    )

    {:ok, %{granted: granted, existing: existing, errors: errors}}
  end

  defp grant_tier_upgrade_capabilities(agent_id, old_tier, new_tier) do
    principal_id = ensure_agent_prefix(agent_id)
    gained = CapabilityTemplates.capabilities_gained(old_tier, new_tier)

    Enum.each(gained, fn template ->
      resource_uri = expand_resource_uri(template.resource_uri, agent_id)

      case Arbor.Security.grant(
             principal: principal_id,
             resource: resource_uri,
             constraints: template.constraints,
             metadata: %{
               source: :tier_promotion,
               old_tier: old_tier,
               new_tier: new_tier,
               granter_id: "trust_system",
               synced_at: DateTime.utc_now()
             }
           ) do
        {:ok, cap} ->
          Logger.debug("Granted capability on promotion",
            agent_id: agent_id,
            capability_id: cap.id,
            resource_uri: resource_uri
          )

        {:error, reason} ->
          Logger.warning("Failed to grant capability on promotion",
            agent_id: agent_id,
            resource_uri: resource_uri,
            reason: reason
          )
      end
    end)
  end

  defp revoke_tier_downgrade_capabilities(agent_id, old_tier, new_tier) do
    principal_id = ensure_agent_prefix(agent_id)
    lost = CapabilityTemplates.capabilities_lost(old_tier, new_tier)

    lost_uris = Enum.map(lost, fn t -> expand_resource_uri(t.resource_uri, agent_id) end)

    # Find and revoke capabilities that are no longer allowed
    case Arbor.Security.list_capabilities(principal_id) do
      {:ok, capabilities} ->
        Enum.each(capabilities, fn cap ->
          if Enum.any?(lost_uris, fn uri -> capability_matches_uri?(cap.resource_uri, uri) end) do
            case Arbor.Security.revoke(cap.id) do
              :ok ->
                Logger.debug("Revoked capability on demotion",
                  agent_id: agent_id,
                  capability_id: cap.id
                )

              {:error, reason} ->
                Logger.warning("Failed to revoke capability on demotion",
                  agent_id: agent_id,
                  capability_id: cap.id,
                  reason: reason
                )
            end
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to list capabilities for demotion sync",
          agent_id: agent_id,
          reason: reason
        )
    end
  end

  defp revoke_modifiable_capabilities(agent_id) do
    principal_id = ensure_agent_prefix(agent_id)

    # Get the read-only capabilities (untrusted tier)
    read_only_uris =
      CapabilityTemplates.capabilities_for_tier(:untrusted)
      |> Enum.map(fn t -> expand_resource_uri(t.resource_uri, agent_id) end)
      |> MapSet.new()

    case Arbor.Security.list_capabilities(principal_id) do
      {:ok, capabilities} ->
        Enum.each(capabilities, fn cap ->
          # Revoke if not in the read-only set
          unless MapSet.member?(read_only_uris, cap.resource_uri) do
            Arbor.Security.revoke(cap.id)
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to list capabilities for freeze",
          agent_id: agent_id,
          reason: reason
        )
    end
  end

  defp find_existing_capability(principal_id, resource_uri) do
    case Arbor.Security.list_capabilities(principal_id) do
      {:ok, capabilities} ->
        case Enum.find(capabilities, fn cap ->
               capability_matches_uri?(cap.resource_uri, resource_uri)
             end) do
          nil -> {:error, :not_found}
          cap -> {:ok, cap}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_resource_uri(template_uri, agent_id) do
    String.replace(template_uri, "/self/", "/#{ensure_agent_prefix(agent_id)}/")
  end

  defp capability_matches_uri?(cap_uri, target_uri) do
    cap_uri == target_uri
  end

  defp tier_higher?(tier1, tier2) do
    tier_order = %{untrusted: 0, probationary: 1, trusted: 2, veteran: 3, autonomous: 4}
    Map.get(tier_order, tier1, -1) > Map.get(tier_order, tier2, -1)
  end

  # Attempt to subscribe to PubSub using configured module
  defp attempt_subscribe do
    pubsub = Arbor.Trust.Config.pubsub()

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
