defmodule Arbor.Comms.InteractionRouter do
  @moduledoc """
  Routes agent-to-human interaction requests to whichever channel the
  human is currently active on, and routes responses back to the
  waiting agent.

  Multi-node correct from Phase 1:

  - **Outstanding state** is serialized by the interaction's origin-node
    authority. Phoenix.Tracker mirrors discovery across the cluster, so a
    channel adapter on Node B can route a response by `request_id` without
    holding a PID across nodes.

  - **Response delivery** broadcasts on the per-agent PubSub topic
    `"interaction:agent:" <> agent_id`. The agent's session/executor
    subscribes at startup. PubSub is cluster-aware, so the responding
    adapter doesn't need to know which node hosts the agent.

  - **Presence** uses `Phoenix.Tracker` for cluster-wide channel
    availability per user.

  - **Audit** emits Arbor signals for every request/response. When the
    interaction carries a nonblank `task_id` in metadata/provenance,
    that value is the signal `correlation_id` so task-scoped consumers
    (e.g. coding-benchmark approval accounting) can aggregate history.
    Signal data stays bounded lifecycle observability — never execution control.

  ## Phase 1 scope

  Only the dashboard adapter is wired. Signal/Telegram/Discord/voice
  are additive future channels — no router changes needed when they
  land.
  """

  require Logger

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.PresenceTracker
  alias Arbor.Contracts.Comms.Interaction

  @typedoc """
  Adapter registry: a map of `channel_atom => module`. Phase 1 only
  populates `:dashboard`; the router falls back to "no adapter, queue
  for later" when no presence is available or no adapter is
  registered for the available channel.

  Configured via Application env:

      config :arbor_comms, :interaction_adapters, %{
        dashboard: Arbor.Dashboard.InteractionAdapter
      }
  """
  @type adapter_map :: %{atom() => module()}

  ## Public API

  @doc """
  Submit a new interaction request. Non-blocking. Returns immediately
  with the `request_id`; the response arrives later on
  `Interaction.response_topic_for_agent(agent_id)`.

  ## Options

  - `:adapter_map` — override the configured adapter map (test-only)
  """
  @spec request(map() | Interaction.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def request(attrs_or_interaction, opts \\ [])

  def request(%Interaction{} = interaction, opts) do
    do_request(interaction, opts)
  end

  def request(attrs, opts) when is_map(attrs) or is_list(attrs) do
    case Interaction.new(attrs) do
      {:ok, interaction} -> do_request(interaction, opts)
      {:error, _} = err -> err
    end
  end

  @doc """
  Submit a response to a previously-requested interaction. Called by
  channel adapters when they recognize an incoming message as a
  response.

  Routes the response back to the waiting agent via PubSub on the
  interaction's `response_topic`. Cluster-aware — works regardless of
  which node hosts the waiting agent.

  The answer is also retained in the authority process
  (`get_response/1`) so waiters that subscribe after publication still
  observe the decision without sleeps or lost-message races. This lookup is
  intentionally in-memory and does not survive authority or node restart.
  """
  @spec respond(String.t(), Interaction.response(), map()) :: :ok | {:error, term()}
  def respond(request_id, response, metadata \\ %{}) when is_binary(request_id) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    case InteractionRegistry.resolve(request_id, response: response, metadata: metadata) do
      {:ok, interaction} ->
        emit_signal(:resolved, interaction, %{response: response, metadata: metadata})
        broadcast_response(interaction, response, metadata)
        :ok

      {:error, {:already_terminal, status}} ->
        Logger.debug("[InteractionRouter] respond/3: request_id #{request_id} already #{status}")

        {:error, {:already_terminal, status}}

      :not_found ->
        Logger.debug(
          "[InteractionRouter] respond/3: unknown request_id #{request_id} (already resolved or expired?)"
        )

        {:error, :not_found}

      {:error, reason} ->
        Logger.warning(
          "[InteractionRouter] respond/3: request_id #{request_id} transition failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Abandon a pending interaction with an explicit lifecycle reason.

  Abandonment is idempotent. If a response already won the terminal
  transition, returns an `:already_terminal` error and leaves that response
  unchanged.
  """
  @spec abandon(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  def abandon(request_id, reason)
      when is_binary(request_id) and (is_atom(reason) or is_binary(reason)) do
    case InteractionRegistry.abandon(request_id, reason) do
      {:ok, %Interaction{} = interaction} ->
        emit_signal(:abandoned, interaction, %{})
        :ok

      {:ok, :already_abandoned} ->
        :ok

      {:error, _reason} = error ->
        error

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  In-memory public lookup for a responded interaction.

  Returns `{:ok, %{response: term(), metadata: map()}}` when the answer is
  still within the registry TTL, otherwise `:not_found`.
  """
  @spec get_response(String.t()) ::
          {:ok, %{response: term(), metadata: map()}} | :not_found
  def get_response(request_id) when is_binary(request_id) do
    case InteractionRegistry.get_resolved(request_id) do
      {:ok, %{response: response, metadata: metadata}} ->
        {:ok, %{response: response, metadata: metadata || %{}}}

      :not_found ->
        :not_found
    end
  end

  @doc """
  Wait for an interaction response without the
  visible-request-before-subscribe race.

  Subscribes to the agent response topic first, then captures and arms the
  origin authority before blocking on PubSub. Always unsubscribes.

  Options:
    * `:timeout` — milliseconds (default 60_000)
    * `:pubsub` — PubSub server (default `Arbor.Comms.PubSub`)
  """
  @spec await_response(String.t(), String.t(), keyword()) ::
          {:ok, term(), map()} | {:error, :timeout | term()}
  def await_response(request_id, agent_id, opts \\ [])
      when is_binary(request_id) and is_binary(agent_id) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    pubsub = Keyword.get(opts, :pubsub, Arbor.Comms.PubSub)
    topic = Interaction.response_topic_for_agent(agent_id)

    # Subscribe before capturing and arming the origin authority so a
    # concurrent response cannot land in the gap before receive/after.
    :ok = Phoenix.PubSub.subscribe(pubsub, topic)

    try do
      case InteractionRegistry.capture_timeout_authority(request_id, timeout) do
        {:ok, _capture, {:terminal, terminal}} ->
          timeout_terminal_result(terminal)

        {:ok, capture, :armed} ->
          receive do
            {:interaction_response, %{request_id: ^request_id, response: response} = payload} ->
              metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
              {:ok, response, metadata}
          after
            timeout ->
              finalize_timeout(capture, request_id)
          end

        :not_found ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Phoenix.PubSub.unsubscribe(pubsub, topic)
    end
  end

  @doc """
  List pending interactions (delegates to the registry). Useful for
  dashboard summaries and audit.
  """
  @spec pending() :: [Interaction.t()]
  def pending, do: InteractionRegistry.list_pending()

  defp finalize_timeout(capture, request_id) do
    case InteractionRegistry.finalize_timeout(capture, request_id) do
      {:ok, terminal} -> timeout_terminal_result(terminal)
      _ -> {:error, :timeout}
    end
  end

  defp timeout_terminal_result(%{status: :responded, response: response, metadata: metadata}) do
    {:ok, response, metadata || %{}}
  end

  defp timeout_terminal_result(_terminal), do: {:error, :timeout}

  ## Private — request flow

  defp do_request(%Interaction{} = interaction, opts) do
    adapter_map = Keyword.get(opts, :adapter_map, configured_adapters())

    with {:ok, _} <- InteractionRegistry.put(interaction),
         :ok <- dispatch(interaction, adapter_map) do
      emit_signal(:requested, interaction, %{})
      {:ok, interaction.request_id}
    else
      :no_channel ->
        # Already persisted; queue for later when presence becomes
        # available. Adapters that come online can pick up pending
        # interactions targeted at their channel via list_pending.
        emit_signal(:queued, interaction, %{})
        {:ok, interaction.request_id}

      {:error, _} = err ->
        err
    end
  end

  defp dispatch(%Interaction{user_id: user_id} = interaction, adapter_map) do
    case PresenceTracker.primary_channel(user_id) do
      {:ok, channel, meta} ->
        case Map.get(adapter_map, channel) do
          nil ->
            Logger.info(
              "[InteractionRouter] no adapter for channel #{inspect(channel)}; queueing #{interaction.request_id}"
            )

            :no_channel

          adapter when is_atom(adapter) ->
            case safe_send(adapter, meta, interaction) do
              :ok ->
                :ok

              {:error, reason} ->
                # Adapter failed but the interaction IS persisted.
                # Treat as queued — log the failure and return :ok so
                # the caller (agent) gets a non-blocking result.
                # Future adapter health / retry can pick this up.
                Logger.warning(
                  "[InteractionRouter] adapter failed for #{interaction.request_id}: " <>
                    "#{inspect(reason)} — interaction queued"
                )

                :no_channel
            end
        end

      :no_presence ->
        Logger.info(
          "[InteractionRouter] no active presence for user #{user_id}; queueing #{interaction.request_id}"
        )

        :no_channel
    end
  end

  defp safe_send(adapter, channel_meta, interaction) do
    adapter.send_interaction(channel_meta, interaction)
  rescue
    e ->
      Logger.warning(
        "[InteractionRouter] adapter #{inspect(adapter)} crashed: #{Exception.message(e)}"
      )

      {:error, {:adapter_crash, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("[InteractionRouter] adapter #{inspect(adapter)} exited: #{inspect(reason)}")
      {:error, {:adapter_exit, reason}}
  end

  ## Private — response flow

  defp broadcast_response(%Interaction{response_topic: topic} = interaction, response, metadata) do
    payload =
      {:interaction_response,
       %{
         request_id: interaction.request_id,
         response: response,
         metadata: metadata,
         resolved_at: DateTime.utc_now()
       }}

    pubsub = current_pubsub()

    try do
      Phoenix.PubSub.broadcast(pubsub, topic, payload)
    rescue
      e ->
        Logger.warning(
          "[InteractionRouter] broadcast failed for #{interaction.request_id}: #{Exception.message(e)}"
        )
    catch
      :exit, reason ->
        Logger.warning(
          "[InteractionRouter] broadcast exited for #{interaction.request_id}: #{inspect(reason)}"
        )
    end
  end

  # HITL traffic is pinned to Arbor.Comms.PubSub — started by
  # Arbor.Comms.Application, always reachable when arbor_comms is up.
  # See Arbor.Comms.Application for the rationale (the prior discovery
  # cond returned nil at supervisor-init time because no other PubSub
  # existed yet).
  defp current_pubsub, do: Arbor.Comms.PubSub

  defp configured_adapters do
    Application.get_env(:arbor_comms, :interaction_adapters, %{})
  end

  ## Signal emission for audit

  # Observability only — never gates execution. Payload is bounded lifecycle
  # data; do not project approval_context, target, params, previews, or notes.
  @max_task_id_bytes 256

  defp emit_signal(event, %Interaction{} = interaction, extra) do
    data =
      %{
        request_id: interaction.request_id,
        kind: interaction.kind,
        agent_id: interaction.agent_id,
        user_id: interaction.user_id,
        urgency: interaction.urgency,
        event_sequence: System.unique_integer([:monotonic, :positive])
      }
      |> Map.merge(safe_signal_extra(interaction.kind, extra))

    opts =
      case interaction_task_id(interaction) do
        nil -> []
        task_id -> [correlation_id: task_id]
      end

    try do
      # Approval accounting queries these events as soon as the owner action
      # returns. Store synchronously so request/response wake-up cannot race the
      # audit observation; subscriber delivery remains asynchronous.
      Arbor.Signals.emit(:interaction, event, data, Keyword.put(opts, :async, false))
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp safe_signal_extra(:approval, %{response: response} = extra) when is_map(extra) do
    base =
      case response do
        value when value in [:approved, "approved"] -> %{response: :approved}
        value when value in [:rejected, "rejected"] -> %{response: :rejected}
        _other -> %{}
      end

    case rework_flag(Map.get(extra, :metadata) || Map.get(extra, "metadata")) do
      nil -> base
      rework? -> Map.put(base, :rework, rework?)
    end
  end

  defp safe_signal_extra(_kind, _extra), do: %{}

  defp rework_flag(metadata) when is_map(metadata) do
    case map_get(metadata, :rework) || map_get(metadata, :decision) do
      true -> true
      :rework -> true
      "rework" -> true
      _other -> nil
    end
  end

  defp rework_flag(_), do: nil

  defp interaction_task_id(%Interaction{metadata: metadata}) when is_map(metadata) do
    # Prefer provenance (bounded approval provenance), then approval_context,
    # then a top-level task_id if present. Atom and string keys accepted.
    candidates = [
      nested_task_id(map_get(metadata, :provenance)),
      nested_task_id(map_get(metadata, :approval_context)),
      map_get(metadata, :task_id)
    ]

    Enum.find_value(candidates, &bounded_task_id/1)
  end

  defp interaction_task_id(_), do: nil

  defp nested_task_id(map), do: nested_task_id(map, 0)

  defp nested_task_id(map, depth) when is_map(map) and depth < 2,
    do: map_get(map, :task_id) || nested_task_id(map_get(map, :provenance), depth + 1)

  defp nested_task_id(_map, _depth), do: nil

  defp bounded_task_id(value) when is_binary(value) do
    if value != "" and byte_size(value) <= @max_task_id_bytes and String.valid?(value) and
         value == String.trim(value) and not String.contains?(value, <<0>>),
       do: value,
       else: nil
  end

  defp bounded_task_id(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(_map, _key), do: nil
end
